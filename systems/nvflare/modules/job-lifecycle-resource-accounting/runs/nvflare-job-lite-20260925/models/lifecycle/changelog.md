# Lifecycle model changelog (models/lifecycle)

Model fixes, property fixes, fault/timing assumptions and counterexamples are kept separate.

## Model versions
- v0 (initial draft, not checked): single START slot per client, heartbeat-missing guard `stReq[c] # j`,
  deploy/start faults not separable. Replaced before any TLC run (fidelity review):
  - [model] START requests per client are a set (late START for an older job must not be overwritten).
  - [model] HeartbeatMissing no longer excludes a job whose START is in flight (an unregistered job is not
    reported by the client heartbeat either; client_executor.py:694-696, communicator.py:595).
  - [model] split RunnerDeploy/RunnerClientDeployFail and RunnerCollectStart/RunnerCollectStartTimeout so faults
    can be bounded in MC.
- v1 (base.tla until abortLive): checked in mc_1/mc_2, hunt_abort_1, hunt_delete_1, variants, hunt_overlap_1/2,
  mc_assume_1c_1. Copy: output/base_v1_before_abortLive.tla.
- v2: adds history variable `abortLive` and invariant AbortOfLiveRunEndsAborted (property fix below).

## Property fixes
- [property, Case A] AckedRunAbortEndsAborted (v1) was too strong: hunt_overlap_2 shows an abort that arrives
  after the SJ already exited normally and after the completion loop cached COMPLETED; reporting COMPLETED is
  reasonable (the run had finished). Kept in base.tla for the record, no longer enabled.
  Replaced by AbortOfLiveRunEndsAborted (v2): only aborts that actually stopped a live SJ (stop_run while the job
  was in run_processes) and were acknowledged by mark_run_aborted must end ABORTED. Still falsifiable
  (hunt_overlap_3 violates it).

## Fault / timing assumptions (explicit, not code guards)
- AssumePromptRunningWrite (MC.tla): job_runner.py:711 set_status(RUNNING) completes before the completion loop
  classifies the same job. Only in *_assume*.cfg / overlap hunts, to look past MC-4a.
- AssumePromptAbortMark (MC.tla): mark_run_aborted runs before the completion loop classifies the aborted job.
  Only in *_assume2 / 2jobs / sim configs, to look past MC-4b.
- AbortOnlyRunning (MC constant): scenario restriction used to look past MC-1 in overlap hunts.

## Counterexamples (candidate implementation defects)
- MC-4a (mc_2.log, TerminalStatusStable): addRun -> SJ exit -> completion publishes COMPLETED -> runner
  set_status(RUNNING) overwrites the terminal status. Needs the runner to stall between job_runner.py:710 and 711
  for longer than the completion loop's archive+publish; narrow.
- MC-1 (hunt_abort_1.log AbortHonored; hunt_abort_AbortedNotLaunched_1.log; hunt_abort_AbortFromDispatchedHonored_1.log):
  admin abort of a SUBMITTED/DISPATCHED job is acknowledged, then the runner's unconditional
  set_status(DISPATCHED)/update_meta write-back/set_status(RUNNING) overwrites FINISHED:ABORTED and the SJ is launched.
- MC-2 (hunt_delete_1.log RunnerAlive; hunt_delete_noscan_1.log; hunt_delete_noscan_nostat1_1.log):
  deleting a queued job makes JobRunner.run exit via (a) scan list->get_meta StorageException,
  (b) _check_job_status on a deleted job (None.meta AttributeError), (c) set_status(FAILED_TO_RUN) raising inside
  the except block.
- MC-4b (hunt_overlap_3.log AbortOfLiveRunEndsAborted): stop_run aborts a live SJ; SJ exits 0; completion caches
  COMPLETED before mark_run_aborted sets run_aborted; job ends COMPLETED despite the acknowledged abort. Requires no
  pending client outcomes and a millisecond window.

## Clean runs (finite, recorded bounds)
- mc_assume_1c_1: Jobs {j1,j2}, Clients {c1}, MaxJobs 1, all faults <=1, no admin; AssumePromptRunningWrite.
  644,171 distinct states, depth 49, no error. (AckedRunAbortEndsAborted vacuous: no aborts.)
- hunt_overlap_assume2_1: Jobs {j1}, Clients {c1,c2}, faults cdf/se/st/sef/cef/rl/od <=1, running-only aborts;
  AssumeBoth. 269,871 distinct states, depth 35, no error.
- mc_assume_2jobs_1: Jobs {j1,j2}, Clients {c1}, MaxJobs 2, all faults <=1, running-only aborts; AssumeBoth.
  49,563,357 distinct states, depth 55, no error.
- mc_assume_1 (2x2, all faults, AssumePromptRunningWrite): stopped manually at 91M distinct states (depth 44);
  incomplete, no violation seen before interruption.
- sim_2x2_1 (MC_sim_2x2.cfg): Jobs {j1,j2}, Clients {c1,c2}, MaxJobs 2, all faults <= 1, running-only aborts, no deletes,
  AssumeBoth; random simulation, depth <= 120, 8 workers. Interrupted manually (exit 143) after 13,553,151 traces /
  1,722,856,644 states checked; no violation. Bounded, incomplete campaign.

## Real-system cross-check of the timing assumptions
- AssumePromptRunningWrite and AssumePromptAbortMark are NOT implementation guarantees: repro/test_bug3_running_overwrite.py
  and repro/test_mc4b_abort_vs_completion.py reproduce MC-4a and MC-4b on the real POC when a delay is inserted at the
  exact window (repro/l3_src.patch). They were used only to explore past those candidates.
