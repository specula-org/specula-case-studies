#!/usr/bin/env python3
"""
preprocess_trace.py — Extract chunk migration trace events from MongoDB structured
logs and convert them to NDJSON format for TLA+ trace validation.

Two-pass approach:
  Pass 1: Build cross-reference maps (migration ID → collection UUID, range).
  Pass 2: Emit NDJSON trace events, tracking spec state machine for state fields.

Usage:
    python3 preprocess_trace.py <input_log> <output_ndjson> [--after TS] [--before TS]
"""

import json
import sys
import argparse
from collections import OrderedDict


# ========================================================================
# Log IDs we care about
# ========================================================================

RELEVANT_IDS = {
    # Cross-reference only (pass 1)
    23889,     # Persisting migration coordinator doc (full migrationDoc)
    # Lifecycle
    22016,     # Starting chunk migration donation (INFO)
    22017,     # Migration successfully entered critical section (INFO)
    22018,     # Migration succeeded and updated collection placement version (INFO)
    23890,     # Persisting range deletion task on donor (StartMigration)
    23891,     # Setting migration decision (commit or abort)
    23892,     # Migration completed without decision (ConfigCommitFail / limbo)
    23893,     # Delivering decision to self and recipient
    6107801,   # Exiting commit critical section (INFO)
    6107802,   # Finished critical section (INFO, with duration)
    5089001,   # Failed to complete migration (WARNING)
    # Commit cleanup sub-steps
    23894,     # Making commit decision durable (DoCommitPersist)
    23895,     # Bumping txn on recipient for commit (DoCommitAdvanceTxn)
    6376300,   # Retrieving orphan count from recipient (DoCommitRetrieveOrphans)
    23896,     # Deleting range deletion task on recipient (DoCommitDeleteRecipientTask)
    11335400,  # No range deletion task found on donor (DoCommitGetDonorTask - not found)
    6555800,   # Marking range deletion task as ready (DoCommitMarkReady)
    # Abort cleanup sub-steps
    23899,     # Making abort decision durable (DoAbortPersist)
    23901,     # Deleting range deletion task on donor (DoAbortDeleteLocal)
    23900,     # Bumping txn on recipient for abort (DoAbortAdvanceTxn)
    4620231,   # Failed to advance txn on recipient (ShardNotFound in abort)
    23902,     # Marking range deletion task on recipient as ready (DoAbortMarkRecipient)
    # Shared
    23903,     # Deleting migration coordinator document (forget)
    # Recovery
    4798510,   # Starting migration coordinator step-up recovery
    4798511,   # Found unfinished migration on step-up
    4798513,   # Finished scheduling recovery tasks
    11420100,  # Finished all recovery tasks
}


# ========================================================================
# Helpers
# ========================================================================

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
    """Maps implementation UUIDs to TLA+ spec constants (m1, m2, ...)."""

    def __init__(self):
        self._map = OrderedDict()
        self._counter = 0

    def get(self, uuid_str):
        uuid_str = str(uuid_str)
        if uuid_str not in self._map:
            self._counter += 1
            self._map[uuid_str] = f"m{self._counter}"
        return self._map[uuid_str]

    def summary(self):
        print(f"\n=== Migration ID Mappings ===")
        for k, v in self._map.items():
            print(f"  {k} -> {v}")


class StateMachine:
    """Tracks the spec state machine for emitting state fields."""

    def __init__(self):
        self.active_migration = "nil"
        self.migration_phase = "idle"
        self.cleanup_phase = "noCleanup"
        self.cleanup_mid = "nil"
        self._decision_path = None  # "commit" or "abort"

    def snapshot(self):
        return {
            "activeMigration": self.active_migration,
            "migrationPhase": self.migration_phase,
            "cleanupPhase": self.cleanup_phase,
            "cleanupMid": self.cleanup_mid,
        }

    def start_migration(self, mid):
        self.active_migration = mid
        self.migration_phase = "prepared"

    def advance_to_config_commit(self):
        self.migration_phase = "committingOnConfig"

    def config_commit_succeed(self, mid):
        self.migration_phase = "cleaning"
        self.cleanup_phase = "cmtPersist"
        self.cleanup_mid = mid
        self._decision_path = "commit"

    def config_commit_fail(self):
        self.active_migration = "nil"
        self.migration_phase = "idle"

    def abort_before_config_commit(self, mid):
        self.migration_phase = "cleaning"
        self.cleanup_phase = "abtPersist"
        self.cleanup_mid = mid
        self._decision_path = "abort"

    def advance_cleanup(self, new_phase):
        self.cleanup_phase = new_phase

    def cleanup_complete(self):
        self.active_migration = "nil"
        self.migration_phase = "idle"
        self.cleanup_phase = "noCleanup"
        self.cleanup_mid = "nil"
        self._decision_path = None

    def stepdown(self):
        self.active_migration = "nil"
        self.migration_phase = "idle"
        self.cleanup_phase = "noCleanup"
        self.cleanup_mid = "nil"
        self._decision_path = None

    def recover(self, mid, decision):
        self.cleanup_mid = mid
        if decision == "committed":
            self.cleanup_phase = "cmtPersist"
            self._decision_path = "commit"
        else:
            self.cleanup_phase = "abtPersist"
            self._decision_path = "abort"


# ========================================================================
# Field extraction
# ========================================================================

def extract_fields(entry):
    """Extract all possible fields from a log entry's attr dict."""
    attr = entry.get("attr", {})
    fields = {}

    # Migration ID — direct or nested
    if "migrationId" in attr:
        fields["migration_id"] = unwrap_uuid(attr["migrationId"])

    # Decision
    if "decision" in attr:
        fields["decision"] = str(attr["decision"]).lower()

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
            md_decision = md.get("decision")
            if md_decision:
                fields["doc_decision"] = str(md_decision).lower()

    # Migration coordinator doc (from 4798511)
    if "migrationCoordinatorDoc" in attr:
        md = attr["migrationCoordinatorDoc"]
        if isinstance(md, dict):
            md_mid = unwrap_uuid(md.get("_id"))
            if md_mid:
                fields["migration_id"] = md_mid
            md_decision = md.get("decision")
            if md_decision:
                fields["doc_decision"] = str(md_decision).lower()

    # Request parameters (from 22016)
    if "requestParameters" in attr:
        rp = attr["requestParameters"]
        if isinstance(rp, dict):
            rp_mid = unwrap_uuid(rp.get("migrationId"))
            if not rp_mid:
                rp_mid = unwrap_uuid(rp.get("_migrationId"))
            if rp_mid:
                fields["migration_id"] = rp_mid

    # Range deletion sub-document (from 6555800)
    if "rangeDeletion" in attr:
        rd = attr["rangeDeletion"]
        if isinstance(rd, dict):
            rd_mid = unwrap_uuid(rd.get("_id"))
            if rd_mid:
                fields["migration_id"] = rd_mid

    # Unfinished migrations count (from 4798511)
    if "unfinishedMigrationsCount" in attr:
        fields["unfinished_count"] = attr["unfinishedMigrationsCount"]

    return fields


# ========================================================================
# Pass 1: Build cross-reference maps
# ========================================================================

def pass1_build_crossref(entries, mapper):
    """Register migration IDs from full coordinator docs."""
    for entry in entries:
        lid = entry.get("id")
        fields = extract_fields(entry)
        mid = fields.get("migration_id")
        if mid:
            mapper.get(mid)


# ========================================================================
# Pass 2: Emit trace events
# ========================================================================

def make_event(ts, name, mid, state):
    """Create an NDJSON trace event dict."""
    ev = OrderedDict()
    ev["tag"] = "trace"
    ev["ts"] = ts
    ev["event"] = OrderedDict()
    ev["event"]["name"] = name
    ev["event"]["mid"] = mid
    ev["event"]["state"] = state
    return ev


def pass2_emit_events(entries, mapper, sm):
    """Convert log entries to trace events, tracking state machine."""
    events = []
    saw_decision_for = {}  # mid -> "committed" or "aborted" (from 23891)

    for entry in entries:
        lid = entry.get("id")
        ts = get_ts(entry)
        fields = extract_fields(entry)
        raw_mid = fields.get("migration_id")

        # === Cross-reference only (no event) ===
        if lid == 23889:
            continue

        # === StartMigration (23890) ===
        if lid == 23890:
            if not raw_mid:
                continue
            mid = mapper.get(raw_mid)
            sm.start_migration(mid)
            events.append(make_event(ts, "StartMigration", mid, sm.snapshot()))
            continue

        # === AdvanceToConfigCommit (22017) ===
        if lid == 22017:
            mid = mapper.get(raw_mid) if raw_mid else sm.active_migration
            if mid == "nil":
                continue
            sm.advance_to_config_commit()
            events.append(make_event(ts, "AdvanceToConfigCommit", mid, sm.snapshot()))
            continue

        # === Setting migration decision (23891) ===
        if lid == 23891:
            if not raw_mid:
                continue
            mid = mapper.get(raw_mid)
            decision = fields.get("decision", "")
            saw_decision_for[raw_mid] = decision
            if "committed" in decision:
                sm.config_commit_succeed(mid)
                events.append(make_event(ts, "ConfigCommitSucceed", mid, sm.snapshot()))
            elif "aborted" in decision:
                sm.abort_before_config_commit(mid)
                events.append(make_event(ts, "AbortBeforeConfigCommit", mid, sm.snapshot()))
            continue

        # === Migration completed without decision (23892) — ConfigCommitFail ===
        if lid == 23892:
            mid = mapper.get(raw_mid) if raw_mid else sm.active_migration
            if mid == "nil":
                continue
            sm.config_commit_fail()
            events.append(make_event(ts, "ConfigCommitFail", mid, sm.snapshot()))
            continue

        # === Delivering decision (23893) — informational, skip ===
        if lid == 23893:
            continue

        # === Commit cleanup sub-steps ===

        if lid == 23894:  # DoCommitPersist
            mid = mapper.get(raw_mid) if raw_mid else sm.cleanup_mid
            sm.advance_cleanup("cmtAdvTxn")
            events.append(make_event(ts, "DoCommitPersist", mid, sm.snapshot()))
            continue

        if lid == 23895:  # DoCommitAdvanceTxn
            mid = mapper.get(raw_mid) if raw_mid else sm.cleanup_mid
            sm.advance_cleanup("cmtGetOrph")
            events.append(make_event(ts, "DoCommitAdvanceTxn", mid, sm.snapshot()))
            continue

        if lid == 6376300:  # DoCommitRetrieveOrphans
            mid = mapper.get(raw_mid) if raw_mid else sm.cleanup_mid
            sm.advance_cleanup("cmtPersOrph")
            events.append(make_event(ts, "DoCommitRetrieveOrphans", mid, sm.snapshot()))
            # Infer DoCommitPersistOrphans (no LOGV2 for it)
            # The code always transitions through CmtPersOrph → CmtDelRecip.
            # Emit a synthetic event since persistUpdatedNumOrphans has no log entry.
            sm.advance_cleanup("cmtDelRecip")
            events.append(make_event(ts, "DoCommitPersistOrphans", mid, sm.snapshot()))
            continue

        if lid == 23896:  # DoCommitDeleteRecipientTask
            mid = mapper.get(raw_mid) if raw_mid else sm.cleanup_mid
            sm.advance_cleanup("cmtGetTask")
            events.append(make_event(ts, "DoCommitDeleteRecipientTask", mid, sm.snapshot()))
            continue

        if lid == 11335400:  # DoCommitGetDonorTask (task NOT found)
            mid = mapper.get(raw_mid) if raw_mid else sm.cleanup_mid
            sm.advance_cleanup("cmtForget")
            events.append(make_event(ts, "DoCommitGetDonorTask", mid, sm.snapshot()))
            continue

        if lid == 6555800:  # DoCommitMarkReady (task found)
            rd_mid = fields.get("migration_id")
            mid = mapper.get(rd_mid) if rd_mid else sm.cleanup_mid
            # Emit DoCommitGetDonorTask first (implicit — task was found)
            sm.advance_cleanup("cmtMarkReady")
            events.append(make_event(ts, "DoCommitGetDonorTask", mid, sm.snapshot()))
            # Then DoCommitMarkReady
            sm.advance_cleanup("cmtForget")
            events.append(make_event(ts, "DoCommitMarkReady", mid, sm.snapshot()))
            continue

        # === Abort cleanup sub-steps ===

        if lid == 23899:  # DoAbortPersist
            mid = mapper.get(raw_mid) if raw_mid else sm.cleanup_mid
            sm.advance_cleanup("abtDelLocal")
            events.append(make_event(ts, "DoAbortPersist", mid, sm.snapshot()))
            continue

        if lid == 23901:  # DoAbortDeleteLocal
            mid = mapper.get(raw_mid) if raw_mid else sm.cleanup_mid
            sm.advance_cleanup("abtAdvTxn")
            events.append(make_event(ts, "DoAbortDeleteLocal", mid, sm.snapshot()))
            continue

        if lid == 23900:  # DoAbortAdvanceTxn
            mid = mapper.get(raw_mid) if raw_mid else sm.cleanup_mid
            sm.advance_cleanup("abtMarkRecip")
            events.append(make_event(ts, "DoAbortAdvanceTxn", mid, sm.snapshot()))
            continue

        if lid == 4620231:  # ShardNotFound during abort advance txn — informational
            continue

        if lid == 23902:  # DoAbortMarkRecipient
            mid = mapper.get(raw_mid) if raw_mid else sm.cleanup_mid
            sm.advance_cleanup("abtForget")
            events.append(make_event(ts, "DoAbortMarkRecipient", mid, sm.snapshot()))
            continue

        # === Forget (shared commit/abort) ===
        if lid == 23903:
            mid = mapper.get(raw_mid) if raw_mid else sm.cleanup_mid
            if sm._decision_path == "commit":
                event_name = "DoCommitForget"
            elif sm._decision_path == "abort":
                event_name = "DoAbortForget"
            else:
                event_name = "DoCommitForget"  # fallback
            sm.advance_cleanup("cleanupDone")
            events.append(make_event(ts, event_name, mid, sm.snapshot()))
            # Emit CleanupComplete immediately after forget
            sm.cleanup_complete()
            events.append(make_event(ts, "CleanupComplete", mid, sm.snapshot()))
            continue

        # === Critical section finished (6107802) — informational ===
        if lid == 6107802 or lid == 6107801:
            continue

        # === Recovery ===
        if lid == 4798511:  # Found unfinished migration
            if not raw_mid:
                continue
            mid = mapper.get(raw_mid)
            doc_decision = fields.get("doc_decision", "")
            if doc_decision in ("committed", "aborted"):
                sm.recover(mid, doc_decision)
                events.append(make_event(ts, "RecoverMigration", mid, sm.snapshot()))
            else:
                # No decision → limbo (RecoverFromLimbo)
                # For now, emit as RecoverFromLimbo; the spec resolves via config query
                sm.recover(mid, "committed")  # assume commit for state; spec will check
                events.append(make_event(ts, "RecoverFromLimbo", mid, sm.snapshot()))
            continue

        if lid in (4798510, 4798513, 11420100):
            # Recovery lifecycle — informational, skip
            continue

        # === Other informational IDs (22016, 22018, 5089001) ===
        # 22016: Starting migration donation — we use 23890 instead
        # 22018: Migration succeeded — we use 23891 instead
        # 5089001: Failed to complete — we use 23892 instead

    return events


# ========================================================================
# Post-processing
# ========================================================================

def postprocess(events):
    """Minor adjustments after initial emission."""
    if not events:
        return events

    # Remove DoCommitPersistOrphans if the next event after DoCommitRetrieveOrphans
    # is NOT DoCommitDeleteRecipientTask (should not happen, but defensive).
    # In practice the code always goes through this path.
    return events


# ========================================================================
# Main
# ========================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Convert MongoDB structured logs to chunk migration TLA+ trace NDJSON"
    )
    parser.add_argument("input", help="Input MongoDB log file (JSON lines)")
    parser.add_argument("output", help="Output NDJSON trace file")
    parser.add_argument("--after", default=None,
                       help="Only include events after this ISO 8601 timestamp")
    parser.add_argument("--before", default=None,
                       help="Only include events before this ISO 8601 timestamp")
    args = parser.parse_args()

    # Read all relevant log entries with timestamp filtering
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

    # Debug: show which log IDs we found
    id_counts = {}
    for e in all_entries:
        lid = e.get("id")
        id_counts[lid] = id_counts.get(lid, 0) + 1
    print("  Log ID distribution:")
    for lid, cnt in sorted(id_counts.items()):
        print(f"    {lid}: {cnt}")

    # Pass 1: Build cross-reference maps
    mapper = IDMapper()
    pass1_build_crossref(all_entries, mapper)

    # Pass 2: Emit trace events with state tracking
    sm = StateMachine()
    events = pass2_emit_events(all_entries, mapper, sm)
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
        a = ev["event"]["name"]
        action_counts[a] = action_counts.get(a, 0) + 1
    print("\n=== Event Summary ===")
    for a, c in sorted(action_counts.items()):
        print(f"  {a}: {c}")


if __name__ == "__main__":
    main()
