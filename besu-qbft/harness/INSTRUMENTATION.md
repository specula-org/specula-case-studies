# Besu QBFT Instrumentation Guide

Guide for adjusting instrumentation during trace validation (Phase 3).

## Instrumented Files

After applying `patches/instrumentation.patch`:

| File | Instrumentation Points |
|------|----------------------|
| `QbftBlockHeightManager.java:178` | `BlockTimerExpiry` — after `startNewRound(0)` |
| `QbftBlockHeightManager.java:283` | `RoundExpiry` — before `doRoundChange()` |
| `QbftRound.java:232` | `HandleProposal` — after `updateStateWithProposedBlock()` |
| `QbftRound.java:333` | `HandlePrepare` — after `addPrepareMessage()` in `peerIsPrepared()` |
| `QbftRound.java:352` | `HandleCommit` — after `addCommitMessage()` in `peerIsCommitted()` |
| `QbftController.java:259-262` | `NewChainHead` — after `startNewHeightManager()` |

All points use the static `TlaTracer` utility class (new file at `QbftRound.java`'s package).

## Trace Module

`TlaTracer.java` — static NDJSON emitter, activated by `-Dtla.trace.file=<path>`.

Key methods:
- `emitFromRound(eventName, round, localAddr)` — node events from QbftRound context
- `emitMsgFromRound(eventName, round, localAddr, msgFrom, msgType)` — message events
- `emitNodeEvent(...)` — standalone node events (used by QbftController)
- `registerNode(address, tlaName)` — maps Address to "s1"/"s2"/etc.
- `nid(address)` — looks up TLA+ name for an Address

## How to Add a New Field

1. Add parameter to `emitNodeEvent()` or `emitMsgEvent()` in `TlaTracer.java`
2. Include it in the JSON format string
3. Pass the value at each call site

## How to Add a New Event

1. Find the code location in the instrumentation-spec
2. Add a `TlaTracer.emitFromRound(...)` or `TlaTracer.emitMsgFromRound(...)` call
3. Rebuild: `./gradlew :consensus:qbft-core:compileIntegrationTestJava`

## How to Move a Capture Point

The `before/after` placement matters for state accuracy:
- **After**: captures post-action state (current approach for all events)
- **Before**: would capture pre-action state

To move: relocate the `TlaTracer.emit*()` call relative to the state-changing code.

## Known Limitations

- **Single-node tracing only**: The test framework (`TestContextBuilder`) runs 1 real node; peers are `ValidatorPeer` stubs. Only s1's events are traced.
- **Self-prepare artifact**: `peerIsPrepared()` is called for both local self-prepares (inside `sendPrepare()`) and remote prepares. The proposer's self-prepare emits a `HandlePrepare(from=s1, to=s1)` event that has no corresponding spec action — it's part of `BlockTimerExpiry` in the spec. This needs to be filtered or the spec needs a silent action.
- **Message injection gap**: When tests call `peers.getNonProposing(0).injectPrepare(...)`, the remote node's full protocol flow (BlockTimerExpiry → HandleProposal → send Prepare) is invisible. The spec needs silent actions for other nodes' state transitions.

## Rebuild and Re-run

```bash
cd artifact/besu
./gradlew :consensus:qbft-core:integrationTest \
  --tests "org.hyperledger.besu.consensus.qbft.core.test.TlaTraceTest" --rerun
```

Traces appear in `consensus/qbft-core/tla_trace_*.ndjson`.
