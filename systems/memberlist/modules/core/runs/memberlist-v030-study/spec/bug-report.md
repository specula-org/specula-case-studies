# Bug Report — HashiCorp memberlist

## Summary

- Scenarios tested: 4
- Bugs found: 3
- Configs run: `MC_hunt_scenario1.cfg`, `MC_hunt_scenario2.cfg`, `MC_hunt_scenario3.cfg`, `MC_hunt_scenario4.cfg`
- Standard model-checking coverage: 59,299,257 states generated and 16,657,644 distinct states through depth 11 in the required 30-minute BFS run; the graph was not exhausted and no standard invariant failed.

## Bug 1: Higher terminal incarnation is discarded by an already-dead record

- **Scenario**: 1 — Terminal-State Ordering Forgets a Newer Incarnation
- **Severity**: High
- **Invariant violated**: `KnownIncarnationMonotonicity`
- **Config**: `MC_hunt_scenario1.cfg`
- **Counterexample**: 17 states, `spec/output/MC_hunt_scenario1_bfs.out`

### Trace Summary

1. `n2` learns `n1` at incarnation 1 through gossip and a state snapshot.
2. Failed probes at `n2` and `n3` start suspicions, and both suspicion timers expire.
3. `n2` first records `Dead(n1, 1)`.
4. `n3` gossips `Dead(n1, 2)` to `n2`.
5. On delivery, `n2` learns that the maximum terminal incarnation is 2, but its retained view stays at incarnation 1, violating monotonicity.

### Root Cause

`deadNode` accepts an incoming death unless its incarnation is strictly less than the stored one (`state.go:1285-1289`). It then detects that the record is already Dead or Left and returns (`state.go:1294-1297`) before the later assignment that would retain the incoming incarnation (`state.go:1320`). A subsequent `Alive(n1, 2)` can therefore pass the stale-incarnation check and resurrect a terminal identity whose higher terminal incarnation was already observed.

### Affected Code

- `state.go:1285`: accepts equal or higher terminal incarnations.
- `state.go:1294`: returns early for an already-terminal record.
- `state.go:1320`: updates the stored incarnation only after that early return.

### Recommendation

Before returning for an already-terminal record, retain a higher incoming incarnation and preserve the correct Dead/Left precedence. Add regression tests for both Dead and Left sequences such as `Alive(1) → Dead(1) → Dead(2) → Alive(2)`.

---

## Bug 2: Delayed pre-restart Alive claims ownership of the old address

- **Scenario**: 3 — Volatile Restart, Anti-Entropy, and Identity Reclaim
- **Severity**: High
- **Invariant violated**: `NoOldEpochOwnership`
- **Config**: `MC_hunt_scenario3.cfg`
- **Counterexample**: 6 states, `spec/output/MC_hunt_scenario3_bfs.out`

### Trace Summary

1. `n1` queues two epoch-1 `Alive(n1, 1, a1)` messages for `n2`.
2. `n1` crashes, losing its volatile membership state.
3. `n1` restarts as epoch 2 at address `a2`, again with incarnation 1.
4. A delayed epoch-1 Alive is delivered to `n2`, which has no prior record for `n1`.
5. `n2` accepts epoch 1/address `a1` as the current owner even though `n1` is already running as epoch 2/address `a2`.

### Root Cause

Startup constructs the local Alive record from a volatile incarnation counter (`memberlist.go:464-472`), and the wire record carries no persistent restart or identity epoch. When an observer has no record for the name, `aliveNode` creates one directly from the delayed packet (`state.go:1005-1038`). The existing incarnation and address conflict checks only protect an already-known record (`state.go:1039-1088`), so they cannot distinguish a packet from a retired process epoch. A packet already handed to the network can outlive the sender process and exercise this path.

### Affected Code

- `memberlist.go:464`: creates restart state using only a volatile incarnation.
- `net.go:191`: the transferred membership record has no restart epoch.
- `state.go:1005`: creates an unknown node from an unqualified Alive record.
- `state.go:1078`: applies incarnation ordering only after the record exists.

### Recommendation

Persist a monotonic incarnation across process restarts, or add a stable boot/identity epoch to membership messages and snapshots and reject retired epochs. Address ownership should not be committed until the receiver can order the sender's identity lifetime.

---

## Bug 3: Rejected join state leaks through the accepting initiator

- **Scenario**: 4 — Join State Escapes Before Mutual Admission
- **Severity**: Medium
- **Invariant violated**: `RejectedMergeIsolation`
- **Config**: `MC_hunt_scenario4.cfg`
- **Counterexample**: 8 states, `spec/output/MC_hunt_scenario4_bfs.out`

### Trace Summary

1. `n2` starts a join against `n1` and sends its local state.
2. `n1` sends its own state before making its admission decision.
3. `n2` reads and accepts `n1`'s state, so `n1` becomes visible at `n2`.
4. `n1` then rejects `n2` through responder-side validation.
5. The state accepted by `n2` is gossiped to uninvolved `n3`; `n3` now sees `n1` solely because of an exchange that `n1` rejected.

### Root Cause

The responder handles a push/pull by reading the initiator, sending local state, and only then calling `mergeRemoteState`, where protocol and merge-delegate validation can reject (`net.go:319-333`, `net.go:1303-1335`). The initiator independently reads that response and merges it (`state.go:673-685`) without learning the responder's later decision. Merging an Alive record queues a broadcast (`state.go:1127`) and makes the rejected exchange externally visible through normal gossip.

### Affected Code

- `net.go:319`: responder reads the remote join state.
- `net.go:325`: responder sends usable local state before validation.
- `net.go:330`: responder can reject only after sending.
- `state.go:677`: initiator receives and independently merges the response.
- `state.go:1127`: accepted state is queued for dissemination.

### Recommendation

Make admission explicit and mutually committed. Validate the remote join state before returning usable membership state, or use a two-phase exchange in which received state remains provisional and cannot be merged or gossiped until both endpoints acknowledge acceptance.

---

## Not Reproduced

| Scenario | Config | States Explored | Result |
|------------|--------|-----------------|--------|
| 2 — Suspicion Evidence Crosses Incarnation and Provenance Boundaries | `MC_hunt_scenario2.cfg` | BFS: 8,857 generated / 4,030 distinct, exhaustive to diameter 15. Simulation: at least 13,295,865 states / 1,184,953 traces at the final progress sample. | No violation after correcting the provenance invariant; the depth-100 randomized follow-up reached its 30-minute budget without a violation |

## Specification Adjustments During Hunting

- The original `ConfirmationProvenanceSoundness` treated a snapshot-created suspicion timer's initial `NoNode` root as an invalid confirmation. This was Case A: `pushNodeState` carries no accusation origin, and `mergeState` reconstructs the source locally. The invariant now permits `NoNode` only as the timer's initial root while still requiring every added confirmation to have a distinct real root. All four implementation traces still pass, and Scenario 2 then completed exhaustive BFS without a violation.
