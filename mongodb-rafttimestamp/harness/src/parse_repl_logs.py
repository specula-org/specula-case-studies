#!/usr/bin/env python3
"""
parse_repl_logs.py — Parse MongoDB LOGV2 structured logs into NDJSON traces
for TLA+ trace validation of the RaftMongoReplTimestamp protocol.

Approach:
  1. Read MongoDB structured JSON logs from each container (mongo1.log, etc.)
  2. Track per-node replication state (term, role, optimes) from context in log entries
  3. Detect events via LOGV2 IDs (state transitions, term updates, commit point, etc.)
  4. Detect optime-change events by diffing tracked state between consecutive entries
  5. Merge all events by timestamp, output as NDJSON

Usage:
    python3 parse_repl_logs.py <log_dir> <output_ndjson> [--after TS] [--before TS]
"""

import json
import sys
import os
import re
import argparse
from collections import OrderedDict
from copy import deepcopy


# ---- Server ID Mapping ----

class ServerMapper:
    """Maps hostname:port → spec server IDs (n1, n2, n3)."""

    def __init__(self):
        self.server_map = OrderedDict()

    def map_server(self, host_id):
        if host_id not in self.server_map:
            idx = len(self.server_map) + 1
            self.server_map[host_id] = f"n{idx}"
        return self.server_map[host_id]

    def get_map(self):
        return dict(self.server_map)


# ---- Per-Node State Tracker ----

class NodeState:
    """Track per-node replication state from log events."""

    def __init__(self, server_id):
        self.server = server_id
        self.current_term = 0
        self.state = "SECONDARY"   # PRIMARY, SECONDARY, DOWN
        self.commit_point = {"term": 0, "index": 0}
        self.last_applied = {"term": 0, "index": 0}
        self.last_durable = {"term": 0, "index": 0}
        self.last_written = {"term": 0, "index": 0}
        self.log_len = 0
        # Track sync source for 'from' field
        self.sync_source = None

    def snapshot(self):
        """Return current state as dict for trace event."""
        return {
            "term": self.current_term,
            "state": self.state,
            "lastApplied": dict(self.last_applied),
            "lastDurable": dict(self.last_durable),
            "lastWritten": dict(self.last_written),
            "commitPoint": dict(self.commit_point),
            "logLen": self.log_len,
        }

    def snapshot_weak(self):
        """Return minimal state (term + state) for weak validation."""
        return {
            "term": self.current_term,
            "state": self.state,
        }


# ---- OpTime Parsing ----

def parse_optime(val):
    """
    Parse a MongoDB optime from various LOGV2 attribute formats.
    Returns {"term": T, "index": I} or None.

    MongoDB optimes in JSON logs appear as:
      {"ts": {"$timestamp": {"t": seconds, "i": increment}}, "t": {"$numberLong": "N"}}
      {"term": N, "index": M}
      Inline strings: "{ ts: Timestamp(s, i), t: N }"
    """
    if val is None:
        return None

    if isinstance(val, dict):
        # Direct {term, index} format
        if "term" in val and "index" in val:
            return {"term": _to_int(val["term"]), "index": _to_int(val["index"])}

        # MongoDB OpTimeAndWallTime or OpTime: {ts: ..., t: ...}
        ts = val.get("ts")
        t = val.get("t")
        if ts is not None and t is not None:
            inc = _extract_ts_inc(ts)
            return {"term": _to_int(t), "index": inc}

        # Nested opTime: {opTime: {...}, wallTime: ...}
        if "opTime" in val:
            return parse_optime(val["opTime"])

    if isinstance(val, str):
        # Try "{ ts: Timestamp(s, i), t: N }"
        m = re.search(r'Timestamp\(\s*(\d+)\s*,\s*(\d+)\s*\)', val)
        t_match = re.search(r'\bt\s*:\s*(\d+)', val)
        if m and t_match:
            return {"term": int(t_match.group(1)), "index": int(m.group(2))}

    return None


def _extract_ts_inc(ts_val):
    """Extract the increment (index proxy) from a Timestamp value."""
    if isinstance(ts_val, dict):
        if "$timestamp" in ts_val:
            return int(ts_val["$timestamp"].get("i", 0))
        # Raw {t: sec, i: inc}
        if "i" in ts_val:
            return int(ts_val["i"])
    return 0


def _to_int(val):
    """Convert various number formats to int."""
    if isinstance(val, int):
        return val
    if isinstance(val, dict):
        if "$numberLong" in val:
            return int(val["$numberLong"])
        if "$numberInt" in val:
            return int(val["$numberInt"])
    try:
        return int(val)
    except (ValueError, TypeError):
        return 0


# ---- State Update from Log Attributes ----

def update_state_from_attrs(attr, node_state):
    """
    Many MongoDB log entries include state in attributes.
    Extract what we can to keep the state tracker current.
    """
    # Term
    for key in ("term", "currentTerm", "newTerm"):
        if key in attr:
            t = _to_int(attr[key])
            if t > 0:
                node_state.current_term = max(node_state.current_term, t)

    # Member state from various fields
    for key in ("newState", "memberState", "newMemberState", "myState"):
        val = attr.get(key)
        if val:
            mapped = _map_member_state(str(val))
            if mapped:
                node_state.state = mapped

    # Optimes — check many possible attribute names
    for key in ("lastAppliedOpTime", "lastApplied", "appliedOpTime",
                "myLastApplied", "appliedThrough"):
        ot = parse_optime(attr.get(key))
        if ot and _optime_gt(ot, node_state.last_applied):
            node_state.last_applied = ot

    for key in ("lastWrittenOpTime", "lastWritten", "writtenOpTime",
                "myLastWritten"):
        ot = parse_optime(attr.get(key))
        if ot and _optime_gt(ot, node_state.last_written):
            node_state.last_written = ot

    for key in ("lastDurableOpTime", "lastDurable", "durableOpTime",
                "myLastDurable"):
        ot = parse_optime(attr.get(key))
        if ot and _optime_gt(ot, node_state.last_durable):
            node_state.last_durable = ot

    for key in ("_lastCommittedOpTimeAndWallTime", "lastCommittedOpTime",
                "committedOpTime", "newCommittedOpTime", "commitPoint",
                "newOpTime"):
        ot = parse_optime(attr.get(key))
        if ot and _optime_gt(ot, node_state.commit_point):
            node_state.commit_point = ot

    # Sync source
    for key in ("syncSource", "syncSourceHost", "source", "from"):
        if key in attr and attr[key]:
            node_state.sync_source = str(attr[key])
            break


def _map_member_state(val):
    """Map MongoDB member state strings to spec state names."""
    v = val.upper().strip()
    if v in ("PRIMARY", "1"):
        return "PRIMARY"
    if v in ("SECONDARY", "2"):
        return "SECONDARY"
    if v in ("DOWN", "8", "NOT_REACHABLE", "STARTUP", "0"):
        return "DOWN"
    if v in ("RECOVERING", "3", "STARTUP2", "5", "ROLLBACK", "9", "ARBITER", "7"):
        return "SECONDARY"  # Map recovering states to SECONDARY for spec
    return None


def _optime_gt(a, b):
    """Check if optime a > b."""
    if a["term"] != b["term"]:
        return a["term"] > b["term"]
    return a["index"] > b["index"]


# ---- Event Handlers ----
# Each handler returns an event dict or None.

def handle_transition_to_primary(attr, node_state):
    """21331: Transition to primary complete."""
    node_state.state = "PRIMARY"
    if "term" in attr:
        node_state.current_term = _to_int(attr["term"])
    return {
        "name": "BecomePrimary",
        "node": node_state.server,
        "state": node_state.snapshot_weak(),
    }


def handle_state_transition(attr, node_state):
    """21358: Replica set state transition (newState, oldState)."""
    new_state = str(attr.get("newState", "")).upper()
    old_state = str(attr.get("oldState", "")).upper()

    if "PRIMARY" in new_state:
        node_state.state = "PRIMARY"
        return {
            "name": "BecomePrimary",
            "node": node_state.server,
            "state": node_state.snapshot_weak(),
        }
    elif "SECONDARY" in new_state and "PRIMARY" in old_state:
        node_state.state = "SECONDARY"
        return {
            "name": "Stepdown",
            "node": node_state.server,
            "state": node_state.snapshot_weak(),
        }
    elif "SECONDARY" in new_state:
        node_state.state = "SECONDARY"
        # Generic transition to secondary (e.g., from STARTUP2)
        return None  # Not a spec event
    return None


def handle_stepdown(attr, node_state):
    """21402 / 21475: Stepping down from primary."""
    node_state.state = "SECONDARY"
    return {
        "name": "Stepdown",
        "node": node_state.server,
        "state": node_state.snapshot_weak(),
    }


def handle_update_term(attr, node_state):
    """21320 / 21827: Term update."""
    new_term = _to_int(attr.get("newTerm") or attr.get("term") or 0)
    if new_term > node_state.current_term:
        node_state.current_term = new_term
    return {
        "name": "UpdateTerm",
        "node": node_state.server,
        "state": node_state.snapshot(),
    }


def handle_advance_commit_point(attr, node_state, ctx=None):
    """6795400 / 21826: Commit point advance."""
    for key in ("newCommittedOpTime", "committedOpTime",
                "_lastCommittedOpTimeAndWallTime", "newOpTime"):
        ot = parse_optime(attr.get(key))
        if ot:
            node_state.commit_point = ot
            break

    host_map = ctx.get("host_to_sid", {}) if ctx else {}
    if node_state.state == "PRIMARY":
        return {
            "name": "AdvanceCommitPoint",
            "node": node_state.server,
            "state": node_state.snapshot_weak(),
        }
    else:
        return {
            "name": "LearnCommitPoint",
            "node": node_state.server,
            "from": _infer_from(node_state, host_map),
            "state": node_state.snapshot(),
        }


def handle_rollback_truncate(attr, node_state, ctx=None):
    """21600: Rollback oplog truncation."""
    host_map = ctx.get("host_to_sid", {}) if ctx else {}
    return {
        "name": "RollbackOplog",
        "node": node_state.server,
        "from": _infer_from(node_state, host_map),
        "state": node_state.snapshot_weak(),
    }


def handle_rollback_common_point(attr, node_state, ctx=None):
    """21607: Rollback common point found."""
    host_map = ctx.get("host_to_sid", {}) if ctx else {}
    return {
        "name": "RollbackOplog",
        "node": node_state.server,
        "from": _infer_from(node_state, host_map),
        "state": node_state.snapshot_weak(),
    }


def handle_recover_truncate(attr, node_state):
    """21557: Removing unapplied oplog entries (recovery truncation)."""
    return {
        "name": "RecoverTruncateOplog",
        "node": node_state.server,
        "state": node_state.snapshot_weak(),
    }


def handle_recover_replay_start(attr, node_state):
    """21545: Starting recovery oplog application."""
    return {
        "name": "RecoverReplayOplog",
        "node": node_state.server,
        "state": node_state.snapshot_weak(),
    }


def handle_recover_complete(attr, node_state):
    """21536: Completed oplog application for recovery."""
    return {
        "name": "RecoverSetTimestamps",
        "node": node_state.server,
        "state": node_state.snapshot_weak(),
    }


def handle_recover_from_stable(attr, node_state):
    """21544: Recovering from stable timestamp."""
    return {
        "name": "RecoverTruncateOplog",
        "node": node_state.server,
        "state": node_state.snapshot_weak(),
    }


def _infer_from(node_state, host_to_sid=None):
    """Infer the 'from' server for pairwise actions."""
    if node_state.sync_source:
        src = node_state.sync_source
        if host_to_sid and src in host_to_sid:
            return host_to_sid[src]
        return src
    return "unknown"


# ---- Event ID → Handler Mapping ----

EVENT_HANDLERS = {
    21331: handle_transition_to_primary,       # Transition to primary complete
    21358: handle_state_transition,             # Replica set state transition
    21402: handle_stepdown,                     # Stepping down (new term)
    21475: handle_stepdown,                     # Stepping down (heartbeat)
    21320: handle_update_term,                  # Updated term
    21827: handle_update_term,                  # Updating term (topology)
    6795400: handle_advance_commit_point,       # Advancing committed opTime (new term)
    21826: handle_advance_commit_point,         # Updating _lastCommittedOpTime (DEBUG 2)
    21600: handle_rollback_truncate,            # Rollback oplog truncation
    21607: handle_rollback_common_point,        # Rollback common point
    21557: handle_recover_truncate,             # Recovery truncation
    21545: handle_recover_replay_start,         # Recovery oplog application start
    21536: handle_recover_complete,             # Recovery application complete
    21544: handle_recover_from_stable,          # Recovering from stable timestamp
}

# IDs that provide state context but don't generate events.
# We still extract optime info from them.
STATE_CONTEXT_IDS = {
    21334,   # waitUntilOpTime context
    21337,   # snapshot optime context
    21332,   # Resetting optimes
    21450,   # Election succeeded (term + state)
    5872100, # Updating commit point for initiate
    21444,   # Start election
    21359,   # Entering primary catch-up mode
    21363,   # Exited primary catch-up mode
    21364,   # Caught up to heartbeat target
    21593,   # Transition to ROLLBACK
    21611,   # Transition to SECONDARY (after rollback)
    21592,   # Rollback complete
    21799,   # Sync source candidate chosen (has syncSource attr)
    21272,   # Oplog fetcher successfully fetched from sync source
    21092,   # Scheduling fetcher to read remote oplog
}

# Deduplicate: don't emit both 21331 and 21358 for the same transition
DEDUP_WINDOW_MS = 200


# ---- Main Parser ----

def parse_log_line(line):
    """Parse a single MongoDB LOGV2 JSON log line."""
    line = line.strip()
    if not line:
        return None
    try:
        return json.loads(line)
    except json.JSONDecodeError:
        return None


def extract_timestamp(entry):
    """Extract ISO timestamp string from a log entry."""
    ts_raw = entry.get("t", {})
    if isinstance(ts_raw, dict):
        return ts_raw.get("$date", "")
    if isinstance(ts_raw, str):
        return ts_raw
    return str(ts_raw)


def parse_logs(log_files, output_file, after_ts=None, before_ts=None):
    """
    Parse log files, merge events by timestamp, output NDJSON trace.

    Args:
        log_files: dict of {container_name: log_file_path}
        output_file: path to output NDJSON
        after_ts: only include events after this ISO timestamp
        before_ts: only include events before this ISO timestamp
    """
    server_mapper = ServerMapper()
    node_states = {}

    # Assign server IDs based on container names (sorted for determinism)
    for container_name in sorted(log_files.keys()):
        sid = server_mapper.map_server(container_name)
        node_states[sid] = NodeState(sid)

    # Also build a hostname → sid mapping for resolving 'from' fields
    host_to_sid = {}

    # Pass 1: Collect all events from all log files
    raw_events = []

    for container_name, log_path in sorted(log_files.items()):
        sid = server_mapper.map_server(container_name)
        node_state = node_states[sid]

        if not os.path.exists(log_path):
            print(f"  WARNING: {log_path} not found, skipping", file=sys.stderr)
            continue

        with open(log_path) as f:
            for line_num, line in enumerate(f, 1):
                entry = parse_log_line(line)
                if entry is None:
                    continue

                ts = extract_timestamp(entry)
                if not ts:
                    continue

                # Apply timestamp filters
                if after_ts and ts < after_ts:
                    continue
                if before_ts and ts > before_ts:
                    continue

                log_id = entry.get("id")
                if log_id is None:
                    continue
                log_id = int(log_id)

                attr = entry.get("attr", {})

                # Always update state tracker from known context IDs
                if log_id in EVENT_HANDLERS or log_id in STATE_CONTEXT_IDS:
                    update_state_from_attrs(attr, node_state)

                # Check if this generates an event
                handler = EVENT_HANDLERS.get(log_id)
                if handler is None:
                    continue

                # Build context for handlers that need it
                ctx = {"host_to_sid": host_to_sid}
                import inspect
                if "ctx" in inspect.signature(handler).parameters:
                    event = handler(attr, node_state, ctx=ctx)
                else:
                    event = handler(attr, node_state)
                if event is None:
                    continue

                # Resolve 'from' field hostnames to spec IDs
                if "from" in event and event["from"] not in ("unknown", ""):
                    from_host = event["from"]
                    if from_host not in host_to_sid:
                        # Try mapping hostname:port
                        if ":" in from_host:
                            hostname = from_host.split(":")[0]
                            for cname in log_files:
                                if hostname in cname or cname in hostname:
                                    host_to_sid[from_host] = server_mapper.map_server(cname)
                                    break
                    if from_host in host_to_sid:
                        event["from"] = host_to_sid[from_host]

                raw_events.append({
                    "ts": ts,
                    "event": event,
                    "log_id": log_id,
                    "container": container_name,
                    "line_num": line_num,
                })

    # Sort by timestamp, then by container name for tie-breaking
    raw_events.sort(key=lambda e: (e["ts"], e["container"]))

    # Deduplicate: remove duplicate events within DEDUP_WINDOW_MS
    deduped = _deduplicate(raw_events)

    # Pass 2: Emit NDJSON
    config = {
        "tag": "config",
        "ts": deduped[0]["ts"] if deduped else "",
        "config": {
            "servers": sorted(server_mapper.get_map().values()),
            "serverMap": server_mapper.get_map(),
        }
    }

    event_count = 0
    with open(output_file, "w") as out:
        out.write(json.dumps(config) + "\n")

        for raw in deduped:
            trace_line = {
                "tag": "trace",
                "ts": raw["ts"],
                "event": raw["event"],
            }
            out.write(json.dumps(trace_line) + "\n")
            event_count += 1

    return event_count, server_mapper.get_map()


def _deduplicate(events):
    """
    Remove duplicate events for the same node within a small time window.
    E.g., both 21331 and 21358 may fire for the same PRIMARY transition.
    """
    if not events:
        return events

    result = []
    seen = {}  # (node, event_name) → last_ts

    for ev in events:
        node = ev["event"].get("node", "")
        name = ev["event"].get("name", "")
        key = (node, name)
        ts = ev["ts"]

        if key in seen:
            # Simple dedup: skip if same event for same node within 1 second
            last_ts = seen[key]
            if ts[:19] == last_ts[:19]:  # Same second (ISO 8601 prefix)
                continue

        seen[key] = ts
        result.append(ev)

    return result


# ---- CLI ----

def main():
    parser = argparse.ArgumentParser(
        description="Parse MongoDB LOGV2 logs into NDJSON traces for "
                    "RaftMongoReplTimestamp TLA+ trace validation"
    )
    parser.add_argument("log_dir",
                        help="Directory containing per-node log files (mongo1.log, ...)")
    parser.add_argument("output",
                        help="Output NDJSON file path")
    parser.add_argument("--after",
                        help="Only include events after this timestamp (ISO 8601)")
    parser.add_argument("--before",
                        help="Only include events before this timestamp (ISO 8601)")
    args = parser.parse_args()

    # Discover log files
    log_files = {}
    log_dir = args.log_dir
    if os.path.isdir(log_dir):
        for fname in sorted(os.listdir(log_dir)):
            if fname.endswith(".log"):
                container = fname.replace(".log", "")
                log_files[container] = os.path.join(log_dir, fname)
    elif os.path.isfile(log_dir):
        container = os.path.basename(log_dir).replace(".log", "")
        log_files[container] = log_dir
    else:
        print(f"ERROR: {log_dir} not found", file=sys.stderr)
        sys.exit(1)

    if not log_files:
        print(f"ERROR: No .log files found in {log_dir}", file=sys.stderr)
        sys.exit(1)

    print(f"Parsing {len(log_files)} log files: {', '.join(sorted(log_files.keys()))}")

    count, server_map = parse_logs(log_files, args.output, args.after, args.before)

    print(f"Emitted {count} trace events to {args.output}")
    print(f"Server mapping: {json.dumps(server_map)}")


if __name__ == "__main__":
    main()
