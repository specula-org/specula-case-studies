# Modeling Brief: nvflare-fedavg

## 1. System Overview

- **Pinned source:** NVIDIA/NVFlare, Python, `53ba7ee567468ea7971dad4faccef13c6cb35dc2`; source root `/home/ubuntu/nvflare-runs-20260913/source-fedavg`. The six requested entry/core files contain 3,175 physical lines. All source citations below refer to this pin.
- **Category A — Distributed / Message-Passing:** clients retrieve identified tasks and submit asynchronous results; local locks, callbacks, monitoring and cancellation provide essential action boundaries. No BFT or weak-memory model is applicable (`nvflare/apis/impl/wf_comm_server.py:190-210,414-435,1046-1062`).
- **Protocol:** current Recipe → FedAvg → ModelController/BaseModelController → WFCommServer/BcastTaskManager → client runner/API. Recipe selects FedAvg, with immediate per-result aggregation (`nvflare/recipe/fedavg.py:461-478`; `nvflare/app_common/workflows/fedavg.py:199-228`).
- **Actual configuration evidence:** no exported job or numeric `min_clients` was supplied. Model the source-selected defaults, parameterizing the selected cohort: one standing training task, `min_responses=None→0` (all selected targets), task timeout `0`, grace `0`, `ignore_result_error=None`, built-in aggregator, in-process client execution, tensor disk offload disabled (`nvflare/app_common/workflows/model_controller.py:74-105`; `nvflare/app_common/workflows/base_model_controller.py:39-57,142-154`; `nvflare/recipe/fedavg.py:227-252,461-478`). Optional filters/offload must be explicit variants.
- **Concurrency:** communicator request/submission/task-retirement checks share `_controller_lock`; callbacks retain it and also take the task callback lock. Dead-client observation/job-policy checks run before that lock; FedAvg control flow and mark-only cancellation also remain independent (`nvflare/apis/impl/wf_comm_server.py:209-210,434-435,476-521,794-827,1060-1062`; `nvflare/app_common/workflows/fedavg.py:224-239`).
- **Reference:** local functional API contracts, not convergence or arithmetic precision. Historical Recipe used ScatterAndGather; that history does not supply today's threshold/grace policy. This phase produced source/history analysis only: no current runtime defect confirmation, model counterexample, trace-conformance result or proof.

## 2. Scenarios

### Scenario 1: Protected broadcast input and outbound ownership

**Mechanism:** the source model, frozen broadcast payload and per-client message envelope have different ownership boundaries.

**Evidence:**
- Historical: [#4129](https://github.com/NVIDIA/NVFlare/pull/4129) documents first-client snapshot protection; [#3223](https://github.com/NVIDIA/NVFlare/issues/3223)/[#3222](https://github.com/NVIDIA/NVFlare/pull/3222) concern shared quantization data; the proposed per-client framework deepcopy in [#3227](https://github.com/NVIDIA/NVFlare/pull/3227) was rejected.
- Current: first `before_task_sent_cb` precedes one deep copy; subsequent targets reuse it. Per-client headers are deep-copied, payload is shared (`nvflare/apis/impl/wf_comm_server.py:277-370,590-600`; `nvflare/apis/shareable.py:157-173`). FedAvg updates its model after the standing task drains (`nvflare/app_common/workflows/fedavg.py:224-239`).
- Outbound filtering follows communicator return; the built-in quantizer explicitly coordinates shared mutation and requires subset-specific filters to own their copies (`nvflare/private/fed/server/server_runner.py:329-371`; `nvflare/app_opt/pt/quantization/quantizer.py:235-316`).

**Affected code paths:** `FedAvg.run`, `_prepare_task_data`, `process_task_request`, `make_copy`, `ServerRunner.process_task_request`.
**Suggested modeling approach:** base variables `sourceVersion`, `broadcastVersion`, `assigned`; capture at first retrieval, not scheduling. Represent per-client headers separately. Keep ordinary outbound failure as a separate step for Scenario 4; do not introduce arbitrary shared-data mutation.
**Granularity:** scheduling, first snapshot/publication, outer filtering/delivery are distinct; communicator callbacks obey the real outer lock.
**Assessment / Priority:** historical protections verified in source; no new default-path input-version defect established. **Low** for a separate MC investigation; essential base semantics for Scenarios 3–4. Addresses priority question 1.

### Scenario 2: Task identity, retry receipt and finite completed history

**Mechanism:** live-task receipt, retired-task deduplication, unknown-task dispatch and transport acknowledgement are separate decisions.

**Evidence:**
- Historical: [#4772](https://github.com/NVIDIA/NVFlare/pull/4772) adds bounded completed-task deduplication; these guards are present at the pin.
- Current: known submissions check assignment, task name, terminal status and prior receipt under callback/outer locks; receipt is stamped after callback processing (`nvflare/apis/impl/wf_comm_server.py:448-521`). Completed history remembers only received ClientTasks, is LRU-bounded to 10,000, and is cleared at finalization (`:44,397-412,870-874,1106-1109`).
- Ordinary client replies restore task identity and cookie jar; server dispatch uses the task-ID cookie. Transport OK acknowledges dispatch, including drops, rather than aggregation acceptance (`nvflare/private/fed/client/client_runner.py:225-234`; `nvflare/private/fed/server/server_commands.py:232-246`; `nvflare/private/fed/server/server_command_agent.py:96-110`).
- Unknown train results reach `_accept_train_result`, but never the aggregation callback or `_results` append (`nvflare/app_common/workflows/base_model_controller.py:298-365`). Thus eviction/late arrival alone does not establish later-round contribution contamination.

**Affected code paths:** client result submission/retry, server command dispatch, `_do_process_submission`, completed history, `process_result_of_unknown_task`.
**Suggested modeling approach:** base variables `taskId`, `taskRound`, `owner`, `receipt`, `dispatchAck`; retain current duplicate/drop and unknown-result no-consumer branches. Ordinary retries keep identity. If history is represented with a smaller bound, state that abstraction explicitly; do not claim testing the actual 10,000-entry limit.
**Granularity:** acknowledgement, consumer outcome and receipt marker are different states; normal submissions cannot overlap each other or monitor removal while the outer lock is held.
**Assessment / Priority:** current exact-duplicate protection and unknown-path non-aggregation verified; no new duplicate-count defect established. **Low** as a standalone MC target. Unknown-result context retention remains CR-2. Addresses priority question 2.

### Scenario 3: Consumer failure after partial aggregation mutation

**Mechanism:** a result consumer can change aggregate state before completing the decision that acceptance reporting observes.

**Evidence:**
- Historical: [#4907](https://github.com/NVIDIA/NVFlare/pull/4907) fixes premature acceptance reporting; its current consumer-first decision is retained, not reverted.
- Current: `_process_result` catches conversion/consumer exceptions and publishes `accepted=False`, then clears the received result (`nvflare/app_common/workflows/base_model_controller.py:263-294`). It does not undo consumer effects or pass those exceptions through the return-code tolerance helper.
- FedAvg adds parameters before metrics and increments `_received_count` only afterward (`nvflare/app_common/workflows/fedavg.py:299-330`). The helper updates keys incrementally and appends contributor history only after its loop; a key's stats precede materialization (`nvflare/app_common/aggregators/weighted_aggregation_helper.py:162-224`). Locks do not roll back exceptions.
- Ordinary runtime failure is exposed by the supported disk-offload materialization interface (`nvflare/app_opt/pt/lazy_tensor_dict.py:63-80`); declare `enable_tensor_disk_offload=True`, streamed PyTorch results (e.g. `server_expected_format=ExchangeFormat.PYTORCH`) and an active Cell. NumPy exchange bypasses offload (`docs/design/tensor_disk_offload.md:11-15,51`). Arithmetic/metric allocation failure is another candidate interface outcome, not permission to use malformed or malicious payloads.

**Affected code paths:** `_process_result` → `_aggregate_one_result` → parameter/metric helper `add` → `_get_aggregated_result` → `update_model`.
**Suggested modeling approach:** variables `consumerPc`, `appliedKeys`, `paramHistory`, `metricHistory`, `accepted`, `receivedCount`, `savedProvenance`. Split per-key application, later consumer work, decision publication and receipt stamping. Keep success, empty-parameter skip, pre-mutation failure and post-mutation failure separate.
**Granularity:** retain the outer lock through the whole callback; local failure/cancellation/control-flow and independent dead-client/policy-abort observations may interleave as the source permits. Explore failure after one key or after parameter completion, then normal task drain/final aggregation.
**Assessment / Priority:** one current source-supported mechanism with two failure windows; potential model/accounting inconsistency, not a reproduced bug. **High**: MC-1 can reveal an externally used rejected contribution rather than merely recheck the historical event-order fix. Addresses priority question 3.

### Scenario 4: Abnormal task retirement versus ordinary round commit

**Mechanism:** the workflow observes queue emptiness without consuming the task's termination reason.

**Evidence:**
- Current ordinary optional-filter failure calls `handle_exception` and returns TRY_AGAIN; it does not trigger run abort (`nvflare/private/fed/server/server_runner.py:333-356`). That handler marks the whole task CANCELLED (`nvflare/apis/impl/wf_comm_server.py:372-390,794-812`).
- The monitor removes any terminal task; `get_num_standing_tasks` returns only list length (`nvflare/apis/impl/wf_comm_server.py:786-792,1067-1109`). FedAvg proceeds to aggregation/update/save after that count becomes zero, without reading terminal status (`nvflare/app_common/workflows/fedavg.py:223-259`).
- Ordinary `ServerRunner` workflow return adds no task-status check; control-flow exceptions and the separate abort signal govern failure handling (`nvflare/private/fed/server/server_runner.py:143-183`). Before/after-send callback and snapshot errors provide other ERROR outcomes (`nvflare/apis/impl/wf_comm_server.py:281-345`).
- Cancellation is mark-only: a callback admitted before cancellation may finish. Normal monitor/finalization waits for the communicator lock, so a live old callback cannot simply run after ordinary next-round reset (`nvflare/apis/impl/wf_comm_server.py:434-521,794-827,882-895,1060-1062`).

**Affected code paths:** outbound filter/callback failure, `handle_exception`, cancellation, monitor retirement, FedAvg wait/final aggregation, server workflow handoff.
**Suggested modeling approach:** variables `terminalStatus`, `standing`, `abort`, `roundPc`, `committedRound`, `outcome`. Split mark-cancel, callback finish, monitor removal, queue-empty observation, model update/save and next-round start. Keep status assignment independent of successful completion.
**Granularity:** preserve actual locks and admit a callback's already-started work. Do not require cancellation to roll back work or instantly terminate callbacks. A source-faithful `FinalizeRound` must retain the existing queue-empty guard so MC can test the missing outcome check.
**Assessment / Priority:** one current cross-layer candidate; potential ordinary commit of a nonempty partial round after operational failure. **High**: MC-2 asks whether the normal workflow outcome misrepresents abnormal task termination. No current runtime consequence is claimed. Addresses priority questions 4–5.

### Scenario 5: Configured progress and distinct completion meanings

**Mechanism:** received responses, accepted contributions, terminal task status, callback cleanup and run abort satisfy different policies.

**Evidence:**
- BcastTaskManager uses receipt markers, not accepted contributions. Default `min_responses=0` waits for all fixed targets; no assignment means continue waiting (`nvflare/apis/impl/bcast_manager.py:42-75`). Empty results may deliberately be skipped by FedAvg (`nvflare/app_common/workflows/fedavg.py:268-273`).
- Dynamic error handling counts distinct failed clients; with all selected responses required, the first non-OK result exhausts tolerance (`nvflare/app_common/workflows/base_model_controller.py:150-154,329-362`; `nvflare/app_common/utils/error_handling_utils.py:51-61`). Conversion/consumer errors follow Scenario 3's separate branch.
- A report becomes a disconnect after configured grace (default 60 s). After task lead time (default 30 s), CLIENT_DEAD requires every outstanding target to be disconnected. Separate all-dead/min-sites/required-sites policy can panic first (`nvflare/apis/impl/wf_comm_server.py:129-132,1024-1058,1157-1248`).
- Historical [#1135](https://github.com/NVIDIA/NVFlare/issues/1135) rejects conflating response grace with callback processing. No ScatterAndGather response threshold is inherited here.

**Affected code paths:** receipt stamping, broadcast exit policy, error tolerance, dead-client monitor, FedAvg abort polling and final aggregation.
**Suggested modeling approach:** variables `failedClients`, `reportedDead`, `disconnected`, `policyAbort`; reuse Scenario 4's status/round state. Keep timers as ordered threshold abstractions. Default task timeout remains disabled. Treat min-sites/required-sites as established job-policy inputs, without modeling admission/resource scheduling.
**Granularity:** dead-report observation, disconnect decision, deployment-policy decision, task drain and workflow observation are distinct. Model monitor fairness only when callbacks terminate and the monitor remains running.
**Assessment / Priority:** configured boundaries verified from source; no independent new liveness bug established. **Medium**, composed with MC-1/MC-2 rather than a separate historical-fix hunt. A permanently missing live client's response alone is expected waiting. Addresses priority questions 3–5.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|---|---|---|
| Current one-task round skeleton and cooperative identity | Required context for Scenarios 3–4 | Start with 2 clients, 2 rounds, 2 symbolic parameter keys; expand to 3 clients for selected/unselected/dead-policy distinctions. Bounds are proposed, not executed configuration. |
| Existing protected input and retry guards | Faithful reachable base states from Scenarios 1–2 | Encode actual copy/identity/drop decisions; allocate no separate hunt to removing current guards. |
| Consumer partial progress and acceptance decision | Scenario 3 | Track provenance per applied key and a separate definitive decision; allow only source-backed ordinary runtime failure points. |
| Task status through round handoff | Scenario 4 | Model actual queue-empty observation separately from terminal reason, run abort and model commit. |
| Explicit policy variants | Scenario 5 | Default all-selected/zero-timeout first; outbound-filter failure and PyTorch/active-Cell disk offload in separate configurations; conventional content filters on the receiving offload path are unsupported (`docs/design/tensor_disk_offload.md:97-108`). Preserve explicit resilient/strict policy if selected. |
| Payload interface | Required delivery boundary | Represent assignment envelope, payload readiness/failure, result dispatch ACK and materialization separately. ACK provides no consumer-acceptance or universal all-bytes-complete guarantee; see analysis-report transport table. |

### 3.2 Do Not Model (with rationale)

- Convergence, floating-point accuracy, numerical kernels, GPU internals, model selection quality: outside functional lifecycle scope; use symbolic values/provenance.
- HA recovery, durable crash/restart, job admission/resource reservations, ScatterAndGather/Swarm/relay policies: explicitly separate scopes.
- Stream/chunk/download implementation internals: keep the observed interface and cancellation/error outcomes, not invented delivery guarantees.
- Security faults, forged identity, arbitrary consumer sabotage, arbitrary concurrent custom workflows: outside cooperative supported-API assumptions.
- Reverting completed-history, broadcast-copy, event-order or finalization fixes: historical reference only, no new information.
- Wildcard-filter lookup, monitor-period spelling, mixed FULL/DIFF conversion and diagnostic retention: local test/code-review work below; do not enlarge MC for deterministic helpers.

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| Partial consumer operation | `consumerPc`, `appliedKeys`, `paramHistory`, `metricHistory`, `accepted`, `receivedCount` | Expose rejected-but-applied state at consumer exception boundaries | 3 |
| Termination reason carried alongside visibility | `terminalStatus`, `standing`, `roundPc`, `abort`, `outcome` | Explore whether abnormal retirement becomes a normal round commit | 4 |
| Commit provenance | `savedProvenance`, `committedRound`, `taskRound` | Observe externally used contribution/round consistency, not only local event values | 3–4 |
| Configured error/death observations | `failedClients`, `reportedDead`, `disconnected`, `policyAbort` | Compose real failure and progress policy with terminal handoff | 3–5 |

## 5. Proposed Invariants

These are properties to check, not transition guards or assumptions. No property equates receipt/ACK with acceptance, or all selected clients with all accepted contributions.

| Invariant | Type | Description | Targets |
|---|---|---|---|
| TypeOK | Safety | Task/client/round/status/provenance variables stay in their declared domains | Base |
| CommittedRoundProvenance | Safety | Every contribution used in a committed round belongs to that round's task and selected client | 3–4 |
| CommittedAcceptanceConsistency | Safety | Once consumer processing ends, a saved aggregate contains no data from a definitively rejected contribution; callback count, helper histories and saved provenance agree under the declared inclusion policy | MC-1, 3 |
| AbnormalTerminationVisible | Safety | Under the declared round-completion policy, abnormal retirement with outstanding selected responses must not produce ordinary save/next ROUND_STARTED/normal-finish observations unless that policy permits partial completion; status logs alone are not the outcome | MC-2, 4–5 |
| EligibleTaskEventuallyDrains | Liveness | All selected responses finish processing, or a configured terminal condition persists, implies eventual task drain under terminating callbacks and fair live monitor scheduling | 5 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Forward-looking current-code question | Expected violation if confirmed | Scenario |
|---|---|---|---|
| MC-1 | Can an ordinary failure after a key/parameter aggregate update leave rejected contribution data in the subsequently committed model or disagree with contribution accounting? | CommittedAcceptanceConsistency | 3 |
| MC-2 | Can a task cancelled/errored during ordinary delivery, callback work or configured dead-client handling drain and then produce an ordinary next round/model save without a policy permitting partial round completion? | AbnormalTerminationVisible | 4–5 |

MC-2 should first use a nonempty accepted aggregate followed by an outbound-filter cancellation; independently validate the cancellation/death-to-round policy before labeling a model violation an implementation bug. Both pass the output-value test: possible consequences are an inconsistent saved model/accounting or a misleading successful round after failure. They are unconfirmed mechanism questions at the pin, not reproductions of closed fixes. Keep cancellation, consumer failure and delivery failure independently attributable before composing them.

### 6.2 Test-Verifiable

| ID | Description | Suggested local regression |
|---|---|---|
| TV-1 | Concrete interface mapping for MC-1/MC-2 remains unexecuted | Use benign arrays for the real controller/communicator filter-failure path; validate lazy I/O separately with actual supported PyTorch offload values/configuration. Assert acceptance, receipt, helper state, status, save and next-round observations; keep success controls. |
| TV-2 | Per-site FULL/DIFF may mix distinct contribution meanings while FedAvg keeps only the first result type (`nvflare/recipe/fedavg.py:156-174,414-443`; `nvflare/app_common/workflows/fedavg.py:275-304`; `nvflare/app_common/utils/fl_model_utils.py:233-239`) | Verify actual per-site export/client conversion and both result orders; first settle whether cross-site homogeneity is a required user contract. No numerical-accuracy hunt. |
| TV-3 | Known open wildcard/empty-DXO filter behavior, [#5073](https://github.com/NVIDIA/NVFlare/pull/5073), remains outside the pin (`nvflare/apis/utils/task_utils.py:40-68`; `nvflare/apis/dxo_filter.py:87-99`) | Small local exact/wildcard and empty-input filter tests; record as known upstream work, not new discovery. |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR-1 | Custom `ModelAggregator.accept_model` has no documented boolean rejection contract, while FedAvg ignores its return (`nvflare/app_common/aggregators/model_aggregator.py:39-58`; `nvflare/app_common/workflows/fedavg.py:280-282`) | Clarify callback versus ModelAggregator semantics before calling a returned False a defect. |
| CR-2 | Unknown successful train result sets `TRAINING_RESULT` and logs aggregator delivery without known-path cleanup or consumer invocation (`nvflare/app_common/workflows/base_model_controller.py:292-306,324-365`) | Audit context lifetime and wording; no later-round aggregation contamination established. |
| CR-3 | Controller assigns public `task_check_period`, communicator reads private `_task_check_period` (`nvflare/apis/impl/controller.py:47-53`; `nvflare/apis/impl/wf_comm_server.py:92-107,1058`) | Review forwarding mismatch; distinguish FedAvg's 0.5 s polling from communicator's default 0.2 s monitor. |
| CR-4 | Server per-client filtering tracker separates membership check and assignment (`nvflare/private/fed/server/server_runner.py:306-327`) | Establish supported retry overlap and filter compensation before promotion; no runtime failure established. |
| CR-5 | General API prose for cancel/targets/done timing differs from implementation | Use actual fixed targets/mark-only cancellation for this model; reconcile docs separately (analysis-report exclusions). |

## 7. Reference Pointers

- Detailed audit: [analysis-report.md](analysis-report.md); source/history/issue inventories and raw evidence: [analysis-evidence/](analysis-evidence/).
- Component audits: [FedAvg](analysis-evidence/fedavg-audit.md), [WFComm](analysis-evidence/wfcomm-audit.md), [client/runner boundary](analysis-evidence/client-audit.md); pinned provenance: [provenance.json](analysis-evidence/provenance.json).
- Core test sources: `tests/unit_test/apis/impl/controller_test.py:660-1693`; `tests/unit_test/app_common/workflow/fedavg_test.py`; `tests/unit_test/app_common/utils/error_handling_utils_test.py`. Read coverage is detailed in the audit; none was executed in this phase.
- Current consumer/error decision: `nvflare/app_common/workflows/base_model_controller.py:251-365`; callback/round state: `nvflare/app_common/workflows/fedavg.py:186-365`; per-key partial state: `nvflare/app_common/aggregators/weighted_aggregation_helper.py:153-265`.
- Historical references remain Scenario evidence only. Spec Generation must preserve these evidence boundaries and independently establish source conformance before interpreting any model counterexample as an implementation defect.
