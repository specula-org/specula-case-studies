# CometBFT Consensus Instrumentation Guide

Guide for adjusting instrumentation during trace validation (Phase 3).

## Instrumented Files

| File | Description |
|------|-------------|
| `consensus/trace_emit.go` | Trace module: `TraceLogger`, `TraceEvent`, `TraceExtFields`, `captureState()` |
| `consensus/state.go` | ~16 emit points in consensus state machine + `traceProposalHash` field |
| `consensus/scenario_trace_test.go` | Test scenarios that generate traces |

## Trace Module (`trace_emit.go`)

- **`TraceLogger`**: Thread-safe NDJSON writer with `Emit(*TraceEvent)` method
- **`captureState()`**: Snapshots `height`, `round`, `step`, `lockedRound`, `lockedValue`, `validRound`, `validValue` from `cs.RoundState`
- **`traceNodeID()`**: Returns hex-encoded validator address (40 chars)
- **`stepString()`**: Maps `RoundStepType` to TLA+ step names (`"NewHeight"`, `"Propose"`, etc.)
- **`blockHashStr()`**: Hex-encodes block hash, returns `"nil"` for empty
- **`TraceExtFields`**: Holds `verified` and `bypassed` bools for Family 1 precommit events

The logger is set via `cs.SetTraceLogger(tl)` in test scenarios.

## Instrumentation Points in `state.go`

| Approx Line | Event Name | Trigger |
|-------------|-----------|---------|
| ~1016 | `HandleTimeoutPropose` | Timeout handler, RoundStepPropose case |
| ~1030 | `HandleTimeoutPrevote` | Timeout handler, RoundStepPrevoteWait case |
| ~1044 | `HandleTimeoutPrecommit` | Timeout handler, RoundStepPrecommitWait case |
| ~1148 | `EnterNewRound` | After `cs.Step = RoundStepNewRound` |
| ~1213 | `EnterPropose` | After step transition; includes `msg.value` when proposer |
| ~1397 | `EnterPrevote` | After step transition + `doPrevote()` |
| ~1500 | `EnterPrevoteWait` | After `TriggeredTimeoutPrecommit = true` |
| ~1536 | `EnterPrecommit` | After step transition + precommit vote sent |
| ~1673 | `EnterPrecommitWait` | After `TriggeredTimeoutPrecommit = true` |
| ~1707 | `EnterCommit` | After `cs.Step = RoundStepCommit` |
| ~1908 | `FinalizeCommit` | After `updateToState` (height incremented) |
| ~2054 | `ReceiveProposal` | After `cs.Proposal = proposal` accepted |
| ~2387 | `ReceivePrevote` | After `cs.Votes.AddVote` for prevote |
| ~2399 | `ReceivePrecommit` | After `cs.Votes.AddVote` for precommit; includes `ext` fields |

## Post-Processing

Raw traces use hex validator addresses as `nid`/`msg.source`/`msg.dest` and hex block hashes in `state.lockedValue`/`state.validValue`/`msg.value`. The Trace.tla expects abstract names (`s1`, `s2`, `s3` and `v1`, `v2`, ...).

```bash
python3 harness/preprocess_trace.py traces/basic_consensus.ndjson traces/basic_consensus_mapped.ndjson
```

The script assigns `s1` to the first unique `nid` (the observed node), then `s2`, `s3` to peers seen in `msg.source`/`msg.dest`. Block hashes are assigned `v1`, `v2`, ... in first-occurrence order.

`run.sh` calls this automatically; mapped files are `*_mapped.ndjson`.

## How to Add a New Field

1. Add the field to `TraceStateSnap`, `TraceMsgFields`, or `TraceExtFields` in `trace_emit.go`
2. Populate it at the relevant emit call in `state.go`
3. Rebuild: `cd artifact/cometbft && go build ./consensus/`

## How to Add a New Event

1. Find the code location in `spec/instrumentation-spec.md`
2. Add `cs.traceLogger.Emit(&TraceEvent{Name: "EventName", Nid: cs.traceNodeID(), State: cs.captureState(), ...})` at the trigger point
3. Rebuild and re-run

## How to Move a Capture Point

`captureState()` reads from `cs.RoundState` at call time. Key state mutations:
- `cs.updateRoundStep(round, step)` — changes `cs.Round` and `cs.Step`
- `cs.LockedRound = ...` / `cs.LockedBlock = ...` — lock changes in `enterPrecommit`
- `cs.ValidRound = ...` / `cs.ValidBlock = ...` — valid block updates in `addVote`

Moving an emit before/after a mutation changes the captured snapshot.

## EnterPrecommitWait Note

`enterPrecommitWait` does NOT call `updateRoundStep` — `cs.Step` stays at `StepPrecommit`. The `EnterPrecommitWait` event therefore captures `step = "Precommit"`, but the Trace.tla's `EnterPrecommitWaitIfLogged` does not call `ValidatePostState`, so this is fine.

## Rebuild and Re-run

```bash
cd artifact/cometbft
go test -v -count=1 \
  -run "TestScenario(BasicConsensus|TimeoutPropose|LockAndRelock|TwoHeights)" \
  -timeout 90s ./consensus/
```

Then post-process:
```bash
python3 harness/preprocess_trace.py traces/basic_consensus.ndjson traces/basic_consensus_mapped.ndjson
```

Or run everything:
```bash
bash harness/run.sh
```
