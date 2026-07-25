# Confirmed Bug Report — sonic-dash-ha

## Summary
- Total findings reviewed: 7 (4 MC bugs + code review families consolidated)
- Reproduced (runtime): 3
- Confirmed (code audit only — code unimplemented): 3
- Inconclusive: 1

All reproduction tests are real Rust `#[test]` functions compiled and executed via `cargo test --package hamgrd` inside the Docker build container. No static analysis or Python scripts were used.

---

## Bug 1: HaSetActorState::new_actor_msg ignores `up` parameter
- **Source**: Code Review (CR-4)
- **Status**: REPRODUCED
- **Severity**: High
- **Location**: `crates/hamgrd/src/ha_actor_messages.rs:144-145`
- **Description**: `HaSetActorState::new_actor_msg` accepts a `up: bool` parameter but hardcodes `up: true` in the constructed struct. The parameter is completely ignored. This means any code attempting to send a "down" notification via this function (e.g., during HA set deletion) would silently produce an "up" notification instead.
- **Trigger scenario**: Any caller passes `up=false` (e.g., during deletion cleanup). The resulting `HaSetActorState` message contains `up: true`, misleading downstream ha-scope actors into believing the HA set is still active.
- **Developer intent**: The function signature clearly indicates `up` should be a variable. Compare with `VDpuActorState::new_actor_msg` (line 116-117) which correctly uses the `up` parameter. This inconsistency confirms it's an oversight.
- **Reproduction test**: `repro/test_bug1_new_actor_msg_ignores_up.rs` — Calls `new_actor_msg(false, ...)` and asserts the resulting message has `up == false`.
- **Reproduction result**: PASS (bug triggered)
- **Test command**: `cargo test --package hamgrd test_bug1_ha_set_actor_state_new_actor_msg_ignores_up_param -- --nocapture`
- **Test output**:
```
running 1 test
thread 'ha_actor_messages::test::test_bug1_ha_set_actor_state_new_actor_msg_ignores_up_param'
  panicked at crates/hamgrd/src/ha_actor_messages.rs:248:9:
BUG CONFIRMED: HaSetActorState::new_actor_msg(up=false, ...) produced up=true, expected false.
The `up` parameter is ignored; `true` is hardcoded at ha_actor_messages.rs:145.
test ha_actor_messages::test::test_bug1_ha_set_actor_state_new_actor_msg_ignores_up_param ... FAILED
test result: FAILED. 0 passed; 1 failed; 0 ignored; 0 measured; 23 filtered out; finished in 0.00s
```
- **Recommendation**: Change line 145 from `&Self { up: true, ha_set }` to `&Self { up, ha_set }`.

---

## Bug 2: HA set deletion does not notify registered ha-scope actors
- **Source**: MC (Bug 3 — Actor Lifecycle Orphan Actors, MC-2)
- **Status**: REPRODUCED
- **Severity**: High
- **Location**: `crates/hamgrd/src/actors/ha_set.rs:154-170` (`delete_dash_ha_set_table`), `ha_set.rs:621-643` (`do_cleanup`)
- **Description**: When an HA set is deleted, `delete_dash_ha_set_table` sends a Del message to the common bridge but does NOT send `HaSetActorState{up:false}` to registered ha-scope actors. The `do_cleanup` function similarly omits this notification. Compare with `update_dash_ha_set_table` (lines 127-152) which correctly notifies all registered ha-scope actors via `ActorRegistration::get_registered_actors()`. This asymmetry (SET notifies, DEL doesn't) creates orphaned ha-scope actors with stale state.
- **Trigger scenario**: SDN controller removes an HA set entry from `DASH_HA_SET_CONFIG_TABLE`. The ha-set actor sends cleanup messages to common bridge, VNet route, BFD sessions, and vDPU actors. But ha-scope actors that registered for `HaSetState` updates are never notified. They continue running with stale `HaSetActorState{up:true}`.
- **Developer intent**: Historical issues #111, #100, and PR #145 review all document this class of deletion notification gaps. The `HaScopeActor::do_cleanup` correctly unregisters from parents — the correct pattern exists but is inconsistently applied for downward (parent-to-child) notification.
- **Reproduction test**: `repro/test_bug2_ha_set_delete_no_notification.rs` — Full integration test. Sets up ha-set actor with registered ha-scope actor, deletes ha-set, expects `HaSetActorState{up:false}` notification. Uses `#[should_panic(expected = "Timed out")]`.
- **Reproduction result**: PASS (bug triggered — notification never arrives, timeout confirms)
- **Test command**: `cargo test --package hamgrd test_bug2_ha_set_delete_no_ha_scope_notification -- --nocapture`
- **Test output**:
```
running 1 test
Step 1 - Sent DASH_HA_SET_CONFIG_TABLE, expecting Ok, got Ok
Step 2 - Receiving VDPUStateRegister|haset0-0, got VDPUStateRegister|haset0-0
Step 3 - Receiving VDPUStateRegister|haset0-0, got VDPUStateRegister|haset0-0
Step 4 - Sent HaSetStateRegister|vdpu0:haset0-0, expecting Ok, got Ok
Step 5 - Sent DASH_HA_GLOBAL_CONFIG, expecting Ok, got Ok
Step 6 - Sent VDPUStateUpdate|vdpu0-0, expecting Ok, got Ok
Step 7 - Sent VDPUStateUpdate|vdpu1-0, expecting Ok, got Ok
Step 8 - Receiving haset0-0, got haset0-0
Step 9 - Receiving HaSetStateUpdate|haset0-0, got HaSetStateUpdate|haset0-0  [initial up=true — OK]
Step 10 - Receiving haset0-0, got haset0-0
Step 11 - Receiving haset0-0, got haset0-0
Step 12 - Receiving haset0-0, got haset0-0
Step 13 - Sent DASH_HA_SET_CONFIG_TABLE, expecting Ok, got Ok  [Del command]
Step 14 - Receiving haset0-0, got haset0-0  [DashHaSetTable Del — OK]
Step 15 - Receiving haset0-0, got haset0-0  [VnetRoute Del — OK]
Step 16 - Receiving haset0-0, got haset0-0  [BFD Del — OK]
Step 17 - Receiving haset0-0, got haset0-0  [BFD Del — OK]
Step 18 - Receiving VDPUStateRegister|haset0-0, got VDPUStateRegister|haset0-0  [vDPU unreg — OK]
Step 19 - Receiving VDPUStateRegister|haset0-0, got VDPUStateRegister|haset0-0  [vDPU unreg — OK]
Step 20 - Receiving HaSetStateUpdate|haset0-0, got Timeout  [BUG: ha-scope never notified]
thread '...' panicked at 'Timed out waiting for request'
test actors::ha_set::test::test_bug2_ha_set_delete_no_ha_scope_notification - should panic ... ok
test result: ok. 1 passed; 0 failed; finished in 5.02s
```
- **Recommendation**: In `do_cleanup`, send `HaSetActorState{up:false}` to all registered ha-scope actors (same pattern as `update_dash_ha_set_table`). Also fix Bug 1 first so the `up` parameter is actually used.

---

## Bug 3: DPU deletion does not notify registered vDPU actors
- **Source**: MC (Bug 3 — Actor Lifecycle Orphan Actors, MC-1)
- **Status**: REPRODUCED
- **Severity**: High
- **Location**: `crates/hamgrd/src/actors/dpu.rs:137-140` (`do_cleanup`), `dpu.rs:376-378` (remote DPU Del)
- **Description**: When a DPU is deleted, `do_cleanup` only calls `delete_reset_info(internal)` — it does NOT call `update_dpu_state()` to send `DPUStateUpdate` with `up=false` to registered vDPU actors. For remote DPU deletion, the handler just calls `context.stop()` without any notification. Registered vDPU actors continue running with stale DPU state (`up=true`), believing the DPU is alive. This stale state cascades up through vDPU → HA set → HA scope.
- **Trigger scenario**: DPU config entry removed from `CONFIG_DB/DPU` table. DPU actor cleans up its reset info and terminates. vDPU actors that registered for `DPUState` updates never learn the DPU is gone. They propagate stale state to HA set and HA scope actors.
- **Developer intent**: The existing `dpu_actor` test does not verify outgoing notifications after deletion — it only sends the Del and waits for termination. This gap in test coverage allowed the bug to persist.
- **Reproduction test**: `repro/test_bug3_dpu_delete_no_notification.rs` — Full integration test. Registers vDPU, brings DPU to up=true (pmon+bfd), deletes DPU, expects `DPUStateUpdate{up:false}`. Uses `#[should_panic(expected = "Timed out")]`.
- **Reproduction result**: PASS (bug triggered — notification never arrives)
- **Test command**: `cargo test --package hamgrd test_bug3_dpu_delete_no_vdpu_notification -- --nocapture`
- **Test output**:
```
running 1 test
Step 1 - Sent DPU_STATE, expecting Ok, got Ok
Step 2 - Sent DPU, expecting Ok, got Ok
Step 3 - Sent DASH_HA_GLOBAL_CONFIG, expecting Ok, got Ok
Step 4 - Receiving switch0_dpu0, got switch0_dpu0
Step 5 - Sent DPUStateRegister|vdpu/test-vdpu, expecting Ok, got Ok
Step 6 - Receiving DPUStateUpdate|switch0_dpu0, got DPUStateUpdate|switch0_dpu0  [initial state]
Step 7 - Sent DASH_BFD_PROBE_STATE, expecting Ok, got Ok
Step 8 - Receiving DPUStateUpdate|switch0_dpu0, got DPUStateUpdate|switch0_dpu0  [DPU up=true]
Step 9 - Sent DPU, expecting Ok, got Ok  [Del command]
Step 10 - Receiving DPUStateUpdate|switch0_dpu0, got Timeout  [BUG: vDPU never notified]
thread '...' panicked at 'Timed out waiting for request'
test actors::dpu::test::test_bug3_dpu_delete_no_vdpu_notification - should panic ... ok
test result: ok. 1 passed; 0 failed; finished in 5.02s
```
- **Recommendation**: In `do_cleanup`, call `update_dpu_state()` with appropriate state before deleting reset info. For remote DPU deletion, add cleanup logic before `context.stop()`.

---

## Bug 4: Cross-Vote Race — Dual Active (HLD Election Protocol)
- **Source**: MC (Bug 1)
- **Status**: CONFIRMED (code audit) — cannot reproduce, election protocol not yet implemented
- **Severity**: Critical (design-level)
- **Location**: HLD Section 7.3 (election algorithm), `ha_scope.rs:257-268` (TODO stubs), `ha_set.rs:346-358` (config-driven `preferred_vdpu_id`)
- **Description**: The HLD election algorithm has a TOCTOU vulnerability. RequestVote messages carry the sender's `desired_state` at send time, but the receiver evaluates it at receive time. If the SDN controller changes `desired_state` between these two points, both nodes independently conclude "I have DsActive but my peer doesn't" and both enter InitToActive, violating SingleDecisionMaker.
- **Why no reproduction**: Election protocol is entirely unimplemented — primary election is config-driven via `preferred_vdpu_id`. Peer state exchange is unimplemented (#77). No code path to trigger the race.
- **MC counterexample**: 11-step trace from Init to dual-Active (see bug-report.md Bug 1 for full trace).
- **Recommendation**: When implementing the election protocol: (1) increment term before sending RequestVote, (2) add a "Voting" state, (3) use current desired_state at evaluation time.

---

## Bug 5: DPU Health Race — Dual Standalone
- **Source**: MC (Bug 2)
- **Status**: CONFIRMED (code audit) — cannot reproduce, standalone transition not implemented
- **Severity**: Critical (design-level)
- **Location**: HLD Section 10.1, `dpu.rs:255-266`, `ha_scope.rs` (standalone logic absent)
- **Description**: EnterStandalone is a purely local decision based on local DPU health. With oscillating DPU health (peer down then own DPU down), both nodes can independently enter Standalone because there is no peer coordination. Peer state exchange not implemented (#77).
- **Why no reproduction**: Standalone transitions are not implemented in the HA state machine.
- **MC counterexample**: 8-step trace from Active/Standby to dual-Standalone (see bug-report.md Bug 2).
- **Recommendation**: Before entering Standalone, verify peer is NOT already in Standalone (requires #77). Consider Standalone election or hysteresis.

---

## Bug 6: Switchover + DPU Failure — Dual Decision Maker
- **Source**: MC (Bug 4)
- **Status**: CONFIRMED (code audit) — cannot reproduce, switchover not implemented
- **Severity**: High (design-level)
- **Location**: HLD Section 8.2, `ha_scope.rs:257-258` (TODO stub)
- **Description**: During planned switchover, if the peer's DPU fails while the switching node is in SwitchingToActive (a decision-making state), the active node enters Standalone. Both nodes are in DecisionMakerStates simultaneously, violating SingleDecisionMaker.
- **Why no reproduction**: Switchover is a TODO stub at `ha_scope.rs:257-258`.
- **MC counterexample**: 6-step trace from Active/Standby to dual decision maker (see bug-report.md Bug 4).
- **Recommendation**: Add DPU health pre-check before SwitchingToActive. Add timeout with rollback.

---

## Bug 7: Config-before-vDPU ordering dependency
- **Source**: Code Review (MC-3, Family 2)
- **Status**: INCONCLUSIVE — transient inconsistency, eventually self-resolves
- **Severity**: Medium
- **Location**: `ha_scope.rs:510-519`, `ha_scope.rs:536-581`
- **Description**: If DASH_HA_SCOPE_CONFIG arrives before vDPU state, `update_npu_ha_scope_state_ha_state` is a no-op (internal entry doesn't exist yet). When vDPU state later arrives, `handle_vdpu_state_update` calls `update_npu_ha_scope_state_base` but NOT `update_npu_ha_scope_state_ha_state`, leaving `local_target_asic_ha_state` and term fields unpopulated. These are only filled when DPU scope state arrives.
- **Why inconclusive**: The gap is transient. When DPU scope state arrives (via `handle_dpu_ha_scope_state_update`), `update_npu_ha_scope_state_ha_state` is called and the fields are populated. Whether this transient window causes real problems depends on SDN controller behavior.
- **Recommendation**: Have `handle_vdpu_state_update` also call `update_npu_ha_scope_state_ha_state` to reduce the transient gap.

---

## Cross-Reference: MC Findings vs Code Reality

| MC Finding | Code Status | Verdict |
|-----------|-------------|---------|
| Bug 1: Cross-Vote Race (MC-8, MC-9) | Election protocol unimplemented (TODO) | Design bug confirmed, cannot reproduce |
| Bug 2: DPU Health Race (MC-9) | Standalone transition unimplemented | Design bug confirmed, cannot reproduce |
| Bug 3: Orphan Actors (MC-1, MC-2) | Code bug present in all parent-child boundaries | **REPRODUCED** (Bugs 1, 2, 3 above) |
| Bug 4: Switchover + DPU Failure (MC-10) | Switchover unimplemented (TODO) | Design bug confirmed, cannot reproduce |
| MC-3: Config ordering | Ordering dependency exists, self-resolves | Inconclusive |
| MC-6/MC-7: Crash recovery | Two-phase commit gap in driver.rs | Not investigated (out of scope) |
