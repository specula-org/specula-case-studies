# Brief Coverage Audit: nvflare-job

This audit maps `modeling-brief.md` §2 (Scenarios), §5 (Proposed Invariants) and §6.1 (Model-Checkable
Findings) to the spec artifacts. The "enabled in" columns were filled by reading the generated `.cfg` files,
not from intent.

- **Category.** Category A (distributed request/reply RPC with timeouts, loss and process crash). Actions
  *inside* the server parent (SP) and client parents (CP) are split at every check-then-act and blocking-I/O
  boundary, following the brief's instruction (concurrent-style granularity).
- **Pinned source.** 53ba7ee5. Every action cites `file:line` in `base.tla`. The header lists the short names.
- **Seeds vs. targets.** Brief §6.1 says the confirmed findings F1, F2, F3, F5 and F16 are fidelity checks,
  not targets. Each seed has a `MC_seed_*.cfg`, and all of them reproduce (§5 below). The open questions
  MC-1 … MC-5 are targeted by `MC_hunt_*.cfg`.
- **Residuals.** Where a seed would mask the open question, a clearly labelled *hunting residual* tolerates
  exactly the seed mechanism. The contract invariant stays defined, enabled in a contract hunt config, and
  unchanged.

## 1. Scenarios (brief §2) → hunt configs

| Brief scenario | Spec mechanism (base.tla) | Hunt config(s) |
|---|---|---|
| **S1** Unguarded job-status writes and check-then-act (HIGH) | Blind `WriteStatus(j, s, writer)`. RMW split into read/write steps for `refresh_meta` (`RunnerRefreshRead/Write`, `job_scheduler.py:303,307`) and `update_meta` (`RunnerMetaRead/Write`, `job_runner.py:674`). Runner PC `ChkSubmitted → Deploy → SetDispatched → MetaRead/Write → ChkDispatched → StartSJ → StartWait → InsertRunning → SetRunning`. Admin abort split into check / write (`AdminAbortBegin/Write`) and into stop_run / mark (`AdminStopRun/MarkAborted`). Admin delete uses a stale authorize-time snapshot (`AdminDeleteAuthorize/Exec`). Completion is split into latch / publish / remove. | `MC_hunt_s1_status.cfg` (residuals for MC-1). `MC_hunt_s1_contracts.cfg` (contract set). |
| **S2** Admission-loop robustness (HIGH) | Runner `Dead` from `RunnerScanReadDeleted` (`:650`), `RunnerCheckSubmitted` (`:661`), and `RunnerExceptSetFailed/Meta` (`:720/:724`). `PoisonAt` constant with "pre" (`:166`) and "post" (`:229`) raises before the history update. `slots` with JOB_STARTED / JOB_COMPLETED / JOB_ABORTED events. `AdminDisable` removes the session without `notify_dead_client`. Dead-client sweeper death (`SweepBegin/SweepEnd`, F7). Completion-thread death (`CmpRemove` KeyError). | `MC_hunt_s2_slots.cfg` (MC-2 residual), `MC_hunt_s2_contracts.cfg`, `MC_hunt_s2_sweeper.cfg`, `MC_hunt_live_admission.cfg` (F4, liveness) |
| **S3** Reservation / allocation lifetime (MED-HIGH) | Per-client bag `free`, `resv` (token, units, ttl), START handler split `CpStartAllocate → CpStartRegister → CpStartLaunch` (+ `CpStartLaunchFail`), waiter `CpChildFinished` frees at LEADER exit, `grp`/`using` model same-group descendants, `CpTick` expiry, `CpCancelResource`, late CHECK processing after `RunnerCheckTimeout`, abort in every CJ state (`CpAbortApp`, `_PendingJobHandle`), heartbeat cleanup | `MC_hunt_s3_resources.cfg`, `MC_hunt_s3_groups.cfg` (F10), `MC_hunt_s3_promptcancel.cfg` (F6, informational) |
| **S4** Terminal-status composition from racing signals (MED) | `Classify` = `_classify_finished_job_status` verbatim. Racing signals: lossy `RUNSTATUS` (`SjFinish` → `SpUpdateRunStatus`), `SpWaitForComplete` rc capture, `SpRemoveRunProcesses` popping first (F20), `SpProcessJobFailure` → `fail_run` / `stop_run`. `CmpOutcomeDeadline` models the 900 s barrier. `runAborted` race with the latch. | `MC_hunt_s4_outcome.cfg` (MC-4 residual), `MC_hunt_s4_unsafe.cfg` (RS-5 + contract), `MC_hunt_s4_groundtruth.cfg` (F17/F20, informational) |
| **S5** Partial deploy/start vs site policy (LOW-MED) | `RunnerDeployJob(F)` per-client ok/fail/timeout plus "unknown clients". `RunnerStartEval` implements `check_client_replies` non-strict: no replies, not-enough replies, ERROR body, timeouts ignored. A disconnect is `AdminDisable` or `ClientCrash`. | `MC_hunt_s5_policy.cfg` (informational action property) |

No scenario was merged. S5 reuses the S1/S3 mechanisms, as the brief suggests, and has its own config.

## 2. Invariants (brief §5) → definition, MC wiring, enabled in

`MC.tla` `EXTENDS base`, so every base invariant is directly usable in MC configs.

| Brief invariant | Type | Defined (base.tla) | Enabled in (actual cfg files) |
|---|---|---|---|
| TerminalStable | Safety | `TerminalStable` (history `firstTerm`) | `MC.cfg`, `MC_hunt_s1_contracts.cfg`, `MC_seed_F3.cfg`, `MC_seed_F16.cfg`. Residual `NoNovelTerminalOverwrite` in `MC_hunt_s1_status.cfg`. |
| AbortHonored | Safety | `AbortHonored` (`ackAbort`, `postAckLaunch`) | `MC_hunt_s1_contracts.cfg`, `MC_seed_F1.cfg`. Residual `AbortHonoredNovel` in `MC_hunt_s1_status.cfg`. |
| OneShot | Safety | `OneShot` (`launches`) | `MC.cfg`, `MC_hunt_s1_status.cfg`, `MC_hunt_s1_contracts.cfg` |
| RunningIsTracked | Safety | `RunningIsTracked` | `MC_hunt_s1_contracts.cfg`, `MC_seed_F3.cfg` |
| SlotBalance | Safety | `SlotBalance` (`startedEv`, `endedEv`, `slots`) | `MC.cfg`, `MC_hunt_s2_slots.cfg`, `MC_hunt_s2_contracts.cfg` |
| RunnerAlive | Safety | `RunnerAliveInv` | `MC_hunt_s2_contracts.cfg`, `MC_hunt_s2_sweeper.cfg`, `MC_seed_F2.cfg` |
| AdmissionProgress | Liveness | `AdmissionProgress` | `MC_hunt_live_admission.cfg` (`MCLiveSpec`) |
| ResourceConservation | Safety | `ResourceConservation` (bag equality over free, reserved, allocated, in-handler) | `MC.cfg`, `MC_hunt_s3_resources.cfg`, `MC_hunt_s3_groups.cfg`, `MC_seed_F9.cfg` |
| ExclusiveOwnership | Safety | `ExclusiveOwnership` (also counts live process groups via `using`) | `MC.cfg`, `MC_hunt_s3_resources.cfg`, `MC_hunt_s3_groups.cfg` |
| NoFreeWhileGroupAlive | Safety | `NoFreeWhileGroupAlive` | `MC_hunt_s3_resources.cfg`, `MC_hunt_s3_groups.cfg` |
| ReservationBounded (clocked) | Safety | `ReservationBounded` (TTL ∈ 1..Expiry; true by construction of the tick model, contract A6) | `MC.cfg`, `MC_hunt_s3_resources.cfg` |
| ↳ PromptCancel (informational; expected to fail, F6) | Safety | `PromptCancel` / `TokenOwned` | `MC_hunt_s3_promptcancel.cfg` |
| FinalMatchesOutcome | Safety | `FinalMatchesOutcome`, clauses (a) and (b); see §6 | `MC_hunt_s4_unsafe.cfg`, `MC_seed_F5.cfg`. Residual `FinalMatchesOutcomeNovel` in `MC_hunt_s4_outcome.cfg`. |
| BoundedFinalization | Liveness | `BoundedFinalization` | `MC_hunt_live_finalize.cfg` (`MCLiveSpec`) |
| EventualCleanup | Liveness | `EventualCleanup` / `JobCleanOn` | `MC_hunt_live_cleanup.cfg` (`MCLiveSpec`) |

Every §5 Safety invariant is enabled in at least one `MC_hunt_*.cfg`. Every liveness property has its own
`MCLiveSpec` config. Liveness configs:
- declare no `CONSTRAINT`, because a truncated graph would make the fairness assumption vacuous;
- use no `VIEW` or `SYMMETRY`;
- keep heartbeats unbounded and fair (`MCHeartbeatLive`).

### 2.1 Additional checks (each traced to a brief scenario; not in brief §5)

| Check | Why | Enabled in |
|---|---|---|
| `NoOrphanSlot` | MC-2 asks "can a slot leak?": every held slot must have a live owner that will release it | `MC_hunt_s2_contracts.cfg`. Residual `NoOrphanSlotNovel` in `MC_hunt_s2_slots.cfg`. |
| `CompletionAlive` | S2 "exception in the single ... finalization path" (RS-7 mechanism) | `MC_hunt_s2_slots.cfg`, `MC_hunt_s2_contracts.cfg` |
| `SweeperAlive` | S2 evidence F7 (dead-client sweeper without a handler) | `MC_hunt_s2_sweeper.cfg` |
| `SjErrorNotMasked` (informational) | S4 / F17 / F20 against ground truth. Best-effort channel, expected to fail under loss | `MC_hunt_s4_groundtruth.cfg` |
| `StartFailureMatchesPolicy` (informational, action property) | S5 / F15 policy question | `MC_hunt_s5_policy.cfg` |
| Structural: `TypeOK`, `RunningWasStarted`, `PublishHasLatch`, `ReservationBounded` | spec sanity | `MC.cfg`, `base.cfg`, `Trace.cfg` |

## 3. Findings (brief §6.1) → trigger, expected violation, hunt config

| ID | Trigger mechanism in the model | Expected violated invariant | Hunt config (fault setup) |
|---|---|---|---|
| MC-1 | Interleavings of runner steps, completion finalize, admin abort/delete, `fail_run`/`stop_run`, CANT_SCHEDULE give-up and RMW writes | `NoNovelTerminalOverwrite`, `AbortHonoredNovel`, `OneShot` (residuals); contracts `TerminalStable`, `AbortHonored`, `RunningIsTracked` | `MC_hunt_s1_status.cfg` / `MC_hunt_s1_contracts.cfg`: 2 jobs, 1 unit (the 2nd job gets NO_RESOURCE, reaching the refresh RMW), MaxJobs 2, MaxScheduleCount 2 (CANT_SCHEDULE reachable), abort 2, delete 1, SJ error 1, CJ error 1, heartbeat 1 |
| MC-2 | JOB_STARTED/end-event pairing on all exits: start exceptions, `:360` KeyError, `fail_run` after SJ exit, `stop_run` of an exited SJ, publication retries on a deleted job | `NoOrphanSlotNovel`, `SlotBalance`, `CompletionAlive`; contracts `RunnerAliveInv`, `NoOrphanSlot` | `MC_hunt_s2_slots.cfg` / `MC_hunt_s2_contracts.cfg`: 2 jobs, MaxJobs 1, abort 1, delete 1, SJ error/crash 1, CJ error 1, heartbeat 1 |
| MC-3 | Late CHECK replies (`RunnerCheckTimeout` + later `CpCheckResource`), dropped CANCEL/START (`LoseMsg`), abort in each CJ state, heartbeat cleanup, launch failure, expiry, leader vs group exit | `ResourceConservation`, `ExclusiveOwnership`, `NoFreeWhileGroupAlive` | `MC_hunt_s3_resources.cfg` (2 jobs, 2 units, loss/timeouts/abort/CJ error/launch fail, heartbeat 2). `MC_hunt_s3_groups.cfg` (descendants 1) |
| MC-4 | Lossy UPDATE_RUN_STATUS, client failure reports, `_remove_run_processes` popping before rc capture, admin abort racing the latch | `FinalMatchesOutcomeNovel` (residual) / `FinalMatchesOutcome` | `MC_hunt_s4_outcome.cfg` (loss, abort, SJ error/crash, CJ error, heartbeat; UNSAFE off). `MC_hunt_s4_unsafe.cfg` (UNSAFE on, 2 clients) |
| MC-5 | Fairness with disable / dead clients: finished jobs reach a terminal status; CJs of terminal jobs exit and free | `BoundedFinalization`, `EventualCleanup` (+ `AdmissionProgress`) | `MC_hunt_live_finalize.cfg` (disable 1, crash 1, 2 clients). `MC_hunt_live_cleanup.cfg`. `MC_hunt_live_admission.cfg`. `MC_hunt_s2_sweeper.cfg` for the sweeper-death precondition |

## 4. Target-specific guidance (Q1–Q4) → where it is answered

| Question | Model coverage |
|---|---|
| Q1: concurrent reserve/acquire/release; conflicting assignment or lost capacity | S3 configs: bag conservation catches loss *and* duplication; `ExclusiveOwnership` also counts live process groups (F10). `PromptCancel` shows capacity held only until expiry (F6). |
| Q2: partial deploy/start; do status and cleanup match? | S5 policy property; `FinalMatchesOutcome` (b) for F5; `EventualCleanup` for cleanup responsibility after partial starts. |
| Q3: cancel / complete / cleanup overlap | S1 residuals and contracts (abort vs. runner / completion / RMW); S4 (stop_run vs. latch); S3 (abort vs. START registration, CL-1 history `abortDropped`). |
| Q4: failed operation's leftover state affects a later job | S2 (runner / completion / sweeper death, orphan slots, F4 starvation) and S3 (leaked units, expiry-only reclaim). |

The guidance says the questions do not presume defects and prescribe no model guards. Accordingly, no
guard was added to any action. Every guard in `base.tla` is a condition that exists in the code.

## 5. Seed fidelity (brief §6.1: "must reproduce before hunting")

Command pattern (from `.specula-output/spec/`, scratch outside the output dir):
`../../tlc-scratch/run_cfg.sh MC_seed_<X>.cfg 4 6 300`. Outputs are in `../../tlc-scratch/out_MC_seed_<X>.txt`.

| Seed | Result | Shortest counterexample (TLC action trace) |
|---|---|---|
| F1 | `AbortHonored` violated (depth 14) | `RunnerTryNext`, `AdminAbortBegin` (SUBMITTED), …, `RunnerDeployJob`, `AdminAbortWrite` (ack), `RunnerSetDispatched` (DISPATCHED over ABORTED) |
| F2 | `RunnerAliveInv` violated (depth 12) | `AdminDeleteAuthorize`, `RunnerScanList`, `AdminDeleteExec`, `RunnerScanReadDeleted` (RS-1 variant of F2 at `:650`) |
| F3 | `TerminalStable` violated (depth 25) | … `RunnerStartServerApp`, `SjFinish(j1,TRUE,1)`, … `RunnerInsertRunning`, `SpWaitForComplete`, `CmpFinalizeBegin`, `CmpPublish`, `CmpRemove`, `RunnerSetRunning` |
| F5 | `FinalMatchesOutcome` (b) violated (depth 27) | 2 clients: c1's CJ `CjExit(rc 1)` while c2's START is still pending, `CpChildFinished`, `SpProcessJobFailure` (`fail_run` pops pending), `RunnerStartCollect` (KeyError `:360`), `RunnerExceptStop`, `RunnerExceptSetFailed` |
| F16 | `TerminalStable` violated (depth 14) | abort of the queued job lands between `RunnerRefreshRead` and `RunnerRefreshWrite` (SUBMITTED written back over FINISHED:ABORTED) |
| F9 (UNSUPPORTED trigger) | `ResourceConservation` violated | `MsgStartAllocateAppMissing` (app dir removed before START). Only with `EnableUnsupported = TRUE`, and outside the supported envelope. |

## 6. Faithfulness decisions (merges and abstractions, each justified)

| Decision | Where | Justification |
|---|---|---|
| `set_status` = one blind write | `WriteStatus` | Its inner RMW can only revert non-status keys (not modeled). The 3 RMW writers that can revert *status* are split. |
| except-path `update_meta` (`:724`) merged with the JOB_ABORTED event | `RunnerExceptMeta` | Its only extra effect is a terminal→terminal revert already reachable at `:720` (`RunnerExceptSetFailed`). |
| SJ launch + pending registration + START fan-out = one step | `RunnerStartServerApp` | No reader of the intermediate state can act before any CJ exists (see comment in spec). |
| `run_aborted` read (`:486`) + classification (`:585`) = one step | `CmpFinalizeBegin` | The only blocking call between them (`abort_client_run`) runs only when an exception record exists. |
| UNSAFE `stop_run` = one step in the cell handler | `SpProcessJobFailure` | The `_stop_run`/mark window is modeled separately for the admin path (`AdminStopRun`/`AdminMarkAborted`). |
| CP waiter reap + report + free + pop = one step | `CpChildFinished` | A `_terminate_job` in the reaped-but-reporting window still leaves descendants alive, which is already reachable via the early return (`CpTerminateJob`). |
| Heartbeat round trip = one step (+ ABORT messages) | `Heartbeat` | The server computes from its state; the client aborts via ordinary `CpAbortApp` steps. |
| Replies after a sender timeout are discarded at creation | `CpCheckResource`, `CpStart*` | Equivalent to delivery then discard. The late request's *side effects* (reservation, launch) still happen. |
| Deploy content abstracted to per-client ok/fail | `RunnerDeployJob(F)` | Brief §3.2 (deploy content / signing are "may fail"). Dead clients always time out. |
| Units follow ListResourceManager semantics; `Need = 0` is the default 0-GPU config | constants | Float GPU memory (F8) and `CUDA_VISIBLE_DEVICES` (F13) are excluded by brief §3.2. |
| SJ may finish normally at any time after launch | `SjFinish(j, FALSE, 0)` | Over-approximation: workflows usually need clients. Counterexamples relying on a *normal* SJ finish during `_start_run` must be judged for realism in confirmation. The F3 seed uses an SJ *error*. |
| Same-group descendants (`desc`) | `CjExit(c, j, rc, TRUE)` | User job code may spawn them. The in-tree Client API trainer uses its own session (report F10). |
| Unsupported F9 trigger | `CpStartAllocateAppMissing` behind `EnableUnsupported` | Kept only for fidelity. It is off in every hunt config. |

Not modeled, per brief §3.2: F8 float drift; F13/F14 GPU binding; PID reuse and `killpg` mechanics (F10/F20
part); validator type coercion (generic `PoisonAt`); archival/zip I/O; auth; docker/k8s/slurm; HA and restart
(F18); the `notify_job_status` retry loop (F11); server shutdown (`stop_all_runs`, confirmed in the report as F7).

## 7. Self-check log (model, property and MC-control changes kept distinct)

| # | Kind | Change | Evidence |
|---|---|---|---|
| 1 | Model fix (spec error) | `SjHandleAbort` left `failRunRec` unspecified in one branch | TLC "Successor state is not completely specified …"; fixed; simulations clean |
| 2 | Model (behaviour-preserving) | canonicalize `sjRC` / `cjRC` after their only reader consumed them | no guard reads them afterwards |
| 3 | Property refinement | `FinalMatchesOutcome` (b): carve-out for *genuine* start failures (no / missing / ERROR START replies), where FAILED_TO_RUN is accurate | The first F5 run surfaced a sibling where another client's START genuinely failed. The clause now matches the documented F5 contract (D8 vs the `:360` KeyError); F5 then reproduced exactly. The contract was sharpened to its documented meaning, not weakened to pass. |
| 4 | Hunting residual (not a contract) | `KnownOverwrite` / `NoNovelTerminalOverwrite`, `AbortHonoredNovel` (+ history `ackInWindow`), `NoOrphanSlotNovel`, `FinalMatchesOutcomeNovel` | Each tolerates exactly one confirmed seed mechanism. The contract versions stay enabled in the `*_contracts` / `*_unsafe` / seed configs. |
| 5 | MC control | per-config `VIEW` (`ViewS1`…`ViewS4`) drops write-only history variables that the config does not check | sound: history never feeds a guard or a non-history update |
| 6 | MC control | liveness configs: no CONSTRAINT / VIEW / SYMMETRY; F4 liveness uses the "pre" shape (finite lasso) | the "post" shape creates a fresh token each pass, giving an infinite graph |

Earlier model versions are preserved at `../../tlc-scratch/base.v0.tla` (before the history refinements) and
`base.v1.tla` (before `startFailCause`/`ackInWindow`).

Trace spec self-check (`../../tlc-scratch/tracegen/`):
- `tlc2ndjson.py` converts TLC counterexamples into the instrumentation-spec NDJSON schema. `replay.sh` validates
  them with `Trace.tla`/`Trace.cfg`.
- 13 model behaviours are accepted with `TraceMatched`. They are one normal completion plus F1, F2, F3,
  F5, F16, and the s1, s2-slots, s2-sweeper, s3-groups, s4-outcome, s4-unsafe and s5 counterexamples,
  covering 1–2 jobs, 1–2 clients, crashes, deletes, aborts, loss and timeouts.
- 4 corrupted traces are rejected at the corrupted event: wrong status, wrong free units, reordered
  publish/latch, and wrong pending set. So `ValidatePostState` is not vacuous.
- These are *synthetic* traces. Real harness traces (Phase 2.5) remain the actual validation.

## 8. Early hunt smoke results (model counterexamples, NOT yet confirmed in code)

Each config was run for ≤ 90 s (`run_cfg.sh <cfg> 4 6 75`). Results are for the next phase to classify:

| Config | First counterexample | Note |
|---|---|---|
| `MC_hunt_s1_status` | `AdminAbortBegin` reads SUBMITTED, the start fails (reservation expired, then START error), `RunnerExceptSetFailed` writes FAILED_TO_RUN, then `AdminAbortWrite` writes ABORTED (terminal→terminal, writer not a seed) | new MC-1 candidate |
| `MC_hunt_s2_slots` | delete authorized on a SUBMITTED snapshot executes after `RunnerSetRunning`: the job is deleted while RUNNING, `CmpPublish` can never succeed, the slot is held | new MC-2 candidate (RS-8 root cause, different consequence) |
| `MC_hunt_s2_sweeper` | `ClientCrash`, `SweepBegin` (blocking), `SpWaitForComplete` pops, `SweepEnd` → sweeper dead | matches report SE-1 B |
| `MC_hunt_s3_groups` | CJ leader exits with descendants; waiter frees the unit | F10 (known) |
| `MC_hunt_s3_promptcancel` | CHECK timeout, then late CHECK reserves an unowned token | F6 (by design) |
| `MC_hunt_s4_outcome` | START lost, non-strict start, RUNNING, admin `AdminStopRun` → SJ handles the abort and exits 0 → completion latches COMPLETED before `AdminMarkAborted` | new MC-4 candidate (`stop_run` orders `_stop_run` before `mark_run_aborted`) |
| `MC_hunt_s4_unsafe` | UNSAFE report during start: `stop_run` no-op mark + `_remove_run_processes` pops before rc capture → COMPLETED | RS-5 + F20 |
| `MC_hunt_s4_groundtruth` | RUNSTATUS(exe_error) not yet processed when the waiter pops → COMPLETED | F17 (informational) |
| `MC_hunt_s5_policy` | c1 disabled after deploy → "not enough replies" → whole job fails though c2 started | F15 (policy; `timeouts.rst:2460-2467` documents only the timeout case) |
| `MC_hunt_live_admission` | lasso: poisoned j1 raises every pass; j2 stays SUBMITTED | F4 (known) |
| `MC_hunt_live_cleanup` | no violation (253,489 states, complete) | — |
| `MC_hunt_s3_resources`, `MC_hunt_live_finalize` | still running at the time cap (1.28 M / 0.34 M states); no violation so far | need full runs |

## 9. Known matches in permitted source / history (recorded separately)

These are from this run's own analysis (`analysis-report.md` §2.4) and in-tree documents. They are not
answers supplied to the model.

- `docs/programming_guide/timeouts.rst:2460-2467` documents that non-strict start does not enforce
  `min_sites`/`required_sites` for timeouts. It does not cover disconnects or explicit errors (S5).
- `docs/user_guide/core_concepts/job.rst:284-286` promises cancellation only for non-admitted jobs, so
  `PromptCancel` failures are a gap in the contract rather than a violation of it (F6).
- `resource_manager_and_consumer.rst:17-20,99-101`: resource checks are virtual bookkeeping.
- No HEAD-reachable commit addresses F1–F9 (report §2.4).
