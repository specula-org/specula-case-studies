# MC-3 reproduction

## Test

`/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/repro/test_bugMC-3_delayed_peer_state.rs`

The test is linked into `hamgrd` only under `cfg(test)`. It uses the normal actor runtime, config messages, election, bulk sync, approval, public SWBus request/resend API, the real `ProducerBridge`, and DPU_APPL_DB. It does not write actor state directly or alter production behavior.

## Command

```text
timeout 8m env SWSS_COMMON_REPO=/users/Pial/dependencies/sonic-swss-common cargo test -p hamgrd delayed_old_peer_state_regresses_term_and_reaches_dpu -- --nocapture --test-threads=1
```

## Actual output

```text
running 1 test
test actors::ha_scope::test::bug_mc3_delayed_peer_state::delayed_old_peer_state_regresses_term_and_reaches_dpu ...
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

## Ladder and outcome

- Level 0 control: term 1 followed by term 2 leaves both peer and local target terms at 2.
- Level 1 trigger: the old acknowledgement is lost and the exact old request ID is resent after term 2 is committed. The incoming key is overwritten and both terms regress to 1.
- Level 2 and Level 3 were not used.
- The state remains at term 1 after the resend has been acknowledged and the queue is exhausted. There is no steady-state peer resynchronization. A subsequent normal admin update reads the regressed local target term and the real producer bridge commits `ha_term=1` to DPU_APPL_DB.
