# MC-2 investigation

## Scope and source provenance

- Repository: `https://github.com/SREGym/SREGym.git`
- Audited commit: `d9a0663e3930d90bd98122e8a852cf8d27c410ec` (`origin/main` at investigation time).
- The supplied worktree contains Specula observational tracing edits. The relevant uninstrumented `HEAD` code was also read with `git show HEAD:...`. The production behavior described below exists in `HEAD`: the request schema has only solution text, the endpoint retries after `RuntimeError`, and `Conductor.submit()` chooses the mutable current stage at acceptance.
- The finding is MC-sourced according to the supplied finding metadata, which names a violation trace. Per the task boundary, the spec and counterexample files were not opened.

## Step 1 — Code audit

### Cited sites and behavior

- `sregym/conductor/conductor_api.py:25-58`: the MCP `submit` tool accepts answer text. The supplied tracing worktree adds an observational `trace_request_id`, but it is not validated against a run or stage and does not affect acceptance when tracing is disabled. The upstream `HEAD` signature is only `submit_via_conductor(ans: str)`.
- `sregym/conductor/conductor_api.py:115-116`: `SubmitRequest` contains only `solution: str`; there is no run id, stage id, request identity, generation, or idempotency token.
- `sregym/conductor/conductor_api.py:124-159`: the HTTP endpoint checks the mutable `submission_stage` once, then retries the same request body for up to 60 seconds whenever `Conductor.submit()` raises `RuntimeError`. It does not revalidate that the request still belongs to the stage observed at entry.
- `sregym/conductor/conductor.py:491-560`: the evaluator thread finishes the current oracle, sets `_evaluating = False` at line 535, and only afterward computes `next_index` and calls `_advance_to_next_stage()` at lines 545-547. Therefore a reachable transition window has `submission_stage == "diagnosis"`, `waiting_for_agent == False`, and `_evaluating == False`.
- `sregym/conductor/conductor.py:562-621`: `Conductor.submit()` rejects while neither waiting nor evaluating, but when it later sees `waiting_for_agent == True`, it reads `stage_sequence[current_stage_index]` at line 601 and binds the supplied text to that current stage. No request-origin state is consulted.
- `sregym/conductor/conductor.py:242-279`: diagnosis evaluates the submitted text and stores it under `results["Diagnosis"]`; mitigation ignores the text and evaluates live system state, then stores `results["Mitigation"]`.
- `main.py:396-434,458-479`: the benchmark driver treats `submission_stage == "done"` as completion and publishes the contents of `conductor.results`, including the prematurely produced mitigation grade.

The uninstrumented `HEAD` has the same ordering and decisions (at its then-current lines `conductor_api.py:110-148` and `conductor.py:516-568`). The supplied tracing calls do not add lifecycle validation.

### Public call chain

1. HTTP clients call `POST /submit` (for example `clients/tierzero/driver.py:188-203`) or Stratus calls the public MCP `submit` tool (`clients/stratus/tools/submit_tool.py:58-128`).
2. `submit_solution()` / `submit_via_conductor()` perform a mutable-stage precheck and call `await _conductor.submit(solution)`.
3. `Conductor.submit()` marks the conductor busy and starts `_submit_evaluate_and_advance()` in a `ThreadPoolExecutor`.
4. The evaluator writes the stage result, clears `_evaluating`, advances `current_stage_index`, and exposes the next stage.
5. `main.py` observes `done` and serializes `conductor.results`; stage-aware clients also consume `/status` to decide whether to run mitigation.

This path is used during ordinary benchmark operation. `get_problem_stages()` defaults to the ordered `["diagnosis", "mitigation"]` sequence (`sregym/conductor/conductor.py:132-167`), and `_build_stage_sequence()` installs both stages when both oracles exist (`:170-218`).

### Concrete reachable trigger

1. A normal two-stage problem reaches `diagnosis`.
2. A diagnosis request is accepted, and its evaluator runs in the executor thread.
3. A delayed/retransmitted copy of that diagnosis request enters the public HTTP or MCP handler while the handler's precheck still observes `diagnosis`.
4. The diagnosis evaluator finishes and clears `_evaluating` before advancing the stage. In this reachable window, the delayed handler calls `Conductor.submit()`, which raises `RuntimeError` because both `waiting_for_agent` and `_evaluating` are false.
5. The handler catches the exception and sleeps before retrying the same untagged body.
6. The evaluator advances to `mitigation` and sets `waiting_for_agent = True`.
7. The handler retry calls `Conductor.submit()` again. It reads the now-current mitigation entry and accepts the stale diagnosis request as the mitigation submission.
8. The mitigation oracle runs before the agent has performed or submitted mitigation, the problem tears down, `/status` becomes `done`, and `main.py` publishes that mitigation grade.

Every state in this sequence is produced by the normal API/evaluator path; no inconsistent pre-state is required.

### Safeguards observed

- Both public handlers reject requests if their initial stage read is outside `diagnosis`/`mitigation`, but that read is not atomic with acceptance and does not bind the request to the observed stage.
- `Conductor.submit()` treats a request received while `_evaluating == True` as an already-accepted duplicate. This masks an immediate duplicate, but `_evaluating` is cleared before stage advancement, leaving the transition window above.
- Once the stale request has been accepted for mitigation, `_advance_to_next_stage()` completes teardown. Later submissions at `done` are ignored and return a completion response; they do not replace or repair the stored mitigation grade.
- `start_problem()` waits for a previous evaluation future before a new run (`sregym/conductor/conductor.py:421-429`), but that protects inter-run cleanup rather than submission origin within a run.
- No caller-side idempotency key, request generation, run id, or expected-stage value reaches the production acceptance logic.

## Step 2 — Developer-knowledge evidence

- Commit `56dec67f` / PR #630 introduced the endpoint retry loop with the comment that it handles a previous stage still being evaluated. It retries the original body without carrying the stage observed at entry.
- Commit `f2276f3e` / PR #694 added `_evaluating` to “track when evaluating to avoid race conditions.” Its guard recognizes requests only while the oracle is actively evaluating; the commit clears `_evaluating` before advancing the stage. The PR body says it fixes race conditions seen with an external agent but does not describe stale cross-stage acceptance.
- Issue #650, “`submit()` being called when conductor is not waiting for a submission,” reports repeated same-stage mitigation calls associated with Stratus force submission. Its discussion attributes the behavior to force submission and closes it via the Stratus remake (PR #664). It does not report a diagnosis-origin request being graded as mitigation.
- Issue #688 reports a different race: Stratus sampled `/status` once while diagnosis evaluation was still running and skipped mitigation when it still saw `diagnosis`. The requested remedy was caller polling. Current Stratus code now polls for the post-diagnosis stage (`clients/stratus/stratus_agent/driver/driver.py:807-829`). This is evidence that developers intend a distinct mitigation phase after diagnosis.
- Commit `9222650b` / PR #708 deliberately stores the diagnosis submission in `Diagnosis.submission` so the text used for the diagnosis judge is auditable in result CSVs. This reinforces stage-specific grading intent.
- TierZero explicitly sends diagnosis text, waits for `mitigation`, performs a separate mitigation interaction, and then sends a distinct mitigation signal (`clients/tierzero/driver.py:311-355`). If `/status` is already `done`, it skips mitigation (`:317-327`).
- The closest supplied scenario test, `tests/specula/test_trace_scenarios.py:596-617`, exercises an immediate transport duplicate while `_evaluating` is true and asserts only that diagnosis eventually advances to mitigation. It does not exercise the post-evaluation/pre-advance retry window or assert origin-stage matching.
- No comment, documentation, or test was found stating that a diagnosis-origin retry may intentionally satisfy the mitigation submission.

## Step 3 — Known status and precedent search

Searches covered:

- upstream open and closed issues, including titles and bodies;
- upstream open PRs and recently closed/merged PRs through 2026-07-27;
- local all-refs git history and commit messages for `submit`, `submission`, `duplicate`, `idempotency`, `retry`, `race`, and `stage`;
- blame and patch history for both affected files.

Closest precedents rechecked:

- Issue #650 / PR #664: duplicate/force-submit activity during an already-running mitigation evaluation, handled in the Stratus caller; no cross-stage acceptance.
- Issue #688: a one-shot `/status` consumer race that skips mitigation; different mechanism and site.
- PR #694: adds an in-flight duplicate guard at the affected conductor site, but neither its report nor patch identifies the surviving transition-window retry or an origin-stage mismatch.
- PR #565 / issue #244: asynchronous submission response/cleanup latency; no duplicate or stage-origin correlation.
- PR #708: diagnosis-result audit storage; no lifecycle token or duplicate handling.
- Recent issues #919 and #920 are benchmark result submissions, not defect reports.

No upstream issue, PR (open, closed, or recently merged), CVE, or advisory found in the searched tracker/history reports the same mechanism at the same sites: a delayed diagnosis request surviving the endpoint retry loop and being accepted/graded as mitigation. Known status recorded for Phase 2: `Novelty: NEW`.

No Phase 1 verdict is made here.
