# Confirmation Report — dash-ha

## Final Result

Reproduced bugs: 6 = 4 NEW + 2 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 1
Env-limited findings: 0
False positives: 0
Dropped: 0
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 7
Dispositions: 7 total = 6 reproduced + 0 env-limited + 1 masked + 0 false-positive + 0 needs-more-info + 0 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | MC-1 | REPRODUCED | yes |
| 2 | MC-2 | REPRODUCED | yes |
| 3 | MC-3 | REPRODUCED | yes |
| 4 | MC-4 | REPRODUCED | yes |
| 5 | MC-5 | REPRODUCED | yes |
| 6 | MC-6 | MASKED | no |
| 7 | MC-7 | REPRODUCED | yes |

## Entry 1: Late DPU acknowledgement regresses an Active scope's ASIC role

- **Finding ID**: MC-1
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/confirmation/MC-1/debate.md

- **Source**: MC
- **Novelty**: KNOWN (cite: https://github.com/sonic-net/sonic-dash-ha/issues/171; fix-status: unfixed)
- **Location**: crates/hamgrd/src/actors/ha_scope/npu.rs:645

## Description

The DPU-state handler unconditionally replaces `local_acked_asic_ha_state` and `local_acked_term` with every received notification, without checking the current target role, term, or write generation. It then broadcasts the regressed value to peers.

The supplied [counterexample](/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/spec/output/MC_hunt_scenario1_role_pair_postfix_bfs.out:37) is a real `LegalRolePair` violation. State 12 has Active and older SwitchingToActive writes outstanding; state 13 acknowledges Active first; state 14 accepts SwitchingToActive last while the control plane remains Active.

## Trigger scenario

The injected Level 2 precondition is reachable through this normal planned-switchover sequence:

```text
DASH_HA_SCOPE_CONFIG_TABLE: approve desired Active
→ emit SwitchingToActive(term 1)
→ peer reports SwitchingToStandby with ASIC role standby
→ local control plane enters Active
→ emit Active(term 2)
→ receive Active(term 2) DPU notification
→ receive older SwitchingToActive(term 1) notification
```

The final two deliveries correspond exactly to counterexample transitions 12→13 and 13→14. The model abstracts both writes at term 1; the implementation increments the final Active write to term 2.

## Developer intent

The official HA workflow orders SwitchingToActive before Active and treats the switching role as transient. [Upstream issue #171](https://github.com/sonic-net/sonic-dash-ha/issues/171) explicitly requires HamgrD to wait for the DPU/Orchagent transition acknowledgement before proceeding and remains open with no associated fix.

The recently merged [PR #193](https://github.com/sonic-net/sonic-dash-ha/pull/193) describes the ASIC acknowledgement as authoritative, but only adds peer-role transition gates; it does not serialize local writes or reject stale local acknowledgements.

## Reproduction result

The required reproduction is [test_bugMC-1_late_ack.rs](/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/repro/test_bugMC-1_late_ack.rs:150). It invokes the production DPU handler, passes its resulting update through the real peer handler, waits, and invokes the production heartbeat path.

Level 0 passed normally. Level 1 timing repetition passed 20/20 and could not supply the missing DPU notification. Level 2 produced:

```text
running 1 test
test actors::ha_scope::bug_mc1_late_ack::late_switching_to_active_ack_regresses_active_scope_and_reaches_peer ... MC1_LEVEL=2 counterexample_states=12->13->14
MC1_ACTIVE_ACK cp=HA_STATE_ACTIVE target_role=active target_term=2 ack_role=active ack_term=2
MC1_STALE_ACK_ACCEPTED cp=HA_STATE_ACTIVE target_role=active target_term=2 ack_role=switching_to_active ack_term=1
MC1_REAL_CONSUMER peer_state=HA_STATE_ACTIVE peer_acked_asic_ha_state=switching_to_active
MC1_PERSISTENCE heartbeat_cp=HA_STATE_ACTIVE heartbeat_ack=switching_to_active stored_ack_term=1
MC1_BUG_TRIGGERED LegalRolePair violated
ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 46 filtered out; finished in 1.15s
```

Checklist:

1. Did Level 0 or Level 1 alone trigger it? **no**. The baseline passed, and timing-only repetition passed 20/20.
2. Level 2 reachability: **yes**. The precondition is counterexample state 12, reached by the real API sequence above; transitions 12→13 and 13→14 deliver Active and then the older SwitchingToActive acknowledgement.
3. Real consumer: [`handle_ha_state_change`](/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/confirmation/MC-1/worktree/crates/hamgrd/src/actors/ha_scope/npu.rs:749) stores the wrong peer role at line 767. The test executes that handler. The later [`handle_peer_heartbeat`](/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/confirmation/MC-1/worktree/crates/hamgrd/src/actors/ha_scope/npu.rs:365) also republishes the stale value.
4. Permanent or masked: **permanent for the drained execution; not masked**. No periodic reconciliation, resend, loopback, term guard, or generation check repairs it. A later heartbeat still reports the stale role. Only a new external DPU notification or process rehydration could overwrite it, neither of which is guaranteed after the counterexample drains both writes.

## Recommendation

Serialize per-scope role transitions by waiting for the corresponding DPU acknowledgement before issuing the next role, or propagate a monotonic write generation end-to-end and reject older notifications. At minimum, reject acknowledgements whose role or term does not match the current target, and add the reproduced Active-then-stale-Switching ordering as a regression test.

---

## Entry 2: Logical HA scope state can redirect traffic before ASIC acknowledgement

- **Finding ID**: MC-2
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/confirmation/MC-2/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: crates/hamgrd/src/actors/ha_set.rs:537
- **Severity**: High

## Description

`CachedHaScopeState` discards the incoming ASIC-acknowledged role and term, while route selection treats a unique logical `Active` scope as immediately eligible. The counterexample reaches `MCHaSetComputeRouteFromReplay`, then records route term 2 while the selected owner remains acknowledged only for term 1.

The real route writer consequently committed a remote primary to APPL_DB even though the accepted state message reported `acked_asic_ha_state=dead`.

## Trigger scenario

1. Configure a switch-owned HA set with managed local and remote vDPUs.
2. Make the route prerequisites ready through normal configuration and VDPU updates.
3. Deliver a legitimate HA-scope message with logical state `Active`, target term `2`, and ASIC-acknowledged role `dead`.
4. `HaSetActor` drops the acknowledgement and term, selects the logical Active vDPU, and sends the route.
5. `ProducerBridge` commits `VNET_ROUTE_TUNNEL_TABLE` with the unacknowledged vDPU as primary.

The message is reachable because `NpuHaScopeActor` issues the Active-role request, commits logical Active, and broadcasts before processing the separate DPU acknowledgement.

## Developer intent

[PR #193](https://github.com/sonic-net/sonic-dash-ha/pull/193) identifies the ASIC-acknowledged role as authoritative when logical state can lead hardware. [PR #201](https://github.com/sonic-net/sonic-dash-ha/pull/201) requires control-plane and ASIC state to agree for role-sensitive transitions.

[PR #211](https://github.com/sonic-net/sonic-dash-ha/pull/211) recently fixed a related stale-Active-versus-Standalone ordering bug at the route selector, but it did not address acknowledged role, term, or pairing freshness. Searches of open issues/PRs, the 100 most recently updated closed issues and PRs, review discussions, and git history found no report of this exact route-eligibility omission.

## Reproduction result

Level 0 succeeded using normal swbus inputs, the real HA-set actor entry point, the real `ProducerBridge`, and APPL_DB. The host lacked `ProducerStateTable`’s SWSS Lua installation, so the same bridge used its supported SWSS `Table` adapter; no HA logic or route payload was changed.

Test: [test_bugMC-2_route_before_asic_ack.sh](/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/repro/test_bugMC-2_route_before_asic_ack.sh)

Command:

```console
cd /users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/confirmation/MC-2/worktree
timeout 12m ../../../repro/test_bugMC-2_route_before_asic_ack.sh
```

Actual output:

```text
running 1 test
Step 1 - Sent DASH_HA_SET_CONFIG_TABLE, expecting Ok, got Ok
Step 2 - Receiving VDPUStateRegister|haset0-0, got VDPUStateRegister|haset0-0
Step 3 - Receiving VDPUStateRegister|haset0-0, got VDPUStateRegister|haset0-0
Step 4 - Sent HaScopeStateUpdate|vdpu0-0:haset0-0, expecting Ok, got Ok
Step 5 - Sent DASH_HA_GLOBAL_CONFIG, expecting Ok, got Ok
Step 6 - Sent VDPUStateUpdate|vdpu0-0, expecting Ok, got Ok
Step 7 - Sent VDPUStateUpdate|vdpu1-0, expecting Ok, got Ok
Step 8 - Receiving haset0-0, got haset0-0
Step 9 - Receiving haset0-0, got haset0-0
Step 10 - Receiving haset0-0, got haset0-0
Step 11 - Sent HaScopeStateUpdate|vdpu1-0:haset0-0, expecting Ok, got Ok
Step 12 - Checking VNET_ROUTE_TUNNEL_TABLE/APPL_DB for key vnet0:3.2.0.0, Checking DB APPL_DB/VNET_ROUTE_TUNNEL_TABLE for key vnet0:3.2.0.0, found
check passed
Step 13 - Receiving haset0-0, got haset0-0
MC-2 BUG TRIGGERED
input logical_state=HA_STATE_ACTIVE logical_term=2 acked_asic_ha_state=dead
real consumer=ProducerBridge -> APPL_DB/VNET_ROUTE_TUNNEL_TABLE
observed route_key=vnet0:3.2.0.0 primary=10.0.1.0
expected route_key absent until acked_asic_ha_state=active and acked_term=2
Step 1 - Checking VNET_ROUTE_TUNNEL_TABLE/APPL_DB for key vnet0:3.2.0.0, Checking DB APPL_DB/VNET_ROUTE_TUNNEL_TABLE for key vnet0:3.2.0.0, found
check passed
persistence_check=route still installed without ASIC acknowledgement
Step 1 - Sent DASH_HA_SET_CONFIG_TABLE, expecting Ok, got Ok
Step 2 - Receiving haset0-0, got haset0-0
Step 3 - Checking VNET_ROUTE_TUNNEL_TABLE/APPL_DB for key vnet0:3.2.0.0, Checking DB APPL_DB/VNET_ROUTE_TUNNEL_TABLE for key vnet0:3.2.0.0, check passed
Step 4 - Receiving haset0-0, got haset0-0
Step 5 - Receiving haset0-0, got haset0-0
Step 6 - Receiving VDPUStateRegister|haset0-0, got VDPUStateRegister|haset0-0
Step 7 - Receiving VDPUStateRegister|haset0-0, got VDPUStateRegister|haset0-0
test actors::ha_set::mc2_repro::mc2_route_programmed_before_asic_ack ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 46 filtered out; finished in 0.36s
```

Checklist:

1. Did Level 0 or Level 1 alone trigger it? **yes** — Level 0, through normal actor messages and configuration without timing assistance.
2. Level 2/3 reachability requirement: **not applicable**; neither was used.
3. Real consumer/caller: `ProducerBridge` at `crates/swss-common-bridge/src/producer.rs:46-52`, which applied the wrong route to APPL_DB.
4. Permanent or masked: **persistent while the acknowledgement is absent or stale**. The idle check found the route still installed; no sync, resend, loopback, or consumer guard removed it. A future independent ASIC acknowledgement may make the route retrospectively consistent, but it neither prevents nor rolls back the already committed premature write. The output removes it only through explicit test cleanup.

## Recommendation

Carry acknowledged term and pairing epoch alongside the existing acknowledged role, retain them in `CachedHaScopeState`, and require logical ownership and hardware acknowledgement to agree for the same current term and pairing generation. Reject stale/replayed updates and preserve the prior safe route until that eligibility condition holds.

---

## Entry 3: Delayed old peer state regresses the accepted term

- **Finding ID**: MC-3
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/confirmation/MC-3/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: crates/hamgrd/src/actors/ha_scope/npu.rs:766

## Description

Confirmed. The TLC counterexample records a real `TermNonRegression` violation: term 2 is applied in State 5, then the delayed term‑1 request is applied in State 7 ([counterexample](/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/spec/output/MC_hunt_scenario2_replay_postfix_bfs.out:41)).

Distinct outgoing requests are retained and resent independently. On receipt, [incoming.rs](/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/confirmation/MC-3/worktree/crates/swbus-actor/src/state/incoming.rs:49) replaces the same logical key without checking request ordering. [npu.rs](/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/confirmation/MC-3/worktree/crates/hamgrd/src/actors/ha_scope/npu.rs:766) then unconditionally copies the stale peer term into both persisted `peer_term` and standby `local_target_term`.

Novelty is `NEW`: searches covered upstream open/closed issues, keyword-matched PRs, and recently merged/closed PRs through 2026-08-01. Adjacent PRs [#209](https://github.com/sonic-net/sonic-dash-ha/pull/209), [#210](https://github.com/sonic-net/sonic-dash-ha/pull/210), and [#211](https://github.com/sonic-net/sonic-dash-ha/pull/211) address different stale-state mechanisms. No prior report or fix for same-key HA-state replay was found, and tested upstream `master` remains affected.

## Trigger scenario

1. Normal config, election, bulk-sync, and approval calls reach stable Standby at term 1.
2. The peer’s term‑1 request is delivered, but its acknowledgement is lost.
3. A newer term‑2 request is delivered and acknowledged; the receiver commits term 2.
4. The retained term‑1 request is resent with its original request ID through the public SWBus resend API.
5. The receiver regresses both terms to 1.
6. A normal disabled-config update consumes the regressed term and writes `ha_term=1` to `DPU_APPL_DB`.

This is Level 1 and directly corresponds to counterexample States 4–7.

## Developer intent

The [SONiC HA primary-election design](https://github.com/sonic-net/SONiC/blob/master/doc/smart-switch/high-availability/smart-switch-ha-hld.md#73-primary-election) treats a larger term as representing more flow history and requires Standby to match Active’s term. Its [clean-launch sequence](https://github.com/sonic-net/SONiC/blob/master/doc/smart-switch/high-availability/smart-switch-ha-hld.md#811-clean-launch-on-both-sides) explicitly updates Standby’s term from Active’s state change. Regression is therefore contrary to protocol intent.

## Reproduction result

Executed [test_bugMC-3_delayed_peer_state.rs](/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/repro/test_bugMC-3_delayed_peer_state.rs):

```text
timeout 8m env SWSS_COMMON_REPO=/users/Pial/dependencies/sonic-swss-common cargo test -p hamgrd delayed_old_peer_state_regresses_term_and_reaches_dpu -- --nocapture --test-threads=1
```

Actual output:

```text
REACHABLE PRECONDITION: public config/election/bulk-sync/approval -> local_state=standby peer_term=1 local_target_term=1
LEVEL 1 FAULT: dropped_ack_for_old_request_id=1785575385549173104
LEVEL 0 CONTROL: in_order_terms=1->2 accepted_peer_term=2 local_target_term=2
LEVEL 1 TRIGGER: resent_old_request_id=1785575385549173104 after_new_request_id=1785575385549173105 peer_term=2->1 local_target_term=2->1
NO AUTO-REPAIR: after_500ms peer_term=1 local_target_term=1
Step 4 - Checking DASH_HA_SCOPE_TABLE/DPU_APPL_DB for key haset2-0, Checking DB DPU_APPL_DB/DASH_HA_SCOPE_TABLE for key haset2-0, found
check passed
BUG TRIGGERED: accepted_peer_term=2 replayed_peer_term=1 persisted_local_target_term=1 dpu_dash_ha_scope_term=1 expected_dpu_term=2
ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 46 filtered out; finished in 0.66s
```

## Recommendation

Add sender incarnation and monotonic sequence fields to HA-state messages. Maintain a per-sender/per-key receive watermark and reject stale or duplicate sequences before modifying either `Incoming` or actor state. Reset the watermark only for a verified new sender incarnation. Add acknowledgement-loss, reordering, duplicate, and sender-restart tests.

## Reproduction checklist

1. **yes** — Level 1 alone triggered it through normal actor/runtime, config, SWBus resend, producer-bridge, and database APIs; only acknowledgement loss and resend timing were assisted.
2. Not applicable: no Level 2 state injection or Level 3 source behavior patch was used. The public sequence also matches counterexample States 4–7.
3. The real consumer is `ProducerBridge` at `crates/swss-common-bridge/src/producer.rs:46-51`; it applied the wrong `ha_term=1` generated by `crates/hamgrd/src/actors/ha_scope/npu.rs:2333-2351`.
4. The regression is persistent under quiescence, not masked. Term 2 was already acknowledged and removed from resend state; the replayed term 1 was subsequently acknowledged, leaving nothing to restore term 2. There is no steady-state term reconciliation, and the wrong DPU write was applied.

---

## Entry 4: Former-peer message contaminates a new pairing

- **Finding ID**: MC-4
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/confirmation/MC-4/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: crates/hamgrd/src/actors/ha_scope/npu.rs:749

## Description

A valid `HaScopeActorState` emitted by the former peer can be delayed across re-pair and then accepted as the new relationship’s state. Source and pairing generation are not validated, so the actor persists foreign peer state, marks the relationship connected, and drives the state machine.

Evidence is recorded in [investigation.md](/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/confirmation/MC-4/investigation.md).

## Trigger scenario

1. Launch with peer `vdpu1`; local state reaches `Connecting`.
2. `vdpu1` creates a legitimate state message, delayed in transport.
3. Process an HA-set update replacing it with `vdpu3`.
4. Release the old message through the real SWBus API.
5. The actor applies term/state from `vdpu1`, transitions to `Connected`, and sends `vdpu3` a `VoteRequest`.

## Developer intent

[PR #157](https://github.com/sonic-net/sonic-dash-ha/pull/157) explicitly added in-flight re-pairing. Its review noted retained peer caches, but neither it nor [issue #100](https://github.com/sonic-net/sonic-dash-ha/issues/100) reports delayed former-peer message acceptance or missing source/epoch validation.

All 211 upstream issue/PR entries and the 100 most recently closed PRs were searched. No report of this exact mechanism was found.

## Reproduction result

Executed [test_bugMC-4_former_peer_repair.rs](/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/repro/test_bugMC-4_former_peer_repair.rs) through the real actor runtime, SWBus, state machine, and STATE_DB bridge.

Command:

```bash
timeout 10m env SWSS_COMMON_REPO=/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/confirmation/MC-4/build-deps/swss-common LIBCLANG_PATH=/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/confirmation/MC-4/build-deps/apt/root/usr/lib/x86_64-linux-gnu LD_LIBRARY_PATH=/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/confirmation/MC-4/build-deps/apt/root/usr/lib/x86_64-linux-gnu:/usr/local/lib PATH=/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/confirmation/MC-4/build-deps/apt/root/usr/bin:/users/Pial/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin cargo test -p hamgrd test_bugmc_4_former_peer_message_contaminates_repair -- --nocapture --test-threads=1
```

Actual output:

```text
running 1 test
test actors::ha_scope::test::npu_driven::mc4_repro::test_bugmc_4_former_peer_message_contaminates_repair ... Step 1 - Sent DASH_HA_SCOPE_CONFIG_TABLE, expecting Ok, got Ok
Step 2 - Receiving VDPUStateRegister|vdpu0-0:haset9-0, got VDPUStateRegister|vdpu0-0:haset9-0
Step 3 - Receiving HaSetStateRegister|vdpu0-0:haset9-0, got HaSetStateRegister|vdpu0-0:haset9-0
Step 4 - Receiving HaScopeStateUpdate|vdpu0-0:haset9-0, got HaScopeStateUpdate|vdpu0-0:haset9-0
Step 5 - Sent VDPUStateUpdate|vdpu0-0, expecting Ok, got Ok
Step 6 - Sent HaSetStateUpdate|haset9-0, expecting Ok, got Ok
Step 7 - Receiving PeerHeartbeat|vdpu0-0:haset9-0, got PeerHeartbeat|vdpu0-0:haset9-0
Step 8 - Receiving HaScopeStateUpdate|vdpu0-0:haset9-0, got HaScopeStateUpdate|vdpu0-0:haset9-0
Step 9 - Receiving HaScopeStateUpdate|vdpu0-0:haset9-0, got HaScopeStateUpdate|vdpu0-0:haset9-0
LEVEL 1 STAGED: request_id=1785575079494172838 source=vdpu1-0:haset9-0 state=HA_STATE_INITIALIZING_TO_STANDBY term=41 before re-pair
Step 1 - Sent HaSetStateUpdate|haset9-0, expecting Ok, got Ok
LEVEL 0 RESULT: orderly re-pair selected new_peer=vdpu3-0:haset9-0; local_state=HA_STATE_CONNECTING and no peer state was applied
LEVEL 1 RELEASED: old request delivered only after current peer became vdpu3-0:haset9-0
BUG TRIGGERED: former_peer=vdpu1-0:haset9-0 supplied peer_state=HA_STATE_INITIALIZING_TO_STANDBY peer_term=41 peer_acked_role=standby; current_peer=vdpu3-0:haset9-0 was advertised Connected and received VoteRequest
OBSERVED CONSUMER: NpuHaScopeActor::next_state persisted local_state=HA_STATE_CONNECTED in STATE_DB and send_vote_request_to_peer targeted vdpu3-0:haset9-0
ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 46 filtered out
```

Expected behavior was to reject the former-peer message, remain `Connecting`, and send no vote until `vdpu3` supplied valid current-generation state.

Checklist:

1. Did Level 0 or Level 1 alone trigger it? **yes** — Level 1 timing assistance alone triggered it; only transport release timing was controlled.
2. Level 2/3 sequence requirement: not applicable; neither state injection nor production-logic modification was used.
3. Real consumer: `NpuHaScopeActor::next_state` at `crates/hamgrd/src/actors/ha_scope/npu.rs:1777`, followed by `apply_pending_state_side_effects` at `:1447`. It persisted `Connected` in STATE_DB and emitted a `VoteRequest` to the new peer.
4. The state is persistent until external corrective input; no downstream mask repairs it. `check_peer_connection_and_retry` at `npu.rs:2068-2117` trusts contaminated `peer_connected == true` and performs no retry, identity validation, or cache reset. A later new-peer message may overwrite fields but does not undo the already-observed transition and vote.

## Recommendation

Add a monotonically increasing pairing epoch to peer protocol messages and validate both source `ServicePath`/actor ID and epoch before decoding or applying them. On re-pair, increment the epoch and clear connection status, peer-derived state/term/acked-role caches, stale peer destinations, retries, and pending protocol work. Add a regression test that releases a former-peer message after successful re-pair and asserts rejection.

---

## Entry 5: Restart duplicates a pending-operation UUID for one live DPU flag

- **Finding ID**: MC-5
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/confirmation/MC-5/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: crates/hamgrd/src/actors/ha_scope/dpu.rs:158

## Description

A restart preserves the pending-operation map in Redis but resets `dpu_ha_scope_state` to `None`. Rehydrating one still-asserted DPU flag therefore generates and appends a fresh UUID in [dpu.rs](/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/confirmation/MC-5/worktree/crates/hamgrd/src/actors/ha_scope/dpu.rs:158), while [base.rs](/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/confirmation/MC-5/worktree/crates/hamgrd/src/actors/ha_scope/base.rs:445) retains the original UUID.

The resulting public state contains two actionable `activate_role` identifiers for one DPU request. Sequentially approving them emitted two DPU activation commands.

## Trigger scenario

1. Start a DPU-owned HA scope through the normal Swbus actor interface.
2. Write one real DPU false→true `activate_role_pending` edge through `DPU_STATE_DB`.
3. Confirm one UUID appears in `STATE_DB/DASH_HA_SCOPE_STATE`.
4. Abort the actor without config-delete cleanup and start a fresh actor.
5. Let the production consumer bridge rehydrate the unchanged true DPU row.
6. Observe two distinct UUIDs; approve one, clear the DPU flag, then approve the remaining stale UUID.

This matches the counterexample suffix: `MCDpuHandlePendingOperation` → `MCCrash` → recovery → `MCDpuHandlePendingOperation`, violating `PendingOperationBijective`.

## Developer intent

The restart comment at `dpu.rs:158-161` expects an already-notified operation to cause no state change or controller action. The analogous NPU rehydration problem was explicitly identified as non-idempotent in [PR #159’s review](https://github.com/sonic-net/sonic-dash-ha/pull/159#discussion_r3164967547), and that NPU path now avoids recreating pending operations.

Upstream open/closed issues and recently merged/closed PRs were searched. PR #159 concerns a different NPU producer site; [PR #210](https://github.com/sonic-net/sonic-dash-ha/pull/210) concerns producer-bridge replay, and [issue #123](https://github.com/sonic-net/sonic-dash-ha/issues/123) concerns unrelated leftover DPU state. No report covered this DPU edge-cache/UUID-map mechanism at the affected site.

## Reproduction result

Level 0 test: [test_bugMC-5_restart_pending_uuid.rs](/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/repro/test_bugMC-5_restart_pending_uuid.rs)

The test uses production Redis tables, actor dispatch, consumer rehydration, and DPU producer endpoint. Its test-only module wiring does not change production logic.

Command:

```text
timeout 5m env SWSS_COMMON_REPO=/users/Pial/.cargo/git/checkouts/sonic-swss-common-f127700b9bf1a3a6/e67092c LIBRARY_PATH=/usr/local/lib LD_LIBRARY_PATH=/usr/local/lib cargo test -p hamgrd mc5_restart_duplicates_pending_uuid_and_reissues_dpu_action -- --nocapture --test-threads=1
```

Actual output:

```text
running 1 test
test actors::ha_scope::bug_mc5_restart_pending_uuid::mc5_restart_duplicates_pending_uuid_and_reissues_dpu_action ... LEVEL0 before_restart pending_ids=[e369a3b6-a55d-41e3-bc43-8d04d5e099aa] pending_types=[activate_role]
LEVEL0 after_restart live_dpu_pending_flags=1 pending_ids=[e369a3b6-a55d-41e3-bc43-8d04d5e099aa,f8a16f33-5533-43d3-b40e-7ada8586b675] pending_types=[activate_role,activate_role] unique_ids=2
LEVEL0 after_dpu_flag_clear_and_settle live_dpu_pending_flags=0 remaining_pending_ids=[f8a16f33-5533-43d3-b40e-7ada8586b675] remaining_types=[activate_role] auto_cleanup=false
BUG_TRIGGERED MC-5 one_false_to_true_edge=1 restart_count=1 distinct_pending_uuids=2 dpu_activate_commands=2
EXPECTED distinct_pending_uuids=1 dpu_activate_commands=1
ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 46 filtered out; finished in 0.45s

EXIT_CODE=0
```

Required checklist:

1. Did Level 0 or Level 1 alone trigger it? **yes — Level 0**.
2. Level 2/3 justification: **not applicable; neither state injection nor a production source patch was used**.
3. Real consumers: the SDN controller observes the notification row identified at `dpu.rs:99-100`; controller approvals are consumed at `dpu.rs:64-79`, and the DPU command path at `dpu.rs:216-273` emitted two activation commands.
4. Permanent or masked: **persistent until explicit external cleanup/approval, not automatically masked**. After the real DPU flag cleared and a settling interval elapsed, one stale UUID remained. Approving it emitted the second DPU command; no sync, loopback, resend, or guard removed it.

## Recommendation

Persist a DPU flag generation/processed marker, or reconcile each asserted flag against an existing unapproved operation of the same type during recovery and reuse its UUID. Add this crash-recovery sequence as a regression test, including flag completion and stale-ID cleanup.

---

## Entry 6: HA-set deletion leaves an applied child scope without its parent

- **Finding ID**: MC-6
- **Status**: MASKED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/confirmation/MC-6/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: crates/hamgrd/src/actors/ha_set.rs:1041

## Description

The counterexample maps to a reachable hamgrd lifecycle defect. Parent cleanup queues `DASH_HA_SET_TABLE Del` and terminates without invalidating or draining registered scopes; the surviving child retains `HaSetActorState` and can emit another scope `Set` referencing the deleted parent entry.

The claimed hardware orphan is currently contained: sairedis Meta tracks the scope’s HA-set OID reference, rejects parent removal with `SAI_STATUS_OBJECT_IN_USE`, and DashHaOrch retains and retries the delete.

## Trigger scenario

1. Create the child scope and referenced HA set through normal actor/table messages.
2. Deliver ordinary HA-set `up` then `down` state, producing an applied `standalone` child.
3. Delete only the parent HA-set configuration.
4. Observe the parent producer `Del` and parent actor termination with no child invalidation.
5. Send a normal child configuration update; the live child emits another scope `Set` using the cached parent.

This succeeded at Level 0 without sleeps, failpoints, state injection, or product-logic modification.

## Developer intent

[PR #102](https://github.com/sonic-net/sonic-dash-ha/pull/102) defined parent and child cleanup independently. [PR #205](https://github.com/sonic-net/sonic-dash-ha/pull/205) established that scopes must not be programmed before their parent and made cached `HaSetActorState` the ordering acknowledgement, but addressed creation ordering only; resetting the dying parent’s local flag does not invalidate an existing child cache.

Open/closed issues and recently merged/closed PRs were searched across `sonic-dash-ha`, `sonic-buildimage`, and `sonic-swss`. The closest reports concern creation ordering, state-table deletion deserialization, or downstream state updates—including [sonic-swss PR #4557](https://github.com/sonic-net/sonic-swss/pull/4557)—not this parent-cleanup/stale-child-cache mechanism. The detailed evidence is in [investigation.md](/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/confirmation/MC-6/investigation.md).

## Reproduction result

Primary Level 0 test: [test_bugMC-6_parent_delete_live_scope.rs](/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/repro/test_bugMC-6_parent_delete_live_scope.rs)

```text
$ timeout 300 env SWSS_COMMON_REPO=/users/Pial/dependencies/sonic-swss-common LD_LIBRARY_PATH=/users/Pial/dependencies/sonic-swss-common/common/.libs cargo test -q -p hamgrd parent_config_delete_leaves_npu_scope_using_cached_parent -- --nocapture

running 1 test
Step 1 - Sent DASH_HA_SCOPE_CONFIG_TABLE, expecting Ok, got Ok
Step 2 - Receiving VDPUStateRegister|vdpu0-0:haset0-0, got VDPUStateRegister|vdpu0-0:haset0-0
Step 3 - Sent VDPUStateUpdate|vdpu0-0, expecting Ok, got Ok
Step 1 - Sent DASH_HA_SET_CONFIG_TABLE, expecting Ok, got Ok
Step 2 - Receiving VDPUStateRegister|haset0-0, got VDPUStateRegister|haset0-0
Step 3 - Receiving VDPUStateRegister|haset0-0, got VDPUStateRegister|haset0-0
Step 4 - Sent DASH_HA_GLOBAL_CONFIG, expecting Ok, got Ok
Step 5 - Sent VDPUStateUpdate|vdpu0-0, expecting Ok, got Ok
Step 6 - Sent VDPUStateUpdate|vdpu1-0, expecting Ok, got Ok
Step 1 - Sent DASH_HA_SET_STATE_TABLE, expecting Ok, got Ok
Step 1 - Sent DASH_HA_SET_STATE_TABLE, expecting Ok, got Ok
MC-6 PRECONDITION: child emitted DASH_HA_SCOPE_TABLE Set role=standalone ha_set_id=haset0-0 version=1
Step 1 - Sent DASH_HA_SET_CONFIG_TABLE, expecting Ok, got Ok
Step 2 - Receiving VDPUStateRegister|haset0-0, got VDPUStateRegister|haset0-0
Step 3 - Receiving VDPUStateRegister|haset0-0, got VDPUStateRegister|haset0-0
MC-6 TRIGGER: parent emitted DASH_HA_SET_TABLE Del and its actor terminated
MC-6 OBSERVED: no child Del/invalidation followed parent termination
Step 1 - Sent DASH_HA_SCOPE_CONFIG_TABLE, expecting Ok, got Ok
MC-6 STALE CACHE: live child emitted another Set role=dead ha_set_id=haset0-0 version=2 after parent termination
.
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 46 filtered out; finished in 0.58s
```

The safeguard test [test_bugMC-6_meta_reference_guard.cpp](/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/repro/test_bugMC-6_meta_reference_guard.cpp) was compiled against current sairedis Meta and executed:

```text
Note: Google Test filter = MetaDashHaDependency.HaScopeBlocksHaSetRemoval
[==========] Running 1 test from 1 test suite.
[----------] Global test environment set-up.
[----------] 1 test from MetaDashHaDependency
[ RUN      ] MetaDashHaDependency.HaScopeBlocksHaSetRemoval
MC-6 MASK: HA_SET remove while HA_SCOPE exists returned SAI_STATUS_OBJECT_IN_USE (-17), parent refcount=1
[       OK ] MetaDashHaDependency.HaScopeBlocksHaSetRemoval (0 ms)
[----------] 1 test from MetaDashHaDependency (0 ms total)

[----------] Global test environment tear-down
[==========] 1 test from 1 test suite ran. (0 ms total)
[  PASSED  ] 1 test.
```

Checklist:

1. Did Level 0 or Level 1 alone trigger it? **yes — Level 0 alone**.
2. Level 2/3 reachability justification: **N/A; neither was used**.
3. `NpuHaScopeActor` consumes the stale parent at `ha_scope/npu.rs:1587` and emits the wrong post-parent scope update at `ha_scope/npu.rs:2310`. No consumer observes orphaned hardware: `DashHaOrch::removeHaSetEntry` at `sonic-swss/orchagent/dash/dashhaorch.cpp:370` receives the deletion attempt, but Meta rejects it.
4. The hamgrd child cache and actor/DB-plane divergence persist until an independent child lifecycle event. The hardware consequence is masked immediately by Meta’s reference guard; DashHaOrch retains and retries the parent deletion instead of removing the referenced hardware object.

## Recommendation

Before deleting an HA set, send an explicit parent-invalid/tombstone message to every registered scope and wait for each child to remove or quiesce its programming and acknowledge completion. Clear or generation-fence cached `HaSetActorState`, and issue the parent `Del` only after the child barrier completes. Add equivalent deletion/recreation coverage for both NPU- and DPU-driven scopes.

---

## Entry 7: Vote completion resets an in-progress switchover retry budget

- **Finding ID**: MC-7
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/confirmation/MC-7/debate.md

- **Source**: MC
- **Novelty**: KNOWN (cite: https://github.com/sonic-net/sonic-dash-ha/pull/145#discussion_r2854609406; fix-status: unfixed)
- **Location**: crates/hamgrd/src/actors/ha_scope/npu.rs:926

## Description

`NpuHaScopeActor` uses one `retry_count` for voting, switchover, and peer connection. A final vote response resets it at lines 926–929 even when it represents an active switchover retry, allowing retries beyond the switchover limit.

The prior PR review reported this same shared-counter mechanism at the same field. Git history confirms it remains unfixed.

## Trigger scenario

1. A standby enters `SwitchingToActive` through normal config and approval operations.
2. Its non-Active, reconnecting peer rejects the switchover SYN with a valid RST.
3. The peer then sends its normal primary-election `VoteRequest`.
4. The final `BecomeStandby` vote response resets the switchover count.
5. Three further valid RSTs cause a fourth retry SYN. Without the vote reset, rejection four would produce `SwitchoverFailed` and transition to Standby.

This matches the TLC actions `MCNpuHandleSwitchoverRst` followed by `MCNpuHandleVoteRequestFinal`.

## Developer intent

The [SmartSwitch HA HLD](https://github.com/sonic-net/SONiC/blob/master/doc/smart-switch/high-availability/smart-switch-ha-hld.md#73-primary-election) says retry counts prevent indefinite retries, while its [planned-switchover workflow](https://github.com/sonic-net/SONiC/blob/master/doc/smart-switch/high-availability/smart-switch-ha-hld.md#821-workflow) says rejection returns the initiator to Standby for a later operation.

PR #145 introduced all three shared uses. Its review explicitly recommended separate counters for independent workflows; no later commit changes `retry_count`.

## Reproduction result

Executable test: [test_bugMC-7_vote_resets_switchover_budget.sh](/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/repro/test_bugMC-7_vote_resets_switchover_budget.sh)

Command:

```console
timeout 10m /users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/repro/test_bugMC-7_vote_resets_switchover_budget.sh
```

Level 0 used production 30-second delays. It reached the first retry, but the test dependency’s Redis fixture has a fixed 15-second lifetime and terminated before the complete sequence:

```text
Step 2 - Receiving SwitchoverRequest|vdpu0-0:haset3-0, got SwitchoverRequest|vdpu0-0:haset3-0
RedisPipeline::pop, err=1: errstr=Broken pipe
Step 3 - Sent VoteRequest|vdpu1-0:haset3-0, expecting Ok, got Timeout
test result: FAILED. 0 passed; 1 failed; finished in 71.05s
```

Level 1 shortened only `RETRY_INTERVAL` from 30 seconds to 1 second. All actor logic, public config operations, SWBUS validation, counter limits, and state transitions remained unchanged:

```text
Level 1: full ActorRuntime and normal SWBUS operations; retry delay only is 30s -> 1s
Step 1 - Sent SwitchoverRequest|vdpu1-0:haset3-0, expecting Ok, got Ok
Step 2 - Receiving SwitchoverRequest|vdpu0-0:haset3-0, got SwitchoverRequest|vdpu0-0:haset3-0
Step 3 - Sent VoteRequest|vdpu1-0:haset3-0, expecting Ok, got Ok
Step 4 - Receiving VoteReply|vdpu0-0:haset3-0, got VoteReply|vdpu0-0:haset3-0
Step 5 - Sent SwitchoverRequest|vdpu1-0:haset3-0, expecting Ok, got Ok
Step 6 - Receiving SwitchoverRequest|vdpu0-0:haset3-0, got SwitchoverRequest|vdpu0-0:haset3-0
Step 7 - Sent SwitchoverRequest|vdpu1-0:haset3-0, expecting Ok, got Ok
Step 8 - Receiving SwitchoverRequest|vdpu0-0:haset3-0, got SwitchoverRequest|vdpu0-0:haset3-0
Step 9 - Sent SwitchoverRequest|vdpu1-0:haset3-0, expecting Ok, got Ok
Step 10 - Receiving SwitchoverRequest|vdpu0-0:haset3-0, got SwitchoverRequest|vdpu0-0:haset3-0
MC-7 TRIGGERED level=1
valid_switchover_rejections=4 retry_limit=3
observed_extra_wire_retry=SwitchoverRequest(Syn)#4
observed_local_ha_state=HA_STATE_SWITCHING_TO_ACTIVE
observed_switchover_state=in_progress
expected_after_rejection_4=Standby/failed and no Syn#4
real_consumers=peer HA scope plus NpuDashHaScopeState/upstream service
test result: ok. 1 passed; 0 failed; finished in 8.05s
```

Checklist:

1. Did Level 0 or Level 1 alone trigger it? **yes — Level 1**, using normal operations with timing assistance only.
2. Level 2/3 reachability justification: **not applicable; neither was used**.
3. Real consumers: the remote peer’s `handle_switchover_request` at `npu.rs:986` receives the excess SYN; locally, `next_state` at `npu.rs:1901` misses the expected failure transition, leaving the real Redis state `in_progress`.
4. Permanence/masking: the `in_progress` state may resolve on a later fifth RST if no other reset occurs. However, no mechanism masks the demonstrated harm: the fourth SYN has already reached the peer and adds a production 30-second interval beyond the configured budget. Later resolution cannot undo that wire action or delay.

## Recommendation

Use separate counters owned by connection, voting, and each switchover operation ID. Validate RST/FIN messages against the current switchover ID/state, reset only the owning workflow, and add this actor-runtime interleaving as a regression test.

---
