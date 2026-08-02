# Confirmation Report — sregym

## Final Result

Reproduced bugs: 5 = 4 NEW + 1 KNOWN-unfixed + 0 KNOWN-fixed + 0 UNKNOWN
Masked live findings: 1
Env-limited findings: 0
False positives: 0
Dropped: 0
Needs more info: 0
Pending repair: 0
Incomplete: 0
Deferred: 0
Total disposition entries: 6
Dispositions: 6 total = 5 reproduced + 0 env-limited + 1 masked + 0 false-positive + 0 needs-more-info + 0 dropped + 0 pending-repair + 0 incomplete + 0 deferred
| Entry | Finding | Status | Counts as final bug? |
|---|---|---|---|
| 1 | MC-1 | REPRODUCED | yes |
| 2 | MC-2 | REPRODUCED | yes |
| 3 | MC-3 | REPRODUCED | yes |
| 4 | MC-4 | MASKED | no |
| 5 | CR-3 | REPRODUCED | yes |
| 6 | CR-4 | REPRODUCED | yes |

## Entry 1: Cleanup Can Start While Submission Evaluation Is In Flight

- **Finding ID**: MC-1
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sregym-vm-codex-gpt56-sol-max-20260727/sregym/.specula-output/confirmation/MC-1/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: main.py:411

## Description

Agent-exit handling snapshots only the current evaluation future, while submission admission and teardown use independent lifecycle checks. A queued request can therefore be admitted after that snapshot, allowing cleanup to undeploy the application while evaluation remains active.

After evaluation finishes, it can advance the already-cleaned run back from `done` to `mitigation`, while the driver has permanently published an incomplete result snapshot.

## Trigger scenario

The reproduction follows counterexample States 9–16:

1. `start_problem()` reaches `diagnosis`, waiting for submission.
2. A request queues.
3. Timeout/exit handling observes no evaluation future.
4. The queued request enters the real submission endpoint and is accepted.
5. Evaluation starts in the executor.
6. Driver timeout cleanup runs while that future is unfinished.
7. The driver copies results before evaluation completes.
8. Evaluation later advances the deleted run to `mitigation`.

## Developer intent

[PR #565](https://github.com/SREGym/SREGym/pull/565) deliberately made submission asynchronous. [Issue #688](https://github.com/SREGym/SREGym/issues/688) confirms slow background evaluation is expected and clients should poll for stage advancement.

The closest reports cover different boundaries: [#674/#679](https://github.com/SREGym/SREGym/pull/679) fenced cleanup against the *next deployment*, while [#704](https://github.com/SREGym/SREGym/issues/704) concerned teardown versus a still-running agent. Searches included open/closed issues and recently merged/closed PRs; none reported this admission-versus-driver-teardown mechanism.

## Reproduction result

Executable test: [test_bugMC-1_cleanup_evaluation_fence.py](/users/Pial/Specula/runs/sregym-vm-codex-gpt56-sol-max-20260727/sregym/.specula-output/repro/test_bugMC-1_cleanup_evaluation_fence.py)

Command:

```text
timeout 2m python /users/Pial/Specula/runs/sregym-vm-codex-gpt56-sol-max-20260727/sregym/.specula-output/repro/test_bugMC-1_cleanup_evaluation_fence.py
```

Captured output:

```text
LEVEL 0 RESULT: end-to-end cluster run unavailable; missing=['kubectl', 'helm', 'docker']
LEVEL 1 RESULT: timing-only cluster run unavailable because sleeps cannot supply the missing cluster tools
LEVEL 2 PRECONDITION: reached via Conductor.start_problem(); counterexample State 9 has stage=diagnosis, waitingForAgent=TRUE
CE_SEQUENCE: app_deployed -> fault_injected -> request_queued -> timeout_fired -> agent_exit_snapshot(in_flight=False) -> request_handler_entered -> submit_accepted -> evaluation_started -> driver_teardown_started -> fault_recovered -> app_cleanup(future_done=False) -> driver_teardown_returned(stage=done) -> driver_snapshot_copied -> evaluation_resumed(app_deployed=False) -> evaluation_future_finished(stage=mitigation)
SUBMIT_RESPONSE: {'status': '200', 'message': 'Submission received'}
OVERLAP_PROOF: app_cleanup(future_done=False), cleanup_count=1
DRIVER_PUBLISHED_SNAPSHOT: {'problem_id': 'mc1-fixture', 'attempt': 1, 'timed_out': True, 'agent_timeout_seconds': 1}
LIVE_RESULTS_AFTER_FUTURE: {'timed_out': True, 'agent_timeout_seconds': 1, 'Diagnosis': {'success': True, 'judge': 'slow-success', 'submission': 'valid diagnosis'}, 'TTL': 0.003480672836303711}
STATUS_POLLS_AFTER_ALL_WORK: [{'stage': 'mitigation'}, {'stage': 'mitigation'}, {'stage': 'mitigation'}]
PERMANENCE_PROOF: three post-future /status polls remain mitigation while app_deployed=False; published snapshot remains without Diagnosis.success
PASS: MC-1 reproduced: teardown overlapped an admitted evaluation, the driver snapshot lost its grade, and /status reopened mitigation after the app was deleted
```

Expected behavior was to close admission and join every admitted evaluation before cleanup and result publication. Instead, `app_cleanup(future_done=False)` proves overlap; the published snapshot lacks the grade; and the actual status endpoint repeatedly exposes `mitigation` after undeployment.

## Recommendation

Introduce one admission/teardown state machine protected by a common lock:

- Atomically close submissions before timeout or exit cleanup.
- Track and join every request admitted before closure.
- Prevent evaluation completion from advancing a closing or completed run.
- Publish results only after the admitted-evaluation set is empty.

## Reproduction checklist

1. Did Level 0 or Level 1 alone trigger it? **no**.
2. Level 2 used only unavailable infrastructure boundaries. The precondition was reached through `Conductor.start_problem() → diagnosis/waiting`, matching counterexample State 9; the executed continuation matches States 10–16: queued request → timeout/exit snapshot → endpoint admission → evaluation → teardown.
3. Real consumers observed wrong outcomes: `sregym/conductor/conductor_api.py:162-169` returned `mitigation` after undeployment, and `main.py:458-493`’s result snapshot omitted `Diagnosis.success`.
4. The bad outcome is **permanent for the completed run and its published snapshot**. Three polls after all asynchronous work still returned `mitigation`, and no later mechanism backfilled the copied result. A subsequent run may reset conductor state but does not repair the prior published result; no safeguard masks this defect.

---

## Entry 2: Delayed Duplicate Submission Is Graded in the Next Stage

- **Finding ID**: MC-2
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sregym-vm-codex-gpt56-sol-max-20260727/sregym/.specula-output/confirmation/MC-2/debate.md

- **Source**: MC
- **Novelty**: NEW
- **Location**: sregym/conductor/conductor_api.py:115

## Description

Submission requests contain only solution text. The endpoint retries against mutable conductor state, while `Conductor.submit()` assigns the request to whichever stage is current at acceptance. A diagnosis-origin duplicate can therefore be retried and graded as mitigation.

Upstream issues and recently closed/merged PRs were searched. [Issue #650](https://github.com/SREGym/SREGym/issues/650), [issue #688](https://github.com/SREGym/SREGym/issues/688), and [PR #694](https://github.com/SREGym/SREGym/pull/694) concern related but different races; none reports this cross-stage mechanism.

## Trigger scenario

1. A diagnosis submission starts asynchronous evaluation.
2. Its delayed duplicate enters `POST /submit`.
3. Diagnosis clears `_evaluating` before advancing the stage.
4. The duplicate receives `RuntimeError`, so the endpoint sleeps and retries.
5. Diagnosis advances to mitigation.
6. The unchanged diagnosis body is accepted as mitigation, evaluated before any repair, and finalizes the benchmark.

The precondition was reached through `Conductor.start_problem()` and real HTTP requests. No state injection or source patch was used.

## Developer intent

SREGym clients treat diagnosis and mitigation as separate operations. TierZero submits diagnosis, waits for mitigation, performs mitigation, then submits a distinct signal. Issue #688 likewise states that the agent should wait for diagnosis evaluation before starting mitigation. Nothing found indicates that a diagnosis retry may intentionally satisfy mitigation submission.

## Reproduction result

Test: [test_bugMC-2_delayed_duplicate_cross_stage.py](/users/Pial/Specula/runs/sregym-vm-codex-gpt56-sol-max-20260727/sregym/.specula-output/repro/test_bugMC-2_delayed_duplicate_cross_stage.py)

Command:

```text
timeout 5m /tmp/specula-mc2-python/venv/bin/python /users/Pial/Specula/runs/sregym-vm-codex-gpt56-sol-max-20260727/sregym/.specula-output/repro/test_bugMC-2_delayed_duplicate_cross_stage.py
```

Actual output:

```text
SOURCE_REPO=/users/Pial/Specula/runs/sregym-vm-codex-gpt56-sol-max-20260727/sregym/.specula-output/confirmation/MC-2/worktree
SOURCE_SHA=d9a0663e3930d90bd98122e8a852cf8d27c410ec
PYTHON=3.12.13
LEVEL0 mode=pure-public-http
LEVEL0 first_response={"http": 200, "json": {"message": "Submission received", "status": "200"}}
LEVEL0 immediate_duplicate_response={"http": 200, "json": {"message": "Submission received", "status": "200"}}
LEVEL0 stage_after_diagnosis=mitigation
LEVEL0 evaluations=[["diagnosis", "diagnosis-origin-copy: frontend root cause"]]
LEVEL0 cross_stage_triggered=false
LEVEL0 control_legitimate_mitigation_response={"http": 200, "json": {"message": "Submission received", "status": "200"}}
LEVEL0 outcome=safeguard_discarded_immediate_duplicate; escalating_to_level1
LEVEL1 mode=public-http-plus-timing-only-runtime-breakpoint
LEVEL1 first_response={"http": 200, "json": {"message": "Submission received", "status": "200"}}
LEVEL1 transition_window={"current_stage_index": 0, "evaluating": false, "stage": "diagnosis", "waiting_for_agent": false}
LEVEL1 endpoint_retry_window={"current_stage_index": 0, "evaluating": false, "stage": "diagnosis", "waiting_for_agent": false}
LEVEL1 delayed_duplicate_response={"http": 200, "json": {"message": "Submission received", "status": "200"}}
LEVEL1 evaluations=[["diagnosis", "diagnosis-origin-copy: frontend root cause"], ["mitigation", "diagnosis-origin-copy: frontend root cause"]]
LEVEL1 mitigation_repaired_at_evaluation=false
LEVEL1 final_stage=done
LEVEL1 persisted_mitigation_success=false
LEVEL1 late_legitimate_mitigation_response={"http": 200, "json": {"message": "All stages have been completed and graded. No further submissions are needed.", "status": "done"}}
REAL_CONSUMER clients/tierzero/driver.py:170-185 returned stage=done; branch at :324-327 skips mitigation
PERSISTED_CONSUMER main.py:462-467 publishes Mitigation.success=False
DOWNSTREAM_RESOLUTION none: late legitimate submission was not evaluated and the stored grade stayed false
EXPECTED stale diagnosis retry rejected; remain at mitigation until a post-repair mitigation submission
ACTUAL stale diagnosis retry accepted for mitigation; benchmark finalized before any mitigation action/submission
RESULT BUG_TRIGGERED MC-2
```

The deterministic reproduction was repeated successfully.

## REPRODUCED checklist

1. Did Level 0 or Level 1 alone trigger it? **yes** — Level 1 used the public HTTP API with timing-only assistance.
2. Level 2/3 reachability evidence: **not applicable**.
3. Real consumer: `clients/tierzero/driver.py:170-185` returned `done`, causing `:324-327` to skip mitigation. `main.py:462-467` publishes the false mitigation grade.
4. Permanent or masked: **permanent**. A later legitimate mitigation submission receives `status=done`; no resend, guard, or synchronization mechanism replaces the stored result.

## Recommendation

Issue server-generated run, stage, request, and idempotency tokens and validate them atomically when accepting submissions. Retries must retain their original stage token, with stale or duplicate requests rejected consistently across HTTP and MCP. Add regression coverage for delayed duplicates spanning stage and run transitions.

---

## Entry 3: Persisted Baseline Is Reused Across Cluster Replacement

- **Finding ID**: MC-3
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sregym-vm-codex-gpt56-sol-max-20260727/sregym/.specula-output/confirmation/MC-3/debate.md

- **Source**: MC
- **Novelty**: KNOWN (cite: [SREGym/SREGym#767](https://github.com/SREGym/SREGym/pull/767); fix-status: unfixed)
- **Location**: sregym/service/cluster_state.py:183
- **Severity**: High
- **Reproduction test**: [test_bugMC-3_cluster_replacement.py](/users/Pial/Specula/runs/sregym-vm-codex-gpt56-sol-max-20260727/sregym/.specula-output/repro/test_bugMC-3_cluster_replacement.py) — Level 2

## Description

SREGym stores a single home-directory baseline containing no cluster identity, generation, schema version, or completeness marker. After cluster replacement, `load_baseline_state` accepts the old parseable file; cleanup then deletes legitimate replacement-cluster resources and overwrites CoreDNS with the previous cluster’s value.

Upstream PR #767 previously reported this exact stale-cache deletion mechanism. Its merged commit changed only the cluster setup playbook and left automatic validation unfixed.

## Trigger scenario

1. SREGym captures cluster A through `save_baseline_state`.
2. The process crashes while its home-directory cache survives.
3. Cluster A is replaced by cluster B, which has legitimate namespace, RBAC, and CoreDNS state.
4. SREGym restarts and accepts cluster A’s baseline.
5. Normal cleanup calls `reconcile_to_baseline`, deleting cluster B’s resources and restoring cluster A’s values.

This matches counterexample States 7–11: `MCCrash` → `MCReplaceCluster` → restart → `MCStartProblem` → old baseline becomes authoritative.

## Developer intent

Issue [#460](https://github.com/SREGym/SREGym/issues/460) sought restoration to a known-clean pre-problem state and identified crash-time recapture as unsafe. PR [#613](https://github.com/SREGym/SREGym/pull/613) introduced persistence as a cleanup heuristic. PR #767 later documented that operators must manually delete the cached baseline after changing cluster networking or reconciliation will remove legitimate Calico RBAC.

No existing test covers baseline loading, persistence, or cross-cluster reconciliation.

## Reproduction result

Command:

```text
timeout 5m env -u SREGYM_TRACE_FILE python3 /users/Pial/Specula/runs/sregym-vm-codex-gpt56-sol-max-20260727/sregym/.specula-output/repro/test_bugMC-3_cluster_replacement.py
```

Exit code: `0`.

Actual output:

```text
SOURCE_MODULE=/users/Pial/Specula/runs/sregym-vm-codex-gpt56-sol-max-20260727/sregym/.specula-output/confirmation/MC-3/worktree/sregym/service/cluster_state.py
CONFIGURED_BASELINE_PATH=/users/Pial/cache_dir/cluster_baseline_state.json
LEVEL_0=NOT_TRIGGERED: kubectl is absent; no live Kubernetes public API is available for a black-box cluster replacement
LEVEL_1=NOT_TRIGGERED: timing assistance cannot create the missing Kubernetes runtime, so Level 0's environment limit remains
LEVEL_2=START: real save_baseline_state -> admissible MCCrash/MCReplaceCluster precondition -> real load_baseline_state -> real reconcile_to_baseline
COUNTEREXAMPLE_SEQUENCE=State 7 MCCrash -> State 8 MCReplaceCluster (clusterGen 1, persistedBaselineGen 0) -> State 9 restart -> State 10 MCStartProblem -> State 11 old baseline authoritative
PERSISTED_KEYS=cluster_role_bindings,cluster_roles,coredns_configmap_data,crds,mutating_webhook_configs,namespaces,node_labels,node_taints,persistent_volumes,storage_classes,validating_webhook_configs
PERSISTED_PROVENANCE=none
LOAD_ACCEPTED=True
CLUSTER_B_BEFORE={"cluster_role_bindings": ["replacement-platform-controller-binding"], "cluster_roles": ["replacement-platform-controller"], "coredns": {"Corefile": "cluster-b.example"}, "namespace_payloads": {"replacement-tenant": "legitimate-cluster-b-data"}, "namespaces": ["default", "kube-system", "replacement-tenant"]}
FIRST_RECONCILE_CHANGES={"cluster_role_bindings_deleted": ["replacement-platform-controller-binding"], "cluster_roles_deleted": ["replacement-platform-controller"], "coredns_reset": true, "crds_deleted": [], "mutating_webhook_configs_deleted": [], "namespaces_deleted": ["replacement-tenant"], "nodes_labels_reset": [], "nodes_taints_reset": [], "persistent_volumes_deleted": [], "storage_classes_deleted": [], "validating_webhook_configs_deleted": []}
CLUSTER_B_AFTER_FIRST={"cluster_role_bindings": [], "cluster_roles": [], "coredns": {"Corefile": "cluster-a.example"}, "namespace_payloads": {}, "namespaces": ["default", "kube-system"]}
SECOND_RECONCILE_CHANGES={"cluster_role_bindings_deleted": [], "cluster_roles_deleted": [], "coredns_reset": false, "crds_deleted": [], "mutating_webhook_configs_deleted": [], "namespaces_deleted": [], "nodes_labels_reset": [], "nodes_taints_reset": [], "persistent_volumes_deleted": [], "storage_classes_deleted": [], "validating_webhook_configs_deleted": []}
CLUSTER_B_AFTER_SECOND={"cluster_role_bindings": [], "cluster_roles": [], "coredns": {"Corefile": "cluster-a.example"}, "namespace_payloads": {}, "namespaces": ["default", "kube-system"]}
MATCHED_BASELINE_CONTROL_CHANGES={"cluster_role_bindings_deleted": [], "cluster_roles_deleted": [], "coredns_reset": false, "crds_deleted": [], "mutating_webhook_configs_deleted": [], "namespaces_deleted": [], "nodes_labels_reset": [], "nodes_taints_reset": [], "persistent_volumes_deleted": [], "storage_classes_deleted": [], "validating_webhook_configs_deleted": []}
MATCHED_BASELINE_CONTROL_AFTER={"cluster_role_bindings": ["replacement-platform-controller-binding"], "cluster_roles": ["replacement-platform-controller"], "coredns": {"Corefile": "cluster-b.example"}, "namespace_payloads": {"replacement-tenant": "legitimate-cluster-b-data"}, "namespaces": ["default", "kube-system", "replacement-tenant"]}
REAL_CONSUMERS=sregym/service/cluster_state.py:227-374 -> sregym/service/kubectl.py:498-503
PERMANENCE=confirmed: a second production reconciliation neither recreates the namespace/RBAC nor restores cluster B's CoreDNS value
BUG_TRIGGERED: parseable cluster-A baseline caused deletion of legitimate cluster-B namespace/RBAC and overwrote cluster-B CoreDNS
LEVEL_3=NOT_ATTEMPTED: Level 2 reproduced without source modification
```

Checklist:

1. Did Level 0 or Level 1 alone trigger it? **no**.
2. Level 2 used the admissible sequence: **State 7 `MCCrash` → State 8 `MCReplaceCluster` (`clusterGen=1`, `persistedBaselineGen=0`) → State 9 restart → State 10 `MCStartProblem` → State 11 old baseline authoritative**. The old file was generated through the real `save_baseline_state` API, not hand-built.
3. The real consumer is `ClusterStateManager.reconcile_to_baseline` at `sregym/service/cluster_state.py:227-374`, which reports destructive changes and delegates namespace deletion to `KubeCtl.delete_namespace` at `sregym/service/kubectl.py:498-503`. Its normal caller is `Conductor._cleanup_sync` at `sregym/conductor/conductor.py:364`.
4. The bad state is **permanent within SREGym**. A second reconciliation neither recreated namespace/RBAC nor restored cluster B’s CoreDNS; no downstream sync, resend, loopback, or guard masked it.

## Recommendation

Persist an atomically written, versioned envelope containing a verified live-cluster identity and completed-capture marker. Reject legacy or mismatched baselines and recapture cluster B before deployment; immediately before destructive reconciliation, revalidate the identity and fail closed if it cannot be verified. Add regression coverage for cluster replacement and configuration migration.

---

## Entry 4: Pod Restart Temporarily Removes the Fault During Diagnosis

- **Finding ID**: MC-4
- **Status**: MASKED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sregym-vm-codex-gpt56-sol-max-20260727/sregym/.specula-output/confirmation/MC-4/debate.md

- **Source**: MC
- **Novelty**: KNOWN (cite: https://github.com/SREGym/SREGym/issues/568; fix-status: unfixed)
- **Location**: sregym/conductor/problems/khaos_faults.py:147

## Description

Khaos probes remain attached to the terminated host PID after a container restart. The conductor continues exposing diagnosis while the replacement PID is temporarily fault-free. The polling monitor later reattaches the fault, making this a transient state masked by downstream repair.

## Trigger scenario

Start a Khaos-backed problem normally, enter diagnosis, then restart a targeted container immediately after a monitor pass. This reproduces counterexample state 10, `MCRestartPod`: diagnosis remains available while the new PID lacks the probe.

## Developer intent

Comments at `khaos_faults.py:262-264` explicitly acknowledge that restarts remove PID-scoped faults. Upstream [issue #568](https://github.com/SREGym/SREGym/issues/568) reported this mechanism, and [PR #569](https://github.com/SREGym/SREGym/pull/569) introduced the asynchronous monitor. No container-generation readiness gate was added.

## Reproduction result

Executed [test_bugMC-4_khaos_restart_gap.py](/users/Pial/Specula/runs/sregym-vm-codex-gpt56-sol-max-20260727/sregym/.specula-output/repro/test_bugMC-4_khaos_restart_gap.py):

```text
timeout 30s /users/Pial/Specula/runs/sregym-vm-codex-gpt56-sol-max-20260727/sregym/.specula-output/repro/test_bugMC-4_khaos_restart_gap.py
```

```text
SOURCE_HEAD=d9a0663e3930d90bd98122e8a852cf8d27c410ec
KHAOS_SOURCE_SHA256=d2f04f86f80cd90ef0fd04085b78a606e6c196aeab63dd166c0e77d7af1e30fc
API_SOURCE_SHA256=524ee918d97e48f227d3ff686661933fa2e8a846a5e7c5b73f13a9bc99ee83e3
LEVEL0=BLOCKED: kubectl missing; no real Kubernetes/Khaos black-box path
LEVEL1=BLOCKED: timing-only assistance cannot run without the Level-0 Kubernetes/Khaos runtime
[reinjection-monitor] Started for write_error on node worker-1 (tracking 1 pods)
LEVEL2_GAP: CE_STEP=State10:MCRestartPod stage=diagnosis cid=container-generation-1 current_pid=4200 attached_pids=[4100] fault_effective=False api_submit_status=200 submit_calls=1
[reinjection-monitor] Re-injecting write_error into PID 4200 (pod hotel-reservation/mongodb-0, container container-ge)
LEVEL2_MASK: elapsed_seconds=5.050 current_pid=4200 attached_pids=[4100, 4200] fault_effective=True trace_events=['RestartPod', 'ReattachFault']
LEVEL3=NOT_ESCALATED: Level 2 positively proved the normal downstream monitor fires; a source delay would only widen the same masked interval
RESULT=MASKED: diagnosis is publicly available while the replacement PID is unattached, then the ordinary polling monitor reattaches the fault
[reinjection-monitor] Stopped
```

Level 0/1 alone did not trigger it. Level 2 used the admissible `State 10: MCRestartPod` transition. The real consumers are `conductor_api.get_status()` and `conductor_api.submit_solution()` at `sregym/conductor/conductor_api.py:119-169`; submission was accepted while `fault_effective=False`. The state is not permanent: `_FaultReinjectionMonitor` reattached PID 4200 after 5.050 seconds, proving the downstream mask.

## Recommendation

Track target container generations and verified probe attachment centrally. Pause `/status` readiness and reject diagnosis submissions while any target generation is awaiting reattachment; fail the stage after a bounded retry deadline.

---

## Entry 5: Partial Baseline Observations Are Treated as Authoritative During Reconciliation

- **Finding ID**: CR-3
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sregym-vm-codex-gpt56-sol-max-20260727/sregym/.specula-output/confirmation/CR-3/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: sregym/service/cluster_state.py:394
- **Severity**: High
- **Reproduction test**: [test_bugCR-3_partial_baseline.py](/users/Pial/Specula/runs/sregym-vm-codex-gpt56-sol-max-20260727/sregym/.specula-output/repro/test_bugCR-3_partial_baseline.py)
- **Investigation**: [investigation.md](/users/Pial/Specula/runs/sregym-vm-codex-gpt56-sol-max-20260727/sregym/.specula-output/confirmation/CR-3/investigation.md)

## Description

Baseline getters convert independent Kubernetes `ApiException`s into empty collections. The snapshot is persisted and loaded without completeness validation, so reconciliation treats a failed observation as authoritative and permanently deletes pre-existing objects absent from that collection.

## Trigger scenario

Create a user-managed ClusterRole, then save the baseline while its Kubernetes list endpoint transiently returns HTTP 503. Restart, load the syntactically valid snapshot containing `"cluster_roles": []`, and run normal cleanup reconciliation after the endpoint recovers. The role is classified as unexpected and deleted.

## Developer intent

The code says reconciliation should reset the cluster to a known-clean baseline. [Issue #460](https://github.com/SREGym/SREGym/issues/460) discusses stale/non-comprehensive snapshots, while [issue #559](https://github.com/SREGym/SREGym/issues/559) reports an `IncompleteRead` that aborts capture; neither reports the caught-`ApiException` → persisted-empty-collection → deletion mechanism. Searches covered open/closed issues and open/closed/merged PRs, including recent work through upstream HEAD; no exact prior report or fix was found.

## Reproduction result

Command, executed successfully twice:

```text
timeout 2m /tmp/cr3-repro-venv.7uNmaA/bin/python /users/Pial/Specula/runs/sregym-vm-codex-gpt56-sol-max-20260727/sregym/.specula-output/repro/test_bugCR-3_partial_baseline.py
```

Actual output:

```text
CoreDNS ConfigMap not found
CoreDNS ConfigMap not found
Failed to list ClusterRoles: (503)
Reason: Service Unavailable
HTTP response headers: HTTPHeaderDict({'Server': 'BaseHTTP/0.6 Python/3.10.12', 'Date': 'Mon, 27 Jul 2026 16:05:08 GMT', 'Content-Type': 'application/json', 'Content-Length': '161'})
HTTP response body: {"apiVersion": "v1", "kind": "Status", "metadata": {}, "status": "Failure", "reason": "ServiceUnavailable", "message": "transient apiserver outage", "code": 503}

CoreDNS ConfigMap not found
CoreDNS ConfigMap not found
CoreDNS ConfigMap not found
CoreDNS ConfigMap not found
CoreDNS ConfigMap not found
CoreDNS ConfigMap not found
SOURCE_FILE=/users/Pial/Specula/runs/sregym-vm-codex-gpt56-sol-max-20260727/sregym/.specula-output/confirmation/CR-3/worktree/sregym/service/cluster_state.py
ESCALATION_LEVEL=0 (public save/load/reconcile APIs; no SUT patch or internal-state injection)
REAL_API_SEQUENCE=create ClusterRole -> save baseline while list returns HTTP 503 -> restart/load -> reconcile
CONTROL_COMPLETE_CAPTURE_ROLE_PRESENT=True
CLUSTER_ROLE_LIST_HTTP_STATUSES=[200, 200, 200, 503, 200, 200, 200, 200, 200, 200, 200, 200, 200]
PARTIAL_SNAPSHOT_CLUSTER_ROLES=[]
PARTIAL_SNAPSHOT_LOAD_ACCEPTED=True
RECONCILE_DELETED=['baseline-critical-reader']
ROLE_PRESENT_AFTER_RECONCILE=False
ROLE_PRESENT_AFTER_SECOND_RECONCILE=False
DELETED_BASELINE_ROLE_RECREATED=False
MUTATED_BASELINE_ROLE_VERBS_AFTER_RECONCILE=['delete']
RECONCILE_CREATE_CALLS=0
RESULT=BUG TRIGGERED: a transient partial baseline was persisted and caused permanent deletion
```

Checklist:

1. Did Level 0 or Level 1 alone trigger it? **yes** — Level 0 used public save/load/reconcile operations and a legitimate Kubernetes HTTP 503 response.
2. Level 2/3 reachability justification: **not applicable**; neither was used.
3. Real caller observing the wrong outcome: `Conductor._cleanup_sync()` at `sregym/conductor/conductor.py:364`; it receives the deletion result and treats reconciliation as complete.
4. Permanent or masked? **permanent** for an unowned resource. `ROLE_PRESENT_AFTER_SECOND_RECONCILE=False` and `RECONCILE_CREATE_CALLS=0` prove no later reconciliation restores it; no downstream mask was found.

Expected behavior is to reject or invalidate the incomplete capture and retain the pre-existing role.

## Recommendation

Make baseline observations explicitly successful or failed and abort persistence if any required read fails. Persist snapshots atomically with a schema version and completeness marker, validate every required field on load, and refuse reconciliation from legacy or incomplete snapshots. If full restoration is intended, retain sufficient manifests to recreate deleted objects and reverse content mutations.

---

## Entry 6: Noise Application Can Complete After Stop Cleanup

- **Finding ID**: CR-4
- **Status**: REPRODUCED
- **Debate**: not run
- **Transcript**: /users/Pial/Specula/runs/sregym-vm-codex-gpt56-sol-max-20260727/sregym/.specula-output/confirmation/CR-4/debate.md

- **Source**: Code Review
- **Novelty**: NEW
- **Location**: sregym/generators/noise/manager.py:84
- **Severity**: High

## Description

`NoiseManager.stop()` waits only five seconds, discards the worker reference even if still alive, and cleans only experiments already recorded. Because `kubectl apply` has no timeout and the experiment is recorded only after it returns, an accepted apply can complete after both cleanup passes and interfere with evaluation.

Upstream searches found no issue or PR reporting this mechanism at this site. Related cleanup and finalizer reports concern different mechanisms; details are recorded in [investigation.md](/users/Pial/Specula/runs/sregym-vm-codex-gpt56-sol-max-20260727/sregym/.specula-output/confirmation/CR-4/investigation.md).

## Trigger scenario

1. Start a problem with noise enabled.
2. The worker begins a valid `PodChaos/pod-failure` apply.
3. Kubernetes processing exceeds the five-second join.
4. Normal agent submission calls `stop()`.
5. Recorded cleanup and the one-shot CR scan see nothing; `stop()` returns.
6. The apply completes and Chaos Mesh makes a target container unready while evaluation is running.

This specifically reproduces NoiseManager’s late-apply path, not Khaos reattachment.

## Developer intent

The conductor explicitly says noise is stopped “to ensure clean environment.” [PR #395](https://github.com/SREGym/SREGym/pull/395) likewise states that noise must be strictly cleaned before evaluation, while [issue #647](https://github.com/SREGym/SREGym/issues/647) specifies start/stop around evaluations.

## Reproduction result

Executable: [test_bugCR-4_late_noise_apply.py](/users/Pial/Specula/runs/sregym-vm-codex-gpt56-sol-max-20260727/sregym/.specula-output/repro/test_bugCR-4_late_noise_apply.py)

Command:

```text
timeout 60s python /users/Pial/Specula/runs/sregym-vm-codex-gpt56-sol-max-20260727/sregym/.specula-output/repro/test_bugCR-4_late_noise_apply.py
```

Exit code: `0`.

```text
LEVEL0_PREFLIGHT=UNAVAILABLE: kubectl is not installed
BASELINE_ORACLE_SUCCESS=True
STOP_ELAPSED_SECONDS=5.000
WORKER_ALIVE_AT_STOP_RETURN=True
RESOURCES_AT_STOP_RETURN=[]
ACTIVE_RECORDS_AT_STOP_RETURN=[]
DELETE_COMMANDS_AT_STOP_RETURN=[]
FORCE_SCAN_SNAPSHOTS_AT_STOP=[('podchaos', 0), ('networkchaos', 0)]
⚠️ Container frontend is not ready
❌ Pod readiness check failed after 1.3s of monitoring
FIRST_APPLY_COMPLETION=PodChaos/noise-pod-failure-1785168507-967 action=pod-failure
LATE_APPLY_AFTER_STOP_RETURN=True
LATE_RESOURCES=['NetworkChaos/noise-network-delay-1785168513-921', 'PodChaos/noise-pod-failure-1785168507-967']
LATE_ACTIVE_RECORDS=[{'name': 'noise-pod-failure-1785168507-967', 'kind': 'PodChaos'}, {'name': 'noise-network-delay-1785168513-921', 'kind': 'NetworkChaos'}]
REAL_ORACLE_RESULT_AFTER_STOP={'success': False}
RESOURCES_AFTER_SECOND_STOP=[]
RECOVERED_CONTROL_ORACLE_SUCCESS=True
RECORDED_RESULT_AFTER_SECOND_STOP=False
LEVEL1_RACE_ONLY=PASS: public start/stop returned before its apply completed
LEVEL2_REACHABLE_CONSUMER=PASS: legitimate PodChaos -> controller marks target container unready -> real SustainedReadinessOracle fails
LEVEL3=NOT_NEEDED
BUG_TRIGGERED=yes
```

Checklist:

1. Did Level 0 or Level 1 alone trigger live consumer harm using a real cluster? **no**. Level 0 lacked `kubectl`; Level 1 demonstrated the lifecycle violation but required Level 2 for its consumer consequence.
2. Reachable Level-2 sequence: `Conductor.start_problem(--noise)` → `NoiseManager.start()` → valid `PodChaos/pod-failure` apply → Chaos Mesh marks the selected container unready → Kubernetes `list_pods` exposes that normal state → `SustainedReadinessOracle.evaluate()` returns failure.
3. Real consumer: `SustainedReadinessOracle.evaluate()` at `sregym/conductor/oracles/sustained_readiness.py:15`, wired by `liveness_probe_too_aggressive.py:44` and invoked by `conductor.py:265`.
4. The Chaos effect is transient, and a later `stop()` removes the CRs. However, the consumer harm is permanent for that stage: the already returned/stored evaluation remains `False`, as shown by `RECORDED_RESULT_AFTER_SECOND_STOP=False`. Later cleanup therefore does not mask the defect.

## Recommendation

Establish quiescence before cleanup: retain and fully join the worker, bound or cancel the apply subprocess, and prevent further applies once stopping begins. After quiescence, delete all recorded and discovered Chaos CRs; finalizer stripping alone is insufficient. Add a regression test where apply exceeds five seconds and assert no experiment or oracle-visible effect appears after `stop()` returns.

---
