# Specification Validation Changelog

## Round 1 - Trace Validation

All four implementation traces passed strong post-state replay; no specification or harness changes were required.

## Round 1 - Model Checking

The 30-minute `MC.cfg` BFS reached depth 15 with 713,521,851 generated states and 128,163,715 distinct states without an enabled-invariant violation; no specification or invariant changes were required.

## Bug Hunting

- [fix-spec] Liveness hunt configs: disabled symmetry in `MC_hunt_scenario1.cfg`, `MC_hunt_scenario2.cfg`, and `MC_hunt_scenario4.cfg` after TLC warned that symmetry is unsafe for temporal checking and failed to reconstruct a successor from its fingerprint. Bounds, actions, invariants, and properties are unchanged.
- [fix-spec] `ModelView`: included `faultCounters` in state equivalence. The prior projection merged states with different remaining fault budgets even though those budgets change future enabled actions, causing temporal successor-recovery failures and potentially pruning reachable executions (Case B).
- [bug] `scheduler_session_disconnect_handler` / restart: an abrupt process death after socket teardown but before `mlacp_peer_disconn_handler` permanently loses the ordinary failover-cleanup obligation. Restart reconstructs volatile state without replaying FDB/isolation/traffic cleanup, violating `MCWarmRecoveryTerminates` (Case C; final reproduction in `MC_hunt_scenario1_bfs_validated.out`).
- [bug] `mlacp_exchange_handler` resynchronization: a second `need_to_sync` request can replace the first outstanding request before its response arrives. Because both requests use request number zero and received Sync Data is not correlated, the first response is accepted as the second response, violating `MCSyncEnvelopeOrdering` (Case C; final reproduction in `MC_hunt_scenario2_bfs_validated.out`).
- [bug] `mlacp_portchannel_state_handler` traffic gating: if the one-shot traffic-disable request cannot reach `mclagsyncd`, a DOWN/UP flap leaves forwarding enabled while the peer has not applied isolation for the new transition. The failure is not retried or latched for the UP path, violating `MCCurrentIsolationBeforeTraffic` (Case C; final reproduction in `MC_hunt_scenario3_bfs_validated.out`).
- [fix-spec] `MCscheduler_csm_read_callback_DeterministicRecovery`: made body-retry exhaustion and remote-close EOF weakly fair while leaving a live peer's partial-header stall unfair. The prior abstraction allowed `BodyRetry` to stutter forever even though `scheduler.c:185-239` has a finite retry limit, producing a spurious Scenario 4 lasso (Case B; `MC_hunt_scenario4_bfs.out`, superseded).
- [fix-spec] Scheduler-gated peer/sidecar work: required `schedulerEnabled` for non-progress peer sends, syncd EOF handling, and syncd reconnect. The prior abstraction let a node blocked in the sole peer-read loop keep generating traffic and dispatch sidecar events, producing another spurious Scenario 4 lasso (Case B; `MC_hunt_scenario4_bfs_sound.out`, superseded).

## Round 2 - Trace Validation

All four implementation traces passed again after the MC state-equivalence fix; no regression occurred.

## Round 2 - Model Checking

The corrected 30-minute `MC.cfg` BFS reached depth 15 with 630,611,559 generated states and 139,257,533 distinct states without an enabled-invariant violation. No further specification or invariant changes were required; trace validation and model checking converged in Round 2.

## Round 3 - Trace Validation

After the Scenario 4 deterministic-recovery fidelity fix, all four implementation traces passed strong post-state replay again; no regression occurred.

## Round 3 - Model Checking

The corrected 30-minute `MC.cfg` BFS reached depth 16 with 609,011,093 generated states and 134,820,993 distinct states without an enabled-invariant violation. No further specification or invariant changes were required; the specification reconverged in Round 3.

## Round 4 - Trace Validation

After adding the missing single-scheduler guards, all four implementation traces passed strong post-state replay again; no regression occurred.

## Round 4 - Model Checking

The corrected 30-minute `MC.cfg` BFS reached depth 15 with 580,164,674 generated states and 128,912,090 distinct states without an enabled-invariant violation. No further specification or invariant changes were required; the specification reconverged in Round 4.

## Result

Validation converged in Round 4. Final bug hunting reproduced three Case C implementation bugs. Scenario 4 found no violation in a 30-minute BFS (depth 25; 16,570,839 generated and 4,530,241 distinct states) or the required 30-minute depth-100 simulation (863,655 traces; 12,771,082 checked states).
