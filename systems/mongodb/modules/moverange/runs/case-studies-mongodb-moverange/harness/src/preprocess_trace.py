#!/usr/bin/env python3
"""
preprocess_trace.py — Extract MoveRange commit protocol events from MongoDB
structured logs and convert to NDJSON for TLA+ trace validation.

Two-pass approach:
  Pass 1: Build cross-reference maps (migration ID -> donor, recipient, key)
  Pass 2: Emit NDJSON trace events with enriched fields.

Usage:
    python3 preprocess_trace.py \\
        --donor <shard0_log> --recipient <shard1_log> \\
        --output <output.ndjson> \\
        [--after TIMESTAMP] [--before TIMESTAMP]
"""

import json
import sys
import argparse
from collections import OrderedDict


# ========================================================================
# Shard name mapping: MongoDB RS names -> TLA+ spec constants
# ========================================================================
SHARD_MAP = {
    "shard0rs": "s1",
    "shard1rs": "s2",
}


def map_shard(name):
    """Map MongoDB shard name to TLA+ constant."""
    if name in SHARD_MAP:
        return SHARD_MAP[name]
    # Try stripping quotes
    clean = str(name).strip('"').strip("'")
    if clean in SHARD_MAP:
        return SHARD_MAP[clean]
    return name


# ========================================================================
# Log IDs we care about (mapped to trace events)
# ========================================================================
RELEVANT_IDS = {
    # Migration lifecycle (migration_coordinator.cpp)
    23889,     # "Persisting migration coordinator doc" -> StartMigration
    23891,     # "MigrationCoordinator setting migration decision" -> DecideAbort (if abort)
    23893,     # "MigrationCoordinator delivering decision" -> context marker
    # Commit sub-steps (migration_coordinator.cpp)
    23894,     # "Making commit decision durable" -> PersistCommitDecision
    23895,     # "Bumping transaction number on recipient for commit" -> CommitBumpRecipientTxn
    23896,     # "Deleting range deletion task on recipient" -> CommitDeleteRecipientRangeDel
    6555800,   # "Marking range deletion task on donor as ready" -> CommitMarkDonorRangeDelReady
    11335400,  # "No range deletion task found on donor" -> skip (alt to 6555800)
    23903,     # "Deleting migration coordinator document" -> CommitForgetMigration OR AbortForgetMigration
    # Abort sub-steps (migration_coordinator.cpp)
    23899,     # "Making abort decision durable" -> AbortPersistDecision
    23901,     # "Deleting range deletion task on donor" -> AbortDeleteDonorRangeDel
    23900,     # "Bumping transaction number on recipient for abort" -> AbortBumpRecipientTxn
    23902,     # "Marking range deletion task on recipient as ready" -> AbortMarkRecipientRangeDelReady
    # Donor critical section (migration_source_manager.cpp)
    22017,     # "Migration successfully entered critical section" -> DonorEnterCriticalSection
    22018,     # "Migration succeeded and updated collection placement version" -> CommitOnConfigServer
    # Recipient critical section (migration_destination_manager.cpp)
    5899114,   # "Entered migration recipient critical section" -> RecipientEnterCriticalSection
    5899108,   # "Exited migration recipient critical section" -> (used for release events)
    # Recovery (migration_util.cpp, shard_filtering_metadata_refresh.cpp)
    4798510,   # "Starting migration coordinator step-up recovery" -> StepUp
    4798502,   # "Recovering migration" -> RecoverMigration
    # Range deletion (range_deletion_util.cpp)
    6180601,   # "Begin removal of range" -> DeleteRange
    # Replication state changes (for stepdown detection)
    21359,     # "Replica set state transition" (replication)
}


def unwrap_uuid(val):
    """Unwrap MongoDB's UUID representations."""
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


class MigrationTracker:
    """Track migration state for cross-referencing and decision disambiguation."""

    def __init__(self):
        # migration_id -> {donor, recipient, key, decision, nss}
        self.migrations = {}
        # nss -> migration_id (most recent)
        self.nss_to_migration = {}
        # key counter for TLA+ mapping
        self._key_counter = 0
        self._key_map = {}  # nss -> "k1", "k2", ...

    def register(self, migration_id, donor=None, recipient=None, nss=None):
        """Register or update a migration."""
        if migration_id not in self.migrations:
            self.migrations[migration_id] = {
                "donor": None, "recipient": None, "nss": None, "decision": None
            }
        m = self.migrations[migration_id]
        if donor:
            m["donor"] = donor
        if recipient:
            m["recipient"] = recipient
        if nss:
            m["nss"] = nss
            self.nss_to_migration[nss] = migration_id

    def set_decision(self, migration_id, decision):
        if migration_id in self.migrations:
            self.migrations[migration_id]["decision"] = decision

    def get_decision(self, migration_id):
        if migration_id in self.migrations:
            return self.migrations[migration_id].get("decision")
        return None

    def get_donor(self, migration_id):
        if migration_id in self.migrations:
            return self.migrations[migration_id].get("donor")
        return None

    def get_recipient(self, migration_id):
        if migration_id in self.migrations:
            return self.migrations[migration_id].get("recipient")
        return None

    def get_nss(self, migration_id):
        if migration_id in self.migrations:
            return self.migrations[migration_id].get("nss")
        return None

    def map_key(self, nss):
        """Map a namespace to a TLA+ key constant (k1, k2, ...)."""
        if nss is None:
            return "k1"  # default for single-key scenarios
        if nss not in self._key_map:
            self._key_counter += 1
            self._key_map[nss] = f"k{self._key_counter}"
        return self._key_map[nss]

    def get_migration_by_nss(self, nss):
        return self.nss_to_migration.get(nss)

    def summary(self):
        print("\n=== Migration Tracker ===")
        for mid, info in self.migrations.items():
            print(f"  {mid[:12]}...: donor={info['donor']} recipient={info['recipient']} "
                  f"decision={info['decision']} nss={info['nss']}")
        print(f"  Key mappings: {self._key_map}")


def extract_migration_id(entry):
    """Extract migration ID from a log entry."""
    attr = entry.get("attr", {})

    # Direct migrationId field
    mid = attr.get("migrationId")
    if mid:
        return unwrap_uuid(mid)

    # From migrationDoc
    md = attr.get("migrationDoc")
    if isinstance(md, dict):
        mid = md.get("_id")
        if mid:
            return unwrap_uuid(mid)

    # From migrationCoordinatorDocument
    mcd = attr.get("migrationCoordinatorDocument")
    if isinstance(mcd, dict):
        mid = mcd.get("_id")
        if mid:
            return unwrap_uuid(mid)

    return None


def extract_nss(entry):
    """Extract namespace string from a log entry."""
    attr = entry.get("attr", {})

    # Direct namespace field
    nss = attr.get("namespace")
    if nss:
        return str(nss)

    # From nss field
    nss = attr.get("nss")
    if nss:
        return str(nss)

    # From migrationDoc
    md = attr.get("migrationDoc")
    if isinstance(md, dict):
        nss = md.get("nss")
        if nss:
            return str(nss)

    return None


def pass1_build_crossref(entries, tracker):
    """Pass 1: Build cross-reference maps from all entries."""
    for entry in entries:
        lid = entry.get("id")
        attr = entry.get("attr", {})
        mid = extract_migration_id(entry)
        nss = extract_nss(entry)

        if lid == 23889:
            # "Persisting migration coordinator doc" — richest source of info
            md = attr.get("migrationDoc", {})
            if isinstance(md, dict):
                donor = str(md.get("donorShardId", ""))
                recipient = str(md.get("recipientShardId", ""))
                mid_doc = unwrap_uuid(md.get("_id"))
                nss_doc = str(md.get("nss", ""))
                if mid_doc:
                    tracker.register(mid_doc, donor=donor, recipient=recipient, nss=nss_doc)

        elif mid:
            tracker.register(mid, nss=nss)

        # Track decisions from 23891/23893
        if lid in (23891, 23893) and mid:
            decision = str(attr.get("decision", "")).lower()
            if "commit" in decision:
                tracker.set_decision(mid, "commit")
            elif "abort" in decision:
                tracker.set_decision(mid, "abort")


def pass2_emit_events(entries, tracker):
    """Pass 2: Convert log entries to trace events."""
    events = []

    for entry in entries:
        lid = entry.get("id")
        ts = get_ts(entry)
        attr = entry.get("attr", {})
        source_shard = entry.get("_source_shard", "s1")
        mid = extract_migration_id(entry)
        nss = extract_nss(entry)

        ev = None

        # ----- Migration lifecycle -----

        if lid == 23889:
            # "Persisting migration coordinator doc" -> StartMigration
            md = attr.get("migrationDoc", {})
            donor = map_shard(str(md.get("donorShardId", "")))
            recipient = map_shard(str(md.get("recipientShardId", "")))
            key = tracker.map_key(str(md.get("nss", "")))
            ev = OrderedDict([
                ("event", "StartMigration"),
                ("shard", donor),
                ("key", key),
                ("donor", donor),
                ("recipient", recipient),
                ("ts", ts),
            ])

        elif lid == 5899114:
            # "Entered migration recipient critical section"
            key = tracker.map_key(nss) if nss else "k1"
            ev = OrderedDict([
                ("event", "RecipientEnterCriticalSection"),
                ("shard", source_shard),
                ("key", key),
                ("ts", ts),
            ])

        elif lid == 22017:
            # "Migration successfully entered critical section" (donor)
            key = tracker.map_key(nss) if nss else "k1"
            ev = OrderedDict([
                ("event", "DonorEnterCriticalSection"),
                ("shard", source_shard),
                ("key", key),
                ("ts", ts),
            ])

        elif lid == 22018:
            # "Migration succeeded and updated collection placement version"
            key = tracker.map_key(nss) if nss else "k1"
            recipient = None
            if mid:
                recipient = map_shard(tracker.get_recipient(mid) or "")
            ev = OrderedDict([
                ("event", "CommitOnConfigServer"),
                ("key", key),
                ("configOwner", recipient or source_shard),
                ("ts", ts),
            ])

        # ----- Commit sub-steps -----

        elif lid == 23894:
            # "Making commit decision durable"
            ev = OrderedDict([
                ("event", "PersistCommitDecision"),
                ("shard", source_shard),
                ("migState", "commitReleaseCritSec"),
                ("ts", ts),
            ])

        elif lid == 23895:
            # "Bumping transaction number on recipient for commit"
            ev = OrderedDict([
                ("event", "CommitBumpRecipientTxn"),
                ("shard", source_shard),
                ("ts", ts),
            ])

        elif lid == 23896:
            # "Deleting range deletion task on recipient"
            ev = OrderedDict([
                ("event", "CommitDeleteRecipientRangeDel"),
                ("shard", source_shard),
                ("ts", ts),
            ])

        elif lid == 6555800:
            # "Marking range deletion task on donor as ready for processing"
            # This fires during both commit and abort paths, but only in commit
            # path for the DONOR's task. Check context.
            ev = OrderedDict([
                ("event", "CommitMarkDonorRangeDelReady"),
                ("shard", source_shard),
                ("ts", ts),
            ])

        elif lid == 23903:
            # "Deleting migration coordinator document"
            # Fires for both commit and abort — disambiguate via tracked decision
            decision = None
            if mid:
                decision = tracker.get_decision(mid)
            if decision == "abort":
                event_name = "AbortForgetMigration"
            else:
                event_name = "CommitForgetMigration"
            ev = OrderedDict([
                ("event", event_name),
                ("shard", source_shard),
                ("ts", ts),
            ])

        # ----- Decision -----

        elif lid == 23891:
            # "MigrationCoordinator setting migration decision"
            decision = str(attr.get("decision", "")).lower()
            if "abort" in decision:
                key = "k1"
                if mid:
                    nss_val = tracker.get_nss(mid)
                    if nss_val:
                        key = tracker.map_key(nss_val)
                ev = OrderedDict([
                    ("event", "DecideAbort"),
                    ("key", key),
                    ("shard", source_shard),
                    ("ts", ts),
                ])
            # For commit decision, no separate trace event (covered by CommitOnConfigServer)

        # ----- Abort sub-steps -----

        elif lid == 23899:
            # "Making abort decision durable"
            ev = OrderedDict([
                ("event", "AbortPersistDecision"),
                ("shard", source_shard),
                ("ts", ts),
            ])

        elif lid == 23901:
            # "Deleting range deletion task on donor" (abort path)
            ev = OrderedDict([
                ("event", "AbortDeleteDonorRangeDel"),
                ("shard", source_shard),
                ("ts", ts),
            ])

        elif lid == 23900:
            # "Bumping transaction number on recipient for abort"
            ev = OrderedDict([
                ("event", "AbortBumpRecipientTxn"),
                ("shard", source_shard),
                ("ts", ts),
            ])

        elif lid == 23902:
            # "Marking range deletion task on recipient as ready"
            ev = OrderedDict([
                ("event", "AbortMarkRecipientRangeDelReady"),
                ("shard", source_shard),
                ("ts", ts),
            ])

        # ----- Critical section release (recipient side) -----
        # NOTE: 5899108 fires on the RECIPIENT, causing cross-shard clock ordering
        # issues. CommitReleaseCritSec and AbortReleaseCritSec are handled as silent
        # actions in Trace.tla to avoid these issues.

        # ----- Recovery -----

        elif lid == 4798510:
            # "Starting migration coordinator step-up recovery"
            ev = OrderedDict([
                ("event", "StepUp"),
                ("shard", source_shard),
                ("ts", ts),
            ])

        elif lid == 4798502:
            # "Recovering migration"
            key = "k1"
            mcd = attr.get("migrationCoordinatorDocument", {})
            if isinstance(mcd, dict):
                mid_doc = unwrap_uuid(mcd.get("_id"))
                if mid_doc:
                    nss_val = tracker.get_nss(mid_doc)
                    if nss_val:
                        key = tracker.map_key(nss_val)
                    # Also extract decision from recovery doc
                    decision_val = mcd.get("decision")
                    if decision_val:
                        decision_str = str(decision_val).lower()
                        # Emit migState based on recovery decision
            ev = OrderedDict([
                ("event", "RecoverMigration"),
                ("shard", source_shard),
                ("key", key),
                ("ts", ts),
            ])

        # ----- Range deletion -----

        elif lid == 6180601:
            # "Begin removal of range"
            key = tracker.map_key(nss) if nss else "k1"
            ev = OrderedDict([
                ("event", "DeleteRange"),
                ("shard", source_shard),
                ("key", key),
                ("ts", ts),
            ])

        # ----- Stepdown detection (replication) -----

        elif lid == 21359:
            # Replica set state transition
            new_state = str(attr.get("newState", "")).upper()
            old_state = str(attr.get("oldState", "")).upper()
            if "PRIMARY" in old_state and "SECONDARY" in new_state:
                ev = OrderedDict([
                    ("event", "Stepdown"),
                    ("shard", source_shard),
                    ("ts", ts),
                ])

        if ev is not None:
            events.append(ev)

    return events


def postprocess(events):
    """Post-processing: add Stepdown before StepUp if missing, etc."""
    if not events:
        return events

    # Check if we have StepUp without preceding Stepdown
    result = []
    saw_stepdown = set()  # shards that have stepped down

    for ev in events:
        if ev["event"] == "Stepdown":
            saw_stepdown.add(ev.get("shard"))
        elif ev["event"] == "StepUp":
            shard = ev.get("shard")
            if shard not in saw_stepdown:
                # Inject Stepdown before StepUp
                stepdown_ev = OrderedDict([
                    ("event", "Stepdown"),
                    ("shard", shard),
                    ("ts", ev["ts"]),
                ])
                result.append(stepdown_ev)
                saw_stepdown.add(shard)
        result.append(ev)

    return result


def read_log_entries(log_file, after_ts=None, before_ts=None):
    """Read relevant log entries from a MongoDB log file."""
    entries = []
    with open(log_file, "r") as f:
        for line in f:
            entry = parse_log_line(line)
            if not entry:
                continue
            lid = entry.get("id")
            if lid not in RELEVANT_IDS:
                # Also check for replication state changes
                # MongoDB uses "c": "REPL" for replication component
                comp = entry.get("c", "")
                if comp == "REPL" and lid:
                    # Check if this is a state transition we care about
                    msg = entry.get("msg", "")
                    if "transition" in msg.lower() or "step" in msg.lower():
                        pass  # Include it
                    else:
                        continue
                else:
                    continue
            ts = get_ts(entry)
            if after_ts and ts < after_ts:
                continue
            if before_ts and ts >= before_ts:
                continue
            entries.append(entry)
    return entries


def detect_stepdown_from_logs(log_file, after_ts=None, before_ts=None):
    """Detect stepdown events from replication log lines.

    MongoDB logs replica set state transitions. We look for patterns
    indicating a PRIMARY -> SECONDARY transition.
    """
    stepdown_entries = []
    with open(log_file, "r") as f:
        for line in f:
            entry = parse_log_line(line)
            if not entry:
                continue
            ts = get_ts(entry)
            if after_ts and ts < after_ts:
                continue
            if before_ts and ts >= before_ts:
                continue
            msg = str(entry.get("msg", "")).lower()
            attr = entry.get("attr", {})

            # Check for various stepdown indicators
            if any(kw in msg for kw in [
                "stepping down",
                "stepped down",
                "entering quiesce mode",
                "not primary",
                "replication state transition"
            ]):
                new_state = str(attr.get("newState", ""))
                old_state = str(attr.get("oldState", ""))
                if ("PRIMARY" in old_state and "SECONDARY" in new_state) or \
                   "stepping down" in msg or "stepped down" in msg:
                    # Create a synthetic entry with id=21359
                    synth = {
                        "id": 21359,
                        "t": entry.get("t", {}),
                        "attr": {"oldState": "PRIMARY", "newState": "SECONDARY"},
                    }
                    stepdown_entries.append(synth)

    return stepdown_entries


def main():
    parser = argparse.ArgumentParser(
        description="Convert MongoDB MoveRange logs to TLA+ trace NDJSON"
    )
    parser.add_argument("--donor", required=True, help="Donor shard (shard0) log file")
    parser.add_argument("--recipient", required=True, help="Recipient shard (shard1) log file")
    parser.add_argument("--output", required=True, help="Output NDJSON trace file")
    parser.add_argument("--after", default=None,
                       help="Only include events after this ISO 8601 timestamp")
    parser.add_argument("--before", default=None,
                       help="Only include events before this ISO 8601 timestamp")
    parser.add_argument("--donor-shard", default="s1",
                       help="TLA+ name for donor shard (default: s1)")
    parser.add_argument("--recipient-shard", default="s2",
                       help="TLA+ name for recipient shard (default: s2)")
    args = parser.parse_args()

    # Read entries from both shard logs
    print(f"Reading donor log: {args.donor}")
    donor_entries = read_log_entries(args.donor, args.after, args.before)
    print(f"  {len(donor_entries)} relevant entries")

    print(f"Reading recipient log: {args.recipient}")
    recipient_entries = read_log_entries(args.recipient, args.after, args.before)
    print(f"  {len(recipient_entries)} relevant entries")

    # Detect stepdown events from logs
    donor_stepdowns = detect_stepdown_from_logs(args.donor, args.after, args.before)
    recipient_stepdowns = detect_stepdown_from_logs(args.recipient, args.after, args.before)
    print(f"  Detected {len(donor_stepdowns)} donor stepdown(s), "
          f"{len(recipient_stepdowns)} recipient stepdown(s)")

    # Tag entries with source shard
    for e in donor_entries:
        e["_source_shard"] = args.donor_shard
    for e in recipient_entries:
        e["_source_shard"] = args.recipient_shard
    for e in donor_stepdowns:
        e["_source_shard"] = args.donor_shard
    for e in recipient_stepdowns:
        e["_source_shard"] = args.recipient_shard

    # Merge all entries by timestamp
    all_entries = donor_entries + recipient_entries + donor_stepdowns + recipient_stepdowns
    all_entries.sort(key=lambda e: get_ts(e))
    print(f"Total entries after merge: {len(all_entries)}")

    # Pass 1: Build cross-references
    tracker = MigrationTracker()
    pass1_build_crossref(all_entries, tracker)
    tracker.summary()

    # Pass 2: Emit trace events
    events = pass2_emit_events(all_entries, tracker)
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
    action_counts = {}
    for ev in events:
        a = ev.get("event", "?")
        action_counts[a] = action_counts.get(a, 0) + 1
    print("\n=== Event Summary ===")
    for a, c in sorted(action_counts.items()):
        print(f"  {a}: {c}")


if __name__ == "__main__":
    main()
