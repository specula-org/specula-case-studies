# MC-1 investigation

## Scope and provenance

- Finding: `MC-1`, invariant `NoEvaluationDuringTeardown`.
- Supplied counterexample:
  `/users/Pial/Specula/runs/sregym-vm-codex-gpt56-sol-max-20260727/sregym/.specula-output/spec/output/MC_hunt_scenario1_bfs.out`.
- Source checkout HEAD: `d9a0663e3930d90bd98122e8a852cf8d27c410ec`
  (`Add cfs_cpu_throttling_hotel_reservation problem (#807)`, 2026-07-26).
- The checkout already contains uncommitted Specula tracing instrumentation in
  the cited files. `git diff` shows that the instrumentation records lifecycle
  actions but does not add a shared submission/teardown fence. In particular,
  the added `tla_trace.boundary_lock()` encloses only future creation and trace
  recording in `Conductor.submit()`; teardown does not acquire it. The
  underlying lifecycle checks and mutations described below are present at
  HEAD as well.

## Step 1: code audit

### Cited sites and call chain

1. `main.py:183-205` defines `driver_loop()`, the benchmark entry that deploys
   problems and waits for HTTP grading.
2. The normal public submission path is
   `POST /submit` at `sregym/conductor/conductor_api.py:119-145`, which checks
   that the stage is `diagnosis` or `mitigation`, then awaits
   `Conductor.submit()`.
3. `sregym/conductor/conductor.py:562-621` independently checks
   `submission_stage`, `waiting_for_agent`, and `_evaluating`, changes the
   admission fields at lines 603-605, and creates/stores `_submit_future` at
   lines 615-619. There is no lock shared with teardown around the initial
   lifecycle checks, the admission-field mutations, and teardown admission
   closure.
4. The future runs `_submit_evaluate_and_advance()` at
   `sregym/conductor/conductor.py:491-560`. Evaluation calls the real stage
   oracle at lines 518-520 and, after it finishes, advances the shared stage at
   lines 545-549.
5. Agent timeout handling in `main.py:397-403` kills the agent and immediately
   calls `finish_after_agent_timeout()` without joining any admitted evaluation.
   `sregym/conductor/conductor.py:402-408` records timeout fields and enters the
   normal teardown path.
6. Process-exit handling in `main.py:411-430` takes a one-time snapshot of the
   current `_submit_future`; it waits only when that particular snapshot is
   non-null and unfinished, then calls `_finish_problem()`. A request admitted
   after the snapshot is not joined.
7. `_finish_problem()` at
   `sregym/conductor/conductor.py:376-400` separately checks
   `submission_stage`, writes `tearing_down`, then synchronously invokes
   `_cleanup_sync()`. `_cleanup_sync()` recovers the fault and calls
   `problem.app.cleanup()` at lines 347-357 before setting the stage to `done`
   at lines 371-374.
8. The driver reads and publishes the run result after leaving the wait loop:
   `main.py:434` reports `conductor.results`; `main.py:458-467` copies the
   results into a snapshot; `main.py:475-498` publishes/writes that snapshot.
   Those reads do not join a future admitted after the earlier exit snapshot.

### Reachability and supplied trace

The counterexample is a real TLC violation, not a no-violation review result:
line 36 reports `Invariant NoEvaluationDuringTeardown is violated`.

The relevant admissible trace suffix is:

- State 9 (`<Unbounded line 201...>`): run 1 is at `diagnosis` and
  `waitingForAgent = TRUE`.
- State 10 (`MCSendSubmission(req1)`): the request is queued while the conductor
  remains at `diagnosis`.
- State 11 (`MCAgentTimeout`): timeout fires and driver cleanup is requested,
  but has not yet changed the conductor stage.
- State 12 (`MCAgentExit`): agent-exit handling starts.
- State 13 (`<Unbounded line 219...>`): driver exit handling has performed its
  evaluation-future check (`cleanupState.driver = "checked"`) while
  `evalInFlight = FALSE`.
- States 14-15 (`MCNext`): the previously queued request is received and
  accepted; `evalInFlight = TRUE`, `evalPhase = "accepted"`, and the stage is
  still `diagnosis`.
- State 16 (`<Unbounded line 221...>`): driver teardown changes the stage to
  `tearing_down` while `evalInFlight = TRUE`, producing the invariant
  violation.

This maps to a normal API/timing sequence: an HTTP request can already be
queued while agent cleanup and process polling run; neither the API-stage
check nor the process-exit future snapshot reserves/closes admission. Slow
oracle evaluation is also normal: the code deliberately runs it in an
executor and immediately acknowledges the submitter.

### Safeguards found

- Both the HTTP route (`conductor_api.py:124-134`) and
  `Conductor.submit()` (`conductor.py:569-581`) reject a request after the
  stage has visibly become `tearing_down` or `done`.
- `waiting_for_agent` and `_evaluating` reject/identify duplicate submissions
  (`conductor.py:587-605`).
- The process-exit path waits for the single future it observes
  (`main.py:411-427`).
- `start_problem()` waits for the current future before deploying a later
  problem (`conductor.py:421-429`).
- `_finish_problem()` is idempotent with respect to `done` and
  `tearing_down` (`conductor.py:389-395`).

None of these operations atomically closes admission and joins every request
admitted before closure. The exit wait is a snapshot, and the timeout path has
no evaluation join. Stage advancement after evaluation can also write a later
stage after driver cleanup has already written `done`.

## Step 2: developer-knowledge evidence

- PR #565, merged 2026-02-20, explicitly changed submission to return without
  waiting for slow fault recovery/teardown and introduced the `tearing_down`
  stage: https://github.com/SREGym/SREGym/pull/565. This establishes that an
  asynchronous response is deliberate, while its description does not discuss
  concurrent driver timeout/exit admission.
- Issue #674 and PR #679 reported and fixed a different lifecycle race:
  cleanup of one run overlapping deployment of the next. The fix snapshots
  `self.problem`, makes cleanup synchronous inside the evaluation future, and
  makes `start_problem()` await that future:
  https://github.com/SREGym/SREGym/issues/674 and
  https://github.com/SREGym/SREGym/pull/679. The issue comments explicitly
  describe the protected boundary as cleanup versus `start_problem()`.
- Issue #688 reports that a client can observe `diagnosis` while its
  background evaluation is still running. Maintainers state that the agent
  should poll for stage advancement rather than make submission synchronous:
  https://github.com/SREGym/SREGym/issues/688. This is evidence that slow,
  in-flight evaluation after an acknowledged submission is expected.
- Issue #704 reports teardown while a mitigation *agent* was still retrying,
  and its comments propose coordinating agent completion; it was closed as
  fixed by PR #705:
  https://github.com/SREGym/SREGym/issues/704. Its reported overlap is agent
  lifetime versus evaluator-owned cleanup after evaluation, not driver cleanup
  versus an evaluation admitted after the driver's future snapshot.
- Issue #650 concerns repeated duplicate submit calls while an existing
  mitigation evaluation is running:
  https://github.com/SREGym/SREGym/issues/650. It does not report the
  admission/teardown boundary.
- Issue #857 concerns orphaned child processes submitting into later runs:
  https://github.com/SREGym/SREGym/issues/857. Its cause is process-tree
  cleanup rather than the shared Conductor admission state.
- `git blame` attributes the process-exit future snapshot in `main.py` and the
  loop-independent future creation in `Conductor.submit()` to commit
  `086d6e167` (PR #673), while the timeout teardown call is from
  `1e1afc387`. The comments at `conductor.py:607-614` promise only that a
  subsequent `start_problem()` can await the stored future.
- No tracked test under `tests/` exercises submission admission concurrently
  with timeout/process-exit cleanup. The only tracked conductor-named test is
  specific to Calico cleanup.

## Step 3: known-status and precedent search

Searches covered open and closed upstream issues/PRs using the terms
`cleanup evaluation`, `teardown submission`, `"agent timeout" cleanup`,
`"evaluation" "agent exit"`, and `"submission" "race" conductor`. The nearby
reports above were re-checked for mechanism and site; none reports driver
timeout/exit taking a future snapshot while a queued API request can be
admitted before teardown closes submissions.

Recently merged and closed PRs from 2026-07-20 through 2026-07-27 were also
enumerated. The five results were #942, #935, #901, #807, and #791; none
changes or reports this lifecycle boundary. Local `origin/main` is at the
2026-07-26 commit used by this checkout.

Known-status evidence: `Novelty: NEW` — no upstream issue or open, closed, or
recently merged PR was found for this same admission/teardown mechanism at
these sites. The similar historical reports are precedents at different
boundaries, not duplicates.

## Reproduction design carried into Phase 2

Exercise the real `Conductor.start_problem()`, submission endpoint function,
executor evaluation, timeout cleanup, stage advancement, and status endpoint
function. Replace only unavailable Kubernetes/application collaborators with
deterministic test doubles and use timing gates to realize the supplied
request-queued → timeout/exit snapshot → admission → teardown order. Assert
caller-visible consequences rather than merely observing overlap:

1. cleanup runs while the admitted evaluation is blocked;
2. the driver's post-timeout result snapshot omits the later grade; and
3. after evaluation finishes, `/status` reports the next stage even though the
   application was already undeployed.

