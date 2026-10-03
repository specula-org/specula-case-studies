# V0 scope: CometBFT state execution and recovery

> BYOM adoption note (2026-09-08): the objective below records the supplied
> model's earlier preparation contract. In this CI initialization it is the
> binding scope for adoption, not an instruction to regenerate the V0 model.

## Objective

Generate a pre-update TLA+ reference model from the supplied old tree only.
Model the lifecycle of consensus-parameter state as a block is executed,
committed, saved, and, when local components are at different heights,
replayed during startup.

This is Category A distributed-system behavior because CometBFT, its ABCI
application, the block store, and the state store can advance at different
durable boundaries. Byzantine voting behavior is outside this V0 scope.

## Source map to establish

Read these old-tree paths completely before writing the model:

- `types/params.go`: parameter representation, basic validation, update
  validation, update application, and serialization.
- `internal/state/execution.go`: block execution, `FinalizeBlock`, state
  transition, commit, and save ordering.
- `internal/state/state.go`: persisted state fields and serialization.
- `internal/consensus/replay.go`: handshake height cases and replay paths.
- `node/node.go`: startup and handshake entry point.
- `proxy/app_conn.go` and the relevant `abci/types` definitions: application
  request/response boundary.
- `spec/abci/abci++_app_requirements.md`: old-tree application contract.

Tests may clarify existing behavior, but test names and assertions must not be
promoted to implementation semantics without checking the production path.

## Model boundary

Represent at least:

- node, application, block-store, and state-store heights;
- the active consensus parameters and their last-change height;
- a block/finalization response carrying an optional parameter update;
- startup phase and whether replay mutates state;
- success or rejection of old-tree validation;
- the durable boundary between block storage, application commit, and state
  save.

Represent actions corresponding to normal block application, application
finalization, validation, state update, commit, state save, crash, handshake,
and the old-tree replay cases. Split actions only at boundaries that can be
observed after restart.

Do not model transaction contents, validator voting rounds, evidence gossip,
light-client verification, cryptographic details, or unrelated configuration
parameters.

## Neutral V0 properties

Use properties justified by the old tree without anticipating another
revision:

- type correctness for heights, phases, and stored parameters;
- successful block application advances state by exactly one height;
- a rejected validation does not install the proposed state;
- persisted height relationships obey the cases accepted by the old
  handshake code;
- a successful parameter update is reflected in the next state and its
  recorded change height;
- recovery reaches a normal startup phase only through an old-tree-supported
  height/replay case.

Do not add a property solely to distinguish behavior that is absent from the
old tree.

## Old-only validation evidence

The following existing tests are suitable baseline checks:

- `types.TestConsensusParamsValidation`
- `types.TestConsensusParamsUpdate`
- `types.TestConsensusParamsUpdate_AppVersion`
- `types.TestConsensusParamsUpdate_VoteExtensionsEnableHeight`
- `internal/state.TestApplyBlock`
- `internal/state.TestFinalizeBlockResponsesSaveLoad1`
- `internal/state.TestFinalizeBlockResponsesSaveLoad2`
- `internal/state.TestConsensusParamsChangesSaveLoad`
- `internal/consensus.TestHandshakeReplayAll`
- `internal/consensus.TestHandshakeReplaySome`
- `internal/consensus.TestHandshakeReplayOne`
- `internal/consensus.TestHandshakeReplayNone`

The old tree does not provide an NDJSON trace stream for this boundary. The V0
generator may map test scenarios to abstract actions, but must record native
trace validation as unavailable unless it creates and separately validates
old-tree instrumentation.

## Acceptance gates

- SANY parses `base.tla` and the configured model.
- A small bounded TLC run completes with the neutral V0 invariants enabled.
- The source mapping cites only supplied old-tree paths and functions.
- The focused old-only tests pass, or the exact dependency limitation is
  recorded.
- The suite contains no external or historical references.
