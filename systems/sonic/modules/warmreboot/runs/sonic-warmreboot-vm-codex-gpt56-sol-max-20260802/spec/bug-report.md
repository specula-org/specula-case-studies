# Warmreboot Validation Bug Report

## Summary

- Scenarios tested: 6
- Bugs found: 6
- Configs run: `MC_hunt_scenario1.cfg`, `MC_hunt_scenario2.cfg`, `MC_hunt_scenario3.cfg`, `MC_hunt_scenario4.cfg`, `MC_hunt_scenario5.cfg`, `MC_hunt_scenario6.cfg`, and focused `MC_hunt_scenario6_flags.cfg`
- Trace validation: all 4 implementation traces pass the converged specification

The standard model repeatedly exposes the admission/ownership defect; focused hunting additionally found unsafe checkpointing after both failed and successful orchagent readiness paths, non-atomic VID/RID-map publication, premature fpmsyncd completion, and premature warm-flag clearing.

## Bug 1: Concurrent reboot attempts can overwrite ownership and erase a live epoch

### Scenario

Admission, cancellation, retry, and cleanup ownership across two concurrent reboot callers.

### Severity

High

### Violated invariant

`PhaseMonotonicity`

### Config

`MC.cfg`; focused reproduction in `MC_hunt_scenario1.cfg`

### Counterexample

`output/MC_hunt_scenario1_bfs.out` (13 states). A second variant is in `output/MC_round4_bfs.out` (12 states).

### Trace Summary

1. Two callers request a reboot and both pass the non-atomic warm-restart flag scan.
2. Caller 1 publishes epoch 1; caller 2 later publishes epoch 2 and becomes the modeled owner.
3. In the focused trace, caller 1's cleanup trap runs after cancellation and unconditionally clears caller 2's epoch-2 flags.
4. Caller 2 then enters irreversible work with its warm flag and epoch erased.
5. The standard-model variant needs no cleanup: caller 2 overwrites the global owner/epoch, then caller 1 enters irreversible work while caller 2 remains owner.

### Root Cause

`check_warm_restart_in_progress` performs independent Redis reads and has no lock, transaction, epoch token, or compare-and-set. Flag publication occurs later, so multiple processes can pass the scan before either publishes. The EXIT/signal trap calls `clear_boot`, whose cleanup is global and is not conditional on the caller still owning the active attempt.

### Affected Code

- `src/sonic-utilities/scripts/fast-reboot:978` — non-atomic in-progress scan.
- `src/sonic-utilities/scripts/fast-reboot:1095` — scan, trap installation, and flag publication are separate operations.
- `src/sonic-utilities/scripts/fast-reboot:418` — unscoped cleanup disables flags and moves dumps.
- `src/sonic-utilities/scripts/fast-reboot:1304` — irreversible boundary has no owner/epoch revalidation.

### Recommendation

Acquire ownership atomically with a monotonically increasing epoch, using a Redis transaction/Lua CAS or an equivalent process lock. Bind every flag and snapshot to that token, make cleanup conditional on an exact owner-and-epoch match, and revalidate ownership immediately before irreversible work. Ensure a handled signal cannot resume the old caller into later phases.

## Bug 2: Forced orchagent pause failure permits a non-quiescent checkpoint

### Scenario

Forced reboot after `orchagent_restart_check` failure with queued producer work.

### Severity

High

### Violated invariant

`CheckpointAfterQuiescence`

### Config

`MC_hunt_scenario2.cfg`

### Counterexample

`output/MC_hunt_scenario2_after_stop_order_bfs.out` (10 states).

### Trace Summary

1. An orch producer has queued and in-flight work.
2. `orchagent_restart_check` fails, but forced mode logs and ignores the failure.
3. The caller crosses the no-rollback boundary and successfully stops `swss`.
4. Redis SAVE runs after the service-stop loop, while the producer was never proven quiescent.
5. The resulting snapshot is saved with pending work and is invalid.

### Root Cause

`pause_orchagent` treats a failed readiness/freeze check as success when `FORCE=yes`; multi-ASIC execution sets `FORCE=yes` automatically after pause begins. The main sequence then proceeds to irreversible service shutdown and database backup without an independent producer fence or a durable negative participant status.

### Affected Code

- `src/sonic-utilities/scripts/fast-reboot:996` — failed restart check is ignored in forced mode.
- `src/sonic-utilities/scripts/fast-reboot:1289` — multi-ASIC execution forces continuation.
- `src/sonic-utilities/scripts/fast-reboot:1294` — pause completion is followed by irreversible work.
- `src/sonic-utilities/scripts/fast-reboot:1348` — services are stopped and backup follows.
- `src/sonic-utilities/scripts/centralize_database:40` — Redis SAVE does not verify producer quiescence.

### Recommendation

Do not treat an orchagent freeze failure as a successful readiness barrier. Abort before the irreversible boundary, or explicitly choose cold recovery while preserving enough state for recovery. If forced continuation is required, require an independent per-ASIC fence proving all producers are stopped and queues drained before SAVE.

## Bug 3: READY is published before orchagent completes its freeze fence

### Scenario

Successful orchagent readiness followed by post-reply drain, FDB mutation, pipeline flush, and heartbeat freeze.

### Severity

High

### Violated invariant

`CompleteSameEpochSnapshot`

### Config

`MC_hunt_scenario3.cfg`

### Counterexample

`output/MC_hunt_scenario3_fair_bfs.out` (18 states).

### Trace Summary

1. `warmRestartCheck` finds no pending orch tasks and publishes `READY`.
2. The restart-check client consumes that reply and the reboot script proceeds.
3. Orchagent's ring drain, FDB-learning changes, sairedis flush, and heartbeat freeze remain later operations.
4. The caller stops services, saves/copies the database, and selects the warm snapshot.
5. Startup consumes a same-epoch dump whose producer fence was incomplete, so the snapshot is present but invalid.

### Root Cause

The `READY` notification is emitted inside `warmRestartCheck` before control returns to the event-loop code that drains the ring and freezes orchagent. The caller treats receipt of `READY` as completion of the whole freeze barrier, but there is no second acknowledgement after the post-reply operations.

### Affected Code

- `src/sonic-swss/orchagent/orchdaemon.cpp:1185` — post-check drain and freeze run after `warmRestartCheck` returns.
- `src/sonic-swss/orchagent/orchdaemon.cpp:1217` — pipeline flush and heartbeat freeze are late steps.
- `src/sonic-swss/orchagent/orchdaemon.cpp:1384` — `restartCheckReply(..., "READY", ...)` is sent before those steps.
- `src/sonic-utilities/scripts/fast-reboot:1294` — the caller proceeds after consuming READY.

### Recommendation

Publish READY only after ring drain, FDB updates, pipeline flush, and the producer/heartbeat fence are complete. Alternatively introduce a second, epoch-correlated `FROZEN` acknowledgement and make the reboot coordinator wait for it on every ASIC before stopping services or checkpointing.

## Bug 4: VID/RID maps are exposed non-reciprocally during replacement

### Scenario

Identity reconciliation and publication of reciprocal VID-to-RID and RID-to-VID maps.

### Severity

High

### Violated invariant

`IdentityMapBijective`

### Config

`MC_hunt_scenario5.cfg`

### Counterexample

`output/MC_hunt_scenario5_bfs.out` (25 states).

### Trace Summary

1. Reconciliation selects a complete injective matching for three VID/RID pairs.
2. Hardware and ASIC_DB operations complete.
3. Publication deletes the entire `VIDTORID` hash first.
4. `RIDTOVID` still contains the previous mapping, so the externally stored maps are no longer reciprocal.
5. Subsequent deletes and per-pair writes are separate crash cuts as well.

### Root Cause

`RedisClient::setVidAndRidMap` replaces two authority hashes using independent `DEL` commands, followed by two independent `HSET` commands per pair. There is no transaction, generation marker, journal, or atomic pointer switch protecting readers or crash recovery from a partially published map.

### Affected Code

- `src/sonic-sairedis/syncd/Syncd.cpp:5978` — publishes the reconciled map.
- `src/sonic-sairedis/syncd/RedisClient.cpp:664` — map replacement routine.
- `src/sonic-sairedis/syncd/RedisClient.cpp:669` — separate hash deletions.
- `src/sonic-sairedis/syncd/RedisClient.cpp:672` — separate reciprocal pair writes.

### Recommendation

Publish both maps atomically, for example with a Redis transaction/Lua script, or build generation-scoped temporary hashes and atomically switch one version pointer. Persist the APPLY epoch/generation and validate reciprocity during restart before accepting warm recovery.

## Bug 5: fpmsyncd publishes RECONCILED before route output is flushed

### Scenario

Timeout-driven route reconciliation with buffered Redis pipeline output.

### Severity

High

### Violated invariant

`ReconciledImpliesOutputsPublished`

### Config

`MC_hunt_scenario6.cfg`

### Counterexample

`output/MC_hunt_scenario6_bfs.out` (7 states).

### Trace Summary

1. fpmsyncd restores cached routes and waits for end-of-input or timeout.
2. The warm-restart timer expires before explicit input completion.
3. Reconciliation derives route updates and places them in the Redis pipeline.
4. `WarmStartHelper::reconcile` sets component state to `RECONCILED`.
5. No output is durable yet; the explicit pipeline flush is a later statement.

### Root Cause

The timeout path calls `RouteSync::onWarmStartEnd`, which invokes `WarmStartHelper::reconcile`. That helper publishes `RECONCILED` after issuing table updates but before the caller executes `pipeline.flush()`, exposing terminal success ahead of durable output.

### Affected Code

- `src/sonic-swss/fpmsyncd/fpmsyncd.cpp:203` — timeout invokes reconciliation.
- `src/sonic-swss/fpmsyncd/fpmsyncd.cpp:214` — reconciliation precedes the explicit flush at line 218.
- `src/sonic-swss/fpmsyncd/routesync.cpp:3768` — delegates to the warm-start helper.
- `src/sonic-swss/warmrestart/warmRestartHelper.cpp:245` — writes are followed by `setState(RECONCILED)` at line 256.

### Recommendation

Make output durability part of the completion barrier: flush and confirm the Redis pipeline before publishing `RECONCILED`. Prefer a single API that performs reconciliation, flushes, and only then commits terminal state, so callers cannot reorder these operations.

## Bug 6: Warmboot finalizer clears flags after timeout with components incomplete

### Scenario

Bounded finalizer wait with incomplete components and no durable recovery output.

### Severity

High

### Violated invariant

`WarmFlagSafeToClear`

### Config

`MC_hunt_scenario6_flags.cfg` (isolated follow-up to `MC_hunt_scenario6.cfg`)

### Counterexample

`output/MC_hunt_scenario6_flags_bfs.out` (7 states).

### Trace Summary

1. A reboot attempt publishes warm and fast flags.
2. fpmsyncd reaches only `RESTORED`; orchagent remains `initial` and the attempt remains pending.
3. The finalizer's five-minute polling loop expires.
4. It logs the remaining components but returns normally.
5. Namespace/global finalization then disables warm/fast flags despite incomplete terminal states and outputs.

### Root Cause

`wait_for_components_to_reconcile` treats timeout as a log-only condition and provides no failing status to its caller. The script waits for its subprocesses and unconditionally calls `finalize_global`, whose finalization routines clear the warm/fast markers.

### Affected Code

- `files/image_config/warmboot-finalizer/finalize-warmboot.sh:237` — bounded wait logs but does not fail.
- `files/image_config/warmboot-finalizer/finalize-warmboot.sh:256` — incomplete component list is ignored.
- `files/image_config/warmboot-finalizer/finalize-warmboot.sh:165` — finalization clears warm state.
- `files/image_config/warmboot-finalizer/finalize-warmboot.sh:293` — global finalization proceeds after the waits.

### Recommendation

Fail closed on reconciliation timeout: preserve the warm/fast evidence, publish an explicit failed/degraded terminal state, and prevent global finalization. Clear flags only after every required namespace/global component reports terminal success and all required outputs are confirmed durable.

## Not Reproduced

| Scenario | Config | Checked properties | Result |
|---|---|---|---|
| Durable APPLY crash recovery | `MC_hunt_scenario4.cfg` | `InitBeforeApply`, `ApplyCommitAgreement`, `NoWarmFromDirtyApply`, `EventualRecoveryDecision` | No violation after the frame-condition fix; full graph completed with 96,798 generated / 28,130 distinct states, diameter 43. |

## Specification Corrections During Hunting

- Case B: constrained Redis SAVE to occur only after every modeled ASIC's swss stop was attempted, matching the source-ordered service loop.
- Case B: added weak fairness for all five model-checking transition families and removed symmetry from temporal hunt configs.
- Case A: repaired two conflicting APPLY frame conditions that changed `applyState` while also declaring it unchanged.
