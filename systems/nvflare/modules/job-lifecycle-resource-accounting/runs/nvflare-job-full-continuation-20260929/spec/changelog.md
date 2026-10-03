# Spec Validation Changelog — nvflare-job

Pinned source 53ba7ee5. Phase 3 (validation-workflow). Entry kinds are kept distinct:
`[fix]` model (base/Trace spec) change from trace validation, `[fix-inv]` property change (Case A),
`[fix-spec]` model change from model checking (Case B), `[bug]` real defect (Case C),
`[obs]` observation/harness change (no model or property change), `[mc-control]` checker configuration only,
`[env]` environment limitation.

Snapshots of every spec version used in this phase are kept under `spec/history/<round>/`
(`r0-phase3-start` = the spec as delivered by Phase 2 / 2.5).

## Round 0 - Initialization
- [env] MCP `run_trace_validation` cannot run on this host: TLC fails with "could not make a directory
  /tmp/tlc_validation/..." because `/tmp/tlc_validation` is a dangling symlink into another user's home.
  Trace validation therefore uses `harness/validate.sh` (direct TLC, `-metadir harness/build/tlc-meta`,
  1 worker, -Xmx4g, sequential) with the same `Trace.tla` / `Trace.cfg`.
- Verified: base/MC/Trace specs, 21 hunting/seed cfgs, 29 traces, instrumentation-spec.md,
  harness/INSTRUMENTATION.md. `Trace.cfg` has `PROPERTIES TraceMatched`; `ValidatePostState` checks every
  observable variable on every event (not a stub). Trace provenance matches the current harness build
  (patch sha256 a74bfbf9..., tla_hooks sha256 66978101...).

## Round 1 - Trace Validation
Baseline (spec r0): 26/29 pass; 3 fail (`spec/output/trace_validation_r1_baseline.txt`; TLC counterexamples from
Phase 2.5 in `harness/evidence/validation/`).
- [fix] Network / every message send-consume action: `msgs` was a set, so two identical in-flight requests merged.
  CellNet does not deduplicate: `fail_run`'s `_stop_run` and the runner's except-path `_stop_run` each send
  ABORT(j) to every participant and to the SJ (`job_runner.py:374-393, 714-719, 843`), and both copies are
  processed. `msgs` is now a multiset (`NoMsgs`/`Send`/`Consume`/`ConsumeAll`/`Keep`; guards use `DOMAIN msgs`).
  (Trace: failrun_during_start_dup_abort.ndjson, 2nd `CpAbortApp(c2)` at #28)
- [fix] CpAbortApp / CpTerminateJob / CjHandleAbort: `termP[c][j]` and `cjAbortMsg[c][j]` were booleans, but every
  `abort_app` on a STARTED/STOPPED registration starts its own `_terminate_job` thread and (when STARTED) fires its
  own CJ ABORT (`client_executor.py:486-547`); CP requests run concurrently on the cell worker pool. Both are now
  counters. (Traces: double_abort_terminate.ndjson #68, random_mix_s1.ndjson #96)
- [fix] Heartbeat: new guard `~HbBusy(c)` and counter `termHb[c][j]`. The heartbeat thread processes the previous
  reply's abort list synchronously (`communicator.py:621-624, 640-646`) and `abort_app` joins the `_terminate_job`
  thread it starts (`client_executor.py:511-533`), so a client sends no heartbeat while one of its cleanup aborts is
  undelivered or blocked in that join. Companion to the multiset change (code evidence, no trace failure): without
  it, unbounded fair heartbeats in the liveness configs would accumulate duplicate cleanup ABORTs / terminate
  threads without bound. `heartbeat_cleanup=True` differs from a plain `terminate()` only for the Slurm launcher
  (out of scope).
- [obs] Harness probe for INSTRUMENTATION.md 7.3 (first bullet): added the timing gate `wfc.after_read` in the
  instrumented `ServerEngine.wait_for_complete` (after the entry read, before the <= 2 s wait; no-op unless a
  scenario registers it) and scenario `wfc_stale_read_after_pop`. Patch regenerated (Phase-2.5 patch, scenarios,
  run.sh and traces preserved in `harness/history/phase2.5/`); all traces regenerated with the new patch.
- [fix] SpWaitForComplete / SpRemoveRunProcesses: new variable `wfcStale[j]`. `wait_for_complete` reads the
  `run_processes` entry (`server_engine.py:205`) before its <= 2 s wait and records the SJ exit code into the object
  it read (`:218-233`); when `_remove_run_processes` popped the entry in between, the exit code is still recorded
  from the stale entry -- even after the completion thread finalized the job, leaving a stale
  `exception_run_processes` entry. The model merged read and record, so it could only express "rc never captured".
  `_remove_run_processes` now stashes the entry it pops while the waiter is alive, and `SpWaitForComplete` with
  the entry gone either records nothing (read after the pop, F20) or records from the stash (read before the pop).
  (Trace: wfc_stale_read_after_pop.ndjson #70; pre-fix counterexample
  `spec/output/r1_wfc_stale_read_after_pop_FAIL_before_wfcStale_fix.tlc.log`)
- [note, not modeled] INSTRUMENTATION.md 7.3 second bullet: `_job_complete_process` calls
  `remove_exception_process(job_id)` when a job vanished from `running_jobs` between the key snapshot and `get`
  (`job_runner.py:443-446, 541`). In scope the only other remover is the runner's except path
  (`job_runner.py:716-717`; `remove_running_job` is called only by HA `pause_server_jobs`), and the `exc` entry of
  a job removed there is never read again (not in `running_jobs`, no pending outcomes, SJ gone). No behavioural
  consequence, so no action was added. Third bullet (SweepEnd Dead branch) is a harness limitation (trace lock).
- Result: 30/30 official traces pass (`spec/output/trace_validation_r1_after_wfc_fix.txt`; re-run after
  regeneration in `harness/build/run_p3r1.log`), 2 parallel stress rounds 30/30 each, random seeds 7-40 34/34
  (`spec/output/trace_validation_r1_*`). Spec snapshot: `spec/history/r1-trace/`.

## Round 1 - Model Checking
Config MC.cfg (spec r1), BFS, 16 workers, -m 20G -M 40G, -t 30.
- [bug] RunnerSetDispatched: `TerminalStable` violated in 11 states (`spec/output/MC_r1_run1.out`):
  `AdminAbortBegin(j1)` reads SUBMITTED, the runner deploys, `AdminAbortWrite` acknowledges ("Aborted the job ...
  before running it.") and writes FINISHED:ABORTED, then `job_runner.py:670` blindly writes DISPATCHED over it
  (the job goes on to run). Case C: confirmed seed F1 (brief 6.1; harness A1/A2), and the real implementation
  exhibits it in the validated trace `abort_during_deploy.ndjson`. Contract: `FINISHED:*` is terminal
  (`job_cli.py:1926-1936`, `job_cmds.py:1067-1070` "already completed"), one-shot execution (`job.rst:342-345`).
  Not a new finding (known seed; see bug-report "Known seeds").
- [mc-control] MC_conv.cfg = MC.cfg with `TerminalStable` replaced by the residual `NoNovelTerminalOverwrite`
  (tolerates only the confirmed seed writers F1/I4, F1/F3, F16, RS-3, I5; see `evidence/deep/runner_status.md` I2-I7,
  I15) so the convergence round can continue past the F1 counterexample BFS always reaches first. `TerminalStable`
  stays enabled in MC.cfg; no property was changed.
- [bug] AdminAbortWrite (MC-A): `NoNovelTerminalOverwrite` violated in 12 states on MC_conv.cfg
  (`spec/output/MC_conv_r1_run1.out`): `AdminAbortBegin(j1)` reads SUBMITTED; the runner schedules j1, its deploy
  to the only dispatched site fails (min_sites not met, `job_runner.py:269-282`), the except path publishes
  FINISHED:FAILED_TO_RUN (`:720`); then the admin handler's `set_status(FINISHED_ABORTED)` (`job_cmds.py:1063`)
  overwrites it and acknowledges "Aborted the job ... before running it.". Case C: `abort_job` reads the status and
  writes without a lock or re-check (`job_cmds.py:1058-1063`), `set_status` is a blind merge
  (`job_def_manager.py:459-481`); `TerminalStable` is the documented contract (abort_job itself refuses FINISHED:*
  jobs as "already completed"). Low severity (terminal -> different terminal; no resource effect). Same
  blind-write root cause as the F1 family, new writer site; corresponds to the spec-generation smoke-test candidate
  (brief-coverage 8, MC_hunt_s1_status).
- [residual] KnownOverwrite: added `o.w = "AdminAbortWrite" /\ o.from \in Terminal` (hunting residual only; used by
  MC_conv.cfg and MC_hunt_s1_status.cfg) so the search continues past MC-A. `TerminalStable` unchanged.
- [bug] CmpPublish (MC-B, F1 family): `NoNovelTerminalOverwrite` violated in 21 states (`spec/output/MC_conv_r1_run2.out`):
  `AdminAbortBegin(j1)` reads SUBMITTED; the runner deploys (DISPATCHED), launches the SJ and sends START
  (`_start_run`); `AdminAbortWrite` then writes FINISHED:ABORTED and acknowledges "Aborted the job ... before running
  it." -- a store-only write (`job_cmds.py:1061-1066`) that stops nothing; the runner inserts j1 into running_jobs,
  the SJ ends, and the completion thread latches and publishes FINISHED:COMPLETED over FINISHED:ABORTED
  (`job_runner.py:484-492, 524`: no check of the persisted status). Case C: third overwrite site of the confirmed F1
  mechanism (F1 lists :670 and :711), reachable when the SJ ends during `_start_run` (F3's confirmed precondition;
  with an SJ execution error the published status is EXECUTION_EXCEPTION). `run_aborted` is set only on the RUNNING
  path (`job_runner.py:802-811`), so CmpPublish can overwrite ABORTED only through the store-only abort.
- [residual] KnownOverwrite: added `o.w = "CmpPublish" /\ o.from = ABORTED` (hunting residual only).
- MC_conv.cfg BFS, 30 min (`spec/output/MC_conv_r1_run3.out`): no violation; 448,903,190 states generated,
  82,819,524 distinct, BFS depth 33, 32,473,737 left on queue at the time limit (state space not exhausted).
- MC_conv.cfg simulation, 30 min, depth 100 (`spec/output/MC_conv_r1_sim1.out`): no violation; 219,007,639
  states checked, 2,134,199 traces (mean length 58).
- No Case A or Case B counterexample in this round: Phase 2 changed no action (only the hunting residual
  `KnownOverwrite`, which Trace.cfg does not use). Re-validation of all 30 traces against the final spec: 30/30
  (`spec/output/trace_validation_r1_final_converged.txt`).

## Round 1 - Convergence
Phase 1 passed after its fixes; Phase 2 then passed with no spec (behaviour) modification -> converged in 1 round.
Converged spec snapshot: `spec/history/r1-converged/` (base.tla sha256 db3585e7...).

## Bug Hunting - seed fidelity regression (converged spec r1)
All confirmed seeds still reproduce (2 workers each, `spec/output/MC_seed_*_r1.out`):
F1 `AbortHonored` (12 states, DISPATCHED over an acked abort); F2 `RunnerAliveInv` (6 states, RS-1 delete during
the scan); F3 `TerminalStable` (24 states, SJ error during `_start_run`, publish, then RUNNING); F5
`FinalMatchesOutcome` (27 states, fail_run pops pending -> KeyError at `:360` -> FAILED_TO_RUN); F9
`ResourceConservation` (15 states, unsupported app-dir removal). MC_seed_F16.cfg stops at the shallower F1
overwrite under `TerminalStable` (the Phase-2 run did too: `tlc-scratch/out_MC_seed_F16.txt`), so
- [mc-control] MC.tla: added checker-only probe `NoRefreshWriteOverwrite` and MC_seed_F16_refresh.cfg (F16 config,
  that invariant only). Result: violated in 30 states -- the queued job's abort lands between `RunnerRefreshRead` and
  `RunnerRefreshWrite`, which writes SUBMITTED back over FINISHED:ABORTED (F16) (`spec/output/MC_seed_F16_refresh_r1.out`).

## Bug Hunting - runs
- [bug] AdminDeleteExec (MC-C): MC_hunt_s2_slots.cfg BFS, `NoOrphanSlotNovel` violated in 22 states
  (`spec/output/MC_hunt_s2_slots_bfs1.out`): `AdminDeleteAuthorize(j1)` snapshots j1 while SUBMITTED; j1 is
  scheduled, deployed, started (JOB_STARTED takes the only slot) and set RUNNING; `AdminDeleteExec` checks only the
  snapshot (`job_cmds.py:507-521`) and deletes the RUNNING job. The completion thread's publish then raises
  StorageException on every pass (`filesystem_storage.py:266-267, 323-324`) and `continue`s
  (`job_runner.py:523-530`), so j1 never leaves running_jobs and JOB_COMPLETED never releases its scheduler slot;
  with max_jobs = 1 no later job is admitted. Case C: same TOCTOU root cause as the confirmed RS-8/K2v (delete during
  `_start_run` kills the runner), new consequence when the delete lands after `job_runner.py:711` (runner survives,
  slot and running_jobs entry leak permanently).
- [residual] NoOrphanSlotNovel: refactored `NoOrphanSlot` into `SlotOwned(j)` (identical contract) and added the
  MC-C tolerance (slot of a deleted job still in running_jobs) to the residual only.
- [bug] CmpRemove (MC-D): MC_hunt_s2_slots.cfg BFS run 2, `CompletionAlive` violated in 28 states
  (`spec/output/MC_hunt_s2_slots_bfs2.out`): delete authorized on a SUBMITTED snapshot; j1's SJ fails during
  `_start_run`; the runner inserts j1 into running_jobs (`:709-710`); the completion thread latches and publishes
  FINISHED:EXECUTION_EXCEPTION; the delete executes (stale snapshot); `set_status(RUNNING)` (`:711`) raises; the
  runner's except path removes j1 from running_jobs (guarded, `:716-717`); the completion thread's unguarded
  `del self.running_jobs[job_id]` (`:532`, no try) raises KeyError and the thread ends -- no later job is ever
  finalized or releases its slot (the runner also dies at `:720`, F2). Case C: RS-7 mechanism (confirmed in the
  analysis phase only with an injected store error at `:711`), here reached through supported operations (F3 timing
  plus the delete TOCTOU; a double race, low likelihood; any transient store error at `:711` reaches the same state).
- [residual] NoOrphanSlotNovel: added `cpc.pc = "Dead"` (orphans left by the MC-D dead completion thread).
- [mc-control] MC_hunt_s2_slots_c2.cfg = MC_hunt_s2_slots.cfg without `CompletionAlive` (its only violating
  transition is MC-D) for the continuation run.
- MC_hunt_s1_status.cfg BFS 30 min (`spec/output/MC_hunt_s1_status_bfs1.out`): no violation; 305,823,584 states,
  62,171,619 distinct, depth 36, 18,941,867 queued at the limit.
- MC_hunt_s2_slots_c2.cfg BFS 30 min (`spec/output/MC_hunt_s2_slots_c2_bfs1.out`): no violation; 311,217,083
  states, 56,717,106 distinct, depth 45, 12,487,571 queued.
- [bug] CmpFinalizeBegin / AdminStopRun (MC-E): MC_hunt_s4_outcome.cfg BFS, `FinalMatchesOutcomeNovel` clause (a)
  violated in 24 states (`spec/output/MC_hunt_s4_outcome_bfs1.out`): j1 RUNNING (its START was lost; non-strict
  start ignores it); admin abort -> `stop_run` = `_stop_run` then `mark_run_aborted` (`job_runner.py:798-800`);
  `_stop_run` sends the SJ ABORT and waits <= 1 s for the reply (`server_engine.py:354-383`); the SJ aborts, fires
  UPDATE_RUN_STATUS(execution_error=False) and exits 0 (`server_commands.py:106-118`,
  `server_app_runner.py:84-91`); `wait_for_complete` pops the entry; the completion thread (run_aborted still
  False, no exception record) latches and publishes FINISHED:COMPLETED; `mark_run_aborted` comes too late. Case C:
  an admin-aborted running job is reported as successfully completed, although `mark_run_aborted` exists to make it
  FINISHED:ABORTED (`job_runner.py:486-487`). Realistic window: the SJ's abort reply is slow or lost (optional,
  1 s) while the SJ exits quickly. Matches the spec-generation smoke-test candidate (brief-coverage 8).
- [residual] New write-only history variable `latchInStopWin[j]` (set by `CmpFinalizeBegin` when it latches while
  the admin is between `_stop_run` and `mark_run_aborted`, i.e. `adm[j].pc = "MarkAborted"`, with run_aborted
  False); `FinalMatchesOutcomeNovel` clause (a) tolerates `sjAbortHandled` only in that case. No action guard or
  non-history update reads it (added to histVars, ViewS4); contract `FinalMatchesOutcome` unchanged. Sanity:
  3 traces re-validated.

## Continuation C1 — independent initialization and trace baseline (2026-09-26)
- Prior Phase 3 stopped on credit exhaustion after MC-E, with the next outcome counterexample unclassified. The historical sections above are retained as evidence, not current completion claims. This is the authorized mixed-model continuation: GPT-6 Astra/max for validation; configured separate GPT-5.5/xhigh confirmation remains launcher-owned.
- [audit] Read the pinned validation/trace/checking skills, adoption review and underlying source/transcript evidence. Preserved the received suite in `history/continuation-r0/` before behavioral edits. Fresh Phase 2.5 traces: 32/32 replayed against that suite (`output/continuation-baseline-traces.json`). This does not establish full conformance: coarse trace locks, process/transport stubs, and projection gaps are audited in `../adoption/harness-audit.md` and `continuation-audit.md`.

## Continuation C1 — model checking and source repairs
- [bug] MC.cfg, 30-minute budget, 8G heap/16G offheap/8 workers: `TerminalStable` fails at depth 11 (5,682 generated / 1,763 distinct; `output/continuation-r1-MC.out`). AdminAbortWrite acknowledges ABORTED during deployment, then RunnerSetDispatched overwrites it. Case C, independently rechecked F1 seed, not a new discovery. Source JC:1058-1066 / JR:669-670 / JD:459-481 has no recheck or mutual exclusion across these threads.
- [fix-spec] Case B/source audit V01/V03: separate per-job scan reads; SJ spawn, registration, pending initialization, and per-client START fanout. Source JD:524-531, JR:304-310, SE:315-329/1073-1083. Previous comments claiming no observable startup intermediate states were unsupported.
- [fix-spec] Case B/source audit V04: split completion server/pending/abort/exception reads from latch; split failure-report acceptance, fail_run recording, cleanup RPC, unsafe-stop marker, and final pending resolution. Source JR:445-492/575-585/815-843 and FS:906-957 uses distinct locks and blocking calls.
- [fix-spec] Case B/source audit V05: give delete and abort independent command state, permitting one concurrent handler of each kind for a job. Multiple simultaneous handlers of the same kind remain an explicit bound.
- [fix-spec] Case B/source audit V07: require the waiter's actual post-exit record read before retaining it across pop; split CP leader reaping/report from pool free/pop. A group kill after OS leader reaping can fail getpgid and leave descendants. Source SE:204-233/385-409, CX:628-681, process_utils.py:293-316.
- [fix-spec] Case B/source audit V10: parent death no longer forces child/group death, and cleanup no longer becomes true merely because CP is dead. Cooperative child exit is a separate possible step, without assuming a stuck notification loop must terminate. Source app/utils.py parent monitor and client_runner.py notification loop require confirmation outside the stubbed trace suite.
- [mc-control] Remove artificial heartbeat/backoff occurrence limits from MC transitions; these are normal operations. Config attempt constraints and temporal reductions are audited separately before searches.

## Continuation C2 — trace regression after semantic repairs
- [regression] Repaired suite replayed 31/32 fresh traces. `wfc_stale_read_after_pop` failed because its old trace did not log whether SE:205 actually captured the record before cleanup. Fine trace debugging showed `wfcHad=FALSE`, no retained record, while the later trace required a retained-reference exception. This is missing capture evidence, not justification to permit a read before process exit.
- [fix] Add `SpWaitRead` around the actual SE:205 dictionary read in the isolated instrumented copy, with independently captured `record_present`; regenerate patch and all 32 scenarios. Validate the read argument and the full post-state. Original supplied assets and pristine product source remain untouched. Coarse compatibility microsteps are next-event/job/message constrained, and do not certify newly enabled interleavings.
- [fix-spec] SE:402-409 terminates the captured SJ handle before taking the lock to pop the process table. Added `SpTerminateRun` so an exited waiter's reference read can interleave there; the end-event trace wrapper has a constrained preparatory microstep.
- C2 fresh replay: 32/32 PASS (`output/continuation-C2-fresh-replay.json`), all scenario/integrity checks pass. Server-engine regression controls: 32 tests each pass with identical outcomes on pristine, patched-disabled and patched-noop copies (`../harness/evidence/continuation/phase3-read-hook-unit-tests/results.json`).

## Continuation C2 — model checking
- [bug] Repaired strict MC.cfg again finds the F1 TerminalStable violation, now in 13 states due to explicit scan steps (`output/continuation-C2-MC-strict.out/.json`). No product behavior was repaired.
- [mc-control] Continue Case C analysis in MC.cfg as required by the orchestration skill: replace only the known-failing TerminalStable check with `NoNovelTerminalOverwrite`; retain strict snapshot `history/continuation-C2-MC-strict.cfg` and strict seeds. Tighten KnownOverwrite to exact writer/from/to categories. This is a residual search, not proof of the original TerminalStable contract; separately target the excluded writers. All other standard and structural checks remain enabled.
- [mc-control] Remove AttemptBound from all active cfgs; do not reduce fault bounds. Remove VIEW/SYMMETRY from the temporal S5 policy probe. Safety symmetry still permutes only homogeneous clients and units; no job-order permutation. Deadlock checks remain disabled because repeated scan/tick actions are allowed and the intended progress checks are explicit temporal properties.
- [environment] C2 residual BFS aborted with `Disk quota exceeded` in /tmp after 13,576,225 generated / 2,715,832 distinct states at last progress depth 33. `output/continuation-C2-MC-disk-quota.out` is not a PASS. State directories are now under this run on the /home/ubuntu filesystem. `continuation_tlc.py` calls the same resource-budgeted durable task API, freezes each model/config and records its hashes; the MCP start signature cannot set TLC_STATE_DIR. Waiting still uses wait_tlc.

## Continuation C3 — source guard and trace validation
- [fix-spec] Case B: normal SjFinish before parent registration was enabled by the finer startup model. ServerAppRunner:82 / SE:828-846 require a nonempty participating-client response first. Added SjBootstrap and a clean-finish prerequisite. This handshake fetches parent membership; ServerRunner.run/:_execute_run does not universally wait for CJ startup, so it does not itself rule out MC-U1. Error/crash-before-registration remains possible.
- [static] Distributed multi-binder existential syntax into equivalent nested binders for the VAV analyzer; zero assignment issues. This changes no transition relation.
- [validation] All 32 refreshed traces pass on C3; `output/continuation-C3-fresh-replay.json` also contains the zero-issue VAV result. Five semantic negative controls (including a false waiter-read argument) fail TraceMatched as expected. Five malformed controls are rejected before replay. A valid finite prefix still passes raw TLC; frozen report integrity rejects its truncation (`../harness/evidence/continuation/phase3-negative-controls/results.json`).

## Continuation C4 — SJ runner prerequisite
- [fix-spec] Case B: server_commands.AbortCommand:106–118 calls abort only if FLContextKey.RUNNER exists, which is installed in FS:1143 after the parent-client handshake. A pre-bootstrap command may return an acknowledgment without stopping an SJ. Require SjBootstrap for modeled successful SjHandleAbort and any rc=0 SjFinish; early configuration exceptions still take a nonzero-error path. The previous search was deliberately stopped for this repair, not counted as a PASS (`output/continuation-C3-MC/`; last progress 110,686,841 generated / 21,144,364 distinct / depth 36).
- C4/C4b trace regressions: 32/32 PASS; all source-model changes now precede the new MC.cfg run. C4b records the final guard form. Source-only candidate headings were added to the working brief solely to preserve the reconciliation queue for the launcher's Scenario enumerator; no new code-review discovery is implied.
- [mc-control] Added strict writer/slot/stop probes with the same existing topology and fault bounds; added the named F5 KeyError seed probe. No fault bounds were reduced. These make residual exclusions independently reviewable and do not change the transition relation.

## Continuation C4 — bounded convergence and hunting entry
- MC.cfg completed its 30-minute search budget with no reported invariant violation (wrapper exit 124). Last recorded progress: depth 39, 402,950,017 generated / 72,017,658 distinct / 30,052,898 queued. Evidence: `output/continuation-C4-MC/`. The graph was not exhausted; this is bounded residual convergence alongside 32/32 fresh trace replay, not a proof of TerminalStable or unbounded correctness.
- No semantic change followed this run. Comment corrections were regenerated and checked equivalent after removing comments/whitespace (`output/continuation-C4-comment-only.json`). Strict seed checks and every hunting config follow on this behavior. Lightweight persistent-finding lookup returned no reusable records (`output/continuation-hunt-history-lookup.json`); historical source seeds remain provenance, not completed confirmation.

## Continuation H1 — strict seed fidelity and probe audit
- F1 (12 states), F2 (5), F3 (33), F5 (33), and dedicated F16-refresh (37) reproduce their named source-derived mechanisms on the repaired model. The direct F5 KeyError probe fails in 31 states. The generic F16 config instead stops at F1 (13), so it is not counted as refresh fidelity. Structured summaries, state/diff inspections and frozen source/model/config hashes are under `output/continuation-S-*/`; classifications are in `hunt-ledger.json`.
- F9's 18-state conservation failure requires EnableUnsupported/app disappearance after allocation. Case B relative to the supported-path task assumptions; preserve it as a defensive oracle control, not an eligible product finding. No normal or hunt cfg enables that branch.
- [fix-inv] Case A/source audit before its first run: NoDeletedTrackedSlot now excludes the completion thread's post-publication Remove state (JR:524–540). A deletion there does not prevent the already-successful publication or the next slot release. The probe still fails for deleted tracked jobs whose completion must publish into missing storage. This changes only a probe oracle, not behavior or the already-running configs; no constraints/fault bounds were reduced.
- [bug] MC_hunt_s2_slots.cfg: CompletionAlive fails in 38 states, independently reproducing historical MC-D/RS-7 after 4m56s BFS. A deleted job makes JR:711 fail after completion's successful publication; the runner exception path deletes running_jobs, then completion's blind `del` at :532 raises KeyError. Slot release has not occurred. Source-classified Case C, pending separate real-code confirmation (`output/continuation-H-s2_slots/`).

## Continuation C5 — source guard found while checking resource counterexample
- [fix-spec] Case B: the first NoFreeWhileGroupAlive path (25 states) let a CJ exit cleanly before an SJ runner could acknowledge SYNC_RUNNER. ClientAppRunner:71-80 sends STARTED before ClientRunner.init_run:743-778, which raises if sync never succeeds; ServerRunner:113-128 installs the responder after SJ bootstrap. Added per-client CjSyncRunner while the SJ is alive, requiring that history before a clean exit/STOPPED report. STARTED still precedes sync. A pre-sync abort can be accepted without the macro step falsely reporting STOPPED; later return/notification is separate. This finite model assumes flat client routing; it does not model hierarchical runners or the concrete sync timeout.
- The in-flight s1_status and s3_resources searches were stopped for this semantic repair and are not PASS results. Their frozen logs remain in `output/continuation-H-*/`. The first group-resource counterexample is Case B as written; a source-valid descendant path must be rediscovered after repair. The 23-state sweeper failure uses no CJ exit and remains a source-supported F7 seed awaiting final-model replay.
- [regression] Initial C5 replay: 7/32. Debugging normal_two_jobs at cursor 71 showed optional hidden sync steps could be skipped before SJ exit, creating a dead replay branch. Trace-only lookahead now requires a feasible hidden sync witness before the last SJ exit opportunity when a later logged clean CJ return needs it. The cursor does not advance in hidden steps; all logged events still validate full post-state. This is witness selection for unobserved process-edge behavior, not observed handshake evidence.
- [fix-harness] After the witness correction, 30/32 replayed. random_mix_s1/s5 still asked a fake CJ to return cleanly despite its first STARTED notification occurring after the SJ exited. Updated only the harness process stubs to select an immediate simulated sync while both are alive, and use an explicitly logged generic nonzero process exit when an unsynced fake CJ was requested to return cleanly. This is controlled process-edge failure injection, not a real SYNC_RUNNER or its 60-second timeout reproduction. All 32 scenarios are being regenerated; pre-change traces and stub source remain frozen.
- [fix-inv] Case A: PromptCancel fails in 8 states on a late CHECK processed after runner timeout. This is the documented TTL retention path, not a permanent leak. AutoCleanResourceManager:28-35/101-116 promises expiry. The same topology/fault bounds now check finite-batch ReservationDrain under MCLiveSpec's fair cleanup ticks, plus existing conservation/TTL checks; VIEW/SYMMETRY removed for temporal checking. The new temporal predicate can fail on a fair behavior retaining reservations indefinitely and is not implied by TypeOK or the safety TTL range. Immediate cancellation is explicitly not covered.
- C5 regenerated suite and integrity checks: 32/32 pass; all 32 replay on the final C5 model/Trace wrapper (`output/continuation-C5-fresh-replay.json`). The full fresh batch, reports and exact harness sources are frozen in `../harness/evidence/continuation/phase3-C5-fresh-suite/`. New MC.cfg 30-minute convergence search follows. The model's CJ notification delivery remains a selected successful-delivery schedule while CP is alive; concrete STARTED-notify timeout, STOPPED retry hangs and hierarchical sync are retained source-only coverage gaps.
- [mc-control] Added MC_hunt_startup_failure.cfg because every inherited cfg disabled the modeled ordinary SJ-launch exception. It preserves MC.cfg's topology and all bounds, raises only MaxSjLaunchFail from 0 to 1, and supplements standard checks with strict slot/completion-thread ownership checks. This changes no behavior operator or running convergence config and does not shrink the search space.

## Continuation C5 — convergence result

- [search] Required MC.cfg search completed its 30-minute budget (task baed9af9c7c048a8b58774f7c382d4a4, exit 124) without a reported invariant violation. Last progress: depth 39, 393,659,474 generated / 70,746,280 distinct / 29,716,718 queued. Frozen source/config/outputs are under output/continuation-C5-MC/. The queue is nonempty: this is bounded residual convergence under the user's authorized time-limited-search interpretation, not exhaustive verification or TerminalStable success.
- [convergence] The same C5 behavior replays all 32 current fresh traces. No model change was required by this MC.cfg run; post-repair hunting now resumes on all configurations and the eight seed fidelity checks. Known strict Case C contracts remain explicitly failing and retained in the report queue.
- [audit] Rebuilding base/MC/Trace from r0 reproduced the exact current bytes. Original-asset/conversation hash preservation and tracked source-pin/diff checks pass; evidence is in output/continuation-C5-rebuild-check.json and continuation-C5-preservation.json.

## Continuation H2 — first C5 hunting batch

- [bug] C5 s3_groups reaches a 27-state NoFreeWhileGroupAlive violation with SJ bootstrap and CJ sync before clean exit. CP frees the unit after reaping its leader while a same-group descendant still uses it (CX:626–681, ProcessAdapter.wait/terminate). Source-seeded F10, now a valid selected process-prerequisite path; real OS/contract confirmation remains separate.
- [bug] C5 s4_outcome reaches historical MC-E in 35 states: completion reads run_aborted=False, the admin then marks/acknowledges abort, and completion publishes COMPLETED using its earlier read. Original residual tested the window only at latch time. Add runAborted to this explicitly known-case residual, retaining NoStoppedSuccess as the strict probe. This is an oracle-only tolerance, not a product fix or success of the strict property.
- [fix-inv] C5 s4_groundtruth, 31 states: Case A for the unconditional ground-truth oracle. An execution-error UPDATE is not processed before the waiter's documented grace/pop, and a clean exit supplies no fallback error code. Replace the unsupported reliable-delivery demand with RecordedExecutionErrorNotMasked, whose recorded-error antecedent is assigned by the real modeled UPDATE path. Keep F17/F20 in the source-only confirmation queue; this change does not establish correct end-to-end user outcomes.
- [fix-inv] C5 s5_policy, 25 states: Case A. Losing a target during request construction makes reply count mismatch fatal (admin.py:102–105), regardless of min_sites. Remove StartFailureMatchesPolicy as N/A instead of weakening it to TRUE. Retain the same bounds and nonvacuous tracking/publication/slot checks; no min/required policy PASS is claimed.
- [trace-controls] C5 negative controls pass: five semantic corruptions violate TraceMatched, five malformed inputs reject, and a valid truncated prefix passes raw replay but fails frozen report integrity. Evidence: harness/evidence/continuation/phase3-C5-negative-controls/.

## Continuation C6 — additional source-fidelity repair

- [fix-spec] Case B source-audit correction: SE:1070–1083 builds the complete START request map before _send_admin_requests can deliver any request. The C5 per-site action incorrectly permitted a client to execute before later target lookups. Retain per-site lookup/disable interleavings but stage delivery until the request map is complete. This adds no new product assumption or reduced fault bound. The first H2 witnesses remain preserved; all final-model traces, MC.cfg convergence, seeds and hunts must now be checked on C6.
- C6 replay: 32/32; VAV: zero issues. MC.cfg completed its 30-minute budget without a reported violation (task ff5ad8ef6b014217a255c74a8f8ac51b, exit 124): depth 39, 426,068,541 generated / 75,922,236 distinct / 32,735,564 queued. Frozen output: output/continuation-C6-MC/. No exhaustive or strict-contract PASS follows. Byte-identical rebuild evidence: output/continuation-C6-rebuild-check.json.

## Continuation C7 — ordinary failed-sync progress

- [fix-spec] Case B found in the pre-hunt fairness audit: C5's clean-CJ sync prerequisite left a CJ permanently alive when its SJ had already exited and MaxCjError=0. ClientRunner:689-690/739-778 raises after the configured sync deadline; worker_process:123-130 propagates the exception. Add CjSyncTimeout for a live CP/CJ with STARTED recorded, no successful sync and an exited SJ. It projects ordinary exception cleanup and generic rc=1 independently of the injected crash budget, with reactive fairness. Existing arbitrary-error/descendant choices and every fault bound remain intact. This is a coarse deadline, not a numerical timeout theorem; stuck cleanup and typed rc variants remain separate limits.
- C7 trace regression: all 32 current fresh traces pass; VAV reports zero assignment issues (228 operators, 56 variables). The new timeout transition is source-derived and not a newly observed harness handshake or elapsed-time measurement. No harness observation changed, so the existing fresh batch remains the replay input. A new MC.cfg run is required before hunting.

- [trace-controls] C7 five semantic corruptions fail TraceMatched, five malformed inputs reject, and truncation is caught by frozen report integrity (phase3-C7-negative-controls/results.json).
- [environment] The first C7 search was interrupted by the previous session ending (task f4ba15edb18846b5831407193a03053e, SIGTERM/-15, last depth 26, 364,391 generated / 80,956 distinct / 26,657 queued). It is not a completed search. On explicit user continuation, preserved all artifacts and restarted unchanged C7/MC.cfg with its full 30-minute budget as continuation-C7-MC-resume.

- [convergence] C7 resumed MC.cfg completed its full 30-minute budget (task 516f96f2be6e4ec4bc47f19106690ca5, exit 124) without a reported invariant violation: depth 40, 419,928,659 generated / 76,111,186 distinct / 33,238,676 queued. Evidence: output/continuation-C7-MC-resume/. Together with unchanged 32/32 fresh replay this permits bounded residual hunting; the graph is not exhausted, known strict contracts still fail, and no unbounded correctness claim follows.

## Continuation H3 — final C7 hunting

- [bug] s3_groups reproduces source-seeded F10 in 28 states: complete START-map construction, SJ bootstrap, CJ STARTED/sync, leader exit/reap, then free while a descendant holds the unit. Source-classified Case C; actual supported process pattern and OS/ownership behavior remain separate confirmation obligations. Frozen evidence and full deltas: output/continuation-H3-s3_groups/.

- [bug / mc-control] First s4_unsafe run stops at F5 in 36 states, not typed-102 fidelity: ordinary failed sync gives generic rc=1 while STARTED, CP maps to 101, active fail_run removes pending, then START collection raises KeyError. The untimed model does not establish the relative 60/20-second schedule. Preserve this run, retain strict F5 probes, and continue the unchanged unsafe topology/fault bounds with existing FinalMatchesOutcomeNovel (which excludes F5). No behavior or MC.cfg check changes.

- [bug] s4_outcome fails FinalMatchesOutcomeNovel in 37 states at an accepted REPORT/expiry/latch race: active fail_run records authoritative 104 after COMPLETED was latched but before publication. Case C, distinct from post-finality ignoring and historical MC-U1. The V04 source review reopened this interaction; the specific schedule is a continuation counterexample. Added a read-only NoInactiveFailureSuccess oracle in MC_OutcomeProbes.tla and MC_hunt_u1_startup_gap.cfg to independently target MC-U1 with exactly s4_outcome bounds and unchanged MCSpec/actions. The launch helper now records/freezes that optional entry module.

- [bug] Continued s4_unsafe reaches a typed-102 stop-before-marker variant in 41 states (output/continuation-H3b-s4_unsafe/). Cleanup kills/pops the SJ before waiter read; completion expires pending and publishes success while the report is still at Mark. Case C candidate sharing stop/marker and F20 record-lifetime mechanisms. This is not RS-5 marker-no-op fidelity: that action has not executed. Retain the original RS-5 source-only confirmation obligation and actual preserved-102/timing prerequisites.

- [oracle-audit] Tightened NoInactiveFailureSuccess to require the completed job still be in running_jobs, excluding deliberate post-finality ignoring. The first focused task had already found a valid 37-state MC-U1 startup gap before its stop request arrived (normal violation exit 12, not interruption): the SJ record is gone, running insertion has not occurred, and an accepted 104 report records nothing. The state already satisfies the new guard. A fresh run on the guard follows; base/MC transitions and bounds are unchanged.

- [bug] Guarded MC-U1 probe reproduces the startup tracking gap in 37 states (output/continuation-H3b-u1_startup_gap/), retaining actual SJ bootstrap and no clean-CJ assumption. It is a historical lead rediscovery.
- [bug] s2_slots reproduces historical MC-D/RS-7 in 38 states after 11m15s: early nonzero SJ crash, terminal publication, stale deletion, failed late RUNNING write, runner removal, then completion blind-del death with the slot held. Final-model evidence: output/continuation-H3-s2_slots/.

## Continuation S2 and H3 — current-model fidelity and strict exclusions

- [seed-fidelity] All eight C7 seeds were rerun. F1=12 states, F2=5, F3=33, F5=33 and direct F5 KeyError=32; dedicated F16 refresh=37. Generic F16 again stops at F1 (13), so it is not refresh fidelity. The F5 direct path uses a STARTING generic exit remapped to 104, without a 60-second sync-deadline assumption. F9=19 states is the deliberately unsupported application-disappearance control (Case B for task reachability), not a product finding.
- [bug] C7 s2_sweeper=23 states rechecks the source-seeded live-run-map iterator failure (F7); the SJ exits with rc1 before bootstrap. probe_deleted_slot=27 states rechecks historical MC-C: stale SUBMITTED delete authorization removes a now-RUNNING stored job, leaving completion unable to publish and release admission.
- [bug] Strict writer probes independently reach historical MC-A (14 states: stale abort replaces FAILED_TO_RUN), MC-B (32: completion replaces acknowledged ABORTED), the startup exception writer (14: FAILED_TO_RUN replaces ABORTED), and deployment metadata RMW (15: stale DISPATCHED replaces ABORTED). These are retained as related evidence for the existing cancellation or metadata-update roots, not inflated into independent discoveries. Terminal-to-terminal precedence/impact is explicitly a separate confirmation question; the short variants do not establish the primary cancellation finding's post-acknowledgment launch. Public abort behavior is documented in flare_api.py:569-571.

- [bug] C7 probe_stop_success rechecks MC-E in 35 states: the running-job abort actually stops a bootstrapped SJ, but completion publishes COMPLETED before the marker write. mark_run_aborted then succeeds while tracking is still present. The final witness acknowledges after publication; the earlier C5 read/mark/latch variant remains separate historical evidence.

- [bug] C7 live_admission finds the original F4 numeric-string poison in a six-state listed temporal trace (back edge to state 2; seven distinct reachable states). Validator conversion is not persisted, scheduling raises before history/count increments, and the outer list-level catch repeats on the oldest job while a valid later job remains SUBMITTED with free capacity. No new discovery credit is claimed.
- [search] C7 s4_groundtruth and s5_policy each used the full 30-minute budget with no violation, both reaching depth 44. Their last distinct/queued counts are 29,313,388/8,558,314 and 26,255,438/8,589,400 respectively. These are incomplete searches of the revised recorded-error and structural checks, not success of the removed ground-truth/START-policy hypotheses. No shallow-search simulation is required at depth 44.

## Continuation C8 — dead-parent START timeout fidelity

- [fix-spec] Case B found during the final fairness audit: C1 retained dead CP allocation/registration state to avoid falsely killing children, but StartRepliesLost still required cst=None. A parent dying after allocate/register could therefore disable the ordinary START timeout when the early-timeout budget was zero. Source SE:1082 and admin.py:314-337 apply the request deadline regardless of remote handler state. StartRepliesLost now treats a missing reply from a dead CP as impossible to arrive, while still accepting already-queued replies. Only this predicate changed; no input/fault bound or invariant was weakened.
- [environment] Four C7 hunts were deliberately stopped for the repair: probe_cant_schedule, live_cleanup, live_finalize and s3_promptcancel. Their logs/process results are preserved as interrupted, not PASS. All completed C7 counterexamples/source analyses remain retained; the final evidence matrix will be rechecked on C8.
- [trace-validation] C8 replays all 32 unchanged fresh traces with TraceMatched and reports zero VAV issues (228 operators/56 variables). The changed predicate controls MC timeout budgeting/fairness and does not change the trace wrapper's action/state matching. Fresh corruption controls and a new full-budget MC.cfg run follow before further hunting.

- [trace-controls] C8 negative controls pass (five semantic TraceMatched failures, five malformed-input rejections, valid-prefix replay plus report-integrity rejection). Rebuilt base/MC/Trace bytes match exactly. The trace-workflow clean_traces step removed 22 generated helper files from the working spec directory after archiving exact copies/hashes under history/continuation-trace-debug-artifacts; no source traces or TLC evidence were removed.

## Continuation C8 — resumed execution

- [interrupted] The first C8 MC.cfg task ended with exit -9 before its 30-minute budget; its last progress was depth 38, 213,505,960 generated / 39,628,259 distinct / 17,503,554 queued. No PASS is inferred. Frozen artifacts and logs remain in output/continuation-C8-MC/.
- [resume] Restarted the byte-identical C8 model/configuration as continuation-C8-MC-resume for the full 30-minute budget, at aggregate 16 GiB heap + 48 GiB off-heap and 16 workers. No source analysis or completed trace checks were restarted.
- [bounded convergence] C8 MC.cfg completed its full 30-minute budget with no reported violation or TLC error: depth 39, 414,115,288 generated / 74,561,992 distinct / 32,570,191 queued. All 32 fresh traces pass on the same model. No semantic change followed replay; this satisfies the continuation's budgeted convergence criterion, not exhaustive or unbounded correctness. Evidence: output/continuation-C8-MC-resume/.

## Continuation C8 — seed fidelity and initial hunts

- [seed fidelity] All eight C8 seeds rerun and inspected: F1 12 states, F2 5, F3 33, F5 outcome 33, F5 KeyError 31, dedicated F16 refresh 37. Generic F16 stops at F1 in 13 states and does not establish refresh fidelity. F9 reaches its deliberately unsupported app-disappearance branch in 19 states; Case B/defensive control, not an eligible ordinary product defect. Evidence: output/continuation-S3-*/ and output/continuation-cases-C8-seeds.json.
- [bug] C8 s3_groups independently reaches NoFreeWhileGroupAlive in 28 states with SJ bootstrap and CJ synchronization before clean leader exit. Source-seeded F10/CL-5 candidate; supported real process-group and later-allocation controls remain for confirmation.
- [bug] C8 s4_outcome reaches FinalMatchesOutcomeNovel in 37 states: accepted active failure is recorded after completion reads its outcome but before formal latch/publication. The C7 variant recorded it after latch; both map to the same V04 finalization gap. The report now states the exact C8 ordering and retains C7 as historical related evidence.
- [bug] C8 strict probes recheck historical MC-A (14 states), MC-B (32), MC-C (27), MC-D (38), MC-E (35), deployment metadata RMW (15) and deployment-failure status overwrite (14). Terminal-only variants retain contract/precedence limits and are grouped with their primary root. Strict S1/S2 cfgs stop at F1/F2 (13/5); no PASS is inferred for their remaining checks. Full source dispositions are in hunt-ledger.json.
- [bug] C8 AdmissionProgress reproduces source-seeded F4: five listed states loop to state 1, complete finite graph 7 distinct states, depth 5. Public numeric-string submission and later-job control remain for independent confirmation.
- [bounded hunt] C8 s4_groundtruth and revised s5_policy completed full 30-minute budgets without reported violations, at depths 44/43 and 30,213,171/25,801,699 distinct states. Queues remain 8,733,877/8,485,496; neither is exhaustive. Their Case A oracle limits remain in force.

## Continuation C8 — September 27 execution resume

- [interrupted] Durable wait results confirm that live_cleanup, live_finalize, s3_promptcancel and the optional probe_cant_schedule simulation ended SIGTERM/-15 when the prior worker stopped. Their partial logs and frozen inputs are collected under output/continuation-H4-*/; none is a completed budget or PASS. The unchanged full-budget attempts use continuation-H4b-*, at four concurrent tasks of 4 GiB heap + 12 GiB off-heap and four workers each (aggregate 64 GiB / 16 workers).
- [preserved] C8 convergence, all 32 fresh trace replays and controls, eight seed checks, and 17 completed hunting configurations remain intact. Only interrupted or never-started checks resume; no completed source analysis or verification is restarted. Report selection retains every interrupted attempt in the run index while choosing the latest same-model attempt per configuration/mode for the final matrix.

- [bounded hunts] The unchanged H4b temporal runs completed their full 30-minute budgets: live_cleanup depth 42 / 4,006,867 distinct / 1,413,343 queued; live_finalize depth 39 / 4,717,707 distinct / 1,900,789 queued; s3_promptcancel depth 44 / 3,897,036 distinct / 1,459,473 queued. No reported violation or TLC/resource error. Finalization's last temporal check was in progress at cutoff; the counts are the last reported progress, and no complete temporal verdict is claimed. All three exceed depth 25, so no shallow-search simulation is required.
- [simulation] The optional unchanged CANT_SCHEDULE probe completed its full 30-minute simulation at depth limit 100: 78,016,422 checked states (including repetitions), 780,167 generated traces, no violation or TLC/resource error. BFS had reached depth 39 without a violation. Neither search refutes historical RS-3 / source Scenario 29; its source-backed confirmation obligation remains. Frozen evidence: output/continuation-H4b-sim-probe_cant_schedule/.
- [execution] Started the remaining C8 hunts, prioritizing the guarded MC-U1 startup-gap probe while s1_status, s2_slots_c2 and s3_resources run concurrently. startup_failure remains queued. This changes only execution order, not any model/configuration or budget.

- [bug] Guarded C8 u1_startup_gap rechecks historical MC-U1 in 37 states after 2m07s: bootstrapped SJ clean exit and waiter pop, successful START, accepted STARTING-client generic error (mapped 104) before running insertion, inactive fail_run return, then insertion/deadline/success publication with Resolve still pending. All action deltas and pinned callers/handlers were inspected; same source-supported Case C candidate and actual-timing/public-deployment limitations as C7. It is a historical rediscovery. The primary report now uses this C8 evidence; startup_failure occupies the freed slot, leaving no queued hunts.

- [bounded hunts] C8 s1_status, s2_slots_c2 and s3_resources completed full 30-minute budgets without reported violations or TLC/resource errors. Last depths were 39/40/43, distinct counts 29,885,311 / 28,348,605 / 23,776,496, with 13,693,983 / 11,917,928 / 8,772,449 states still queued. These are incomplete searches of the declared residual/ownership checks, not strict status/completion-thread or default-GPU proofs. No shallow-search simulation is required. startup_failure is the sole remaining active hunt.

- [bounded hunt] C8 startup_failure completed its 30-minute budget without a reported violation or TLC/resource error: depth 37, 98,823,566 generated / 19,097,576 distinct / 8,426,654 queued. Only MaxSjLaunchFail was increased from MC.cfg, zero to one; no other bound was reduced. No shallow-search simulation is required. All TLC tasks are now observed and collected.

## Result — continuation Phase 3

Bounded residual convergence completed at C8 after eight numbered continuation repair revisions: all 32 fresh traces pass, corruption/input/truncation controls pass, VAV reports zero assignment issues, and the unchanged MC.cfg completed its full 30-minute budget without a reported violation. The complete final matrix contains 25 BFS hunts, eight seed checks and one optional depth-100 simulation. Fifteen hunts and seven seeds reach source-classified Case C witnesses (including duplicates); F9 remains a Case B defensive control; ten hunts and the optional simulation used full budgets without reported violations. All no-violation BFS depths exceed 25. No search bound was reduced to obtain depth.

Bug hunting produces 13 source-classified MC candidate entries in bug-report.md, mirrored one-for-one by findings.json. They are not independently confirmed implementation bugs yet. All original/source-derived leads, MC-A–E/MC-U1, Case A policy corrections, unsupported cases and lower-priority findings remain reconciled for launcher consolidation with the 33 source-review Scenarios. Follow the configured serial GPT-5.5/xhigh confirmation, then the normal GPT-6 Astra/max repair/evolution and classification phases. The original Claude interruption and separate $180.5573146 historical spend are retained; new Codex subscription usage/API-equivalent estimates are separate. No product implementation logic was modified.

- [final checks] Report/schema consistency, all selected frozen-input hashes, 186 saved evidence-file hashes, all 32 fresh trace/report hashes, negative controls, all 33 source-review Scenario headings, source pin/tracked diff, all 35 configuration parameter comparisons, and six report/review documents' links pass. Every continuation run is collected; execution has no active or queued tasks. Evidence: output/continuation-C8-artifact-final.json, output/continuation-C8-bounds-audit.json, output/continuation-final-document-links.json and output/continuation-final-preservation.json. These checks establish artifact integrity, not independent product confirmation.
