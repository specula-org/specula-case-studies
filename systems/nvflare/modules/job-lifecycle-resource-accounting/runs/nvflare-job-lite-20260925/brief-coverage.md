# Brief coverage audit (spec-generation Phase 2.5)

Filled from the actual cfg files and logs under `models/lifecycle` (L) and `models/resources` (R).

## Scenarios (brief §2)

| Scenario | Model | Targeting configs (actual files) | Result |
|---|---|---|---|
| S1 abort vs dispatch | L | MC_hunt_abort.cfg, MC_hunt_abort_AbortedNotLaunched.cfg, MC_hunt_abort_AbortFromDispatchedHonored.cfg | violations (MC-1) |
| S2 job-store exceptions escaping JobRunner | L | MC_hunt_delete.cfg, MC_hunt_delete_noscan.cfg, MC_hunt_delete_noscan_nostat1.cfg | violations (MC-2 a/b/c) |
| S3 reservation/allocation ownership | R | MC.cfg (ownership), MC_hunt_ReservationTracked.cfg, MC_hunt_NoRejectionByLeftoverReservation.cfg, MC_hunt_leftover_noCT*.cfg | ownership clean; leftover diagnostics fire |
| S4 completion / fail_run / start overlap | L | MC.cfg (baseline), MC_hunt_overlap.cfg, MC_hunt_overlap_assume2.cfg, MC_assume_1c.cfg, MC_assume_2jobs.cfg, MC_sim_2x2.cfg | violations MC-4a, MC-4b; clean under explicit timing assumptions |
| S5 client process-exit cleanup + heartbeat | R (+L client actions) | R MC.cfg (CJExit/WaiterFree/ClientAbort/HeartbeatAbort/launch windows), L configs include ClientAbort/Heartbeat* | clean |

## Invariants (brief §5)

| Invariant | Defined in | Enabled in (cfg) | Outcome |
|---|---|---|---|
| AbortHonored | L base.tla | MC_hunt_abort.cfg | violated (hunt_abort_1) |
| (diagnostic) AbortedNotLaunched / AbortFromDispatchedHonored | L base.tla | MC_hunt_abort_AbortedNotLaunched.cfg / MC_hunt_abort_AbortFromDispatchedHonored.cfg | violated |
| TerminalStatusStable | L base.tla | MC.cfg, MC_assume*.cfg, MC_hunt_overlap*.cfg, MC_sim_2x2.cfg | violated in MC.cfg (mc_2 = MC-4a) and hunt_overlap_1 (MC-1 path); holds under AssumePromptRunningWrite |
| RunnerAlive | L base.tla | MC.cfg, MC_hunt_delete.cfg, MC_assume_1c.cfg, MC_assume_2jobs.cfg, MC_sim_2x2.cfg | violated (hunt_delete_1); holds without deletes |
| (diagnostic) RunnerAliveExceptScan / ...ExceptScanStat1 | L base.tla | MC_hunt_delete_noscan*.cfg | violated (other crash paths) |
| NoStaleAdmission | L base.tla | MC.cfg, MC_assume*.cfg, MC_hunt_overlap*.cfg, MC_sim_2x2.cfg | holds in all completed runs |
| AckedRunAbortEndsAborted (v1) | L base.tla | MC_hunt_overlap.cfg (run 2 only) | violated -> classified Case A (too strong), replaced |
| AbortOfLiveRunEndsAborted (v2) | L base.tla | MC_hunt_overlap.cfg, MC_hunt_overlap_assume2.cfg, MC_assume_1c.cfg, MC_assume_2jobs.cfg, MC_sim_2x2.cfg | violated (hunt_overlap_3 = MC-4b); holds under AssumePromptAbortMark |
| ResourceConservation | R base.tla | R MC.cfg, R hunts | holds (12.5M states) |
| NoConflictingAllocation (as NoOverAllocation) | R base.tla | R MC.cfg, R hunts | holds |
| AllocationOwned | R base.tla | R MC.cfg, R hunts | holds |
| FailedStartCleanedUp (diagnostic) | — | — | Not written as an invariant: S4 failed-start cleanup is covered by RunnerExcCleanup + StopRun effects in L and by the real-system Q2 check (logs/q2_partial_start_L0_run1.json). Liveness-style cleanup was checked on the real system rather than with TLC fairness. |
| (diagnostic) ReservationTracked / NoRejectionByLeftoverReservation | R base.tla | R MC_hunt_*.cfg | violated (by-design, expiry-bounded) |

Falsifiability note: AbortOfLiveRunEndsAborted remains falsifiable (hunt_overlap_3 violates it); it is fully silenced only by the
explicit AssumePromptAbortMark timing assumption, which is recorded as an assumption, not a code guard.

## Findings (brief §6.1)

| Finding | Trigger mechanism in model | Expected invariant | Config | Result |
|---|---|---|---|---|
| MC-1 | AdminAbortRead/Act interleaved with RunnerDeploy/SetDispatched/UpdateMeta/StartSJ/SetRunning | AbortHonored, TerminalStatusStable | MC_hunt_abort*.cfg | violated |
| MC-2 | AdminDeleteSnap/Act interleaved with RunnerScanList/ScanRead/CheckSubmitted/Deploy/Exc* | RunnerAlive | MC_hunt_delete*.cfg | violated (3 paths) |
| MC-3 | CHECK/START/CANCEL/expiry/launch-failure/abort/heartbeat with runner skip/failure paths | AllocationOwned, ResourceConservation | R MC.cfg | no violation (bounded) |
| MC-4 | CompleteClassify/Publish, fail_run from CJReport/HeartbeatMissing, AdminAbort vs runner start | TerminalStatusStable, NoStaleAdmission, AbortOfLiveRunEndsAborted | MC.cfg, MC_hunt_overlap*.cfg | violated (MC-4a, MC-4b) |

## Guidance mapping (user questions)

| Question | Where represented |
|---|---|
| Q1 concurrent reserve/acquire/release | R model (MaxJobs=2, K=1, late CHECK/START, expiry, cancel, free-at-exit); real partial-start check |
| Q2 partial deploy/start status & cleanup | L RunnerClientDeployFail/RunnerCollectStartTimeout/ClientStartErr + R RunnerDeployPartial/CollectStartWith; real T-1 and Q2 runs |
| Q3 cancel/complete/cleanup overlap | L S1/S4 hunts; real MC-1, MC-4a, MC-4b runs |
| Q4 failed operation affecting later jobs | L RunnerAlive (MC-2), NoStaleAdmission; R NoRejectionByLeftoverReservation; real MC-2, MC-2(a), T-1 runs |
