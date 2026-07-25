#!/usr/bin/env python3
"""
Parse MongoDB LOGV2 structured JSON logs and merge with client-side traces
to produce complete NDJSON trace files matching v3 Trace.tla event schema.

v3 spec models decision logic & resource contention, NOT protocol messages.
Coordinator events mapped:
  22467: "Going to write decision"         -> CoordDecideCommit / CoordDecideAbort
  22469: "Wrote decision"                  -> CoordPersistAndSend
  22481: "Coordinator going to send..."    -> CoordSendDecisionToShard (per shard)
  22474: "Deleted coordinator doc"         -> CoordFinish

Participant events from transaction summary (log ID 51802) are NOT emitted
as separate trace events in v3 — shard state transitions are modeled atomically
within CoordDecideCommit (prepare) and CoordSendDecisionToShard (commit/abort).

Session ID format in MongoDB 8.x logs:
  attr.sessionId = {"id": {"$uuid": "..."}, "uid": {...}}
  attr.txnNumberAndRetryCounter = {"txnNumber": N, "txnRetryCounter": 0}
"""

import json
import os
import sys
from datetime import datetime, timezone


# Shard mapping
SHARD_MAP = {"shard1RS": "s1", "shard2RS": "s2"}


def map_shard(name):
    for k, v in SHARD_MAP.items():
        if k in str(name):
            return v
    return str(name)


def parse_iso_to_ns(iso_str):
    """Parse MongoDB ISO 8601 timestamp to epoch nanoseconds."""
    try:
        iso_str = iso_str.replace("Z", "+00:00")
        dt = datetime.fromisoformat(iso_str)
        return int(dt.timestamp() * 1e9)
    except (ValueError, TypeError):
        return int(datetime.now(timezone.utc).timestamp() * 1e9)


def extract_lsid_txn(attr):
    """Extract (lsid_uuid_hex, txnNumber) from LOGV2 attr field."""
    lsid = None
    txn_num = None

    # Try sessionId (MongoDB 8.x coordinator logs)
    if "sessionId" in attr:
        sid = attr["sessionId"]
        if isinstance(sid, dict):
            uid = sid.get("id", sid.get("uuid", ""))
            if isinstance(uid, dict) and "$uuid" in uid:
                lsid = uid["$uuid"].replace("-", "")
            elif isinstance(uid, str):
                lsid = uid.replace("-", "")

    # Fallback: try lsid
    if lsid is None and "lsid" in attr:
        lsid_obj = attr["lsid"]
        if isinstance(lsid_obj, dict):
            uid = lsid_obj.get("id", lsid_obj.get("uuid", ""))
            if isinstance(uid, dict) and "$uuid" in uid:
                lsid = uid["$uuid"].replace("-", "")
            elif isinstance(uid, str):
                lsid = uid.replace("-", "")

    # Try txnNumberAndRetryCounter (MongoDB 8.x)
    if "txnNumberAndRetryCounter" in attr:
        tnrc = attr["txnNumberAndRetryCounter"]
        if isinstance(tnrc, dict):
            tn = tnrc.get("txnNumber")
            if isinstance(tn, dict) and "$numberLong" in tn:
                txn_num = int(tn["$numberLong"])
            elif tn is not None:
                txn_num = int(tn)

    # Fallback: try txnNumber
    if txn_num is None and "txnNumber" in attr:
        tn = attr["txnNumber"]
        if isinstance(tn, dict) and "$numberLong" in tn:
            txn_num = int(tn["$numberLong"])
        elif tn is not None:
            txn_num = int(tn)

    # Try nested in "parameters" or "transaction" (51802 summary)
    for wrapper_key in ("parameters", "transaction"):
        if wrapper_key in attr and isinstance(attr[wrapper_key], dict):
            sub = attr[wrapper_key]
            if lsid is None:
                for lsid_key in ("sessionId", "lsid"):
                    if lsid_key in sub:
                        lsid_obj = sub[lsid_key]
                        if isinstance(lsid_obj, dict):
                            uid = lsid_obj.get("id", lsid_obj.get("uuid", ""))
                            if isinstance(uid, dict) and "$uuid" in uid:
                                lsid = uid["$uuid"].replace("-", "")
                            elif isinstance(uid, str):
                                lsid = uid.replace("-", "")
                        break
            if txn_num is None:
                for tn_key in ("txnNumberAndRetryCounter", "txnNumber"):
                    if tn_key in sub:
                        tn = sub[tn_key]
                        if isinstance(tn, dict) and "txnNumber" in tn:
                            txn_num = int(tn["txnNumber"])
                        elif isinstance(tn, dict) and "$numberLong" in tn:
                            txn_num = int(tn["$numberLong"])
                        elif tn is not None:
                            txn_num = int(tn)
                        break

    return lsid, txn_num


def make_event(ts_ns, event_name, txn_tla_id, extra=None):
    """Create a trace event dict matching v3 spec envelope."""
    ev = {
        "tag": "trace",
        "ts": ts_ns,
        "event": event_name,
        "txn": txn_tla_id,
    }
    if extra:
        ev.update(extra)
    return ev


def parse_shard_logs(log_file, shard_name, session_to_txn_map, scenario_commit_types):
    """Parse a single shard's mongod log file for v3 coordinator events.

    Args:
        log_file: path to shard log file
        shard_name: MongoDB shard name (e.g., "shard1RS")
        session_to_txn_map: {(lsid_hex, txnNumber): tla_txn_id}
        scenario_commit_types: {tla_txn_id: commit_type} for inferring shard state

    Returns:
        list of trace event dicts
    """
    tla_shard = map_shard(shard_name)
    events = []

    # Track decision per txn for CoordSendDecisionToShard
    txn_decisions = {}  # txn_tla_id -> "commit" | "abort"

    if not os.path.exists(log_file):
        print(f"  WARNING: Log file not found: {log_file}")
        return events

    with open(log_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue

            component = entry.get("c", "")
            if component != "TXN":
                continue

            log_id = entry.get("id")
            attr = entry.get("attr", {})
            ts_str = entry.get("t", {}).get("$date", "")
            ts_ns = parse_iso_to_ns(ts_str)

            lsid, txn_num = extract_lsid_txn(attr)
            if lsid is None or txn_num is None:
                continue

            txn_key = (lsid, txn_num)
            txn_tla = session_to_txn_map.get(txn_key)
            if txn_tla is None:
                # Try partial UUID match (first 24 hex chars)
                for k, v in session_to_txn_map.items():
                    if lsid and k[0] and len(lsid) >= 24 and len(k[0]) >= 24:
                        if lsid[:24] == k[0][:24] and k[1] == txn_num:
                            txn_tla = v
                            break
            if txn_tla is None:
                continue

            # === v3 Coordinator Events ===

            if log_id == 22467:
                # "Going to write decision" -> CoordDecideCommit / CoordDecideAbort
                decision_raw = str(attr.get("decision", "")).lower()
                if "commit" in decision_raw:
                    txn_decisions[txn_tla] = "commit"
                    events.append(make_event(ts_ns, "CoordDecideCommit", txn_tla, {
                        "cPhase": "CP_decided",
                        "cDecision": "D_commit",
                    }))
                else:
                    txn_decisions[txn_tla] = "abort"
                    events.append(make_event(ts_ns, "CoordDecideAbort", txn_tla, {
                        "cPhase": "CP_decided",
                        "cDecision": "D_abort",
                    }))

            elif log_id == 22469:
                # "Wrote decision" -> CoordPersistAndSend
                events.append(make_event(ts_ns, "CoordPersistAndSend", txn_tla, {
                    "cPhase": "CP_sending",
                }))

            elif log_id == 22481:
                # "Coordinator going to send command to shard" (DECISION phase)
                # Emit PER SHARD — each occurrence is a CoordSendDecisionToShard
                target_shard = map_shard(attr.get("shardId", ""))
                decision = txn_decisions.get(txn_tla, "commit")

                if decision == "commit":
                    shard_state = "SS_committed"
                else:
                    shard_state = "SS_aborted"

                events.append(make_event(ts_ns, "CoordSendDecisionToShard", txn_tla, {
                    "shard": target_shard,
                    "sState": shard_state,
                    "response": "R_ok",
                }))

            elif log_id == 22474:
                # "Deleted coordinator doc" -> CoordFinish
                events.append(make_event(ts_ns, "CoordFinish", txn_tla, {
                    "cPhase": "CP_done",
                }))

    return events


def build_session_map(scenarios):
    """Build (lsid_hex, txnNumber) -> tla_txn_id map from ALL scenarios."""
    session_map = {}
    for scenario in scenarios:
        meta = scenario.get("session_meta", {})
        for tla_id, info in meta.items():
            lsid = info.get("lsid", "")
            txn_num = info.get("txnNumber", 0)
            session_map[(lsid, txn_num)] = tla_id
    return session_map


def build_commit_type_map(scenarios):
    """Build tla_txn_id -> commit_type map from all scenarios."""
    ct_map = {}
    for scenario in scenarios:
        ct_map[scenario["txn_id"]] = scenario.get("commit_type", "CT_2pc")
    return ct_map


def load_client_events(client_trace_file):
    """Load client-side trace events from NDJSON file."""
    events = []
    if not os.path.exists(client_trace_file):
        return events
    with open(client_trace_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if obj.get("tag") == "trace":
                events.append(obj)
    return events


def merge_and_write(client_events, server_events, output_file):
    """Merge events with causal ordering correction, write NDJSON trace.

    Causal rules for v3 spec:
    - RouterCommitTxn precedes CoordDecideCommit (same txn, 2PC path)
    - CoordDecideCommit precedes CoordPersistAndSend (same txn)
    - CoordPersistAndSend precedes CoordSendDecisionToShard (same txn)
    - CoordSendDecisionToShard precedes CoordFinish (same txn)
    - CoordFinish precedes RouterReceive2PCResult (same txn)
    """
    all_events = list(client_events) + list(server_events)
    all_events.sort(key=lambda e: int(e.get("ts", 0)))

    # Causal fixup: ensure trigger events precede their effects
    CAUSAL_RULES = [
        ("RouterCommitTxn", {"CoordDecideCommit", "CoordDecideAbort"}),
        ("CoordFinish", {"RouterReceive2PCResult"}),
    ]

    for trigger_name, effect_names in CAUSAL_RULES:
        trigger_indices = {}
        for i, ev in enumerate(all_events):
            if ev.get("event") == trigger_name:
                txn = ev.get("txn", "")
                trigger_indices[txn] = i

        for txn, trigger_idx in trigger_indices.items():
            earliest_effect = None
            for i, ev in enumerate(all_events):
                if ev.get("event") in effect_names and ev.get("txn") == txn:
                    if earliest_effect is None or i < earliest_effect:
                        earliest_effect = i

            if earliest_effect is not None and trigger_idx > earliest_effect:
                trigger_ev = all_events.pop(trigger_idx)
                all_events.insert(earliest_effect, trigger_ev)

    with open(output_file, "w") as f:
        for ev in all_events:
            if ev.get("tag") == "trace":
                f.write(json.dumps(ev, separators=(",", ":")) + "\n")

    return len([e for e in all_events if e.get("tag") == "trace"])


def main():
    harness_dir = os.environ.get("HARNESS_DIR",
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    trace_dir = os.environ.get("TRACE_DIR",
        os.path.join(os.path.dirname(harness_dir), "traces"))
    log_dir = os.path.join(harness_dir, "logs")

    meta_path = os.path.join(trace_dir, "scenario_meta.json")
    if not os.path.exists(meta_path):
        print(f"ERROR: {meta_path} not found. Run test_scenarios.py first.")
        sys.exit(1)

    with open(meta_path) as f:
        scenarios = json.load(f)

    session_map = build_session_map(scenarios)
    commit_type_map = build_commit_type_map(scenarios)
    print(f"Session map ({len(session_map)} entries): {session_map}")
    print(f"Commit types: {commit_type_map}")

    # Parse all shard logs
    shard1_events = parse_shard_logs(
        os.path.join(log_dir, "shard1.log"), "shard1RS", session_map, commit_type_map)
    shard2_events = parse_shard_logs(
        os.path.join(log_dir, "shard2.log"), "shard2RS", session_map, commit_type_map)
    all_server_events = shard1_events + shard2_events
    print(f"Parsed {len(shard1_events)} events from shard1, {len(shard2_events)} from shard2")

    # Group server events by txn_id
    server_by_txn = {}
    for ev in all_server_events:
        txn = ev.get("txn", "")
        server_by_txn.setdefault(txn, []).append(ev)

    # Merge each scenario
    for scenario in scenarios:
        name = scenario["name"]
        txn_id = scenario["txn_id"]
        client_file = os.path.join(trace_dir, f"{name}_client.ndjson")

        client_events = load_client_events(client_file)
        server_events = server_by_txn.get(txn_id, [])

        output_file = os.path.join(trace_dir, f"{name}.ndjson")
        count = merge_and_write(client_events, server_events, output_file)
        event_names = [e["event"] for e in client_events + server_events if "event" in e]
        print(f"  {name}.ndjson: {count} events (client: {len(client_events)}, "
              f"server: {len(server_events)})")
        print(f"    actions: {list(dict.fromkeys(event_names))}")

    print("Log parsing complete.")


if __name__ == "__main__":
    main()
