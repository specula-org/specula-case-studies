#!/usr/bin/env python3
"""
Parse MongoDB LOGV2 structured JSON logs from a replica set into NDJSON traces
matching the MongoRaftReconfig Trace.tla event schema.

Log-based instrumentation: no recompilation needed.  MongoDB's LOGV2 structured
logs contain all state transition events for elections, reconfigs, term updates,
and config propagation.

LOGV2 ID mapping:
  21450: "Election succeeded"           -> WinElection
  21331: "Transition to primary"        -> CompleteDrain
  21392: "New replica set config"       -> Reconfig / ForceReconfig / SendConfig
  21352: "replSetReconfig command"      -> (context for 21392 classification)
  21320: "Updated term"                 -> UpdateTerms
  21592: "Rollback complete"            -> RollbackEntries
  4634504: "Removed newlyAdded field"   -> RemoveNewlyAdded
  21355: "Stepping down (config)"       -> (state tracking)
  21475: "Stepping down (heartbeat)"    -> (state tracking)
  21328: "Shutting down replication"    -> (state tracking)
"""

import json
import os
import sys
from datetime import datetime, timezone


# Map container-internal hostnames to TLA+ server IDs.
HOST_MAP = {
    "mongo1:27017": "s1",
    "mongo2:27017": "s2",
    "mongo3:27017": "s3",
    "mongo4:27017": "s4",
    "mongo5:27017": "s5",
}

# Reverse: container name -> TLA+ ID
CONTAINER_MAP = {
    "mongo-rs0-1": "s1",
    "mongo-rs0-2": "s2",
    "mongo-rs0-3": "s3",
    "mongo-rs0-4": "s4",
    "mongo-rs0-5": "s5",
}


def map_host(host_port):
    """Map host:port to TLA+ server ID."""
    return HOST_MAP.get(host_port, host_port)


def parse_iso_to_ns(iso_str):
    """Parse MongoDB ISO 8601 timestamp to epoch nanoseconds string."""
    try:
        iso_str = iso_str.replace("Z", "+00:00")
        dt = datetime.fromisoformat(iso_str)
        return str(int(dt.timestamp() * 1e9))
    except (ValueError, TypeError):
        return str(int(datetime.now(timezone.utc).timestamp() * 1e9))


class NodeState:
    """Track per-node state for enriching trace events."""
    def __init__(self, nid):
        self.nid = nid
        self.currentTerm = 0
        self.state = "SECONDARY"
        self.configVersion = 1
        self.configTerm = 0
        self.drainMode = False
        self.config_members = []  # list of host:port

    def to_dict(self):
        return {
            "currentTerm": self.currentTerm,
            "state": self.state,
            "configVersion": self.configVersion,
            "configTerm": self.configTerm,
            "drainMode": self.drainMode,
        }


def make_event(ts_ns, event_name, node_id, state_dict, extra=None):
    """Create a trace event dict matching Trace.tla envelope."""
    ev = {
        "tag": "trace",
        "ts": ts_ns,
        "event": {
            "name": event_name,
            "node": node_id,
            "state": state_dict,
        }
    }
    if extra:
        ev["event"].update(extra)
    return ev


def parse_config_bson(config_obj):
    """Extract configVersion, configTerm, member list from config BSON."""
    version = config_obj.get("version", 0)

    # configTerm: MongoDB uses "term" field in the config object.
    # For force reconfig, the "term" field is ABSENT from the config BSON.
    # This corresponds to UninitializedTerm (-1) in the TLA+ spec.
    if "term" not in config_obj:
        term = -1  # UninitializedTerm for force reconfig
    else:
        term = config_obj["term"]
        if term is None:
            term = -1
        elif isinstance(term, dict) and "$numberLong" in term:
            term = int(term["$numberLong"])
        else:
            try:
                term = int(term)
            except (TypeError, ValueError):
                term = -1

    members = []
    newly_added_members = set()
    for m in config_obj.get("members", []):
        host = m.get("host", "")
        members.append(host)
        if m.get("newlyAdded", False):
            newly_added_members.add(host)

    return version, term, members, newly_added_members


def parse_node_log(log_file, node_id):
    """Parse a single node's mongod log for replication events.

    Returns list of trace event dicts, sorted by timestamp.
    """
    ns = NodeState(node_id)
    events = []

    # Track whether a user-initiated reconfig command (21352) is pending.
    pending_reconfig_command = False
    # Track recently removed newlyAdded (4634505 precedes 21392)
    pending_newly_added_removal = None  # memberId
    # Track whether this is the first config event (rs.initiate)
    seen_first_config = False
    # Track whether CompleteDrain was already emitted from 21392 during drain
    drain_complete_emitted = False

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

            log_id = entry.get("id")
            attr = entry.get("attr", {})
            ts_str = entry.get("t", {}).get("$date", "")
            ts_ns = parse_iso_to_ns(ts_str)

            # ----------------------------------------------------------
            # 21450: "Election succeeded, assuming primary role"
            # -> WinElection
            # ----------------------------------------------------------
            if log_id == 21450:
                term = attr.get("term", ns.currentTerm)
                if isinstance(term, dict) and "$numberLong" in term:
                    term = int(term["$numberLong"])
                ns.currentTerm = int(term)
                ns.state = "PRIMARY"
                ns.drainMode = True
                events.append(make_event(ts_ns, "WinElection", node_id,
                                         ns.to_dict()))

            # ----------------------------------------------------------
            # 21331: "Transition to primary complete"
            # -> CompleteDrain (only if not already emitted from 21392)
            # ----------------------------------------------------------
            elif log_id == 21331:
                term = attr.get("term", ns.currentTerm)
                if isinstance(term, dict) and "$numberLong" in term:
                    term = int(term["$numberLong"])
                ns.currentTerm = int(term)
                ns.drainMode = False
                ns.configTerm = ns.currentTerm
                if drain_complete_emitted:
                    # Already emitted CompleteDrain from the 21392 event.
                    drain_complete_emitted = False
                else:
                    # Fallback: emit CompleteDrain from 21331 if 21392 wasn't
                    # seen during drain (shouldn't happen normally).
                    events.append(make_event(ts_ns, "CompleteDrain", node_id,
                                             ns.to_dict()))

            # ----------------------------------------------------------
            # 21352: "replSetReconfig admin command received"
            # Context marker: next 21392 on this node is user-initiated.
            # ----------------------------------------------------------
            elif log_id == 21352:
                pending_reconfig_command = True

            # ----------------------------------------------------------
            # 4634505: "Beginning automatic reconfig to remove 'newlyAdded'"
            # Context marker: next 21392 on this node is RemoveNewlyAdded.
            # Use 4634505 (begin), not 4634504 (complete), because 4634504
            # fires AFTER the 21392 config change and would pollute the
            # next 21392 event.
            # ----------------------------------------------------------
            elif log_id == 4634505:
                member_id = attr.get("memberId", None)
                pending_newly_added_removal = member_id

            # ----------------------------------------------------------
            # 21392: "New replica set config in use"
            # -> Reconfig / ForceReconfig / SendConfig / RemoveNewlyAdded
            # Classification:
            #   1. If preceded by 4634504 -> RemoveNewlyAdded
            #   2. If configTerm == -1 -> ForceReconfig
            #   3. If preceded by 21352 -> Reconfig
            #   4. Otherwise -> SendConfig (heartbeat propagation)
            # ----------------------------------------------------------
            elif log_id == 21392:
                config_obj = attr.get("config", {})
                if not config_obj:
                    continue

                version, term, members, newly_added = parse_config_bson(config_obj)
                old_version = ns.configVersion
                old_term = ns.configTerm

                ns.configVersion = version
                ns.configTerm = term
                ns.config_members = members

                # Build config set for trace (TLA+ server IDs)
                config_set = [map_host(h) for h in members]

                # Skip initial config (rs.initiate) — not a protocol action.
                # TraceInit handles the initial state.
                if not seen_first_config:
                    seen_first_config = True
                    continue

                # Config change during drain mode = doOptimizedReconfig.
                # This is the actual CompleteDrain action — emit it here
                # (before heartbeat propagation events) rather than at the
                # 21331 log which fires later.
                if ns.drainMode and pending_newly_added_removal is None:
                    ns.drainMode = False
                    drain_complete_emitted = True
                    events.append(make_event(ts_ns, "CompleteDrain", node_id,
                                             ns.to_dict()))
                    continue

                if pending_newly_added_removal is not None:
                    # RemoveNewlyAdded: find which member lost newlyAdded
                    # The memberId from 4634505 is a member _id (int).
                    member_host = None
                    for m in config_obj.get("members", []):
                        m_id = m.get("_id")
                        if isinstance(m_id, dict):
                            m_id = m_id.get("$numberInt", m_id)
                        if str(m_id) == str(pending_newly_added_removal):
                            member_host = m.get("host", "")
                            break
                    member_sid = map_host(member_host) if member_host else "unknown"
                    events.append(make_event(ts_ns, "RemoveNewlyAdded", node_id,
                                             ns.to_dict(),
                                             {"member": member_sid,
                                              "config": config_set}))
                    pending_newly_added_removal = None
                    pending_reconfig_command = False

                elif pending_reconfig_command and term == -1:
                    # ForceReconfig: user-initiated rs.reconfig({force:true})
                    # Only the node that ran the command (21352 preceded)
                    # emits ForceReconfig. Secondaries receiving this config
                    # via heartbeat emit SendConfig.
                    events.append(make_event(ts_ns, "ForceReconfig", node_id,
                                             ns.to_dict(),
                                             {"config": config_set}))
                    pending_reconfig_command = False

                elif pending_reconfig_command:
                    # User-initiated safe Reconfig
                    events.append(make_event(ts_ns, "Reconfig", node_id,
                                             ns.to_dict(),
                                             {"config": config_set}))
                    pending_reconfig_command = False

                else:
                    # Heartbeat config propagation (SendConfig).
                    # Includes both normal configs AND force configs
                    # propagated via heartbeat to secondaries.
                    # Heartbeat also exchanges terms — the receiver's term
                    # is updated to at least the config's term.
                    # (MongoDB does this internally but doesn't always log it.)
                    if term >= 0 and term > ns.currentTerm:
                        ns.currentTerm = term
                    events.append(make_event(ts_ns, "SendConfig", node_id,
                                             ns.to_dict(),
                                             {"receiver": node_id,
                                              "sender": "unknown",
                                              "config": config_set}))

            # ----------------------------------------------------------
            # 21320: "Updated term"
            # -> UpdateTerms (term exchange via heartbeat/vote)
            # ----------------------------------------------------------
            elif log_id == 21320:
                new_term = attr.get("term", ns.currentTerm)
                if isinstance(new_term, dict) and "$numberLong" in new_term:
                    new_term = int(new_term["$numberLong"])
                new_term = int(new_term)
                if new_term != ns.currentTerm:
                    old_term_val = ns.currentTerm
                    ns.currentTerm = new_term
                    # If term increased, node steps down to Follower
                    if new_term > old_term_val and ns.state == "PRIMARY":
                        ns.state = "SECONDARY"
                        ns.drainMode = False
                    events.append(make_event(ts_ns, "UpdateTerms", node_id,
                                             ns.to_dict(),
                                             {"peer": "unknown"}))

            # ----------------------------------------------------------
            # 21592: "Rollback complete"
            # -> RollbackEntries
            # ----------------------------------------------------------
            elif log_id == 21592:
                events.append(make_event(ts_ns, "RollbackEntries", node_id,
                                         ns.to_dict(),
                                         {"source": "unknown"}))

            # ----------------------------------------------------------
            # State tracking only (no trace event emitted)
            # ----------------------------------------------------------
            elif log_id in (21355, 21475):
                # Stepping down from primary
                ns.state = "SECONDARY"
                ns.drainMode = False

            elif log_id == 21328:
                # Shutting down replication subsystems
                ns.state = "DOWN"
                ns.drainMode = False

    return events


def load_client_events(client_file):
    """Load client-side trace events from NDJSON file."""
    events = []
    if not os.path.exists(client_file):
        return events
    with open(client_file) as f:
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


def resolve_send_config_senders(events):
    """Post-process SendConfig events to fill in sender field.

    Two-pass approach:
    1. Build full config_timeline from ALL events (who created each config)
    2. Resolve each SendConfig's sender from the timeline
    """
    # Pass 1: Build complete config source map
    config_source = {}  # (version, term) -> node that originated this config
    for ev in events:
        name = ev.get("event", {}).get("name", "")
        node = ev.get("event", {}).get("node", "")
        state = ev.get("event", {}).get("state", {})
        cv = state.get("configVersion", 0)
        ct = state.get("configTerm", 0)

        if name in ("Reconfig", "ForceReconfig", "CompleteDrain",
                     "RemoveNewlyAdded", "WinElection"):
            if (cv, ct) not in config_source:
                config_source[(cv, ct)] = node

    # Pass 2: Resolve SendConfig senders
    for ev in events:
        name = ev.get("event", {}).get("name", "")
        if name == "SendConfig":
            node = ev.get("event", {}).get("node", "")
            state = ev.get("event", {}).get("state", {})
            cv = state.get("configVersion", 0)
            ct = state.get("configTerm", 0)
            sender = config_source.get((cv, ct), "unknown")
            if sender == node:
                sender = "unknown"  # Can't send to self
            ev["event"]["sender"] = sender

    return events


def merge_and_write(all_events, output_file):
    """Sort all events by timestamp and write NDJSON."""
    all_events.sort(key=lambda e: int(e.get("ts", "0")))

    with open(output_file, "w") as f:
        for ev in all_events:
            if ev.get("tag") == "trace":
                f.write(json.dumps(ev, separators=(",", ":")) + "\n")

    trace_count = sum(1 for e in all_events if e.get("tag") == "trace")
    return trace_count


def assign_to_scenarios(events, scenario_boundaries):
    """Split events into per-scenario traces based on time boundaries.

    scenario_boundaries: list of (name, start_ts, end_ts)
    Events before first scenario go to first scenario.
    Events after last boundary go to last scenario.
    """
    if not scenario_boundaries:
        return {"all": events}

    result = {name: [] for name, _, _ in scenario_boundaries}

    for ev in events:
        ts = int(ev.get("ts", "0"))
        assigned = False
        for name, start, end in scenario_boundaries:
            if start <= ts <= end:
                result[name].append(ev)
                assigned = True
                break
        if not assigned:
            # Assign to the closest scenario
            min_dist = float("inf")
            closest = scenario_boundaries[0][0]
            for name, start, end in scenario_boundaries:
                dist = min(abs(ts - start), abs(ts - end))
                if dist < min_dist:
                    min_dist = dist
                    closest = name
            result[closest].append(ev)

    return result


def main():
    harness_dir = os.environ.get("HARNESS_DIR",
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    trace_dir = os.environ.get("TRACE_DIR",
        os.path.join(os.path.dirname(harness_dir), "traces"))
    log_dir = os.path.join(harness_dir, "logs")

    print("Parsing replica set logs...")

    # Parse logs from each node
    all_events = []
    for container, sid in sorted(CONTAINER_MAP.items()):
        log_file = os.path.join(log_dir, f"{container.replace('mongo-rs0-', 'mongo')}.log")
        node_events = parse_node_log(log_file, sid)
        print(f"  {container} ({sid}): {len(node_events)} events")
        all_events.extend(node_events)

    # Load client-side events from all scenario files
    for fname in sorted(os.listdir(trace_dir)):
        if fname.endswith("_client.ndjson"):
            client_file = os.path.join(trace_dir, fname)
            client_events = load_client_events(client_file)
            if client_events:
                print(f"  Client events from {fname}: {len(client_events)}")
                all_events.extend(client_events)

    # Sort by timestamp
    all_events.sort(key=lambda e: int(e.get("ts", "0")))

    # Resolve SendConfig sender fields
    all_events = resolve_send_config_senders(all_events)

    # Write combined trace
    combined_file = os.path.join(trace_dir, "combined.ndjson")
    total = merge_and_write(all_events, combined_file)
    print(f"\nCombined trace: {total} events -> {combined_file}")

    # Also split into per-scenario traces if client files exist
    scenarios = []
    for fname in sorted(os.listdir(trace_dir)):
        if fname.endswith("_client.ndjson"):
            scenario_name = fname.replace("_client.ndjson", "")
            scenarios.append(scenario_name)

    if scenarios:
        # Use client event timestamps as scenario boundaries
        for scenario_name in scenarios:
            client_file = os.path.join(trace_dir, f"{scenario_name}_client.ndjson")
            client_events = load_client_events(client_file)
            if client_events:
                ts_list = [int(e.get("ts", "0")) for e in client_events]
                start_ts = min(ts_list)
                end_ts = max(ts_list)
            else:
                # No client events, use the full range
                start_ts = 0
                end_ts = int(9e18)

            # For per-scenario trace, include events around the scenario time window
            # with a 30-second buffer on each side
            buffer_ns = 30 * 1_000_000_000
            scenario_events = [
                e for e in all_events
                if start_ts - buffer_ns <= int(e.get("ts", "0")) <= end_ts + buffer_ns
            ]

            if not scenario_events:
                # If no events in window, write all events (single scenario mode)
                scenario_events = all_events

            output_file = os.path.join(trace_dir, f"{scenario_name}.ndjson")
            count = merge_and_write(scenario_events, output_file)
            event_names = list(dict.fromkeys(
                e["event"]["name"] for e in scenario_events
                if "event" in e and isinstance(e["event"], dict) and "name" in e["event"]
            ))
            print(f"  {scenario_name}.ndjson: {count} events")
            print(f"    actions: {event_names}")

    # Summary
    print("\nEvent summary:")
    event_counts = {}
    for ev in all_events:
        name = ev.get("event", {}).get("name", "unknown")
        event_counts[name] = event_counts.get(name, 0) + 1
    for name, count in sorted(event_counts.items()):
        print(f"  {name}: {count}")

    print("\nLog parsing complete.")


if __name__ == "__main__":
    main()
