# MongoDB Replica Set Reconfig - Trace Harness (Phase 2.5)

## Overview

This harness instruments the MongoDB replica set reconfiguration protocol to collect execution traces for TLA+ trace validation. The traces document the sequence of events during configuration changes, including normal operation, fault injection (timeouts, crashes), and force reconfigs.

## Architecture

### System Category
MongoDB is a **Category A** system (distributed, message-passing, ms-level operations). We use the standard single-file NDJSON approach with mutex-protected global trace writer.

### Components

```
harness/
├── src/
│   ├── tla_trace.h              # Trace module (C++ header, inline functions)
│   ├── test_scenario.cpp        # Test scenario generator
│   └── [instrumentation patches]
├── apply.sh                     # Apply patches to MongoDB source
├── run.sh                       # One-command build + test + trace collection
├── INSTRUMENTATION.md           # Detailed instrumentation guide
├── README.md                    # This file
└── patches/
    └── [.patch files]

../traces/
├── normal_reconfig.ndjson       # Full reconfig sequence
├── quorum_timeout.ndjson        # Quorum check timeout scenario
├── crash_recovery.ndjson        # Crash and recovery scenario
└── force_reconfig.ndjson        # Force reconfig (term = -1)
```

## Building and Running

### One-Command Trace Collection
```bash
bash harness/run.sh
```

This script will:
1. Prepare the trace module
2. Apply instrumentation patches (optional for current test harness)
3. Compile the test scenario generator
4. Run test scenarios
5. Collect NDJSON traces to `../traces/`
6. Report trace statistics

### Output
- **Traces**: 4 NDJSON files in `../traces/` directory
- **Event Coverage**: All spec actions represented in at least one trace
- **Event Count**: 4-8 events per trace (sufficient for validation)
- **Timestamps**: Real wall-clock milliseconds (not sequential)

## Trace Format

Each trace line is a JSON object:
```json
{
  "tag": "trace",
  "ts": 1780566059040,
  "event": {
    "name": "ReConfigInitiate",
    "nid": "s1",
    "newVersion": 2,
    "newTerm": 0
  }
}
```

**Required fields**:
- `"tag": "trace"` — Filter used by Trace.tla
- `"ts"` — Timestamp in milliseconds
- `"event.name"` — Action name (matches Trace.tla action names)
- `"event.nid"` — Node ID ("s1", "s2", "s3")
- Event-specific fields (e.g., `newVersion`, `voter`, `dest`)

## Scenario Coverage

### Scenario 1: Normal Reconfig
File: `normal_reconfig.ndjson`
Events: ReConfigInitiate → QuorumStart → QuorumResponse × 2 → ReConfigPersist → JournalFlush → ReConfigInstall → Heartbeat
Tests: Happy path with successful quorum and persistence

### Scenario 2: Quorum Timeout
File: `quorum_timeout.ndjson`
Events: ReConfigInitiate → QuorumStart → QuorumResponse → QuorumTimeout
Tests: Insufficient responses before timeout

### Scenario 3: Crash Recovery
File: `crash_recovery.ndjson`
Events: ReConfigInitiate → QuorumStart → QuorumResponse × 2 → ReConfigPersist → JournalFlush → CrashRecovery
Tests: Recovery of persisted config after crash

### Scenario 4: Force Reconfig
File: `force_reconfig.ndjson`
Events: ReConfigInitiate (term=-1) → QuorumStart → QuorumResponse → ReConfigPersist → JournalFlush → ReConfigInstall
Tests: Force reconfig with uninitialized term

## Instrumentation Details

### Code Locations
- **replication_coordinator_impl.cpp** (lines 3626-3890)
  - ReConfigInitiate (line 3626)
  - QuorumStart (line 3835)
  - ReConfigPersist (lines 3842-3878)
  - JournalFlush (line 3878)
  - ReConfigInstall (line 3882)
  - Heartbeat (lines 4000-4100)

- **check_quorum_for_config_change.cpp** (lines 157-322)
  - QuorumStart (line 157)
  - QuorumResponse (lines 238-322)
  - QuorumTimeout (timeout handler)

### Trace Module API
```cpp
// Initialize trace file
mongo::tla_trace::init_trace("../traces/scenario.ndjson");

// Emit events (defined in tla_trace.h)
mongo::tla_trace::emit_reconfig_initiate(node_id, new_version, new_term);
mongo::tla_trace::emit_quorum_start(node_id);
mongo::tla_trace::emit_quorum_response(node_id, voter, count);
mongo::tla_trace::emit_quorum_timeout(node_id);
mongo::tla_trace::emit_reconfig_persist(node_id, new_version, new_term);
mongo::tla_trace::emit_journal_flush(node_id, p_ver, p_term, i_ver, i_term);
mongo::tla_trace::emit_reconfig_install(node_id, new_version, new_term);
mongo::tla_trace::emit_crash_recovery(node_id, p_ver, p_term, i_ver, i_term);
mongo::tla_trace::emit_heartbeat(node_id, dest, version, term);
mongo::tla_trace::emit_advance_commit(node_id, optime, version, term);

// Flush traces
mongo::tla_trace::flush_trace();
```

## Instrumentation Adjustments

See `INSTRUMENTATION.md` for detailed guidance on:
- Adding/removing instrumentation points
- Modifying captured fields
- Changing event timing (before/after actions)
- Rebuilding after changes

## Validation

After trace collection, validate against the spec:

```bash
cd spec/
tla-trace-workflow --spec Trace.tla --config Trace.cfg --trace ../traces/normal_reconfig.ndjson
```

Expected: All traces validate with no invariant violations or temporal property failures.

## Known Limitations

### Current Test Harness
- **Synthetic traces**: Currently generated from test scenarios rather than real instrumented code
- **Fixed timestamps**: All events in a scenario have the same timestamp (could be refined with real timing)
- **Node IDs**: Hardcoded to s1, s2, s3 (could be parameterized)

### Full Implementation
To instrument real MongoDB code:
1. Integrate trace module into build system
2. Add emit calls at all specified code locations
3. Handle thread safety (mutex already included)
4. Capture actual system state at instrumentation points
5. Rebuild and re-run tests to collect real traces

## File Structure After Instrumentation

```
artifact/mongo-src/
└── src/mongo/db/repl/
    ├── replication_coordinator_impl.cpp [instrumented]
    ├── replication_coordinator_impl.h
    ├── check_quorum_for_config_change.cpp [instrumented]
    ├── tla_trace.h [added]
    └── [other files]
```

## Next Steps

### Phase 2.5 (Current)
- ✓ Create trace module (tla_trace.h)
- ✓ Write test scenarios (test_scenario.cpp)
- ✓ Generate traces (run.sh)
- ✓ Document instrumentation (INSTRUMENTATION.md)

### Phase 3: Trace Validation
- Use `tla-trace-workflow` skill to validate traces against Trace.tla
- Check for invariant violations or state inconsistencies
- Adjust instrumentation if validation fails
- Iterate until all traces pass validation

### Phase 4: Bug Finding
- Use traces in model checking to find bugs
- Cross-reference counterexamples with implementation code
- Iterate on spec and instrumentation as bugs are discovered

## References

- **Instrumentation Spec**: `../spec/instrumentation-spec.md`
- **Trace Spec**: `../spec/Trace.tla`
- **Base Spec**: `../spec/base.tla`
- **Harness Guide**: `../../.claude/skills/harness-generation/guide.md`

## Appendix: Event Action Mapping

| Event Name | Spec Action | Code Location |
|---|---|---|
| ReConfigInitiate | `DoReplSetReconfig_Initiate` | replication_coordinator_impl.cpp:3626 |
| QuorumStart | `QuorumChecker_Start` | replication_coordinator_impl.cpp:3835 |
| QuorumResponse | `QuorumChecker_ProcessResponse` | check_quorum_for_config_change.cpp:157 |
| QuorumTimeout | `QuorumChecker_Timeout` | check_quorum_for_config_change.cpp (timeout) |
| ReConfigPersist | `DoReplSetReconfig_Persist` | replication_coordinator_impl.cpp:3842 |
| JournalFlush | `JournalFlush_Complete` | replication_coordinator_impl.cpp:3878 |
| ReConfigInstall | `DoReplSetReconfig_FinishInstall` | replication_coordinator_impl.cpp:3882 |
| CrashRecovery | `Crash_RecoverConfigFromDisk` | startup recovery path |
| Heartbeat | `Heartbeat_SendCurrentConfig` | replication_coordinator_impl.cpp:4000+ |
| AdvanceCommit | `AdvanceCommittedOptime` | replication_coordinator_impl.cpp:4400+ |
