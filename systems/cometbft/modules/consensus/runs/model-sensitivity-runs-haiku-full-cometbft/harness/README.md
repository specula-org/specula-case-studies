# CometBFT Trace Collection Harness

This directory contains the instrumentation harness for collecting execution traces from CometBFT's consensus module for TLA+ trace validation.

## Overview

The harness enables:
1. **Instrumentation** — The consensus code emits NDJSON trace events at key state transitions
2. **Test Execution** — Test scenarios exercise protocol paths to generate traces
3. **Trace Collection** — Tests write NDJSON events to files in the `../traces/` directory
4. **Preprocessing** — Optional node ID normalization for trace validation

## Directory Structure

```
harness/
├── apply.sh                    # Verifies instrumentation is present
├── run.sh                      # Master script: runs tests, collects traces
├── preprocess_traces.py        # Normalizes node IDs in traces
├── INSTRUMENTATION.md          # Guide for Phase 3 adjustments
├── src/                        # Harness source code (if standalone instrumentation needed)
├── README.md                   # This file
└── ../ (parent)
    ├── artifact/cometbft/      # Instrumented CometBFT code
    │   ├── consensus/
    │   │   ├── trace_emit.go          # Trace infrastructure
    │   │   ├── state.go               # Instrumentation points
    │   │   └── scenario_trace_test.go # Test scenarios
    │   └── ...
    └── traces/                        # Output NDJSON trace files
        ├── basic_consensus.ndjson
        ├── timeout_propose.ndjson
        ├── lock_and_relock.ndjson
        └── ...
```

## Quick Start

### Run Trace Collection (Go 1.24+ required)

```bash
cd /path/to/cometbft
bash harness/run.sh
```

This will:
1. Verify instrumentation is in place
2. Run test scenarios to generate traces
3. Collect NDJSON files in `traces/`
4. Validate trace format and content

### Expected Output

```
================================================
CometBFT Trace Collection
================================================
Project root: /home/ubuntu/.../cometbft
...
✓ Instrumentation verified
✓ Traces directory ready
✓ Tests completed
✓ Collected 4 trace files
  - basic_consensus.ndjson (156 lines)
  - timeout_propose.ndjson (142 lines)
  - lock_and_relock.ndjson (198 lines)
  - two_heights.ndjson (234 lines)
✓ All traces validated
```

## Instrumentation Architecture

### Core Components

**`consensus/trace_emit.go`** — Trace infrastructure
- `TraceLogger` — Thread-safe NDJSON writer
- `TraceEvent` — Event envelope (name, node ID, state, optional message fields)
- `TraceStateSnap` — Consensus state snapshot (height, round, step, locks)
- Helper functions for step/block/node ID serialization

**`consensus/state.go`** — Instrumentation points
- Added field: `traceLogger *TraceLogger` to State struct
- Added method: `SetTraceLogger(tl *TraceLogger)`
- 14+ emit points at key state transitions:
  - `EnterNewRound`, `EnterPropose`, `EnterPrevote`, `EnterPrevoteWait`
  - `EnterPrecommit`, `EnterPrecommitWait`, `EnterCommit`
  - `HandleTimeoutPropose`, `HandleTimeoutPrevote`, `HandleTimeoutPrecommit`
  - `AddVote`, `ReceiveProposal`

**`consensus/scenario_trace_test.go`** — Test scenarios
- `TestScenarioBasicConsensus` — 3-validator consensus single height
- `TestScenarioTimeoutPropose` — Propose timeout handling
- `TestScenarioLockAndRelock` — Lock/unlock/relock protocol paths
- `TestScenarioTwoHeights` — Multi-height execution
- Helper functions: `traceDir()`, `setupTraceLogger()`, `subscribe()`, `ensurePrevote()`, etc.

### Instrumentation Points Summary

| Event | Trigger | State Snapshot |
|---|---|---|
| `EnterNewRound` | Transition to new round | After round increment |
| `EnterPropose` | Start proposal period | Current |
| `EnterPrevote` | Start prevote period | After step update |
| `EnterPrevoteWait` | Have +2/3 prevotes | Current |
| `EnterPrecommit` | Start precommit period | After step update |
| `EnterPrecommitWait` | Have +2/3 precommits | Current |
| `EnterCommit` | Block committed | Current |
| `HandleTimeoutPropose` | Propose timeout fired | Current |
| `HandleTimeoutPrevote` | Prevote timeout fired | Current |
| `HandleTimeoutPrecommit` | Precommit timeout fired | Current |
| `AddVote` | Vote added to vote set | After vote acceptance |
| `ReceiveProposal` | Proposal message received | Current |

### Trace Event Format

NDJSON (one event per line, newline-delimited JSON):

```json
{
  "ts": "2025-06-04T10:15:30.123456789Z",
  "tag": "trace",
  "event": {
    "name": "EnterPrevote",
    "nid": "a1b2c3d4e5f6789012345678",
    "state": {
      "height": 1,
      "round": 0,
      "step": "Prevote",
      "lockedRound": -1,
      "lockedValue": "nil",
      "validRound": -1,
      "validValue": "nil"
    }
  }
}
```

## Workflow: From Instrumentation to Validation

### Phase 2.5: Trace Collection (This Harness)

1. **Apply instrumentation** → `apply.sh` verifies code is instrumented
2. **Build project** → Compile instrumented consensus module
3. **Run tests** → Test scenarios generate execution traces
4. **Collect traces** → Tests write NDJSON events to `traces/*.ndjson`
5. **Validate format** → Check JSON validity, event counts, field presence

**Output**: `traces/*.ndjson` — NDJSON files with 20-200+ events each

### Phase 3: Trace Validation

1. **Load traces** → TLA+ Trace module reads NDJSON files
2. **Replay against spec** → For each event, invoke corresponding spec action
3. **Validate state** → Check that implementation state matches spec state
4. **Report mismatches** → If validation fails, identify which event/field caused it
5. **Iterate** — Fix instrumentation (via `INSTRUMENTATION.md` guide) and re-run

**Input**: `traces/*.ndjson` from Phase 2.5  
**Output**: Validation pass/fail, diagnostic logs

## Adjusting Instrumentation (Phase 3)

See `INSTRUMENTATION.md` for detailed guidance on:
- Adding new trace events
- Changing state capture timing (before vs. after)
- Adding message fields (vote type, block ID, etc.)
- Rebuilding and re-running tests

Quick checklist:
1. Edit `artifact/cometbft/consensus/state.go` (add emit call)
2. Run `cd artifact/cometbft && go test -v -run Scenario ./consensus`
3. Check output: `cat ../../traces/scenario_name.ndjson | jq .`
4. Run validation: `tla-trace-workflow` with `Trace.tla`

## Environment Requirements

### For Trace Collection (Phase 2.5)

- **Go 1.24+** — To compile and run tests
- **Linux/macOS/Windows** — Test infrastructure is platform-agnostic
- **Disk space** — ~100MB for artifact code + traces

### For Trace Validation (Phase 3)

- **TLA+ Toolbox** or **tlc-trace-debugger** — To validate traces against spec
- **Python 3** — Optional, for preprocessing node IDs

## Common Issues

| Issue | Cause | Solution |
|---|---|---|
| `Error: artifact directory not found` | Wrong working directory | Run from project root: `cd /path/to/cometbft && bash harness/run.sh` |
| `Error: trace_emit.go not found` | Instrumentation removed | Check git status; instrumentation should be in artifact code |
| `No traces collected in traces/` | Tests didn't create TraceLogger | Verify `SetTraceLogger()` is called in test setup (scenario_trace_test.go) |
| `Tests timeout` | Deadlock in consensus protocol | May indicate a real bug; check if spec should prevent it |
| `Invalid JSON in trace` | Encoding error | Check `TraceEvent` struct; all fields should be JSON-serializable |

## Preprocessing Traces

To normalize hex node IDs to simpler names:

```bash
# Keep original IDs (default)
./preprocess_traces.py traces/basic_consensus.ndjson traces/basic_consensus.normalized.ndjson

# Map to v1, v2, v3, ... based on discovery order
./preprocess_traces.py traces/basic_consensus.ndjson traces/basic_consensus.normalized.ndjson --rename-to-v-style

# Use short 8-char hex prefix
./preprocess_traces.py traces/basic_consensus.ndjson traces/basic_consensus.normalized.ndjson --rename-short
```

**Note**: If using preprocessing, update Trace.cfg to use the normalized file path.

## Testing Instrumentation Locally

If modifying instrumentation:

```bash
cd artifact/cometbft

# Compile just the consensus package
go test -c ./consensus

# Run a single test scenario
go test -v -run TestScenarioBasicConsensus ./consensus

# Check trace output
cat ../../traces/basic_consensus.ndjson | jq 'select(.event.name == "EnterPrevote")'
```

## Next Steps: Phase 3 (Trace Validation)

Once traces are collected:

1. **Copy traces to validation workspace** (if running validation elsewhere)
2. **Point Trace.cfg to trace file** — Set `JSON` environment variable
3. **Run TLC model checker** — `tlc Trace.tla`
4. **Debug failures** — Use `tla-trace-debugger` to interactively inspect events
5. **Fix instrumentation** — Iterate using `INSTRUMENTATION.md` guide
6. **Re-collect and re-validate** — Repeat until all traces pass

## References

- **Specification**: `../spec/base.tla`, `../spec/Trace.tla`
- **Instrumentation Spec**: `../spec/instrumentation-spec.md`
- **Artifact Code**: `artifact/cometbft/consensus/`
- **Harness Guide**: `INSTRUMENTATION.md`
- **CometBFT Docs**: https://docs.cometbft.com/

## Contact & Support

For issues with trace collection:
1. Check `INSTRUMENTATION.md` for known issues and solutions
2. Verify artifact code integrity: `git -C artifact/cometbft status`
3. Check test logs: `go test -v ./consensus | grep -A 5 "ERROR"`
4. See `common_test.go` in artifact for test infrastructure details
