#!/usr/bin/env python3
"""
Parse MongoDB LOGV2 structured JSON logs for migration lifecycle events
and merge with client-side traces to produce NDJSON trace files matching
Trace.tla event schema.

Migration lifecycle log IDs (from migration_source_manager.cpp):
  22016: "Starting chunk migration donation"          -> extract from/to/ns
  22017: "Migration successfully entered critical section" -> StartMigration
  22018: "Migration succeeded and updated collection placement version" -> ConfigCommit
  6107802: "Finished critical section"                 -> ReleaseCriticalSection
  5089001: "Failed to complete the migration"          -> DonorStepDown

DonorRecovery log (from migration_coordinator.cpp):
  23893: "MigrationCoordinator delivering decision"    -> DonorRecovery
         (only used for step-up recovery, not normal cleanup)

ConfigCommitFail (from migration_coordinator.cpp):
  23899: "Making abort decision durable"               -> ConfigCommitFail
"""

import json
import os
import sys
from datetime import datetime, timezone


# Shard mapping
SHARD_MAP = {"shard1RS": "s1", "shard2RS": "s2", "shard1": "s1", "shard2": "s2"}

# Namespace mapping
NS_MAP = {"testdb.items": "ns1"}


def map_shard(name):
    for k, v in SHARD_MAP.items():
        if k in str(name):
            return v
    return str(name)


def map_ns(ns):
    return NS_MAP.get(ns, ns)


def parse_iso_to_ns(iso_str):
    """Parse MongoDB ISO 8601 timestamp to epoch nanoseconds."""
    try:
        iso_str = iso_str.replace("Z", "+00:00")
        dt = datetime.fromisoformat(iso_str)
        return int(dt.timestamp() * 1e9)
    except (ValueError, TypeError):
        return int(datetime.now(timezone.utc).timestamp() * 1e9)


def make_event(ts_ns, event_name, extra=None):
    """Create a trace event dict matching Trace.tla envelope."""
    ev = {"event": event_name}
    if extra:
        ev.update(extra)
    ev["_sort_ts"] = ts_ns
    return ev


def parse_migration_logs(log_file, shard_name):
    """Parse a single shard's mongod log for migration lifecycle events.

    Two-pass approach:
      Pass 1: Collect migration metadata from 22016 (from/to shard, key).
      Pass 2: Map lifecycle events using migrationId to look up metadata.
    """
    tla_shard = map_shard(shard_name)
    events = []

    if not os.path.exists(log_file):
        print(f"  WARNING: Log file not found: {log_file}")
        return events

    # Pass 1: collect migration metadata from 22016 entries
    # Key: migrationId -> {ns, from, to, key}
    migration_meta = {}

    with open(log_file) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue

            if entry.get("id") == 22016:
                attr = entry.get("attr", {})
                params = attr.get("requestParameters", {})

                # Extract namespace from _shardsvrMoveRange field
                nss = params.get("_shardsvrMoveRange", "")
                if not nss:
                    nss = attr.get("namespace", "")

                # Extract migration ID
                mig_id = ""
                mig_uuid = attr.get("migrationId", {})
                if isinstance(mig_uuid, dict):
                    uuid_obj = mig_uuid.get("uuid", mig_uuid)
                    if isinstance(uuid_obj, dict) and "$uuid" in uuid_obj:
                        mig_id = uuid_obj["$uuid"]

                # Extract from/to shards
                from_shard = tla_shard  # donor is always self
                to_shard = map_shard(params.get("toShard", ""))

                # Extract key — use the min bound if it's a real key
                key = "k1"  # default
                min_bound = params.get("min", {})
                if isinstance(min_bound, dict) and "_id" in min_bound:
                    raw_key = min_bound["_id"]
                    if isinstance(raw_key, str):
                        key = raw_key
                    # $minKey means the entire range; use default

                migration_meta[nss] = {
                    "ns": map_ns(nss),
                    "from": from_shard,
                    "to": to_shard,
                    "key": key,
                }
                if mig_id:
                    migration_meta[mig_id] = migration_meta[nss]

    # Pass 2: map lifecycle events
    # Track if we've seen DonorStepDown for this shard — if so, 23893 is recovery
    saw_step_down = set()  # set of namespace strings

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

            # Helper: extract namespace from attr
            def get_ns():
                nss = attr.get("namespace", "")
                if not nss:
                    nss = str(attr.get("nss", ""))
                return nss

            # Helper: look up migration metadata for this namespace
            def get_meta(nss):
                meta = migration_meta.get(nss, {})
                if not meta:
                    meta = migration_meta.get(map_ns(nss), {})
                return meta

            # --- StartMigration (22017) ---
            # "Migration successfully entered critical section"
            if log_id == 22017:
                nss = get_ns()
                meta = get_meta(nss)
                events.append(make_event(ts_ns, "StartMigration", {
                    "ns": meta.get("ns", map_ns(nss)),
                    "key": meta.get("key", "k1"),
                    "from": meta.get("from", tla_shard),
                    "to": meta.get("to", "s2"),
                    "migrationPhase": "CritSec",
                }))

            # --- ConfigCommit (22018) ---
            # "Migration succeeded and updated collection placement version"
            elif log_id == 22018:
                nss = get_ns()
                meta = get_meta(nss)
                events.append(make_event(ts_ns, "ConfigCommit", {
                    "ns": meta.get("ns", map_ns(nss)),
                    "migrationPhase": "Committed",
                }))

            # --- ConfigCommitFail (23899) ---
            # "Making abort decision durable"
            elif log_id == 23899:
                nss = get_ns()
                meta = get_meta(nss)
                events.append(make_event(ts_ns, "ConfigCommitFail", {
                    "ns": meta.get("ns", map_ns(nss)),
                    "migrationPhase": "Idle",
                }))

            # --- ReleaseCriticalSection (6107802) ---
            # "Finished critical section"
            elif log_id == 6107802:
                nss = get_ns()
                meta = get_meta(nss)
                events.append(make_event(ts_ns, "ReleaseCriticalSection", {
                    "ns": meta.get("ns", map_ns(nss)),
                    "migrationPhase": "Idle",
                }))

            # --- DonorStepDown (5089001) ---
            # "Failed to complete the migration"
            elif log_id == 5089001:
                nss = get_ns()
                meta = get_meta(nss)
                saw_step_down.add(nss)
                events.append(make_event(ts_ns, "DonorStepDown", {
                    "shard": tla_shard,
                    "ns": meta.get("ns", map_ns(nss)),
                }))

            # --- DonorStepDown alternative (23892) ---
            # "Migration completed without setting a decision"
            elif log_id == 23892:
                nss = get_ns()
                meta = get_meta(nss)
                saw_step_down.add(nss)
                events.append(make_event(ts_ns, "DonorStepDown", {
                    "shard": tla_shard,
                    "ns": meta.get("ns", map_ns(nss)),
                }))

            # --- DonorRecovery (23893) ---
            # "MigrationCoordinator delivering decision to self and to recipient"
            # Only emit as DonorRecovery if preceded by a DonorStepDown.
            # During normal migration, this fires as part of cleanup — skip it.
            elif log_id == 23893:
                nss = get_ns()
                if nss in saw_step_down:
                    meta = get_meta(nss)
                    decision = str(attr.get("decision", "")).lower()
                    coord_doc = "Committed" if "commit" in decision else "Aborted"
                    events.append(make_event(ts_ns, "DonorRecovery", {
                        "shard": tla_shard,
                        "ns": meta.get("ns", map_ns(nss)),
                        "coordinatorDoc": coord_doc,
                    }))
                    saw_step_down.discard(nss)

    return events


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
            if "event" in obj:
                if "ts" in obj:
                    obj["_sort_ts"] = int(obj["ts"])
                else:
                    obj["_sort_ts"] = 0
                events.append(obj)
    return events


def merge_and_write(client_events, server_events, output_file):
    """Merge client and server events, sort by timestamp, write NDJSON."""
    all_events = list(client_events) + list(server_events)
    all_events.sort(key=lambda e: e.get("_sort_ts", 0))

    with open(output_file, "w") as f:
        for ev in all_events:
            out = {k: v for k, v in ev.items() if k != "_sort_ts"}
            f.write(json.dumps(out, separators=(",", ":")) + "\n")

    return len(all_events)


def main():
    harness_dir = os.environ.get("HARNESS_DIR",
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    trace_dir = os.environ.get("TRACE_DIR",
        os.path.join(os.path.dirname(harness_dir), "traces"))
    log_dir = os.path.join(harness_dir, "logs")

    # Parse all shard logs for migration events
    shard1_events = parse_migration_logs(
        os.path.join(log_dir, "shard1.log"), "shard1RS")
    shard2_events = parse_migration_logs(
        os.path.join(log_dir, "shard2.log"), "shard2RS")
    all_server_events = shard1_events + shard2_events
    print(f"Parsed {len(shard1_events)} events from shard1, "
          f"{len(shard2_events)} from shard2")

    # Load scenario metadata
    meta_path = os.path.join(trace_dir, "scenario_meta.json")
    if not os.path.exists(meta_path):
        print(f"WARNING: {meta_path} not found. Writing server-only traces.")
        output = os.path.join(trace_dir, "server_events.ndjson")
        count = merge_and_write([], all_server_events, output)
        print(f"  server_events.ndjson: {count} events")
        return

    with open(meta_path) as f:
        scenarios = json.load(f)

    for scenario in scenarios:
        name = scenario["name"]
        client_file = os.path.join(trace_dir, f"{name}_client.ndjson")
        client_events = load_client_events(client_file)

        ts_start = scenario.get("ts_start", 0)
        ts_end = scenario.get("ts_end", float("inf"))
        scenario_server_events = [
            e for e in all_server_events
            if ts_start <= e.get("_sort_ts", 0) <= ts_end
        ]

        if "include_migration" in scenario and scenario["include_migration"]:
            relevant_server = scenario_server_events
        else:
            relevant_server = []

        output_file = os.path.join(trace_dir, f"{name}.ndjson")
        count = merge_and_write(client_events, relevant_server, output_file)
        event_names = list(dict.fromkeys(
            e.get("event", "") for e in client_events + relevant_server
        ))
        print(f"  {name}.ndjson: {count} events "
              f"(client: {len(client_events)}, server: {len(relevant_server)})")
        print(f"    actions: {event_names}")

    print("Log parsing complete.")


if __name__ == "__main__":
    main()
