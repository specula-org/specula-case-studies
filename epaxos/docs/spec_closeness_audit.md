# Spec Closeness Audit: `base.tla` / `Trace.tla` vs Implementation

Date: 2026-02-22

## Verdict

`base.tla` and `Trace.tla` are **not yet implementation-level**.

They are currently a **hybrid**:
- stronger than a paper-level EPaxos model (they include several implementation bugs/quirks),
- but still significantly abstracted from the real Go code in ways that can hide or distort implementation bugs.

## What Is Already Close

- Core action decomposition exists (`ClientRequest`, `PreAccept`, `PreAcceptOK`, `FastPathCommit`, `Accept`, `AcceptOK`, `Commit`, `Execute`, `Prepare`, `PrepareOK`, `RecoveryAccept`, `Join`) in `spec/base.tla`.
- Several known implementation issues are intentionally encoded (e.g., nontriviality pressure, recovery branches, crash/restart scaffolding).
- Trace wrapper is event-driven and aligned to emitted event names in `artifact/epaxos/epaxos/trace_helpers.go`.

## Why It Is Still Too High-Level

### 1. Batched commands are collapsed to single-command semantics

Implementation stores and transmits `[]state.Command` per instance:
- `Instance.Cmds []state.Command` (`artifact/epaxos/epaxos/epaxos.go:94`)
- `bcastPreAccept` / `bcastCommit` carry `Command []state.Command` (`artifact/epaxos/epaxos/epaxos.go:510`, `artifact/epaxos/epaxos/epaxos.go:613`)

Spec uses one `cmd` record everywhere:
- `InstType.cmd` and `MsgType.cmd` (`spec/base.tla:41`, `spec/base.tla:78`)

Impact:
- misses intra-batch conflict/order behaviors,
- linearizability/execution checks can pass while batch-level bugs remain.

### 2. Execution model is much coarser than the implementation

Implementation executes via SCC/Tarjan and ordered tie-breaking:
- SCC traversal: `findSCC` / `strongconnect` (`artifact/epaxos/epaxos/exec.go:46`, `artifact/epaxos/epaxos/exec.go:58`)
- execution order tie-break by `(Seq, replica, proposeTime)` (`artifact/epaxos/epaxos/exec.go:170`)

Spec `Execute` only checks dependency frontier against `committedUpTo` and flips one slot to `EXECUTED`:
- `spec/base.tla:634`

Impact:
- can miss execution-order anomalies that only appear through SCC composition and tie-breaking.

### 3. Recovery path is compressed; TryPreAccept behavior is not first-class

Implementation has explicit `handleTryPreAccept` and `handleTryPreAcceptReply` with `possibleQuorum`, deferred-cycle logic, and restarts:
- `artifact/epaxos/epaxos/epaxos.go:1375`
- `artifact/epaxos/epaxos/epaxos.go:1461`

Spec has no explicit `TryPreAccept` / `TryPreAcceptReply` actions; this behavior is folded into `PrepareOK`/`RecoveryAccept` abstractions:
- `spec/base.tla:746`
- `spec/base.tla:807`

Impact:
- weak coverage for bugs in subcase-4 / tpa transitions and defer-cycle logic.

### 4. Trace mapping currently tolerates many unmodelable events via no-op

`Trace.tla` now intentionally no-ops out-of-bounds IDs:
- representability guard + fallback `TraceNoOp` (`spec/Trace.tla:39`, `spec/Trace.tla:69`, `spec/Trace.tla:84`, `spec/Trace.tla:95`, `spec/Trace.tla:105`, `spec/Trace.tla:120`, `spec/Trace.tla:129`)

Impact:
- enables long-trace validation under small bounds,
- but reduces strict replay fidelity (some real transitions are skipped instead of modeled).

### 5. Command identity in traces is synthetic, not implementation-native

Trace wrapper synthesizes command ids:
- `NormCmdId(...)` (`spec/Trace.tla:24`)

Implementation does not expose model-stable per-command ids in replica trace events (only key/op payload in event maps):
- `commandMap` omits id/client seq (`artifact/epaxos/epaxos/trace_helpers.go:29`)

Impact:
- aliasing risk in `executedOrder`/`serializedPairs` reasoning,
- weakens bug localization around per-command ordering properties.

### 6. Durable metadata bug is not modeled at byte-level

Implementation overwrite bug in persistence encoding:
- `binary.LittleEndian.PutUint32(b[0:4], uint32(inst.bal))`
- then overwrite with `inst.vbal` at same range (`artifact/epaxos/epaxos/epaxos.go:205`, `artifact/epaxos/epaxos/epaxos.go:206`)

Spec stable metadata is updated as ideal structured values, not encoded bytes:
- e.g. `stableMeta' = ... [bal |-> ..., vbal |-> ...]` (`spec/base.tla:390`, `spec/base.tla:477`, `spec/base.tla:835`)

Impact:
- crash/restart checks can miss persistence-corruption behaviors.

### 7. Network/send policy abstraction omits Alive/Thrifty/peer-order effects

Implementation send fanout depends on `Alive`, `Thrifty`, `PreferredPeerOrder`:
- `bcastPreAccept` (`artifact/epaxos/epaxos/epaxos.go:519`)
- `bcastAccept` (`artifact/epaxos/epaxos/epaxos.go:584`)

Spec generally sends to `members \ {n}` in one set-comprehension:
- e.g. `spec/base.tla:307`, `spec/base.tla:475`, `spec/base.tla:557`

Impact:
- quorum/race corner cases tied to partial fanout may be missed.

## Additional Trace-Level Gap

Implementation traces events for `Prepare`, `PreAccept`, `Accept`, `Commit`, etc., but **not** for `TryPreAccept` and `TryPreAcceptReply` message handling.
- See trace points: `artifact/epaxos/epaxos/epaxos.go:477`, `:513`, `:579`, `:617`, `:1273`, `:1359`, `:1500`

Impact:
- even with better base spec, trace validation cannot fully constrain these branches without more instrumentation.

## Priority Changes to Reach Implementation-Level

1. Model batched command payloads end-to-end (`CmdSeqType`) in instance/message state and execution.
2. Introduce explicit `TryPreAccept` / `TryPreAcceptReply` actions and deferred-cycle bookkeeping.
3. Replace coarse `Execute` with SCC-oriented execution abstraction that preserves the implementation tie-break rule.
4. Add persistence-encoding abstraction for `recordInstanceMetadata` overwrite behavior on restart.
5. Tighten `Trace.tla`: make no-op fallback optional/configurable so strict replay mode fails on unrepresentable events.
6. Extend instrumentation to emit deterministic command identity and TryPreAccept events.

## Bottom Line

Current specs are useful for protocol-level sanity and some known bug classes, but they are not yet close enough to implementation mechanics for high-confidence implementation bug discovery.
