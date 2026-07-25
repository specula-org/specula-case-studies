# CometBFT Instrumentation Guide

This document guides Phase 3 agents in adjusting the trace instrumentation when validation reveals issues.

## Current Instrumentation Status

The CometBFT consensus module has been instrumented to emit NDJSON trace events. The infrastructure consists of:

- **`consensus/trace_emit.go`** — Core trace infrastructure
  - `TraceLogger` — Thread-safe NDJSON writer
  - `TraceEvent` — Event envelope with name, node ID, and state snapshot
  - `TraceStateSnap` — Captured consensus state (height, round, step, locks, valid block)
  - Helper functions: `stepString()`, `captureState()`, `traceNodeID()`, `blockHashStr()`

- **`consensus/state.go`** — Instrumentation points
  - Field: `traceLogger *TraceLogger` (added to State struct at line 140-141)
  - Method: `SetTraceLogger(tl *TraceLogger)` (line 229)
  - 14+ emit points throughout the state machine (see list below)

- **`consensus/scenario_trace_test.go`** — Test scenarios that generate traces
  - `TestScenarioBasicConsensus` — 3-validator single-height consensus
  - `TestScenarioTimeoutPropose` — Propose timeout behavior
  - `TestScenarioLockAndRelock` — Lock/unlock/relock protocol paths
  - `TestScenarioTwoHeights` — Multi-height execution
  - Helper functions: `traceDir()`, `setupTraceLogger()`, `subscribe()`, `ensurePrevote()`, etc.

## Instrumentation Points

### Implemented Events

| Event Name | File | Line | Triggering Action | State Snapshot |
|---|---|---|---|---|
| `HandleTimeoutPropose` | state.go | 1017 | Propose timeout in NewHeight/NewRound | Current |
| `HandleTimeoutPrevote` | state.go | 1031 | Prevote timeout (no +2/3) | Current |
| `HandleTimeoutPrecommit` | state.go | 1045 | Precommit timeout | Current |
| `EnterPropose` | state.go | 1213 | Transition to Propose step | Current |
| `EnterNewRound` | state.go | 1148 | Transition to NewRound (after round increment) | **After** round/height change |
| `EnterPrevote` | state.go | 1397 | Transition to Prevote step | **After** step update |
| `EnterPrevoteWait` | state.go | 1500 | Hit +2/3 prevotes | Current |
| `EnterPrecommit` | state.go | 1536 | Transition to Precommit step | **After** step update |
| `EnterPrecommitWait` | state.go | 1673 | Hit +2/3 precommits or timeout | Current |
| `EnterCommit` | state.go | 1707 | Transition to Commit step | Current |
| `AddVote` | state.go | 1908 | Vote added to vote set | **After** vote accepted |
| `ReceiveProposal` | state.go | 2054 | Proposal message received | Current |

### Missing Events (from spec but not yet instrumented)

- `ReceiveBlockPart` — Block part assembly (lines 2073-2149)
- `HandleCompleteProposal` — Complete proposal handling (lines 2151-2184)
- `UnlockOnPol` — POL-based unlock (lines 2409-2423)
- `UpdateValidBlock` — ValidBlock update (lines 2427-2432)
- `CheckVoteExtension` — Vote extension validation (lines 2296-2345)
- `CrashAndRecover` — Recovery from crash (lines 186-192, 592-631)

## How to Add/Modify Instrumentation

### 1. Add a New Trace Event

To emit a new trace event at a specific location:

```go
// At the desired instrumentation point in consensus/state.go:
cs.traceLogger.Emit(&TraceEvent{
    Name:  "EventName",          // Must match spec action name exactly
    Nid:   cs.traceNodeID(),     // Node identifier (hex-encoded pubkey address)
    State: cs.captureState(),    // Current consensus state
})
```

The `TraceEvent` structure includes:
- `Name` — String name matching TLA+ spec action
- `Nid` — Node ID (output of `cs.traceNodeID()`)
- `State` — `TraceStateSnap` with height, round, step, locks, valid block
- `Msg` — Optional message fields for vote/proposal events (not currently used in basic events)

### 2. Add Message Fields to a Trace Event

For events that carry message metadata (votes, proposals), extend the emit call:

```go
// Example: Add vote fields to AddVote event
vote := &types.Vote{...}  // The vote being added
cs.traceLogger.Emit(&TraceEvent{
    Name:  "AddVote",
    Nid:   cs.traceNodeID(),
    State: cs.captureState(),
    Msg: &TraceMsgFields{
        Source: hex.EncodeToString(vote.ValidatorAddress),
        Type:   "prevote",  // or "precommit"
        Value:  blockHashStr(vote.BlockID.Hash),
        Round:  vote.Round,
        VE:     "",  // vote extension if applicable
    },
})
```

### 3. Change State Capture Timing (Before/After)

The `captureState()` call captures state at emit time. To capture state **before** a mutation:

```go
// BEFORE: Save old state
oldState := cs.captureState()

// DURING: Mutation happens
cs.LockedBlock = newBlock
cs.LockedRound = newRound

// AFTER: Emit with new state
cs.traceLogger.Emit(&TraceEvent{
    Name:  "LockBlock",
    Nid:   cs.traceNodeID(),
    State: cs.captureState(),
})
```

If you need to capture state **before** the mutation, save it manually:

```go
// Save state before mutation
preLockState := TraceStateSnap{
    Height:      cs.Height,
    Round:       cs.Round,
    Step:        stepString(cs.Step),
    LockedRound: cs.LockedRound,  // OLD value
    LockedValue: blockHashStr(cs.LockedBlock.Hash() if cs.LockedBlock != nil else nil),
    ValidRound:  cs.ValidRound,
    ValidValue:  blockHashStr(cs.ValidBlock.Hash() if cs.ValidBlock != nil else nil),
}

// Now mutate
cs.LockedBlock = newBlock
cs.LockedRound = newRound

// Emit with the saved pre-state if needed, or capture post-state
cs.traceLogger.Emit(&TraceEvent{
    Name:  "LockBlock",
    Nid:   cs.traceNodeID(),
    State: cs.captureState(),  // This is NOW the NEW state
})
```

### 4. Understand State Capture Level

The current instrumentation captures **full state** (all consensus variables). No weak-state events yet.

If adding weak-state events (e.g., from background goroutines), document it in a comment:

```go
// WEAK_STATE: Only term and role available in this goroutine
cs.traceLogger.Emit(&TraceEvent{
    Name: "AsyncEvent",
    Nid:  cs.traceNodeID(),
    // Cannot use cs.captureState() here due to lock-free context
    // Must construct minimal state manually or skip tracing
})
```

## How to Rebuild and Re-Run After Changes

1. **Edit instrumentation point** in `consensus/state.go`
2. **Rebuild**:
   ```bash
   cd artifact/cometbft
   go test -c ./consensus -o /tmp/consensus.test
   ```
3. **Re-run tests**:
   ```bash
   cd ../..  # Back to project root
   TRACE_DIR=traces ./harness/run.sh
   ```
4. **Check trace output**:
   ```bash
   jq . traces/basic_consensus.ndjson | head -30
   ```

## Trace Format Details

Each trace line is NDJSON (one JSON object per line):

```json
{
  "ts": "2025-06-04T10:15:30.123456789Z",
  "tag": "trace",
  "event": {
    "name": "EnterPrevote",
    "nid": "a1b2c3d4e5f6...",
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

### Field Mappings

| TLA+ Variable | Trace Field | Code Access |
|---|---|---|
| height | `state.height` | `cs.Height` |
| round | `state.round` | `cs.Round` |
| step | `state.step` | `stepString(cs.Step)` |
| lockedBlock[v] | `state.lockedValue` | `blockHashStr(cs.LockedBlock.Hash() if cs.LockedBlock != nil)` |
| lockedRound[v] | `state.lockedRound` | `cs.LockedRound` |
| validBlock[v] | `state.validValue` | `blockHashStr(cs.ValidBlock.Hash() if cs.ValidBlock != nil)` |
| validRound[v] | `state.validRound` | `cs.ValidRound` |

## Testing Instrumentation

To verify an instrumentation change works:

1. **Add a new scenario test** in `consensus/scenario_trace_test.go`:
   ```go
   func TestScenarioMyNewPath(t *testing.T) {
       config = test.ResetTestRoot("scenario_new_path")
       defer os.RemoveAll(config.RootDir)

       tl := setupTraceLogger(t, "my_new_path")
       cs1, vss := randState(3)

       cs1.SetTraceLogger(tl)
       // ... test code ...
   }
   ```

2. **Run the test**:
   ```bash
   cd artifact/cometbft
   go test -v -run TestScenarioMyNewPath ./consensus
   ```

3. **Inspect the trace**:
   ```bash
   jq '.event | select(.name == "MyNewEvent")' ../../traces/my_new_path.ndjson
   ```

## Common Issues and Fixes

| Issue | Symptom | Fix |
|---|---|---|
| Trace file not created | `traces/` directory empty | Check `setupTraceLogger()` in test and ensure it calls `cs.SetTraceLogger(tl)` |
| Missing events | Event name appears 0 times in all traces | Verify instrumentation point is reached (add `cs.Logger.Info()` nearby to confirm) |
| Nil state values | `"lockedValue": null` instead of `"nil"` | Check `blockHashStr()` function — it should return `"nil"` string, not null |
| Wrong step name | `"step": "Unknown"` | Verify `stepString()` maps all `RoundStepType` enum values |
| State mismatch | Spec expects value A, trace shows B | Check state capture timing (before vs. after mutation) |

## Phase 3 Validation Flow

1. **Collect traces** (Phase 2.5): `./harness/run.sh` → `traces/*.ndjson`
2. **Validate traces** (Phase 3): `tla-trace-workflow` with `spec/Trace.tla`
3. **If validation fails**:
   - Check error message for which event/field mismatches
   - Use this guide to add/move/modify instrumentation
   - Re-run collection and validation
4. **Iterate** until all traces pass validation

## References

- **Specification**: `../spec/instrumentation-spec.md`
- **Trace Spec**: `../spec/Trace.tla`
- **Current Implementation**: `artifact/cometbft/consensus/state.go`, `trace_emit.go`
- **Test Scenarios**: `artifact/cometbft/consensus/scenario_trace_test.go`
