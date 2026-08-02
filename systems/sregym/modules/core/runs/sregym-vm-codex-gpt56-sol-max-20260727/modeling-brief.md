# SREGym Modeling Brief

## 1. System Overview

SREGym is a Python Kubernetes fault-injection benchmark (79,397 Python LOC; 5,897 LOC in the selected lifecycle/control core) at revision `d9a0663e3930d90bd98122e8a852cf8d27c410ec`.
It is **Category A (Distributed / Message-Passing)** because its correctness depends on HTTP/MCP requests, Kubernetes API and `kubectl` effects, persisted cluster state, and independently progressing agent, evaluator, noise, and control-plane actors.
It is not a BFT or consensus system; the protocol to model is the benchmark run lifecycle: deploy, inject, accept one diagnosis and one mitigation submission, grade, recover, and isolate the next run.
The reference paper describes a coordinated run with exactly two submissions, while the implementation uses a driver thread, API thread, per-submission executor, agent process/container, and optional noise thread.
Kubernetes and shell operations are long-running, fallible messages rather than atomic local calls.
The implementation also adds persisted baseline reconciliation, asynchronous acknowledgments, an API-filtering proxy, and temporal state-based oracles beyond the paper's abstract four-tuple problem definition.

## 2. Scenarios

### Scenario 1: Evaluation and teardown have no common completion fence

**Mechanism**: Timeout, process-exit, evaluator, and teardown paths can concurrently change one run's stage and environment without a generation-tagged, atomic completion barrier.

**Evidence**:
- Historical: [#408](https://github.com/SREGym/SREGym/issues/408), [#410](https://github.com/SREGym/SREGym/issues/410), and [#674](https://github.com/SREGym/SREGym/issues/674) document earlier premature-`done` and cleanup/next-run races; commits `b56d743b` and `562acb79` fixed those particular paths.
- Code analysis: timeout immediately invokes teardown without awaiting or cancelling `_submit_future` (`main.py:393-404`); process exit waits at most 300 seconds, then tears down anyway (`main.py:406-425`).
- Code analysis: the evaluator unconditionally clears `_evaluating`, advances the stage, and may restart noise after evaluation (`sregym/conductor/conductor.py:468-514`), even if another actor already completed teardown.
- Code analysis: `_finish_problem` uses an unsynchronized check-then-set guard (`sregym/conductor/conductor.py:367-385`), while the driver can snapshot `results` concurrently (`main.py:428-463`).

**Affected code paths**: `driver_loop`, `Conductor.submit`, `_submit_evaluate_and_advance`, `_advance_to_next_stage`, `_finish_problem`, `_cleanup_sync`, `start_problem`.

**Suggested modeling approach**:
- Variables: `runGen`, `stage`, `evalInFlight`, `evalRun`, `evalStage`, `timeoutFired`, `cleanupState`, `resultsVersion`, `noiseEpoch`.
- Actions: split `AcceptSubmission`, `BeginEvaluation`, `CompleteEvaluation`, `AgentTimeout`, `AgentExit`, `BeginCleanup`, `CompleteCleanup`, and `StartNextRun`.
- Granularity: evaluation and cleanup must be multi-step actions; allow timeout/exit between their begin and complete steps.

**Priority**: High  
**Rationale**: The current timeout path admits a concrete teardown-during-evaluation interleaving, and the same mechanism has repeatedly caused high-impact historical races.

### Scenario 2: Submission acknowledgments are not correlated to run or stage

**Mechanism**: A submission contains only solution text, so retries, duplicates, and delayed requests are interpreted against mutable current state rather than their originating run and stage.

**Evidence**:
- Historical: [#650](https://github.com/SREGym/SREGym/issues/650), [#688](https://github.com/SREGym/SREGym/issues/688), and [#704](https://github.com/SREGym/SREGym/issues/704) show duplicate submission, stage-sampling, and completion-ownership failures; their specific client paths are fixed.
- Code analysis: both HTTP and MCP request schemas omit run, stage, generation, and request ID (`sregym/conductor/conductor_api.py:23-53,110-148`).
- Code analysis: an in-flight duplicate is acknowledged as already accepted and discarded (`sregym/conductor/conductor.py:537-548`), but both endpoints replace that result with a generic “Submission received” success.
- Code analysis: endpoint retry loops can outlive the state observed by the initial precheck (`sregym/conductor/conductor_api.py:33-51,116-145`).
- Compensating mechanism: current TierZero and Stratus drivers poll for the exact next stage; this reduces, but does not define, safety for other HTTP/MCP clients (`clients/tierzero/driver.py:307-323`; `clients/stratus/stratus_agent/driver/driver.py:807-817`).

**Affected code paths**: `SubmitRequest`, `submit_solution`, `submit_via_conductor`, `Conductor.submit`, client stage polling.

**Suggested modeling approach**:
- Variables: `submissionQueue`, `acceptedByStage`, `requestStatus`; each abstract message records `originRun`, `originStage`, and `requestId`.
- Actions: `SendSubmission`, `DelayOrDuplicate`, `ReceiveSubmission`, `Acknowledge`, `AdvanceStage`, and `RetrySubmission`.
- Granularity: separate receipt, acceptance, grading, and acknowledgment; compare an ideal tagged protocol with the implemented untagged projection.

**Priority**: Medium  
**Rationale**: It can silently lose a required mitigation or bind stale work to a new stage, but disciplined stock clients partially contain the exposure.

### Scenario 3: Crash/restart reconciliation trusts an unversioned, possibly partial baseline

**Mechanism**: A process-global cache snapshot is treated as authoritative across cluster lifetimes, while capture can record partial observations and reconciliation is asymmetric.

**Evidence**:
- Historical: [#460](https://github.com/SREGym/SREGym/issues/460) established that per-problem recovery cannot restore arbitrary agent changes; commits `8181d966` and `74f9fef4` added baseline reconciliation and persistence but not full restoration.
- Historical: [#64](https://github.com/SREGym/SREGym/issues/64) concerns abnormal-exit residue; current shutdown stops agents/noise but does not invoke conductor recovery/reconciliation (`main.py:537-563,630-652`).
- Code analysis: the fixed home-directory path contains no cluster identity, schema version, or capture completeness metadata (`sregym/paths.py:11-16`; `sregym/service/cluster_state.py:48-113`).
- Code analysis: each list helper converts `ApiException` into an empty collection, so a transient read failure becomes valid persisted baseline state (`sregym/service/cluster_state.py:130-163,352-395,451-511`).
- Code analysis: load accepts omitted fields as empty and reuses the file indefinitely (`sregym/service/cluster_state.py:98-113,165-182`; `sregym/conductor/conductor.py:787-796`).
- Code analysis: reconciliation deletes current-minus-baseline objects but does not recreate deleted baseline objects or restore arbitrary edits (`sregym/service/cluster_state.py:184-350`).

**Affected code paths**: `deploy_app`, `capture_baseline`, `save_baseline_state`, `load_baseline_state`, `reconcile_to_baseline`, abnormal shutdown.

**Suggested modeling approach**:
- Variables: `clusterGen`, `baselineGen`, `baselineComplete`, `observedFields`, `preexisting`, `runCreated`, `clusterResources`, `persistedBaseline`, `deleteIssued`.
- Actions: split per-field `ObserveBaseline`, `PersistBaseline`, `Crash`, `Restart`, `LoadBaseline`, `AgentMutate`, `ReconcileDelete`, and `Restore`.
- Granularity: model partial observation and persistence separately; abstract resource payloads to identity, origin, and mutable value.

**Priority**: High  
**Rationale**: This boundary controls cross-run isolation and can preserve contamination or delete resources that were not created by the benchmark run.

### Scenario 4: “Stop noise” does not establish oracle quiescence

**Mechanism**: Noise application, pod/fault reattachment, and oracle observation have temporal windows, but the lifecycle treats `stop()` as an instantaneous quiescence barrier.

**Evidence**:
- Historical: open [#753](https://github.com/SREGym/SREGym/issues/753) confirms that pod restart can create a healthy window before Khaos re-injects; affected new Khaos problems are currently disabled by `a3cacad5`, so the issue is mechanism evidence rather than a replay target.
- Code analysis: `stop()` joins for only five seconds, clears its thread reference, then cleans the currently recorded list (`sregym/generators/noise/manager.py:71-95`).
- Code analysis: an application may block in unbounded `exec_command` and is recorded only after the command returns (`sregym/generators/noise/manager.py:125-157`; `sregym/service/kubectl.py:714-724`).
- Code analysis: cleanup can therefore clear the list before the late apply appends; the fallback strips finalizers but does not delete the late resource (`sregym/generators/noise/manager.py:176-245`).
- Code analysis: evaluation starts immediately after `stop()` returns (`sregym/conductor/conductor.py:468-505`).

**Affected code paths**: `NoiseManager.start`, `stop`, `_background_loop`, `_apply_experiment`, `_cleanup_experiments`, `_force_remove_all_chaos_resources`, evaluator/oracle entry.

**Suggested modeling approach**:
- Variables: `noiseRun`, `noiseLoopCount`, `applyInFlight`, `activeNoise`, `faultEffective`, `podGen`, `oracleState`, `quiescenceObserved`.
- Actions: `BeginNoiseApply`, `CompleteNoiseApply`, `StopNoise`, `JoinTimeout`, `CleanupRecordedNoise`, `RestartPod`, `ReattachFault`, `BeginOracle`, and `CompleteOracle`.
- Granularity: split command issue from effect and oracle start from its final verdict; permit an old noise epoch to complete after stop or run change.

**Priority**: High  
**Rationale**: The present interleaving can grade or start the next stage while a supposedly stopped disturbance remains in flight, directly threatening score soundness.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

- **Run lifecycle and completion ownership**: model driver, API, evaluator, and cleanup as actors, because Scenario 1 depends on their interleavings; use a generation tag on every in-flight operation.
- **Submission transport**: model queued, delayed, duplicated, and retried messages from Scenario 2; receipt, acceptance, and acknowledgment are distinct.
- **Baseline provenance and asymmetric reconciliation**: model only abstract resource identity/origin/value and per-field observation from Scenario 3, not Kubernetes object schemas.
- **Noise/fault effectiveness and oracle windows**: model begin/complete effects and a quiescence predicate from Scenario 4.
- **Crashes and restarts**: allow a crash after any externally visible step and retain only Kubernetes state plus the persisted baseline.

### 3.2 Do Not Model (with rationale)

- **Kubernetes scheduling, Helm, CRD schemas, and individual fault scripts**: these are environment internals; abstract them as fallible effects.
- **LLM diagnosis semantics and judge nondeterminism**: use an unconstrained solution value and Boolean grading result.
- **The real-kubeconfig mount, proxy implementation, internet filtering, and hard-coded kube-proxy image**: these are direct trust-boundary/code-review defects, not state-space questions.
- **Exact pod readiness, alert PromQL, and replica predicate code**: verify these local predicates with tests; model only the abstract oracle-soundness contract.
- **Closed fixed bugs as injected old states**: retain them as mechanism evidence, not model-checking targets.
- **BFT, quorum, leader election, or Byzantine actors**: SREGym implements none of these.

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| Run generations | `runGen`, `stage`, `stageOwner` | Prevent an old actor from changing a new/current run | 1, 2 |
| Evaluation/cleanup barriers | `evalInFlight`, `cleanupState`, `timeoutFired` | Represent non-atomic grading and teardown | 1 |
| Submission envelopes | `submissionQueue`, `originRun`, `originStage`, `requestId` | Explore delay, duplicate, retry, and wrong binding | 2 |
| Baseline provenance | `clusterGen`, `baselineGen`, `baselineComplete`, `observedFields` | Distinguish valid, stale, and partial snapshots | 3 |
| Resource ownership | `preexisting`, `runCreated`, `clusterResources` | Check safe reconciliation and restoration | 3 |
| Noise epochs | `noiseRun`, `applyInFlight`, `activeNoise`, `noiseLoopCount` | Detect late apply and overlapping loops | 4 |
| Oracle truth | `faultEffective`, `quiescenceObserved`, `oracleState` | Separate observed health from actual mitigation | 4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| `ReferenceStageOrder` | Safety | Each run follows setup → diagnosis → mitigation → teardown → done, skipping only unconfigured stages | Reference lifecycle |
| `OneAcceptedPerStage` | Safety | At most one request is accepted for each configured run/stage | 2 |
| `SubmissionOriginMatches` | Safety | Every graded request originated in the same run and stage | 2 |
| `DoneIsTerminal` | Safety | No actor reopens or mutates a done run | 1 |
| `NoEvaluationDuringTeardown` | Safety | Evaluation and environment teardown never overlap for one run | 1 |
| `NoOverlappingRuns` | Safety | A new run cannot deploy until all old-run evaluation and cleanup effects are quiescent | 1, 4 |
| `FaultBeforeDiagnosis` | Safety | Diagnosis becomes submission-ready only after the intended fault effect is established | 1, 4 |
| `BaselineMatchesCluster` | Safety | A loaded authoritative baseline is complete and belongs to the current cluster generation | 3 |
| `PreexistingResourcesPreserved` | Safety | Benchmark actions never delete or overwrite a pre-run resource without restoration | 3 |
| `CleanupDeletesOnlyRunOwned` | Safety | Reconciliation deletion targets are known to have been created by the run | 3 |
| `NoiseQuiescentAtEvaluation` | Safety | No active or in-flight noise from any epoch exists while an oracle evaluates | 4 |
| `OraclePassImpliesMitigated` | Safety | A successful verdict implies the intended fault is ineffective and required workload state is healthy | 4 |
| `AcceptedSubmissionTerminates` | Liveness | Under fair, terminating external calls, an accepted request is graded or records an explicit timeout | 1, 2 |
| `TeardownEventuallyCompletes` | Liveness | Under successful cleanup effects, teardown eventually reaches done exactly once | 1, 3 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Scenario |
|---|---|---|---|
| MC-1 | If timeout or bounded process-exit waiting fires while diagnosis/mitigation evaluation is in flight, can the evaluator reopen a stage, mutate published results, restart noise, or duplicate cleanup? | `DoneIsTerminal`, `NoEvaluationDuringTeardown`, `NoOverlappingRuns` | 1 |
| MC-2 | Can a delayed, early, duplicate, or retried untagged submission receive success while being lost or graded for a different stage/run? | `OneAcceptedPerStage`, `SubmissionOriginMatches`, `AcceptedSubmissionTerminates` | 2 |
| MC-3 | Across crash/restart, partial capture, or cluster replacement, can a loaded baseline preserve contamination or delete/overwrite a preexisting resource? | `BaselineMatchesCluster`, `PreexistingResourcesPreserved`, `CleanupDeletesOnlyRunOwned` | 3 |
| MC-4 | Can noise apply or Khaos reattachment complete after `stop()`, allowing an oracle to pass or a next run to start before the environment is quiescent? | `NoiseQuiescentAtEvaluation`, `OraclePassImpliesMitigated`, `NoOverlappingRuns` | 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| TV-1 | Generic `MitigationOracle` records baseline replica counts but accepts a healthy downscale from N to 1 (`sregym/conductor/oracles/mitigation.py:23-32,69-84`). | Add a baseline=3/current=1 unit case beside `tests/oracles/test_mitigation_oracle_baseline.py`. |
| TV-2 | `DeploymentReadinessOracle` accepts desired=ready=0 after its settle timeout (`sregym/conductor/oracles/deployment_readiness.py:27-46,59-73`). | Fake a zero-scaled target deployment and assert failure without waiting. |
| TV-3 | Generic readiness grading cannot detect MongoDB authorization/user faults ([#483](https://github.com/SREGym/SREGym/issues/483)). | Inject each logical fault with pods Ready; require a workload/authorization probe to fail until true recovery. |
| TV-4 | `AlertOracle` fails on unrelated preexisting alerts ([#745](https://github.com/SREGym/SREGym/issues/745)); [PR #933](https://github.com/SREGym/SREGym/pull/933)'s name-only baseline can hide a new instance of the same alert name. | Test full alert identity and disappearance/reappearance, not only alert-name set membership. |
| TV-5 | `KubeCtl.exec_command` returns stderr on nonzero exit, so injectors/noise can record success after failed apply (`sregym/service/kubectl.py:714-724`). | Parameterize representative inject/recover/apply paths with nonzero subprocess results and require an exception or verified postcondition. |
| TV-6 | Noise apply can append after stop cleanup. | Block `kubectl apply` beyond join timeout, call `stop`, release it, and assert no live thread/resource/list entry remains. |
| TV-7 | Baseline load accepts missing fields and capture accepts per-field empty failures. | Unit-test schema validation, capture completeness, cluster identity mismatch, and atomic persistence. |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR-1 | Every isolated agent container receives the real unproxied kubeconfig (`sregym/service/container_runner.py:253-263`), bypassing the hidden fault plane promised by the proxy and paper. | Remove it from the agent container or run privileged workload oracles in a separate trust domain. |
| CR-2 | Proxy authorization for hidden-label individual resources occurs only after forwarding PUT/PATCH/DELETE upstream (`sregym/service/k8s_proxy.py:299-349,372-385`). | Authorize before forwarding; use RBAC credentials that cannot mutate hidden resources. |
| CR-3 | `fix_kubernetes` rewrites kube-proxy to `v1.31.13` on every run ([#808](https://github.com/SREGym/SREGym/issues/808); `sregym/conductor/conductor.py:702-709`). | Capture and restore the actual pre-fault image, scoped to the faulting run. |
| CR-4 | Recover/app cleanup exceptions bypass reconciliation and `done`, while the `tearing_down` guard blocks retry (`sregym/conductor/conductor.py:319-385`). | Use a phase ledger plus `try/finally`; retry only incomplete idempotent phases. |
| CR-5 | Driver crash/KeyboardInterrupt does not call conductor teardown (`main.py:537-563,630-652`). | Add an explicit shutdown owner and recovery-on-next-start contract. |
| CR-6 | Agent egress is unrestricted at HEAD ([#911](https://github.com/SREGym/SREGym/issues/911)); draft [PR #914](https://github.com/SREGym/SREGym/pull/914) uses proxy environment variables that a shell-capable agent can unset. | Enforce egress below the agent's privilege boundary and add adversarial bypass tests. |
| CR-7 | Train-ticket tracing remains nonfunctional ([#558](https://github.com/SREGym/SREGym/issues/558)); draft [PR #663](https://github.com/SREGym/SREGym/pull/663) has changes requested because current images lack instrumentation. | Instrument owned images and require an end-to-end nonempty trace test. |

## 7. Reference Pointers

- Detailed audit: `analysis-report.md`
- Lifecycle: `main.py:204-563`; `sregym/conductor/conductor.py:168-568`
- Submission API: `sregym/conductor/conductor_api.py:23-53,110-158`
- Baseline: `sregym/service/cluster_state.py:48-350,352-511`; `sregym/paths.py:11-16`
- Noise: `sregym/generators/noise/manager.py:71-245`
- Trust boundary: `sregym/service/container_runner.py:231-263`; `sregym/service/k8s_proxy.py:211-385`
- Oracles: `sregym/conductor/oracles/mitigation.py:23-118`; `sregym/conductor/oracles/deployment_readiness.py:24-100`; `sregym/conductor/oracles/alert_oracle.py:20-168`
- Reference: [SREGym paper, arXiv:2605.07161v2](https://arxiv.org/html/2605.07161v2)
- Historical anchors: [#64](https://github.com/SREGym/SREGym/issues/64), [#408](https://github.com/SREGym/SREGym/issues/408), [#410](https://github.com/SREGym/SREGym/issues/410), [#460](https://github.com/SREGym/SREGym/issues/460), [#650](https://github.com/SREGym/SREGym/issues/650), [#674](https://github.com/SREGym/SREGym/issues/674), [#688](https://github.com/SREGym/SREGym/issues/688), [#704](https://github.com/SREGym/SREGym/issues/704), [#753](https://github.com/SREGym/SREGym/issues/753); open fix context: [PR #663](https://github.com/SREGym/SREGym/pull/663), [PR #914](https://github.com/SREGym/SREGym/pull/914), [PR #933](https://github.com/SREGym/SREGym/pull/933)
