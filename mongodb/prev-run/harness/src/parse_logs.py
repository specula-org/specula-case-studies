#!/usr/bin/env python3
"""
Parse MongoDB LOGV2 structured JSON logs and merge with client-side traces
to produce complete NDJSON trace files for TLA+ trace validation.

Strategy:
1. Read client trace to get lsid(s) used in each scenario
2. Parse server logs, filter to matching lsids
3. Map server events to TLA+ action names
4. Merge client + server events by timestamp
"""

import json
import os
import sys
from datetime import datetime, timezone


def parse_iso_to_ns(iso_str):
    """Parse ISO 8601 timestamp to epoch nanoseconds."""
    try:
        dt = datetime.fromisoformat(iso_str)
        return int(dt.timestamp() * 1e9)
    except (ValueError, TypeError):
        return 0


def extract_lsid_key(entry):
    """Extract (lsid_uuid, txnNumber) from a log entry's attr."""
    attr = entry.get("attr", {})
    lsid = None
    txn_num = None

    # Try direct fields first
    for key in ["sessionId", "lsid"]:
        if key in attr:
            sid = attr[key]
            if isinstance(sid, dict) and "id" in sid:
                id_val = sid["id"]
                if isinstance(id_val, dict) and "$uuid" in id_val:
                    lsid = id_val["$uuid"]
                elif isinstance(id_val, str):
                    lsid = id_val
            break

    # Try under parameters (summary logs)
    if lsid is None and "parameters" in attr:
        params = attr["parameters"]
        if "lsid" in params:
            sid = params["lsid"]
            if isinstance(sid, dict) and "id" in sid:
                id_val = sid["id"]
                if isinstance(id_val, dict) and "$uuid" in id_val:
                    lsid = id_val["$uuid"]
                elif isinstance(id_val, str):
                    lsid = id_val

    # txnNumber
    for key in ["txnNumberAndRetryCounter", "txnNumber"]:
        if key in attr:
            val = attr[key]
            if isinstance(val, dict) and "txnNumber" in val:
                txn_num = val["txnNumber"]
            elif isinstance(val, (int, float)):
                txn_num = int(val)
            break
    if txn_num is None and "parameters" in attr:
        params = attr["parameters"]
        for key in ["txnNumber", "txnNumberAndRetryCounter"]:
            if key in params:
                val = params[key]
                if isinstance(val, dict) and "txnNumber" in val:
                    txn_num = val["txnNumber"]
                elif isinstance(val, (int, float)):
                    txn_num = int(val)
                break

    if lsid and txn_num is not None:
        return f"{lsid}:{txn_num}"
    return None


def get_session_keys_from_client_trace(filepath):
    """Extract session keys (lsid:txnNumber) from meta lines in client trace."""
    keys = set()
    lsid = None
    txn_num = None
    if not os.path.exists(filepath):
        return keys
    with open(filepath) as f:
        for line in f:
            try:
                obj = json.loads(line.strip())
                if obj.get("tag") == "meta":
                    if "lsid" in obj:
                        lsid = obj["lsid"]
                    if "txnNumber" in obj:
                        txn_num = obj["txnNumber"]
            except (json.JSONDecodeError, KeyError):
                continue
    if lsid and txn_num is not None:
        keys.add(f"{lsid}:{txn_num}")
    return keys


def parse_shard_logs(log_path, target_session_keys, shard_tla_id):
    """
    Parse a shard's log file, extract TXN events matching target session keys,
    and return a list of trace events.
    target_session_keys: set of "lsid:txnNumber" strings
    """
    events = []
    if not os.path.exists(log_path):
        print(f"  WARNING: {log_path} not found")
        return events

    with open(log_path) as f:
        for line in f:
            try:
                entry = json.loads(line.strip())
            except json.JSONDecodeError:
                continue

            if entry.get("c") != "TXN":
                continue

            log_id = entry.get("id")
            attr = entry.get("attr", {})
            ts_str = entry.get("t", {}).get("$date", "")
            ts = str(parse_iso_to_ns(ts_str))

            # Get session key
            sess_key = extract_lsid_key(entry)
            if sess_key is None:
                continue

            # Filter: only process events whose full session key matches
            if sess_key not in target_session_keys:
                continue

            # Map to TLA+ events
            if log_id == 23984:
                # "New transaction started" -> ShardTxnStart
                events.append(_make_event(ts, "ShardTxnStart", shard_tla_id, "shard", sess_key,
                                          state={"inShardTxns": True, "prepared": False, "aborted": False}))

            elif log_id == 22465:
                # "Wrote participant list" -> ShardTxnCoordinateCommit
                events.append(_make_event(ts, "ShardTxnCoordinateCommit", shard_tla_id, "shard", sess_key,
                                          state={"coordDocState": "participants"}))

            elif log_id == 22478:
                # "Coordinator received vote to commit"
                from_shard = attr.get("shardId", "unknown")
                events.append(_make_event(ts, "RecvCommitVote", shard_tla_id, "shard", sess_key,
                                          extra={"from": from_shard}))

            elif log_id == 22469:
                # "Wrote decision" - need to determine commit vs abort
                # Check the log message text for hints
                msg_text = entry.get("msg", "")
                # Also check if there's a terminationCause or decision field
                if "abort" in msg_text.lower() or "abort" in str(attr).lower():
                    events.append(_make_event(ts, "WriteAbortDecision", shard_tla_id, "shard", sess_key,
                                              state={"coordDocState": "abort"}))
                else:
                    events.append(_make_event(ts, "WriteCommitDecision", shard_tla_id, "shard", sess_key,
                                              state={"coordDocState": "commit"}))

            elif log_id == 22476:
                # "Coordinator going to send command to shard"
                # This fires for prepareTransaction sends (before votes) AND
                # for commitTransaction/abortTransaction sends (after decision).
                cmd = attr.get("command", {})
                if isinstance(cmd, dict):
                    if "commitTransaction" in cmd:
                        events.append(_make_event(ts, "SendCommit", shard_tla_id, "shard", sess_key,
                                                  state={"coordDocState": "done"}))
                    elif "abortTransaction" in cmd:
                        events.append(_make_event(ts, "SendAbort", shard_tla_id, "shard", sess_key,
                                                  state={"coordDocState": "done"}))
                    # prepareTransaction sends are NOT trace events (implicit in spec)

            elif log_id == 22474:
                # "Deleted coordinator doc" — if no 22476 commit/abort send was seen,
                # this indicates the commit/abort delivery completed.
                # We use this as a fallback for SendCommit/SendAbort.
                # Check if we already emitted a SendCommit/SendAbort for this session.
                has_send = any(e["event"]["name"] in ("SendCommit", "SendAbort")
                               for e in events if e["event"].get("_sess_key") == sess_key)
                if not has_send:
                    # Infer from the decision that was written
                    has_abort = any(e["event"]["name"] == "WriteAbortDecision"
                                    for e in events if e["event"].get("_sess_key") == sess_key)
                    if has_abort:
                        events.append(_make_event(ts, "SendAbort", shard_tla_id, "shard", sess_key,
                                                  state={"coordDocState": "done"}))
                    else:
                        events.append(_make_event(ts, "SendCommit", shard_tla_id, "shard", sess_key,
                                                  state={"coordDocState": "done"}))

            elif log_id == 5047001:
                # "Transaction coordinator made abort decision"
                events.append(_make_event(ts, "WriteAbortDecision", shard_tla_id, "shard", sess_key,
                                          state={"coordDocState": "abort"}))

            elif log_id == 51802:
                # Transaction summary
                term_cause = attr.get("terminationCause", "")
                was_prepared = attr.get("wasPrepared", False)

                if was_prepared:
                    events.append(_make_event(ts, "ShardTxnPrepare", shard_tla_id, "shard", sess_key,
                                              state={"inShardTxns": True, "prepared": True}))

                if term_cause == "committed":
                    events.append(_make_event(ts, "ShardTxnCommit", shard_tla_id, "shard", sess_key,
                                              state={"inShardTxns": False, "prepared": False}))
                elif term_cause == "aborted":
                    events.append(_make_event(ts, "ShardTxnAbort", shard_tla_id, "shard", sess_key,
                                              state={"inShardTxns": False, "aborted": True}))

            elif log_id == 20507:
                # "Received commitTransaction" — shard-level commit receipt
                pass  # Covered by 51802 summary

            elif log_id == 20508:
                # "Received abortTransaction"
                pass  # Covered by 51802 summary

    print(f"  {log_path}: {len(events)} trace events for {len(target_session_keys)} sessions")
    return events


def _make_event(ts, name, nid, ntype, sess_key, state=None, extra=None):
    event = {"name": name, "nid": nid, "ntype": ntype, "_sess_key": sess_key}
    if state:
        event["state"] = state
    if extra:
        event.update(extra)
    return {"tag": "trace", "ts": ts, "event": event}


# Shard name mapping: MongoDB shard names -> TLA+ IDs
SHARD_MAP = {"shard1RS": "s1", "shard2RS": "s2"}
SHARD_MAP_INV = {v: k for k, v in SHARD_MAP.items()}


def build_tid_map(client_events, server_events):
    """
    Build a unified session key -> TLA+ tid mapping.
    Client events already have tids; server events need to be matched.
    """
    # The client trace uses pymongo's internal session tracking.
    # Server logs use lsid:txnNumber keys.
    # We need to match them by timing and shard correlation.
    # For simplicity, assign sequential tids to all unique session keys.
    tid_map = {}
    counter = 0
    for ev in client_events + server_events:
        if ev.get("tag") != "trace":
            continue
        # Client events already have tid
        if "tid" in ev.get("event", {}):
            continue
        sess_key = ev.get("event", {}).get("_sess_key")
        if sess_key and sess_key not in tid_map:
            counter += 1
            tid_map[sess_key] = f"t{counter}"
    return tid_map


def merge_traces(client_trace_path, server_events, output_path):
    """
    Merge client + server events into a single trace file with correct causal ordering.

    Causal ordering rules:
    1. RouterTxnStart comes first
    2. For each shard, RouterTxnOp MUST come before ShardTxnStart
    3. RouterTxnCoordinateCommit/CommitSingleShard/Abort MUST come before
       all 2PC coordinator events (ShardTxnCoordinateCommit, RecvCommitVote, etc.)
    4. 2PC coordinator events come in server log order
    5. ShardTxnCommit/ShardTxnAbort come last

    Strategy: Client events go first in emitted order. Server events are
    grouped into "after RouterTxnOp" (ShardTxnStart) and "after commit"
    (everything else), then appended in log order.
    """
    client_events = []
    config_lines = []

    if os.path.exists(client_trace_path):
        with open(client_trace_path) as f:
            for line in f:
                try:
                    obj = json.loads(line.strip())
                    if obj.get("tag") == "trace":
                        client_events.append(obj)
                    elif obj.get("tag") == "config":
                        config_lines.append(obj)
                except (json.JSONDecodeError, KeyError):
                    continue

    # Resolve shard names and add tid to server events
    resolved_server = []
    for ev in server_events:
        event = dict(ev["event"])
        if "from" in event and event["from"] in SHARD_MAP:
            event["from"] = SHARD_MAP[event["from"]]
        event.pop("_sess_key", None)
        event["tid"] = "t1"
        resolved_server.append({"tag": "trace", "ts": ev["ts"], "event": event})

    # Split server events: ShardTxnStart events vs post-commit events
    shard_start_events = []
    post_commit_events = []
    for ev in resolved_server:
        if ev["event"]["name"] == "ShardTxnStart":
            shard_start_events.append(ev)
        else:
            post_commit_events.append(ev)

    # Build ordered trace:
    # 1. Interleave client events with ShardTxnStart (after matching RouterTxnOp)
    # 2. Append post-commit server events at the end
    ordered = []
    shard_starts_by_nid = {}
    for ev in shard_start_events:
        nid = ev["event"]["nid"]
        shard_starts_by_nid[nid] = ev

    for cev in client_events:
        ordered.append(cev)
        name = cev["event"].get("name", "")
        if name == "RouterTxnOp":
            # After routing an op to a shard, emit the ShardTxnStart for that shard
            shard = cev["event"].get("shard")
            if shard in shard_starts_by_nid:
                ordered.append(shard_starts_by_nid.pop(shard))

    # Any remaining ShardTxnStart events (shouldn't happen in well-structured traces)
    for ev in shard_starts_by_nid.values():
        ordered.append(ev)

    # Append post-commit events in server log order (already sorted by timestamp)
    post_commit_events.sort(key=lambda e: int(e.get("ts", "0")))
    ordered.extend(post_commit_events)

    # Write output
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "w") as f:
        for cfg in config_lines:
            f.write(json.dumps(cfg, separators=(",", ":")) + "\n")
        for ev in ordered:
            f.write(json.dumps(ev, separators=(",", ":")) + "\n")

    print(f"  -> {output_path}: {len(ordered)} trace events")
    return len(ordered)


def main():
    # base_dir = case-studies/mongodb/harness/src/../.. = case-studies/mongodb
    src_dir = os.path.dirname(os.path.abspath(__file__))  # harness/src
    harness_dir = os.path.dirname(src_dir)                # harness/
    base_dir = os.path.dirname(harness_dir)               # case-studies/mongodb
    trace_dir = os.path.join(base_dir, "traces")
    log_dir = os.path.join(harness_dir, "logs")

    print("=== Parsing MongoDB server logs ===")

    scenarios = [
        ("basic_commit", os.path.join(trace_dir, "basic_commit_client.ndjson"),
         os.path.join(trace_dir, "basic_commit.ndjson")),
        ("single_shard", os.path.join(trace_dir, "single_shard_client.ndjson"),
         os.path.join(trace_dir, "single_shard.ndjson")),
        ("abort", os.path.join(trace_dir, "abort_client.ndjson"),
         os.path.join(trace_dir, "abort.ndjson")),
    ]

    log_files = {
        "shard1RS": os.path.join(log_dir, "shard1.log"),
        "shard2RS": os.path.join(log_dir, "shard2.log"),
    }

    for scenario_name, client_path, output_path in scenarios:
        print(f"\nScenario: {scenario_name}")

        # Get session keys from client trace
        session_keys = get_session_keys_from_client_trace(client_path)
        print(f"  Session keys: {session_keys}")

        # Parse server logs for matching events
        server_events = []
        for shard_name, log_path in log_files.items():
            tla_id = SHARD_MAP.get(shard_name, shard_name)
            events = parse_shard_logs(log_path, session_keys, tla_id)
            server_events.extend(events)

        # Merge and write
        merge_traces(client_path, server_events, output_path)

    print("\n=== Done ===")


if __name__ == "__main__":
    main()
