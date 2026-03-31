#!/usr/bin/env python3
"""
preprocess_trace.py — Extract range deletion trace events from MongoDB structured logs
and convert them to NDJSON format for TLA+ trace validation.

Two-pass approach:
  Pass 1: Extract all relevant log entries and build cross-reference maps
          (migration ID → range, collection UUID → range, etc.)
  Pass 2: Emit NDJSON trace events with enriched fields from cross-references.

Usage:
    python3 preprocess_trace.py <input_log_file> <output_ndjson> [--after TIMESTAMP]
"""

import json
import sys
import argparse
from collections import OrderedDict


def unwrap_uuid(val):
    """Unwrap MongoDB's various UUID representations to a plain string."""
    if val is None:
        return None
    if isinstance(val, str):
        return val
    if isinstance(val, dict):
        if "$uuid" in val:
            return val["$uuid"]
        if "uuid" in val:
            return unwrap_uuid(val["uuid"])
    return str(val)


def normalize_range(range_str):
    """Normalize a range string so different representations of the same range
    map to the same key.

    MongoDB logs ranges in two formats:
    1. String: "[{ _id: MinKey }, { _id: MaxKey })"
    2. Dict-as-string: "{'min': {'_id': {'$minKey': 1}}, 'max': {'_id': {'$maxKey': 1}}}"

    We normalize both to a canonical form: "MinKey..MaxKey" or "0..10".
    """
    if range_str is None:
        return None
    s = str(range_str)

    # Extract boundary values from various formats
    import re

    # Detect MinKey/MaxKey
    has_minkey = "MinKey" in s or "$minKey" in s or "minKey" in s
    has_maxkey = "MaxKey" in s or "$maxKey" in s or "maxKey" in s

    if has_minkey and has_maxkey:
        return "MinKey..MaxKey"

    # Try to extract numeric boundaries: [{ _id: 0 }, { _id: 10 })
    nums = re.findall(r'_id:\s*(\d+)', s)
    if len(nums) == 2:
        return f"{nums[0]}..{nums[1]}"

    # Try dict format: {'min': {'_id': 0}, 'max': {'_id': 10}}
    nums = re.findall(r"'_id':\s*(\d+)", s)
    if len(nums) == 2:
        return f"{nums[0]}..{nums[1]}"

    # Fallback: return cleaned string
    return s


def parse_log_line(line):
    """Parse a MongoDB structured log line (JSON)."""
    line = line.strip()
    if not line:
        return None
    try:
        return json.loads(line)
    except json.JSONDecodeError:
        return None


def get_ts(entry):
    """Extract ISO 8601 timestamp from MongoDB log entry."""
    t = entry.get("t", {})
    if isinstance(t, dict) and "$date" in t:
        return t["$date"]
    return str(t)


class IDMapper:
    """Maps implementation IDs to TLA+ spec constants."""

    def __init__(self):
        self._migration_map = OrderedDict()
        self._range_map = OrderedDict()
        self._task_map = OrderedDict()
        self._counters = {"m": 0, "r": 0, "t": 0}
        # Cross-reference: migration UUID → (coll_uuid, range_str)
        self.migration_to_task_key = {}

    def migration(self, mid):
        mid = str(mid)
        if mid not in self._migration_map:
            self._counters["m"] += 1
            self._migration_map[mid] = f"M{self._counters['m']}"
        return self._migration_map[mid]

    def range(self, r):
        r = normalize_range(r)
        if r not in self._range_map:
            self._counters["r"] += 1
            self._range_map[r] = f"R{self._counters['r']}"
        return self._range_map[r]

    def task(self, coll_uuid, range_str):
        range_str = normalize_range(range_str)
        key = f"{coll_uuid}|{range_str}"
        if key not in self._task_map:
            self._counters["t"] += 1
            self._task_map[key] = self._counters["t"]
        return self._task_map[key]

    def register_migration(self, mid, coll_uuid, range_str):
        """Register a migration→task cross-reference."""
        self.migration_to_task_key[str(mid)] = (coll_uuid, normalize_range(range_str))

    def task_from_migration(self, mid):
        """Get task ID from migration UUID via cross-reference."""
        mid = str(mid)
        if mid in self.migration_to_task_key:
            cu, rs = self.migration_to_task_key[mid]
            return self.task(cu, rs)
        return None

    def range_from_migration(self, mid):
        """Get range ID from migration UUID."""
        mid = str(mid)
        if mid in self.migration_to_task_key:
            _, rs = self.migration_to_task_key[mid]
            return self.range(rs)
        return None

    def summary(self):
        print("\n=== ID Mappings ===")
        print(f"  Migrations: {dict(self._migration_map)}")
        print(f"  Ranges: {dict(self._range_map)}")
        print(f"  Tasks: {dict(self._task_map)}")
        print(f"  Migration→Task cross-ref: {dict(self.migration_to_task_key)}")


# ========================================================================
# Log IDs we care about (in processing order)
# ========================================================================
RELEVANT_IDS = {
    # Service lifecycle
    6834800,   # RecoveryBegin
    6834802,   # Recovery finished (info)
    11079600,  # Service is now up → RecoveryComplete
    11420000,  # Processor state transition
    # Migration lifecycle
    23889,     # Persisting migration coordinator doc (has full migrationDoc)
    23890,     # Persisting range deletion task on donor
    23891,     # Setting migration decision
    23893,     # Delivering decision
    23894,     # Making commit decision durable
    6555800,   # Marking task as ready (ClearPending)
    23899,     # Making abort decision durable
    23901,     # Deleting range deletion task on donor
    # Task registration
    7536600,   # Registering range deletion task
    11943500,  # Waiting for overlapping task
    7536601,   # Finished waiting for ongoing queries
    7536602,   # Scheduling range deletion task
    6180600,   # Query dependency info
    # Deletion execution
    6872501,   # Beginning deletion
    9239400,   # Finished deletion
    6872504,   # Completed removal of persistent task
}


def extract_fields(entry):
    """Extract all possible fields from a log entry's attr dict."""
    attr = entry.get("attr", {})
    fields = {}

    # Collection UUID — various nesting levels
    for key in ["collectionUUID", "collectionUuid", "collUUID"]:
        if key in attr:
            fields["coll_uuid"] = unwrap_uuid(attr[key])
            break

    # Range string
    if "range" in attr:
        fields["range_str"] = str(attr["range"])

    # Migration ID
    if "migrationId" in attr:
        fields["migration_id"] = unwrap_uuid(attr["migrationId"])

    # Pending flag
    if "pending" in attr:
        fields["pending"] = attr["pending"]

    # Decision
    if "decision" in attr:
        fields["decision"] = str(attr["decision"]).lower()

    # Namespace
    if "namespace" in attr:
        fields["namespace"] = attr["namespace"]

    # Processor state transition
    if "oldState" in attr:
        fields["old_state"] = str(attr["oldState"])
    if "newState" in attr:
        fields["new_state"] = str(attr["newState"])

    # Range deletion sub-document (from 6555800)
    if "rangeDeletion" in attr:
        rd = attr["rangeDeletion"]
        if isinstance(rd, dict):
            rd_coll = unwrap_uuid(rd.get("collectionUuid"))
            if rd_coll:
                fields["coll_uuid"] = rd_coll
            rd_mid = unwrap_uuid(rd.get("_id"))
            if rd_mid:
                fields["migration_id"] = rd_mid
            rd_range = rd.get("range")
            if rd_range:
                fields["range_str"] = str(rd_range)

    # Migration doc (from 23889)
    if "migrationDoc" in attr:
        md = attr["migrationDoc"]
        if isinstance(md, dict):
            md_mid = unwrap_uuid(md.get("_id"))
            if md_mid:
                fields["migration_id"] = md_mid
            md_coll = unwrap_uuid(md.get("collectionUuid"))
            if md_coll:
                fields["coll_uuid"] = md_coll
            md_range = md.get("range")
            if md_range:
                fields["range_str"] = str(md_range)

    return fields


def pass1_build_crossref(entries, mapper):
    """Pass 1: Build cross-reference maps from all entries."""
    for entry in entries:
        lid = entry.get("id")
        fields = extract_fields(entry)

        mid = fields.get("migration_id")
        cu = fields.get("coll_uuid")
        rs = fields.get("range_str")

        # Register migration→task cross-reference when we have all three
        if mid and cu and rs:
            mapper.register_migration(mid, cu, rs)
            mapper.migration(mid)
            mapper.range(rs)
            mapper.task(cu, rs)


def pass2_emit_events(entries, mapper, after_ts=None):
    """Pass 2: Convert log entries to trace events."""
    events = []

    for entry in entries:
        lid = entry.get("id")
        ts = get_ts(entry)
        fields = extract_fields(entry)

        if after_ts and ts < after_ts:
            continue

        ev = OrderedDict()
        ev["tag"] = "range_deletion"
        ev["ts"] = ts

        mid = fields.get("migration_id")
        cu = fields.get("coll_uuid")
        rs = fields.get("range_str")

        # Helper to set task/migration/range on the event
        def set_task_fields():
            if cu and rs:
                ev["task"] = mapper.task(cu, rs)
                ev["range"] = mapper.range(rs)
            elif mid:
                t = mapper.task_from_migration(mid)
                if t:
                    ev["task"] = t
                r = mapper.range_from_migration(mid)
                if r:
                    ev["range"] = r

        def set_migration_field():
            if mid:
                ev["migration"] = mapper.migration(mid)
            elif cu and rs:
                # Reverse lookup: find migration for this task
                key = f"{cu}|{rs}"
                for m, (c, r) in mapper.migration_to_task_key.items():
                    if f"{c}|{r}" == key:
                        ev["migration"] = mapper.migration(m)
                        break

        # === Map each log ID ===

        if lid == 11420000:
            # Processor state transition
            new_state = fields.get("new_state", "")
            # Map MongoDB enum values to spec names
            if new_state in ("1", "kRunning"):
                ev["action"] = "StepUp"
                ev["serviceState"] = "kReadyForInit"
                ev["processorState"] = "kInit"
            elif new_state in ("2", "kStopped"):
                ev["action"] = "StepDown"
                ev["serviceState"] = "kDown"
                ev["processorState"] = "kStopped"
            else:
                continue

        elif lid == 6834800:
            ev["action"] = "RecoveryBegin"
            ev["serviceState"] = "kInitializing"

        elif lid == 11079600:
            ev["action"] = "RecoveryComplete"
            ev["serviceState"] = "kUp"
            ev["processorState"] = "kRunning"

        elif lid == 23890:
            # "Persisting range deletion task on donor" → StartMigration
            ev["action"] = "StartMigration"
            set_migration_field()
            set_task_fields()

        elif lid == 23893:
            # "Delivering decision" → CommitMigration or AbortMigration
            decision = fields.get("decision", "")
            if "committed" in decision:
                ev["action"] = "CommitMigration"
                ev["migrationState"] = "committed"
            elif "aborted" in decision:
                ev["action"] = "AbortMigration"
                ev["migrationState"] = "aborted"
            else:
                continue
            set_migration_field()
            set_task_fields()

        elif lid == 6555800:
            # "Marking range deletion task as ready" → ClearPending
            ev["action"] = "ClearPending"
            set_task_fields()
            ev["taskState"] = "registered"
            ev["taskDocPending"] = False

        elif lid == 7536600:
            # "Registering range deletion task"
            pending = fields.get("pending")
            if pending is False or pending == "false" or str(pending) == "False":
                # Re-registration via OpObserver (after ClearPending). This is the
                # second RegisterTask call that fires when pending is removed.
                # We already capture ClearPending via 6555800, so skip to avoid duplication.
                continue
            else:
                # First registration with pending=true. This is part of CommitMigration.
                # We already capture CommitMigration via 23893, so skip.
                continue

        elif lid == 11943500:
            # "Waiting for overlapping range deletion task"
            ev["action"] = "CheckOverlap"
            set_task_fields()
            ev["taskState"] = "waitOverlap"

        elif lid == 7536601:
            # "Finished waiting for ongoing queries"
            ev["action"] = "QueriesDrained"
            set_task_fields()
            ev["taskState"] = "ready"

        elif lid == 6872501:
            # "Beginning deletion of documents in orphan range"
            ev["action"] = "ProcessorPickTask"
            set_task_fields()
            ev["taskState"] = "executing"
            ev["taskDocProcessing"] = True

        elif lid == 6872504:
            # "Completed removal of persistent range deletion task"
            ev["action"] = "CompleteTask"
            set_task_fields()
            ev["taskState"] = "completed"
            ev["taskDocExists"] = False

        else:
            # Skip informational-only log IDs (6834802, 23889, 23891, 23894,
            # 23899, 23901, 7536602, 6180600, 9239400)
            continue

        events.append(ev)

    return events


def postprocess(events):
    """Post-processing: infer missing events."""
    if not events:
        return events

    first_ts = events[0]["ts"]

    # 0. If trace has no service lifecycle preamble but needs one
    #    (i.e., first event is a migration/task event that requires service to be up),
    #    inject StepUp → RecoveryBegin → RecoveryComplete at the start.
    has_service_lifecycle = any(
        ev["action"] in ("StepUp", "RecoveryBegin", "RecoveryComplete")
        for ev in events
    )
    if not has_service_lifecycle:
        needs_service = any(
            ev["action"] in ("CommitMigration", "ClearPending", "CheckOverlap",
                             "OverlapResolved", "QueriesDrained", "ProcessorPickTask",
                             "CompleteTask", "StartMigration")
            for ev in events
        )
        if needs_service:
            preamble = []
            for action, fields in [
                ("StepUp", {"serviceState": "kReadyForInit", "processorState": "kInit"}),
                ("RecoveryBegin", {"serviceState": "kInitializing"}),
                ("RecoveryComplete", {"serviceState": "kUp", "processorState": "kRunning"}),
            ]:
                ev = OrderedDict()
                ev["tag"] = "range_deletion"
                ev["ts"] = first_ts
                ev["action"] = action
                ev.update(fields)
                preamble.append(ev)
            events = preamble + events

    # 1. If RecoveryBegin has no preceding StepUp, inject one
    result = []
    saw_stepup = False
    for ev in events:
        if ev["action"] == "StepUp":
            saw_stepup = True
        elif ev["action"] == "RecoveryBegin" and not saw_stepup:
            stepup = OrderedDict()
            stepup["tag"] = "range_deletion"
            stepup["ts"] = ev["ts"]
            stepup["action"] = "StepUp"
            stepup["serviceState"] = "kReadyForInit"
            stepup["processorState"] = "kInit"
            result.append(stepup)
            saw_stepup = True
        result.append(ev)
    events = result

    # 2. Inject CheckOverlap for tasks that go straight to QueriesDrained
    tasks_with_overlap = set()
    for ev in events:
        if ev["action"] == "CheckOverlap" and "task" in ev:
            tasks_with_overlap.add(ev["task"])

    result = []
    for ev in events:
        if ev["action"] == "QueriesDrained" and "task" in ev:
            if ev["task"] not in tasks_with_overlap:
                check = OrderedDict()
                check["tag"] = "range_deletion"
                check["ts"] = ev["ts"]
                check["action"] = "CheckOverlap"
                check["task"] = ev["task"]
                check["taskState"] = "waitQueries"
                if "range" in ev:
                    check["range"] = ev["range"]
                result.append(check)
                tasks_with_overlap.add(ev["task"])
        result.append(ev)

    return result


def main():
    parser = argparse.ArgumentParser(
        description="Convert MongoDB structured logs to TLA+ trace NDJSON"
    )
    parser.add_argument("input", help="Input MongoDB log file (JSON lines)")
    parser.add_argument("output", help="Output NDJSON trace file")
    parser.add_argument("--after", default=None,
                       help="Only include events after this ISO 8601 timestamp")
    parser.add_argument("--before", default=None,
                       help="Only include events before this ISO 8601 timestamp")
    args = parser.parse_args()

    # Read all relevant log entries, applying timestamp filter
    all_entries = []
    with open(args.input, "r") as f:
        for line in f:
            entry = parse_log_line(line)
            if entry and entry.get("id") in RELEVANT_IDS:
                ts = get_ts(entry)
                if args.after and ts < args.after:
                    continue
                if args.before and ts >= args.before:
                    continue
                all_entries.append(entry)

    print(f"Read {len(all_entries)} relevant log entries from {args.input}")

    # Pass 1: Build cross-reference maps
    mapper = IDMapper()
    pass1_build_crossref(all_entries, mapper)

    # Pass 2: Emit trace events (no need for after_ts since entries already filtered)
    events = pass2_emit_events(all_entries, mapper)
    print(f"Extracted {len(events)} trace events")

    # Post-processing
    events = postprocess(events)
    print(f"After post-processing: {len(events)} trace events")

    # Write output
    with open(args.output, "w") as f:
        for ev in events:
            f.write(json.dumps(ev) + "\n")
    print(f"Wrote trace to {args.output}")

    # Summary
    mapper.summary()
    action_counts = {}
    for ev in events:
        a = ev.get("action", "?")
        action_counts[a] = action_counts.get(a, 0) + 1
    print("\n=== Event Summary ===")
    for a, c in sorted(action_counts.items()):
        print(f"  {a}: {c}")


if __name__ == "__main__":
    main()
