#!/usr/bin/env python3
"""
Parse MongoDB LOGV2 structured JSON logs for DDL coordinator phase transitions,
merge with client-side trace events, and produce final NDJSON trace files
for TLA+ trace validation.

DDL events come from log ID 5390501 (universal phase transition log), emitted
by _enterPhaseGeneric() in sharding_coordinator.cpp at debug level 2.

Client-side events (router/shard actions) come from test_scenarios.py.
"""

import json
import os
import sys
from datetime import datetime, timezone


# ============================================================================
# DDL Phase Mapping
# ============================================================================

# operationType (from attr.coordinatorId.operationType) + newPhase → (TLA+ event, ddlPhase)
# operationType values from MongoDB 8.x: createCollection_V4, dropCollection_V2,
# renameCollection, movePrimary, createDatabase, addShard
DDL_PHASE_MAP = {
    # Create tracked collection — operationType: createCollection_V4
    ("createCollection_V4", "enterWriteCriticalSectionOnCoordinator"): ("CreateTrackedAcquireLock", "acquireLock"),
    ("createCollection_V4", "enterCriticalSection"): ("CreateTrackedEnterCS", "enterCS"),
    ("createCollection_V4", "commitOnShardingCatalog"): ("CreateTrackedCommitMetadata", "commitMetadata"),
    ("createCollection_V4", "exitCriticalSection"): ("CreateTrackedExitCS", "done"),
    # Older versions without _V4 suffix
    ("createCollection", "enterWriteCriticalSectionOnCoordinator"): ("CreateTrackedAcquireLock", "acquireLock"),
    ("createCollection", "enterCriticalSection"): ("CreateTrackedEnterCS", "enterCS"),
    ("createCollection", "commitOnShardingCatalog"): ("CreateTrackedCommitMetadata", "commitMetadata"),
    ("createCollection", "exitCriticalSection"): ("CreateTrackedExitCS", "done"),

    # Drop collection — operationType: dropCollection_V2
    ("dropCollection_V2", "freezeCollection"): ("DropAcquireLock", None),
    ("dropCollection_V2", "enterCriticalSection"): ("DropEnterCS", None),
    ("dropCollection_V2", "dropCollection"): ("DropCommitMetadata", None),
    ("dropCollection_V2", "releaseCriticalSection"): ("DropExitCS", None),
    ("dropCollection", "freezeCollection"): ("DropAcquireLock", None),
    ("dropCollection", "enterCriticalSection"): ("DropEnterCS", None),
    ("dropCollection", "dropCollection"): ("DropCommitMetadata", None),
    ("dropCollection", "releaseCriticalSection"): ("DropExitCS", None),

    # Rename collection — operationType: renameCollection
    ("renameCollection", "checkPreconditions"): ("RenameAcquireLock", None),
    ("renameCollection", "blockCrudAndRename"): ("RenameEnterCS", None),
    ("renameCollection", "renameMetadata"): ("RenameCommitMetadata", None),
    ("renameCollection", "unblockCRUD"): ("RenameExitCS", None),

    # MovePrimary — operationType: movePrimary
    ("movePrimary", "clone"): ("MovePrimaryAcquireLock", None),
    ("movePrimary", "enterCriticalSection"): ("MovePrimaryEnterCS", None),
    ("movePrimary", "commit"): ("MovePrimaryCommitMetadata", None),
    ("movePrimary", "exitCriticalSection"): ("MovePrimaryExitCS", None),
}

# Additional log IDs for DDL events not captured by 5390501
SUPPLEMENTARY_LOG_IDS = {
    5390503: "CollectionDropped",       # "Collection dropped" (drop complete)
    5460504: "CollectionRenamed",       # "Collection renamed" (rename complete)
    7120201: "MovePrimaryStarted",      # "Running movePrimary operation"
    7120206: "MovePrimaryCompleted",    # "Completed movePrimary operation"
    5565601: "CoordinatorReleased",     # "Releasing sharding coordinator"
    7418502: "CoordinatorFailed",       # coordinator failed, abort reason persisted
    5656000: "CoordinatorRetry",        # Re-executing coordinator (retry)
}


def parse_iso_to_ns(iso_str):
    """Parse ISO 8601 timestamp to epoch nanoseconds."""
    try:
        dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
        return int(dt.timestamp() * 1e9)
    except (ValueError, TypeError):
        return 0


def get_coordinator_info(attr):
    """Extract coordinator type and namespace from attr.coordinatorId.

    Returns (operationType, namespace) or (None, None).
    attr.coordinatorId format: {"namespace": "test.coll1", "operationType": "createCollection_V4"}
    """
    coord_id = attr.get("coordinatorId", {})
    if not isinstance(coord_id, dict):
        return None, None
    op_type = coord_id.get("operationType", "")
    ns = coord_id.get("namespace", "")
    return str(op_type) if op_type else None, str(ns) if ns else None


def parse_ddl_events(log_path, label=""):
    """Parse a server log file for DDL coordinator phase transitions.

    Returns list of trace events sorted by timestamp.
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

            log_id = entry.get("id")
            if log_id != 5390501:
                continue

            attr = entry.get("attr", {})
            ts_str = entry.get("t", {}).get("$date", "")
            ts = ts_str  # Keep ISO format

            new_phase = attr.get("newPhase", "")
            op_type, ns = get_coordinator_info(attr)

            if not op_type or not new_phase:
                continue

            # Look up the TLA+ event using operationType + newPhase
            key = (op_type, new_phase)
            if key not in DDL_PHASE_MAP:
                continue

            event_name, ddl_phase = DDL_PHASE_MAP[key]
            event = {"event": event_name, "ts": ts}

            if ns:
                # For movePrimary, the "ns" is the database name (not db.coll)
                if op_type == "movePrimary":
                    event["_dbName"] = ns  # store for later use
                else:
                    event["ns"] = ns

            if ddl_phase:
                event["ddlPhase"] = ddl_phase

            # Store sort key
            event["_ts_ns"] = parse_iso_to_ns(ts_str)
            events.append(event)

            if label:
                print(f"    [{label}] {event_name} ns={ns} phase={new_phase}")

    return events


def parse_move_primary_metadata(log_path):
    """Parse movePrimary logs for toShard info (log IDs 7120201, 7120206)."""
    info = {}  # dbName -> toShard
    if not os.path.exists(log_path):
        return info

    with open(log_path) as f:
        for line in f:
            try:
                entry = json.loads(line.strip())
            except json.JSONDecodeError:
                continue

            log_id = entry.get("id")
            if log_id in (7120201, 7120206):
                attr = entry.get("attr", {})
                to_shard = attr.get("to", "")
                db_name = attr.get("db", attr.get("namespace", ""))
                if isinstance(db_name, dict):
                    db_name = db_name.get("db", "")
                if to_shard and db_name:
                    info[str(db_name)] = str(to_shard)

    return info


def read_client_trace(filepath):
    """Read client-side trace file, returning events and timestamp markers."""
    events = []
    markers = {}

    if not os.path.exists(filepath):
        return events, markers

    with open(filepath) as f:
        for line in f:
            try:
                obj = json.loads(line.strip())
            except json.JSONDecodeError:
                continue

            if "_marker" in obj:
                markers[obj["_marker"]] = obj.get("ts", "")
            elif "_meta" in obj:
                pass  # skip metadata lines
            elif "event" in obj:
                obj["_ts_ns"] = parse_iso_to_ns(obj.get("ts", ""))
                events.append(obj)

    return events, markers


def merge_and_write_trace(client_events, ddl_events, move_primary_info,
                          output_path, scenario_name):
    """Merge client-side and DDL events, write final NDJSON trace.

    Ordering: DDL create events → client router/shard events → DDL drop events.
    Within each group, sort by timestamp.
    """
    # Annotate movePrimary events with toShard
    for ev in ddl_events:
        if ev["event"].startswith("MovePrimary") and "_dbName" in ev:
            db_name = ev.pop("_dbName")
            to_shard = move_primary_info.get(db_name, "unknown")
            ev["toShard"] = to_shard

    # Classify events into phases
    create_events = [e for e in ddl_events
                     if e["event"].startswith("Create")]
    drop_events = [e for e in ddl_events
                   if e["event"].startswith("Drop")]
    move_events = [e for e in ddl_events
                   if e["event"].startswith("MovePrimary")]
    other_ddl = [e for e in ddl_events
                 if not any(e["event"].startswith(p) for p in
                           ["Create", "Drop", "MovePrimary"])]

    # Sort each group by timestamp
    for group in [create_events, drop_events, move_events, other_ddl, client_events]:
        group.sort(key=lambda e: e.get("_ts_ns", 0))

    # Build ordered trace: create DDL → move DDL → client events → drop DDL
    ordered = create_events + move_events + other_ddl + client_events + drop_events

    # Clean internal fields before writing
    with open(output_path, "w") as f:
        for ev in ordered:
            clean = {k: v for k, v in ev.items() if not k.startswith("_")}
            f.write(json.dumps(clean, separators=(",", ":")) + "\n")

    n_ddl = len(create_events) + len(drop_events) + len(move_events)
    n_client = len(client_events)
    print(f"  -> {output_path}: {len(ordered)} events "
          f"({n_ddl} DDL + {n_client} client)")
    return len(ordered)


def main():
    src_dir = os.path.dirname(os.path.abspath(__file__))
    harness_dir = os.path.dirname(src_dir)
    base_dir = os.path.dirname(harness_dir)
    trace_dir = os.path.join(base_dir, "traces")
    log_dir = os.path.join(harness_dir, "logs")

    print("=== Parsing MongoDB server logs for DDL events ===")

    # Log files to search (DDL coordinators can run on configsvr or primary shard)
    log_files = [
        os.path.join(log_dir, "configsvr.log"),
        os.path.join(log_dir, "shard0.log"),
        os.path.join(log_dir, "shard1.log"),
    ]

    # Parse DDL events from all server logs
    all_ddl_events = []
    move_primary_info = {}
    for log_path in log_files:
        label = os.path.basename(log_path).replace(".log", "")
        ddl_events = parse_ddl_events(log_path, label=label)
        all_ddl_events.extend(ddl_events)
        mp_info = parse_move_primary_metadata(log_path)
        move_primary_info.update(mp_info)

    print(f"\n  Total DDL events found: {len(all_ddl_events)}")
    if move_primary_info:
        print(f"  MovePrimary info: {move_primary_info}")

    # Process each scenario
    scenarios = [
        ("basic_create_txn",
         os.path.join(trace_dir, "basic_create_txn_client.ndjson"),
         os.path.join(trace_dir, "basic_create_txn.ndjson"),
         "test.coll1"),
        ("move_primary_txn",
         os.path.join(trace_dir, "move_primary_txn_client.ndjson"),
         os.path.join(trace_dir, "move_primary_txn.ndjson"),
         "test2.coll2"),
    ]

    for scenario_name, client_path, output_path, target_ns in scenarios:
        print(f"\nScenario: {scenario_name}")

        # Read client events
        client_events, markers = read_client_trace(client_path)
        print(f"  Client events: {len(client_events)}")

        # Filter DDL events to the relevant namespace/database
        # For movePrimary scenarios, also include events for the database
        ns_prefix = target_ns.split(".")[0]  # database name
        relevant_ddl = []
        for ev in all_ddl_events:
            ev_ns = ev.get("ns", ev.get("_dbName", ""))
            if ev_ns == target_ns or ev_ns == ns_prefix or ev_ns.startswith(ns_prefix + "."):
                relevant_ddl.append(dict(ev))  # copy to avoid mutation

        print(f"  Relevant DDL events: {len(relevant_ddl)}")

        # Merge and write
        merge_and_write_trace(
            client_events, relevant_ddl, move_primary_info,
            output_path, scenario_name
        )

    print("\n=== Done ===")


if __name__ == "__main__":
    main()
