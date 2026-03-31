# Chunk Migration Trace Instrumentation Guide

No source code patching required. All trace events are extracted from MongoDB's built-in LOGV2 structured logging at debug verbosity level 3.

## Architecture

```
MongoDB (Docker)         preprocess_trace.py      TLC
  shard0 logs     --->   parse & map IDs    --->  Trace.tla validates
  (LOGV2 JSON)           emit NDJSON              against base.tla
```

## Log ID → Trace Event Mapping

| Log ID | Event Name | Source File | Line | Notes |
|--------|-----------|-------------|------|-------|
| 23890 | StartMigration | migration_coordinator.cpp | 152 | "Persisting range deletion task on donor" |
| 22017 | AdvanceToConfigCommit | migration_source_manager.cpp | 587 | "Migration successfully entered critical section" (proxy) |
| 23891 (committed) | ConfigCommitSucceed | migration_coordinator.cpp | 173 | "Setting migration decision" |
| 23891 (aborted) | AbortBeforeConfigCommit | migration_coordinator.cpp | 173 | "Setting migration decision" |
| 23892 | ConfigCommitFail | migration_coordinator.cpp | 187 | "Migration completed without setting a decision" |
| 23894 | DoCommitPersist | migration_coordinator.cpp | 235 | "Making commit decision durable" |
| 23895 | DoCommitAdvanceTxn | migration_coordinator.cpp | 244 | "Bumping txn on recipient for commit" |
| 6376300 | DoCommitRetrieveOrphans | migration_coordinator.cpp | 259 | "Retrieving orphan count from recipient" |
| — | DoCommitPersistOrphans | (no LOGV2) | — | Inferred after DoCommitRetrieveOrphans |
| 23896 | DoCommitDeleteRecipientTask | migration_coordinator.cpp | 273 | "Deleting range deletion task on recipient" |
| 11335400 | DoCommitGetDonorTask | migration_coordinator.cpp | 290 | "No range deletion task found on donor" (not found) |
| 6555800 | DoCommitGetDonorTask + DoCommitMarkReady | migration_coordinator.cpp | 313 | "Marking task as ready" (found → emit both) |
| 23903 | DoCommitForget / DoAbortForget | migration_coordinator.cpp | 390 | "Deleting coordinator document" |
| 23899 | DoAbortPersist | migration_coordinator.cpp | 329 | "Making abort decision durable" |
| 23901 | DoAbortDeleteLocal | migration_coordinator.cpp | 342 | "Deleting range deletion task on donor" |
| 23900 | DoAbortAdvanceTxn | migration_coordinator.cpp | 353 | "Bumping txn on recipient for abort" |
| 23902 | DoAbortMarkRecipient | migration_coordinator.cpp | 377 | "Marking range deletion task on recipient as ready" |
| 4798511 | RecoverMigration / RecoverFromLimbo | migration_util.cpp | 368 | "Found unfinished migration on step-up" |

## How to Add a New Field to an Event

1. Find the LOGV2 entry in the source (by log ID from table above)
2. Check what `attr` fields MongoDB logs at that point
3. In `preprocess_trace.py`, add extraction logic in `extract_fields()`
4. In `pass2_emit_events()`, include the field in the event dict
5. Update `Trace.tla` to reference the new field

## How to Add a New Event Type

1. Find a LOGV2 entry that fires at the desired code point (use `grep -n LOGV2 <file>`)
2. Add its log ID to `RELEVANT_IDS` in `preprocess_trace.py`
3. Add a handler in `pass2_emit_events()` following the existing pattern
4. Update the state machine transitions if needed
5. Add a `TraceXxx` wrapper in `Trace.tla`

## How to Move a Capture Point

If validation shows a timing mismatch (event fires too early/late):
1. Find the current log ID and its source line
2. Look for alternative LOGV2 entries at the desired point
3. If no suitable entry exists, this would require a MongoDB source patch (avoid if possible)
4. Update the log ID mapping in `preprocess_trace.py`

## How to Rebuild and Re-run

```bash
# Re-run everything from scratch
cd case-studies/mongodb-chunkmigration && bash harness/run.sh

# Re-preprocess existing logs (no Docker needed)
python3 harness/src/preprocess_trace.py harness/logs/shard0.log traces/basic_commit.ndjson --after <ts>

# Clean up Docker
cd harness/src && docker compose down -v
```

## State Tracking

The preprocessor tracks the spec's state machine internally:
- `activeMigration`, `migrationPhase`, `cleanupPhase`, `cleanupMid`
- State is deterministic from the event sequence
- Each emitted event includes the post-state snapshot

## Known Limitations

1. **DoCommitPersistOrphans**: No LOGV2 entry — inferred from sequence (emitted right after DoCommitRetrieveOrphans)
2. **CleanupComplete**: No direct LOGV2 — emitted synthetically after DoCommitForget/DoAbortForget
3. **ConfigCommitFail**: Log 23892 fires when decision is not set, but this is rare in normal tests
4. **Stepdown**: Not detectable from logs in single-node RS — requires explicit replSetStepDown test
5. **RecoverFromLimbo vs RecoverMigration**: Distinguished by `decision` field in coordinator doc logged in 4798511
6. **Migration ID → m1/m2**: Mapped by order of first encounter; Trace.cfg must use string constants

## Verbosity Requirements

All migration coordinator logs are under `kShardingMigration` component at DEBUG level 2-3. Docker compose sets `{sharding: {verbosity: 3}}` to capture all entries.
