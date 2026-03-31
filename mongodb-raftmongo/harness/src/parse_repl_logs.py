#!/usr/bin/env python3
"""
parse_repl_logs.py — Parse MongoDB LOGV2 structured logs into NDJSON traces
for TLA+ trace validation of the RaftMongo replication commit point protocol.

Usage:
    python3 parse_repl_logs.py <log_dir> <output_ndjson> [--after TS] [--before TS]

The log_dir should contain one log file per replica set member (e.g., mongo1.log, mongo2.log, mongo3.log).
Events are merged, sorted by timestamp, and server IDs are mapped to s1/s2/s3.
"""

import json
import sys
import os
import re
import argparse
from collections import OrderedDict


# ---- Server ID Mapping ----

class ServerMapper:
    """Maps container names to spec server IDs (s1, s2, s3)."""

    def __init__(self):
        self.server_map = OrderedDict()

    def map_server(self, host_id):
        if host_id not in self.server_map:
            idx = len(self.server_map) + 1
            self.server_map[host_id] = f"s{idx}"
        return self.server_map[host_id]

    def get_map(self):
        return dict(self.server_map)


# ---- State Tracker ----

class NodeState:
    """Track per-node replication state from log events."""

    def __init__(self, server_id):
        self.server = server_id
        self.current_term = 0
        self.state = "Follower"
        self.commit_point = {"term": 0, "index": 0, "_ts": 0}
        self.last_written = {"term": 0, "index": 0, "_ts": 0}
        self.last_applied = {"term": 0, "index": 0, "_ts": 0}
        self.last_durable = {"term": 0, "index": 0, "_ts": 0}

    @staticmethod
    def _strip_ts(ot):
        """Remove internal _ts field from optime for output."""
        return {"term": ot["term"], "index": ot["index"]}

    def snapshot(self):
        """Return state snapshot. Keeps _ts for normalization; stripped at output."""
        return {
            "server": self.server,
            "currentTerm": self.current_term,
            "state": self.state,
            "commitPoint": dict(self.commit_point),
            "lastWritten": dict(self.last_written),
            "lastApplied": dict(self.last_applied),
            "lastDurable": dict(self.last_durable),
        }


# ---- OpTime Parsing ----

def parse_optime_value(val):
    """
    Parse an optime from various MongoDB formats:
    1. Structured: {"ts":{"$timestamp":{"t":sec,"i":inc}},"t":term}
    2. Simple: {"term": N, "index": M}
    3. String: "{ ts: Timestamp(sec, inc), t: term }, walltime"
    4. String: "Timestamp(sec, inc) term T"
    Returns {"term": T, "index": I, "_ts": S} or None.
    _ts is the seconds component (for normalization); stripped before output.
    """
    if val is None:
        return None

    if isinstance(val, dict):
        # Format 2: {"term": N, "index": M}
        if "term" in val and "index" in val:
            return {"term": int(val["term"]), "index": int(val["index"]), "_ts": 0}
        # Format 1: {"ts": {"$timestamp": {"t": sec, "i": inc}}, "t": term}
        ts = val.get("ts")
        t = val.get("t")
        if ts is not None and t is not None:
            if isinstance(ts, dict) and "$timestamp" in ts:
                sec = int(ts["$timestamp"].get("t", 0))
                inc = int(ts["$timestamp"].get("i", 0))
                return {"term": int(t), "index": inc, "_ts": sec}
            if isinstance(ts, dict):
                # Other timestamp formats
                sec = int(ts.get("t", 0))
                inc = int(ts.get("i", ts.get("inc", 0)))
                return {"term": int(t), "index": inc, "_ts": sec}
        return None

    if isinstance(val, str):
        # Format 3: "{ ts: Timestamp(sec, inc), t: term }, walltime"
        m = re.search(r'Timestamp\(\s*(\d+)\s*,\s*(\d+)\s*\)', val)
        t_match = re.search(r'\bt:\s*(-?\d+)', val)
        if m and t_match:
            sec = int(m.group(1))
            inc = int(m.group(2))
            term = int(t_match.group(1))
            return {"term": term, "index": inc, "_ts": sec}
        # Format 4: "Timestamp(sec, inc) term T"
        m = re.match(r'Timestamp\((\d+),\s*(\d+)\)\s*term\s*(\d+)', val)
        if m:
            return {"term": int(m.group(3)), "index": int(m.group(2)), "_ts": int(m.group(1))}

    return None


def parse_optime(attr, key):
    """Extract an optime from a log attribute dict by key."""
    val = attr.get(key)
    return parse_optime_value(val)


def map_member_state(val):
    """Map MongoDB member state strings to spec state names."""
    v = str(val).upper()
    if v in ("PRIMARY",):
        return "Leader"
    if v in ("CANDIDATE",):
        return "Candidate"
    return "Follower"


# ---- State Updater ----

def update_state_from_attrs(attr, node_state):
    """Update node state tracker from log attributes."""
    # Term — only update from explicit term fields, not from "t" (which is optime term)
    for key in ("newTerm", "currentTerm"):
        if key in attr:
            try:
                node_state.current_term = int(attr[key])
            except (ValueError, TypeError):
                pass

    # Member state
    for key in ("newState", "memberState", "myState"):
        val = attr.get(key)
        if val:
            node_state.state = map_member_state(val)

    # Optimes (structured format)
    for key in ("lastWrittenOpTime", "lastWritten", "writtenOpTime"):
        ot = parse_optime(attr, key)
        if ot and ot["term"] >= 0:
            node_state.last_written = ot
    for key in ("lastAppliedOpTime", "lastApplied", "appliedOpTime"):
        ot = parse_optime(attr, key)
        if ot and ot["term"] >= 0:
            node_state.last_applied = ot
    for key in ("lastDurableOpTime", "lastDurable", "durableOpTime"):
        ot = parse_optime(attr, key)
        if ot and ot["term"] >= 0:
            node_state.last_durable = ot
    for key in ("_lastCommittedOpTimeAndWallTime", "newCommittedOpTime",
                "lastCommittedOpTime", "committedOpTime"):
        ot = parse_optime(attr, key)
        if ot and ot["term"] >= 0:
            node_state.commit_point = ot


# ---- Event Handlers ----
# Each returns a dict {"name": ..., "state": ...} or None to skip.

def handle_start_election(log_id, attr, node_state):
    """21444, 4615652, 4615660, 4615661, 4615662"""
    new_term = attr.get("newTerm") or attr.get("term")
    if new_term is not None:
        node_state.current_term = int(new_term)
    node_state.state = "Candidate"
    return {"name": "StartElection", "state": node_state.snapshot()}


def handle_vote_granted(log_id, attr, node_state, server_mapper):
    """5972100 — 'Voting yes in election'. No attributes in log, state from tracker."""
    # VoteGranted has no attrs in MongoDB 8.x logs — state comes from
    # surrounding 21827 UpdateTerm and 21358 state transition events.
    # The voter's state is already updated by prior log entries.
    state = node_state.snapshot()
    # We can't identify the candidate from this log line.
    # The Trace spec uses existential quantification over candidates.
    return {"name": "VoteGranted", "state": state}


def handle_election_won(log_id, attr, node_state):
    """21450"""
    new_term = attr.get("term") or attr.get("newTerm")
    if new_term is not None:
        node_state.current_term = int(new_term)
    node_state.state = "Leader"
    return {"name": "ElectionWon", "state": node_state.snapshot()}


def handle_transition_to_primary(log_id, attr, node_state):
    """21331"""
    new_term = attr.get("term")
    if new_term is not None:
        node_state.current_term = int(new_term)
    node_state.state = "Leader"
    return {"name": "TransitionToPrimary", "state": node_state.snapshot()}


def handle_stepdown_explicit(log_id, attr, node_state):
    """21402, 21475"""
    node_state.state = "Follower"
    return {"name": "Stepdown", "state": node_state.snapshot()}


def handle_state_transition(log_id, attr, node_state):
    """
    21358 — 'Replica set state transition'
    Emits Stepdown when transitioning from PRIMARY to SECONDARY.
    Emits nothing for other transitions (startup, etc.)
    """
    old_state = attr.get("oldState", "")
    new_state = attr.get("newState", "")
    node_state.state = map_member_state(new_state)

    if old_state == "PRIMARY" and new_state == "SECONDARY":
        return {"name": "Stepdown", "state": node_state.snapshot()}

    # Other transitions tracked but not emitted as events
    return None


def handle_update_term(log_id, attr, node_state):
    """21827"""
    old_term = attr.get("oldTerm")
    new_term = attr.get("newTerm") or attr.get("term")
    if new_term is not None:
        node_state.current_term = int(new_term)
    # Skip startup initialization (oldTerm=-1 → newTerm=0)
    if old_term is not None and int(old_term) < 0:
        return None
    return {"name": "UpdateTerm", "state": node_state.snapshot()}


def handle_advance_commit_point(log_id, attr, node_state):
    """21826, 6795400"""
    # 21826: attr._lastCommittedOpTimeAndWallTime = "{ ts: Timestamp(sec,inc), t: T }, walltime"
    cp = attr.get("_lastCommittedOpTimeAndWallTime")
    if cp:
        ot = parse_optime_value(cp)
        if ot and ot["term"] >= 0:
            node_state.commit_point = ot
        elif ot and ot["term"] < 0:
            # Skip initial RS config commit (term=-1)
            return None
    # 6795400: different attr format
    for key in ("newCommittedOpTime", "committedOpTime", "lastCommittedOpTime"):
        ot = parse_optime(attr, key)
        if ot and ot["term"] >= 0:
            node_state.commit_point = ot
            break
    # Skip commit point events where term < 0 or commitPoint hasn't changed from init
    if node_state.commit_point["term"] < 0:
        return None
    return {"name": "AdvanceCommitPoint", "state": node_state.snapshot()}


def handle_rollback(log_id, attr, node_state):
    """21607"""
    return {"name": "RollbackOplog", "state": node_state.snapshot()}


def handle_crash_recovery(log_id, attr, node_state):
    """501401"""
    node_state.state = "Follower"
    return {"name": "Crash", "state": node_state.snapshot()}


# ---- Log ID Dispatch Table ----

# Events that produce trace lines
EVENT_HANDLERS = {
    # StartElection — only 21444 ("Dry election run succeeded, running for election")
    # has the newTerm attribute. 4615652/4615660/etc fire BEFORE the term increment
    # and don't carry the new term, so we skip them.
    21444: "start_election",
    # VoteGranted
    5972100: "vote_granted",
    # ElectionWon
    21450: "election_won",
    # TransitionToPrimary
    21331: "transition_to_primary",
    # Stepdown (explicit)
    21402: "stepdown",
    21475: "stepdown",
    # State transition (generates Stepdown for PRIMARY→SECONDARY)
    21358: "state_transition",
    # UpdateTerm
    21827: "update_term",
    # AdvanceCommitPoint
    21826: "advance_commit_point",
    6795400: "advance_commit_point",
    # RollbackOplog
    21607: "rollback",
    # Crash recovery
    501401: "crash_recovery",
}

# State-only log IDs (not events, just state tracking)
STATE_ONLY_IDS = {
    21334,  # waitUntilOpTime (contains optime info)
    21335,  # setMyLastWrittenOpTimeAndWallTimeForward
    21337,  # setMyLastDurableOpTimeAndWallTimeForward (contains optime info)
}

# Skip these (duplicate or redundant)
SKIP_IDS = {21592}  # RollbackComplete (redundant with 21607)

# Dedup: avoid double-emitting Stepdown from both 21402/21475 and 21358
# Only emit from 21358 state_transition (always fires), skip 21402/21475
# Actually we need to check: if 21402/21475 fires, 21358 also fires at the same time.
# So we use 21358 as the canonical source and dedup.


def dispatch_event(log_id, attr, node_state, server_mapper):
    """Dispatch a log entry to the appropriate handler. Returns event dict or None."""
    handler_key = EVENT_HANDLERS.get(log_id)
    if handler_key is None:
        return None

    if handler_key == "start_election":
        return handle_start_election(log_id, attr, node_state)
    elif handler_key == "vote_granted":
        return handle_vote_granted(log_id, attr, node_state, server_mapper)
    elif handler_key == "election_won":
        return handle_election_won(log_id, attr, node_state)
    elif handler_key == "transition_to_primary":
        return handle_transition_to_primary(log_id, attr, node_state)
    elif handler_key == "stepdown":
        return handle_stepdown_explicit(log_id, attr, node_state)
    elif handler_key == "state_transition":
        return handle_state_transition(log_id, attr, node_state)
    elif handler_key == "update_term":
        return handle_update_term(log_id, attr, node_state)
    elif handler_key == "advance_commit_point":
        return handle_advance_commit_point(log_id, attr, node_state)
    elif handler_key == "rollback":
        return handle_rollback(log_id, attr, node_state)
    elif handler_key == "crash_recovery":
        return handle_crash_recovery(log_id, attr, node_state)
    return None


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


def parse_logs(log_files, output_file, after_ts=None, before_ts=None):
    """
    Parse multiple log files, merge events by timestamp, and output NDJSON trace.
    """
    server_mapper = ServerMapper()
    node_states = {}

    # Assign server IDs (sorted for determinism)
    for container_name in sorted(log_files.keys()):
        sid = server_mapper.map_server(container_name)
        node_states[sid] = NodeState(sid)

    # Pass 1: Process each file sequentially to maintain state,
    # collect all events with timestamps
    raw_events = []

    for container_name, log_path in sorted(log_files.items()):
        sid = server_mapper.map_server(container_name)
        node_state = node_states[sid]

        if not os.path.exists(log_path):
            print(f"  WARNING: {log_path} not found, skipping", file=sys.stderr)
            continue

        # Track recent stepdown log IDs to dedup 21358 + 21402/21475
        recent_stepdown_ts = None

        with open(log_path) as f:
            for line_num, line in enumerate(f, 1):
                entry = parse_log_line(line)
                if entry is None:
                    continue

                # Extract timestamp
                ts_raw = entry.get("t", {})
                if isinstance(ts_raw, dict):
                    ts = ts_raw.get("$date", "")
                elif isinstance(ts_raw, str):
                    ts = ts_raw
                else:
                    continue

                if not ts:
                    continue

                log_id = entry.get("id")
                if log_id is None:
                    continue
                log_id = int(log_id)

                if log_id in SKIP_IDS:
                    continue

                attr = entry.get("attr", {})
                if attr is None:
                    attr = {}

                # Always try state update from state-tracking IDs
                if log_id in STATE_ONLY_IDS:
                    # 21337: opTime is lastDurable; 21335: opTime is lastWritten
                    if log_id == 21337 and "opTime" in attr:
                        ot = parse_optime(attr, "opTime")
                        if ot and ot["term"] >= 0:
                            node_state.last_durable = ot
                    elif log_id == 21335 and "opTime" in attr:
                        ot = parse_optime(attr, "opTime")
                        if ot and ot["term"] >= 0:
                            node_state.last_written = ot
                    update_state_from_attrs(attr, node_state)
                    continue

                # For event IDs, first update state then dispatch
                if log_id not in EVENT_HANDLERS:
                    continue

                # Apply timestamp filters for events only
                if after_ts and ts < after_ts:
                    # But still update state (even outside window)
                    update_state_from_attrs(attr, node_state)
                    if log_id in EVENT_HANDLERS:
                        dispatch_event(log_id, attr, node_state, server_mapper)
                    continue
                if before_ts and ts > before_ts:
                    continue

                # Update state before dispatching
                update_state_from_attrs(attr, node_state)

                # Dedup stepdown: skip 21402/21475 if 21358 at same ts
                if log_id in (21402, 21475):
                    recent_stepdown_ts = ts
                    # Skip — 21358 will emit the Stepdown event
                    continue
                if log_id == 21358 and recent_stepdown_ts == ts:
                    # 21358 fires alongside 21402/21475 — emit from 21358
                    pass

                event = dispatch_event(log_id, attr, node_state, server_mapper)

                if event:
                    raw_events.append({
                        "ts": ts,
                        "event": event,
                        "container": container_name,
                        "log_id": log_id,
                    })

    # Sort by timestamp (stable sort preserves file order for same ts)
    raw_events.sort(key=lambda e: e["ts"])

    # Pass 2: Dedup — remove duplicate events at same timestamp from same server
    # (e.g., 21444 StartElection fires right after 4615652)
    deduped = []
    seen = set()
    for raw in raw_events:
        key = (raw["ts"], raw["event"]["name"], raw["event"]["state"]["server"])
        if key not in seen:
            seen.add(key)
            deduped.append(raw)
    raw_events = deduped

    # Pass 3: Normalize optimes — map MongoDB (term, sec, inc) to sequential indices.
    # MongoDB optimes use (seconds, increment) within a term. The increment resets
    # when seconds change, so raw inc values are not sequential. We normalize to
    # sequential indices to match the TLA+ spec's [term, index] model.
    #
    # Collect all distinct raw optimes from all events' optime fields.
    raw_optimes = set()
    optime_fields = ["commitPoint", "lastWritten", "lastApplied", "lastDurable"]
    for raw in raw_events:
        state = raw["event"].get("state", {})
        for field in optime_fields:
            ot = state.get(field)
            if ot and (ot["term"] > 0 or ot.get("_ts", 0) > 0 or ot["index"] > 0):
                # Use (term, seconds, increment) as unique identifier
                raw_optimes.add((ot["term"], ot.get("_ts", 0), ot["index"]))

    # Sort by (term, seconds, increment) — this is MongoDB's natural ordering
    sorted_optimes = sorted(raw_optimes)

    # Assign sequential indices per term
    optime_map = {}  # (term, seconds, increment) -> sequential index
    per_term_counter = {}  # term -> next sequential index
    for term, sec, inc in sorted_optimes:
        if term not in per_term_counter:
            per_term_counter[term] = 1
        optime_map[(term, sec, inc)] = per_term_counter[term]
        per_term_counter[term] += 1

    # Apply normalization: replace raw optimes with sequential indices, strip _ts
    def normalize_optime(ot):
        if ot.get("term", 0) == 0 and ot.get("index", 0) == 0:
            return {"term": 0, "index": 0}
        key = (ot["term"], ot.get("_ts", 0), ot["index"])
        if key in optime_map:
            return {"term": ot["term"], "index": optime_map[key]}
        # Fallback: strip _ts and return
        return {"term": ot["term"], "index": ot["index"]}

    for raw in raw_events:
        state = raw["event"].get("state", {})
        for field in optime_fields:
            if field in state:
                state[field] = normalize_optime(state[field])

    # Emit NDJSON
    config = {
        "tag": "config",
        "ts": raw_events[0]["ts"] if raw_events else "",
        "config": {
            "servers": sorted(server_mapper.get_map().values()),
            "serverMap": server_mapper.get_map(),
        }
    }

    event_count = 0
    with open(output_file, "w") as out:
        out.write(json.dumps(config) + "\n")

        for raw in raw_events:
            trace_line = {
                "tag": "trace",
                "ts": raw["ts"],
                "event": raw["event"],
            }
            out.write(json.dumps(trace_line) + "\n")
            event_count += 1

    return event_count, server_mapper.get_map()


def main():
    parser = argparse.ArgumentParser(
        description="Parse MongoDB LOGV2 logs into NDJSON traces for RaftMongo TLA+ validation"
    )
    parser.add_argument("log_dir",
                        help="Directory with per-node log files (mongo1.log, mongo2.log, mongo3.log)")
    parser.add_argument("output",
                        help="Output NDJSON file path")
    parser.add_argument("--after",
                        help="Only include events after this timestamp (ISO 8601)")
    parser.add_argument("--before",
                        help="Only include events before this timestamp (ISO 8601)")
    args = parser.parse_args()

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
