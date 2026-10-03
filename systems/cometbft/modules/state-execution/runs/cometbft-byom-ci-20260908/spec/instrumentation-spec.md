# Instrumentation Specification — Exact-old Specula V0

## 1. Trace event schema

Every line is one JSON object written by `internal/speculatrace.Emit`:

```json
{"tag":"trace","ts":0,"event":{"name":"ActionName","nid":"node","state":{},"msg":{}}}
```

`ts` is a real Unix-nanosecond observation time. It is deliberately ignored by
the model. `nid` is constant because the scoped subsystem is one node's durable
block/application/state lifecycle. Events are mutex-serialized and synced after
each line. When `SPECULA_TRACE_FILE` is unset, all hooks are no-ops.

The `event.state` object is a full post-action snapshot:

| Trace field | TLA+ variable | Exact-old implementation source |
|---|---|---|
| `blockStoreHeight` | `blockStoreHeight` | `BlockStore.Height()` |
| `appHeight` | `appHeight` | shadow initialized from `Info.LastBlockHeight`, advanced only after commit/replay |
| `stateStoreHeight` | `stateStoreHeight` | `stateStore.Load().LastBlockHeight` |
| `stateHeight` | `stateHeight` | current `sm.State.LastBlockHeight` |
| `activeParam` | `activeParam` | SHA-256 fingerprint of the complete in-memory `ConsensusParams` JSON value |
| `persistedParam` | `persistedParam` | fingerprint of the complete persisted `ConsensusParams` value |
| `lastParamChange` | `lastParamChange` | `LastHeightConsensusParamsChanged` in memory |
| `persistedLastParamChange` | `persistedLastParamChange` | the same field in the loaded state |
| `responseHeight` | `responseHeight` | shadow updated after `SaveFinalizeBlockResponse` or recovered during handshake |
| `responseParam` | `responseParam` | fingerprint of the response's resulting complete parameter value, or `NoParam` |
| `phase` | `phase` | lifecycle phase at the hook |
| `replayMutatesState` | `replayMutatesState` | true only while the final block is replayed through `ApplyBlock` |
| `pendingBlockHeight` | `pendingBlockHeight` | current block under application, otherwise 0 |
| `pendingParam` | `pendingParam` | proposed complete parameter fingerprint, otherwise `NoParam` |
| `validationOutcome` | `validationOutcome` | `none`, `accepted`, or `rejected` |

Event-specific message fields are:

| Event | Message fields |
|---|---|
| `BlockStored` | `height` |
| `ApplyBlockStart` | `height` |
| `FinalizeBlock` | `height`, `proposedParam`, `updatePresent` |
| `SaveFinalizeBlockResponse` | `height` |
| `UpdateStateAccepted` | `height`, `proposedParam`, `updatePresent` |
| `UpdateStateRejected` | `height`, `proposedParam`, `updatePresent` |
| `CommitApp` | `height` |
| `SaveState` | `height` |
| `HandshakeStart` | `appHeight`, `blockStoreBase`, `blockStoreHeight`, `stateStoreHeight` |
| `ReplayAppBlock` | `height` |
| `ReplayStateBlockStart` | `height`, `mode` (`real` or `mock`) |
| `HandshakeComplete` | `height` |

`updatePresent` records whether the ABCI response carried a non-nil consensus
parameter update. The trace wrapper derives its abstract `updatePresent`
variable from the corresponding non-`NoParam` `pendingParam`; error text is not
part of the supplied model boundary.

## 2. Action-to-code mapping

All line numbers below refer to the instrumented writable copy. The underlying
operation is source-derived from the byte-identical immutable tree.

| Spec action / event | Instrumented location | Trigger point and snapshot |
|---|---|---|
| `SaveBlock` / `BlockStored` | `internal/state/execution.go:216-226` | At `ApplyBlock` entry, after its caller has durably saved the block; suppressed for replay, whose stored block is already represented by `ReplayStateBlockStart`. |
| `ApplyBlockStart` / `ApplyBlockStart` | `internal/state/execution.go:223-226` | Immediately after the entry snapshot and before block validation/finalization. |
| `FinalizeBlock(p)` / `FinalizeBlock` | `internal/state/execution.go:248-258` | After successful ABCI `FinalizeBlock`; `p` is the complete updated parameter fingerprint or `NoParam`. |
| `SaveFinalizeBlockResponse` / same | `internal/state/execution.go:281-289` | After the state store save returns successfully. |
| `UpdateStateAccepted` / same | `internal/state/execution.go:325-329` | After exact-old `updateState` validates and installs all response changes in memory. |
| `UpdateStateRejected` / same | `internal/state/execution.go:314-319` | On `updateState` error and before `ApplyBlock` returns it; no commit/state save follows. |
| `CommitApp` / same | `internal/state/execution.go:340-345` | After exact-old `Commit` succeeds and the application height shadow advances. |
| `SaveState` / same | `internal/state/execution.go:357-365` | After the new state has been durably saved; remains in `handshake` phase during final-block replay. |
| `BeginHandshake` / `HandshakeStart` | `internal/consensus/replay.go:254-276` | After ABCI `Info` has supplied the application height and before the recovery decision. The trace file is reset here to exclude fixture setup. |
| `ReplayAppBlock` / same | `internal/consensus/replay.go:523-529` | After one `ExecCommitBlock` completes on the app-only replay path. Core state remains unchanged. |
| `SelectRealReplay` / `ReplayStateBlockStart` | `internal/consensus/replay.go:448`, `535`, `570-578` | Before final-block `replayBlock` with the real app. |
| `SelectMockReplay` / `ReplayStateBlockStart` | `internal/consensus/replay.go:467`, `570-578` | Before final-block `replayBlock` with the saved response-backed mock app. |
| `CompleteHandshake` / `HandshakeComplete` | `internal/consensus/replay.go:296-303` | After recovery succeeds and the state store is reloaded. |

`Crash`, `AppReportsOlderHeight`, and `EnvironmentStutter` are model-only
environment actions. They do not correspond to an executable call boundary,
so they have no runtime event and are used only by `MC.tla`. `AbortRejectedApply`
is represented by trace termination immediately after `UpdateStateRejected`; it
has no additional implementation operation to observe.

## 3. Special considerations

- Parameters are never sampled by selected subfield. A stable fingerprint of
  the complete serialized value prevents a hidden update from being treated as
  equality while keeping TLC's data domain finite.
- Application height and saved-response identity are not jointly exposed by a
  production getter at every hook. The opt-in package maintains those two
  shadow observations, initializes them from ABCI `Info`/the state store during
  handshake, and updates them only after the corresponding exact-old operation.
- `ApplyBlock` is reused during final-block recovery. A replay flag avoids
  falsely emitting a new durable block save and keeps the state save in the
  handshake phase until `HandshakeComplete`.
- The harness runs one scenario per Go process and file. This removes
  cross-test event interleaving; the writer mutex handles intra-process calls.
- The instrumentation ignores emission failures at production call sites so
  tracing cannot replace or alter functional error paths. Harness setup treats
  failure to create the file as a test failure.
- `Trace.tla` validates every captured state field after every event and has no
  silent fallback transition. `TraceMatched` plus fairness ensures a prefix is
  not reported as a successful trace.
