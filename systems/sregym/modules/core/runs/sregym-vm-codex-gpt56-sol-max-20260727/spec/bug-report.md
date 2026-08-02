# Bug Report — sregym

## Summary

- Scenarios tested: 4
- Bugs found: 4
- Configs run: `MC_hunt_scenario1.cfg`, `MC_hunt_scenario2.cfg`, `MC_hunt_scenario3.cfg`, `MC_hunt_scenario4.cfg`
- Convergence: all 4 implementation traces passed, followed by a complete `MC.cfg` BFS with 176,411 generated states, 69,450 distinct states, and diameter 59
- Hunting strategy: each BFS had a 30-minute cap and terminated early with an invariant violation, so no simulation follow-up was required

| Scenario | Generated States | Distinct States | Queue at Violation | Diameter | Result |
|----------|-----------------:|----------------:|-------------------:|---------:|--------|
| 1 | 617 | 366 | 95 | 19 | `NoEvaluationDuringTeardown` violated |
| 2 | 6,666 | 2,834 | 651 | 30 | `SubmissionOriginMatches` violated |
| 3 | 660 | 461 | 96 | 18 | `BaselineMatchesCluster` violated |
| 4 | 50 | 39 | 0 | 15 | `FaultBeforeDiagnosis` violated |

## Bug 1: Cleanup Can Start While Submission Evaluation Is In Flight

- **Scenario**: 1 — Evaluation and teardown have no common completion fence
- **Severity**: High
- **Invariant violated**: `NoEvaluationDuringTeardown`
- **Config**: `MC_hunt_scenario1.cfg`
- **Counterexample**: 16 states, `spec/output/MC_hunt_scenario1_bfs.out`

### Trace Summary

1. A run captures its baseline, deploys, injects the fault, and enters diagnosis.
2. Request `req1` is sent, but the driver observes an agent timeout and process exit before the API accepts it. The driver checks cleanup eligibility while no evaluation future is visible.
3. Before the driver changes the stage to `tearing_down`, the API receives and accepts `req1`, creating a diagnosis evaluation future.
4. The driver then begins teardown while `evalInFlight = TRUE`, violating `NoEvaluationDuringTeardown`.

### Root Cause

Timeout cleanup immediately calls `_finish_problem`, and the process-exit path only takes a non-atomic snapshot of `_submit_future`. The API thread can admit a request after that snapshot. `_finish_problem` itself uses an unsynchronized check-then-set on `submission_stage`, while `Conductor.submit` separately checks the same lifecycle state, marks evaluation active, and creates the executor future. There is therefore no common admission/teardown fence, allowing cleanup to recover the fault and remove the application while the evaluator still reads or mutates the run and its results.

### Affected Code

- `main.py:397`: timeout cleanup starts without awaiting or cancelling a concurrently admitted submission.
- `main.py:411`: process-exit handling snapshots `_submit_future` before calling cleanup, leaving a time-of-check/time-of-use window.
- `sregym/conductor/conductor.py:387`: `_finish_problem` checks and changes `submission_stage` without synchronization with submission admission.
- `sregym/conductor/conductor.py:576`: `submit` performs its lifecycle checks independently from teardown.
- `sregym/conductor/conductor.py:603`: submission acceptance mutates waiting/evaluation state before creating the executor future.

### Recommendation

Introduce one lifecycle lock or state machine that atomically closes submission admission before teardown begins. Under that same fence, record every admitted evaluation future; teardown must then await or explicitly cancel and join those futures before fault recovery, undeployment, reconciliation, or result publication.

---

## Bug 2: Delayed Duplicate Submission Is Graded in the Next Stage

- **Scenario**: 2 — Submission acknowledgments are not correlated to run or stage
- **Severity**: Medium
- **Invariant violated**: `SubmissionOriginMatches`
- **Config**: `MC_hunt_scenario2.cfg`
- **Counterexample**: 27 states, `spec/output/MC_hunt_scenario2_bfs.out`

### Trace Summary

1. Request `req1` originates in diagnosis and is duplicated in transport. The first copy is received and accepted for diagnosis.
2. The API receives the duplicate while diagnosis evaluation is active. The evaluator thread can continue independently after the endpoint's stage precheck.
3. Diagnosis finishes and the conductor advances to mitigation.
4. The stale copy of `req1` is then accepted as the mitigation submission even though its modeled origin remains diagnosis, violating `SubmissionOriginMatches`.

### Root Cause

The production request contains only solution text; it carries no run generation, stage, request ID, or idempotency key. Both endpoint prechecks and their retry behavior are based on mutable current state, and `Conductor.submit` binds the request to whichever stage is current when it finally accepts it. Because evaluation runs in a separate executor thread, that thread can advance the stage between endpoint receipt/precheck and conductor acceptance even though the API coroutine itself has no suspension point. A delayed or duplicate request can therefore receive a generic success while being graded as work for another stage.

### Affected Code

- `sregym/conductor/conductor_api.py:25`: the MCP submission accepts only answer text and has no lifecycle provenance.
- `sregym/conductor/conductor_api.py:115`: the HTTP `SubmitRequest` schema contains only `solution`.
- `sregym/conductor/conductor_api.py:124`: the endpoint validates only the conductor's mutable current stage.
- `sregym/conductor/conductor_api.py:139`: retries can outlive the state observed by the endpoint precheck.
- `sregym/conductor/conductor.py:601`: acceptance selects the current stage without validating request origin or identity.

### Recommendation

Issue an opaque run/stage token and idempotency key with each submission opportunity, require clients to return them, and validate them atomically with acceptance. Abort retries when the token no longer matches the current run and stage, and return the conductor's actual duplicate/stale status instead of replacing it with generic success.

---

## Bug 3: Persisted Baseline Is Reused Across Cluster Replacement

- **Scenario**: 3 — Crash/restart reconciliation trusts an unversioned baseline
- **Severity**: High
- **Invariant violated**: `BaselineMatchesCluster`
- **Config**: `MC_hunt_scenario3.cfg`
- **Counterexample**: 11 states, `spec/output/MC_hunt_scenario3_bfs.out`

### Trace Summary

1. Cluster generation 0 is observed completely and persisted as the authoritative baseline.
2. The SREGym process crashes, clearing its in-memory baseline, and the underlying cluster is replaced with generation 1.
3. The process restarts and starts another problem.
4. It loads the generation-0 cache and marks it complete and authoritative for generation 1, violating `BaselineMatchesCluster`.

### Root Cause

All clusters share one home-directory cache path. The serialized baseline contains resource collections but no cluster identity, generation, server fingerprint, schema version, or completeness metadata, and deserialization defaults missing fields to empty values. `deploy_app` trusts any successfully parsed file and suppresses fresh capture for the lifetime of the conductor. Later reconciliation computes current-minus-stale-baseline and deletes those resources, so legitimate resources belonging to a replacement cluster can be treated as benchmark residue.

### Affected Code

- `sregym/paths.py:16`: every cluster uses the fixed `cluster_baseline_state.json` cache path.
- `sregym/service/cluster_state.py:83`: baseline serialization omits provenance, version, and completeness metadata.
- `sregym/service/cluster_state.py:100`: deserialization accepts missing collections as empty.
- `sregym/service/cluster_state.py:183`: load accepts any existing parseable cache without validating the current cluster.
- `sregym/conductor/conductor.py:841`: deployment treats a loaded cache as authoritative and skips recapture.
- `sregym/service/cluster_state.py:227`: reconciliation deletes current resources absent from that baseline.

### Recommendation

Persist an atomic, versioned envelope containing a stable cluster identity and capture-completeness marker. Validate all metadata against the live API server before use; on mismatch, partial capture, or unknown schema, quarantine the cache and recapture rather than reconciling. Prefer a cache namespace derived from the cluster identity and fail closed if a complete baseline cannot be established.

---

## Bug 4: Pod Restart Temporarily Removes the Fault During Diagnosis

- **Scenario**: 4 — Stop/noise and Khaos reattachment do not establish quiescence
- **Severity**: High
- **Invariant violated**: `FaultBeforeDiagnosis`
- **Config**: `MC_hunt_scenario4.cfg`
- **Counterexample**: 10 states, `spec/output/MC_hunt_scenario4_bfs.out`

### Trace Summary

1. The run deploys, injects its Khaos eBPF fault, and starts the reinjection monitor.
2. The conductor exposes diagnosis while the fault is effective.
3. The affected pod restarts. Its new container has a new host PID, so the pinned fault disappears and the workload becomes healthy.
4. Diagnosis remains submission-ready while reattachment is merely pending, violating `FaultBeforeDiagnosis`.

### Root Cause

The implementation explicitly acknowledges that each eBPF probe is pinned to a host PID and must be recreated after a container restart. The background monitor polls, then resolves the new PID and performs reinjection; its loop sleeps for up to five seconds between checks, PID lookup may take additional seconds, and failures are deferred to a later iteration. The conductor advances to diagnosis immediately after initial injection and has no gate that pauses diagnosis when the monitored container generation changes. Agents can therefore observe or submit against a healthy interval even though the benchmark claims the fault is active.

### Affected Code

- `sregym/conductor/problems/khaos_faults.py:140`: reinjection is performed by an asynchronous polling loop.
- `sregym/conductor/problems/khaos_faults.py:147`: the monitor waits up to five seconds between checks.
- `sregym/conductor/problems/khaos_faults.py:174`: a new container triggers asynchronous PID resolution and reinjection.
- `sregym/conductor/problems/khaos_faults.py:178`: restart is observed before the new fault is attached.
- `sregym/conductor/conductor.py:298`: the conductor advances to the first stage after initial injection without a continuing effectiveness barrier.

### Recommendation

Track fault effectiveness by target container generation and make diagnosis readiness conditional on all targets being attached for the current generation. On restart, atomically pause or invalidate the stage, synchronously reattach (with bounded failure handling), and reopen diagnosis only after verification that the intended fault is effective; otherwise fail the run rather than grading a healthy window.

---

## Not Reproduced

| Scenario | Config | States Explored | Result |
|----------|--------|-----------------|--------|
| None | — | — | Every configured scenario reproduced an invariant violation |

## Spec Adjustments During Hunting

- Scenario 2 initially allowed multiple zero-retry API handlers to accumulate before any called the no-suspension `Conductor.submit` coroutine. The single API event loop prevents that precondition, so `ReceiveSubmission` was constrained to require older received handlers to have yielded through retry. All implementation traces and the main model were rerun to convergence before hunting resumed; the final counterexample instead uses the real API-thread/evaluator-thread stage race described above.
