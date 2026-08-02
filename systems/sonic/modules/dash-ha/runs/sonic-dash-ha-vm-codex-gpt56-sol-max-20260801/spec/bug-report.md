# Bug Report — dash-ha

## Summary

- Scenarios tested: 7
- Bugs found: 7 distinct implementation defects
- Configs run: `MC_hunt_scenario1_pipeline.cfg`, `MC_hunt_scenario1_role_pair.cfg`, `MC_hunt_scenario2_replay.cfg`, `MC_hunt_scenario3_repair.cfg`, `MC_hunt_scenario4_recovery.cfg`, `MC_hunt_scenario5_lifecycle.cfg`, `MC_hunt_scenario6_route.cfg`, `MC_hunt_scenario7_retry.cfg`
- Severity: 6 High, 1 Medium
- Classification: all reported findings are Case C (source-code defects)
- Search method: bounded breadth-first model checking on the final trace-converged model
- Simulation follow-up: not required because every focused BFS run produced a counterexample

The pipeline and route configurations independently reproduced the same routing defect, so they are reported as one finding. All counterexamples below were reproduced after the last specification correction and after the final round of implementation-trace validation and standard invariant checking.

## Bug 1: Late DPU acknowledgement regresses an Active scope's ASIC role

- **Scenario**: Asynchronous role-write acknowledgements during planned switchover
- **Severity**: High
- **Invariant violated**: `LegalRolePair`
- **Config**: `MC_hunt_scenario1_role_pair.cfg`
- **Counterexample**: 14 states — `output/MC_hunt_scenario1_role_pair_postfix_bfs.out`

### Trace Summary

1. Node `n2` receives and caches peer state `SwitchingToStandby` with acknowledged role `Standby`.
2. `n2` advances from `Standby` to `SwitchingToActive` and queues both the transitional DPU role write and a switchover request.
3. The transitional `SwitchingToActive` write reaches the DPU pipeline.
4. The cached peer acknowledgement permits `n2` to advance to `Active`, which queues a newer `Active` role write.
5. The newer `Active` DPU acknowledgement arrives first, so control-plane and acknowledged ASIC roles agree on `Active`.
6. The older `SwitchingToActive` acknowledgement arrives afterward and blindly overwrites the acknowledged role. The control plane remains `Active`, with no matching `Active` transition still pending, violating `LegalRolePair`.

### Root Cause

The DPU-state handler copies every observed role and term into `local_acked_asic_ha_state` and `local_acked_term` without correlating the update to the role write that caused it. Multiple role writes can be outstanding during a state transition, but neither a per-scope write generation nor the currently expected role is checked before accepting an acknowledgement. A delayed older observation can therefore regress acknowledged hardware state after a newer write has completed.

### Affected Code

- `crates/hamgrd/src/actors/ha_scope/npu.rs:623-652` — accepts and persists each DPU role/term update without freshness correlation.
- `crates/hamgrd/src/actors/ha_scope/npu.rs:1510-1524` — writes the final `Active` role.
- `crates/hamgrd/src/actors/ha_scope/npu.rs:1543-1560` — writes transitional switchover roles asynchronously.
- `crates/swss-common-bridge/src/producer.rs:28-70` — producer path decouples issued writes from later observations.

### Recommendation

Associate every DPU role write with a monotonic per-scope generation and expected role, and accept an acknowledgement only if it matches the latest outstanding generation. If the DPU interface cannot carry that generation, serialize role transitions until the prior role is acknowledged and reject observations that do not match the current desired transition.

---

## Bug 2: Logical HA scope state can redirect traffic before ASIC acknowledgement

- **Scenario**: Route selection from replayed logical peer state
- **Severity**: High
- **Invariant violated**: `RouteMatchesAckedOwner`
- **Config**: `MC_hunt_scenario6_route.cfg` (canonical); independently reproduced by `MC_hunt_scenario1_pipeline.cfg`
- **Counterexample**: 6 states — `output/MC_hunt_scenario6_route_postfix_bfs.out`

### Trace Summary

1. Node `n1` receives peer generation/term 2 advertising logical state `Active`, while the same message reports acknowledged ASIC role `Dead`.
2. The HA-scope handler caches the logical peer state and term.
3. Route replay selects `n1` as the active route candidate from that logical state.
4. The producer applies the term-2 route to `n1`, although `n1`'s acknowledged ASIC role/term does not establish it as an eligible traffic owner, violating `RouteMatchesAckedOwner`.

The pipeline configuration reaches the same bad state through the broader parent/scope producer pipeline, independently confirming the root cause.

### Root Cause

`HaSetActor` route selection consumes a cache containing the HA scope's logical `new_state` and vDPU identifiers, but not the scope's acknowledged ASIC role, acknowledged term, or pairing freshness. It treats logical `Active`/`Standalone` as sufficient to write the VNET route. The route can therefore move ahead of hardware acknowledgement or be driven by a stale logical update.

### Affected Code

- `crates/hamgrd/src/actors/ha_set.rs:74-78` — cached scope state omits acknowledged role and term.
- `crates/hamgrd/src/actors/ha_set.rs:537-552` — updates the reduced cache from scope-state messages.
- `crates/hamgrd/src/actors/ha_set.rs:601-672` — chooses a route owner from logical `Active`/`Standalone` state.
- `crates/hamgrd/src/actors/ha_set.rs:996-1029` — emits the VNET route update from that choice.

### Recommendation

Carry acknowledged ASIC role, acknowledged term, and pairing epoch into the HA-set cache. Select a route owner only when the logical state and hardware acknowledgement agree for the same current term and pairing epoch; otherwise retain or withdraw the existing route until eligibility is confirmed.

---

## Bug 3: Delayed old peer state regresses the accepted term

- **Scenario**: Reordered at-least-once HA-scope state delivery
- **Severity**: High
- **Invariant violated**: `TermNonRegression`
- **Config**: `MC_hunt_scenario2_replay.cfg`
- **Counterexample**: 7 states — `output/MC_hunt_scenario2_replay_postfix_bfs.out`

### Trace Summary

1. Two distinct HA-scope state requests for the same logical key are retained: generation/term 1 and a newer generation/term 2.
2. The generation-2 request is delivered and handled first, advancing the peer cache and accepted term to 2.
3. The delayed generation-1 request is then delivered under the same key.
4. The incoming table and HA-scope handler overwrite the newer peer state and term with generation/term 1, violating `TermNonRegression`.

### Root Cause

The outgoing transport retains independently identified messages for retry, while the incoming table uses the actor-message key as last-writer-wins storage. `handle_ha_state_change` then unconditionally copies the decoded peer state and term. There is no sender incarnation, monotonic message generation, or `(term, sequence)` freshness check at either overwrite point.

### Affected Code

- `crates/swbus-actor/src/state/outgoing.rs:37-50,97-140,211-275` — queues, retains, and retries independently identified requests.
- `crates/swbus-actor/src/state/incoming.rs:49-72,147-154` — overwrites the same logical key on each arrival.
- `crates/hamgrd/src/actors/ha_scope/npu.rs:749-793` — blindly assigns peer state and term; standby can also copy the regressed peer term locally.

### Recommendation

Add a monotonic sender incarnation and per-scope sequence number to HA-scope state messages. Reject updates older than the last accepted `(incarnation, term, sequence)` before modifying the incoming cache or actor state, and persist enough of that watermark to remain safe across restart.

---

## Bug 4: Former-peer message contaminates a new pairing

- **Scenario**: Peer re-pair while an old peer message is pending
- **Severity**: High
- **Invariant violated**: `CurrentPeerIsolation`
- **Config**: `MC_hunt_scenario3_repair.cfg`
- **Counterexample**: 6 states — `output/MC_hunt_scenario3_repair_postfix_bfs.out`

### Trace Summary

1. Two messages from `peer-a` are sent toward `n1`; one reaches the incoming table but has not yet been applied by the HA-scope actor.
2. `n1` is re-paired from `peer-a` to `peer-b`, advancing the modeled pair epoch.
3. The already-delivered `peer-a` message is subsequently decoded and applied.
4. `n1` marks the peer connected and installs cache state sourced from `peer-a` even though its current peer is `peer-b`, violating `CurrentPeerIsolation`.

### Root Cause

Re-pairing replaces the peer identity/service path but does not invalidate pending incoming messages or attach a pairing epoch to them. Dispatch is by logical message key, and the HA-scope decoder/handler does not validate the incoming entry's source against the current peer before changing control state.

### Affected Code

- `crates/hamgrd/src/actors/ha_scope/npu.rs:525-586` — replaces peer configuration without purging old peer protocol state/messages.
- `crates/hamgrd/src/actors/ha_scope/npu.rs:93-235` — dispatches HA-scope messages by logical key without a current-source guard.
- `crates/hamgrd/src/actors/ha_scope/npu.rs:749-793` — applies the decoded message and marks the peer connected.
- `crates/hamgrd/src/actors/ha_scope/base.rs:125-136` — decodes message data without validating source identity.

### Recommendation

Include a pairing epoch/incarnation in peer messages and validate both source peer and epoch before dispatch or cache mutation. On re-pair, clear peer-derived state, connection status, retry state, and pending incoming/outgoing work addressed to the former peer.

---

## Bug 5: Restart duplicates a pending-operation UUID for one live DPU flag

- **Scenario**: Crash/recovery while a DPU pending flag remains asserted
- **Severity**: High
- **Invariant violated**: `PendingOperationBijective`
- **Config**: `MC_hunt_scenario4_recovery.cfg`
- **Counterexample**: 6 states — `output/MC_hunt_scenario4_recovery_postfix_bfs.out`

### Trace Summary

1. `n1` observes a false-to-true DPU pending flag and allocates operation UUID 1.
2. The operation is persisted and the in-memory DPU-state edge cache records the asserted flag.
3. `hamgrd` crashes. The durable pending-operation map and live DPU flag survive, but the in-memory edge cache is lost.
4. After recovery, the still-asserted flag is treated as a new edge and UUID 2 is allocated.
5. Both UUID 1 and UUID 2 remain pending for the same single DPU request, violating `PendingOperationBijective`.

### Root Cause

Restart intentionally treats all currently asserted flags as new because the old DPU state is volatile. Each apparent edge receives a fresh UUID, while the persisted pending-operation map is loaded and extended rather than reconciled by operation identity. The implementation therefore cannot distinguish an old live flag from a genuinely new request after restart.

### Affected Code

- `crates/hamgrd/src/actors/ha_scope/dpu.rs:158-182` — treats asserted flags as new after restart and generates fresh UUIDs.
- `crates/hamgrd/src/actors/ha_scope/base.rs:445-493` — loads the persisted map and inserts new UUID entries without deduplicating by live DPU operation.

### Recommendation

Give each DPU pending request a durable generation/token and reuse the existing pending UUID when that same token remains asserted after restart. If the DPU cannot provide a token, persist the last-observed flag state together with the outstanding operation type and reconcile idempotently instead of appending a fresh UUID.

---

## Bug 6: HA-set deletion leaves an applied child scope without its parent

- **Scenario**: Parent HA-set cleanup while a child HA scope remains applied
- **Severity**: High
- **Invariant violated**: `ParentBeforeScope`
- **Config**: `MC_hunt_scenario5_lifecycle.cfg`
- **Counterexample**: 6 states — `output/MC_hunt_scenario5_lifecycle_postfix_bfs.out`

### Trace Summary

1. The initial state has both the parent HA set and child HA scope applied.
2. The configuration for `n1` is deleted.
3. HA-set cleanup marks the parent deleting and queues its deletion, but emits no child-scope invalidation or acknowledgement barrier.
4. The producer applies the parent delete. The parent is absent while the child scope remains applied and still retains its old parent cache epoch, violating `ParentBeforeScope`.

### Root Cause

The HA-set cleanup path deletes parent-owned resources and unregisters the parent actor without first invalidating or draining dependent HA-scope state. Child logic trusts its cached parent state, so asynchronous parent deletion can complete while a child remains programmed.

### Affected Code

- `crates/hamgrd/src/actors/ha_set.rs:1041-1067` — deletes parent resources and unregisters without a child invalidation barrier.
- `crates/hamgrd/src/actors/ha_scope/npu.rs:1587-1596` — gates child behavior on cached HA-set actor state.
- `crates/hamgrd/src/actors/ha_scope/npu.rs:2310-2351` — continues scope/table updates from cached parent existence.

### Recommendation

Introduce an explicit parent tombstone/invalidation protocol. Revoke and acknowledge all dependent child scope programming before deleting the HA set, prevent new child writes once deletion begins, and clear cached parent epochs and registrations only after child cleanup completes.

---

## Bug 7: Vote completion resets an in-progress switchover retry budget

- **Scenario**: Interleaved vote and switchover retries on one HA scope
- **Severity**: Medium
- **Invariant violated**: `RetryIsolation`
- **Config**: `MC_hunt_scenario7_retry.cfg`
- **Counterexample**: 3 states — `output/MC_hunt_scenario7_retry_postfix_bfs.out`

### Trace Summary

1. A switchover `RST` increments the shared retry counter and records one switchover retry.
2. An unrelated vote request reaches a final result and resets the shared counter to zero.
3. The switchover operation still has one logical retry consumed, but its enforcement counter has been reset by another protocol, violating `RetryIsolation`.

### Root Cause

Vote, switchover, and connection workflows share the actor-wide `retry_count`. Each workflow increments and resets it according to its own lifecycle, so an event from one protocol can erase or consume another protocol's retry budget.

### Affected Code

- `crates/hamgrd/src/actors/ha_scope/npu.rs:863-948` — vote handling increments and resets `retry_count`.
- `crates/hamgrd/src/actors/ha_scope/npu.rs:986-1028` — switchover handling uses and resets the same counter.
- `crates/hamgrd/src/actors/ha_scope/npu.rs:2063-2117` — connection retry logic also shares the counter.

### Recommendation

Use separate retry counters keyed by protocol and operation identifier, for example `(Vote, election_id)`, `(Switchover, switchover_id)`, and `(Connect, peer_incarnation)`. Only the workflow that owns a counter should reset it.

## Not Reproduced

None. Every supplied focused configuration produced a source-confirmed violation on the final converged model.

| Scenario | Config | States Explored | Result |
|---|---|---:|---|
| — | — | — | No non-reproduced scenarios; route and pipeline were deduplicated as one root cause. |

## Spec Fixes During Hunting

Four pre-report counterexamples were classified and corrected before the final bug search:

1. **Case A — `LegalRolePair`:** allowed only the implementation's visible queued/in-flight/durable asynchronous role-transition window.
2. **Case B — `RoleForState` / `RequiredActions`:** corrected `SwitchingToStandby` and `InitializingToStandby` to program the `Standby` role, matching source.
3. **Case A — `ParentBeforeScope`:** changed over-strong epoch equality to the intended parent-at-least-as-new implication.
4. **Case B — `DpuHandlePendingOperation`:** limited live operation creation to a false-to-true flag edge, while retaining the restart replay behavior that exposes Bug 5.

After the last action-level correction, all four implementation traces passed, and the standard `MC.cfg` BFS ran for 30 minutes without an invariant violation (65,923,597 generated / 19,407,952 distinct states; diameter 7).
