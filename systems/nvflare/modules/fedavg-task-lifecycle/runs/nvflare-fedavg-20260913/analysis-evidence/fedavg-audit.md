# FedAvg delegated source audit

Pinned source: `/home/ubuntu/nvflare-runs-20260913/source-fedavg` at `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. Source checkout remained clean. Evidence scope is code/history/discussion analysis only: no NVFlare tests, model generation, TLC, trace validation, runtime reproduction, or security experiment was executed. All participants and extension code in candidate scenarios are cooperative; failures are ordinary local runtime failures. Source references below are relative to that pinned source root.

## Method and coverage

Read the experiment AGENTS.md, source AGENTS.md/CLAUDE.md, experiment-local code_analysis SKILL.md, guide.md, and deep-analysis/distributed-analysis/bug-archaeology references in full. Category A: server-to-client task/result messages and independent workflow/request/submission/monitor threads determine lifecycle behavior. Python locks and callback boundaries are modeled explicitly; there is no BFT threat model. Sequence: reconnaissance inventory, exhaustive assigned archaeology, complete current core reading and adjacent verification, then this handoff.

The historical memory was used only to preserve the distinction between responded/accepted and Recipe FedAvg/ScatterAndGather. Every current claim below was checked against the pinned source. This delegated audit does not represent the entire parent task's global issue/open-PR inventory.

- Git history was complete (`--is-shallow-repository=false`). Exactly five assigned paths yielded **77 distinct commits over all local refs**, including **46 keyword candidates** and **31 non-keyword commits**. Every candidate and every non-keyword core patch was read in full. Required keywords were case-insensitive substrings across subject and body: fix, bug, race, panic, deadlock, correctness, crash, corrupt, leak, inconsistent, wrong, safety. Templates and broader unrelated commit text are explicitly classified rather than equated to a defect.
- **57 commits are ancestors of the pinned head; 20 belong only to other refs.** Release cherry-picks/equivalents are mapped, not treated as separate newly discovered mechanisms. Classification: 34 functional fixes (25 keyword), 6 resource-management changes, 3 architecture changes, 6 API changes, 6 refactors, 9 features, 7 documentation, 2 formatting, 2 branch literal/revert changes, 1 release sync, and 1 broader fix whose helper hunk is documentation. These are commit counts, not unique bug counts.
- **10 assigned issues deeply read, all 37 comments saved/read**. Five confirmed historical bugs, one acknowledged design limitation, three enhancement/test requests, one resolved expectation error, zero disputed reports, zero currently confirmed new bugs. Every issue has raw body/metadata, `gh issue view --comments` output, all paginated REST comments and applicable timeline data. `gh issue view --comments` alone printed comments without issue bodies in this non-TTY environment; bodies were read from separately saved REST metadata.
- **10 additional PR discussions completely read**: #172, #288, #292, #1401, #1851, #2475, #2465, #2505, #5273, #4907. Full bodies, issue comments, reviews, and inline review comments are separately preserved. #5273 is open/draft, optional algorithm research, and outside the lifecycle scope. Its contributor-reported benchmark numbers are not independently validated evidence.

Primary delegated artifacts:

- `fedavg-commits.json`: all 77 hashes, dates, keyword matches, complete-patch pointers, individual root cause/component/severity/classification, ancestry and current-equivalent fixes.
- `fedavg-issues.json`: all 10 issue classifications, complete-comment counts, fix inclusion, linked PR states and exact discussion pointers.
- `fedavg/commits/all-core-diffs.txt`: all complete core textual patches, **8,261 lines**, inspected in contiguous non-truncated chunks. The separate per-hash `.patch` files preserve full commit messages and patch metadata (**13,063 total lines**).

Complete current-file reads:

| File | Physical lines |
|---|---:|
| `nvflare/app_common/workflows/fedavg.py` | 534 |
| `nvflare/app_common/workflows/base_fedavg.py` | 322 |
| `nvflare/app_common/workflows/base_model_controller.py` | 494 |
| `nvflare/app_common/workflows/model_controller.py` | 136 |
| `nvflare/app_common/aggregators/weighted_aggregation_helper.py` | 271 |
| `nvflare/app_common/aggregators/model_aggregator.py` | 83 |
| `nvflare/app_common/utils/error_handling_utils.py` | 109 |
| `nvflare/app_opt/pt/lazy_tensor_dict.py` | 133 |
| **Complete source files** | **8 files / 2,082 lines** |
| `tests/unit_test/app_common/workflow/fedavg_test.py` | 2,310 |
| `tests/unit_test/app_common/utils/error_handling_utils_test.py` | 540 |
| **Complete test files** | **2 files / 2,850 lines / 129 test definitions** |

The test-definition counts are AST inventory, not executed tests or parameterized test-case counts. Adjacent targeted reads covered FLModelUtils conversion/update, recipe per-site configuration/data-kind validation, client in-process DIFF preparation, WFCommServer submission/retirement, broadcast exit logic, server-runner task-data filter exceptions, current legacy fixes, and applicable pinned docs. Those adjacent files are not claimed as complete reads. No TODO/FIXME/HACK/XXX/BUG/WARN developer signal was found in the five assigned current core paths.

## Reconnaissance and current contract

`FedAvg -> BaseFedAvg -> ModelController -> BaseModelController` is the Recipe path. `FedAvg.run` sets the outbound model's round (`fedavg.py:183-190`), samples clients (`:197`), creates fresh built-in helpers/reset custom stats (`:199-212`), sends one nonblocking broadcast (`:216-221`), polls standing tasks (`:224-228`), obtains the aggregate and updates/saves the model (`:230-259`).

`send_model` defaults to `min_responses=None`, `timeout=0` (`model_controller.py:74-104`). `broadcast_model` maps None to zero, the broadcast manager's all-targets sentinel (`base_model_controller.py:142-154`); `BcastTaskManager.check_task_exit` counts `result_received_time`, not aggregator acceptance (`nvflare/apis/impl/bcast_manager.py:56-70`). Default Recipe FedAvg therefore waits for responses from all selected targets and has no task deadline. It does **not** inherit ScatterAndGather's minimum-client/grace-period contract. A zero deadline also does not mean abnormal termination is impossible: current WFCommServer can retire ERROR/CANCELLED/CLIENT_DEAD tasks (`wf_comm_server.py:1068-1109`).

Submission processing is serialized by `_controller_lock` and the task `cb_lock` (`wf_comm_server.py:434-435,475-507`). BaseModelController sets callback context round from the originating task (`base_model_controller.py:256-261`), evaluates return-code policy, converts and consumes, then publishes `AGGREGATION_ACCEPTED` (`:263-294`). WFCommServer records the receipt after that callback returns (`wf_comm_server.py:521`). The helper's own lock serializes `add`/`get_result` (`weighted_aggregation_helper.py:162,228`). Task retirement removes the standing task before final callbacks/cleanup (`wf_comm_server.py:1100-1155`); workflow advancement is separately scheduled and reads the task count without acquiring those locks (`:786-792`).

## Historical issues: verified classification and containment

| Issue | Deep-read result | Current scope/fix status |
|---|---|---|
| [#2488](https://github.com/NVIDIA/NVFlare/issues/2488) | Round-metadata API enhancement, following controller layering refactor | Closed; current FedAvg explicitly sets start/total/current round. No universal generic-controller round inference claimed. |
| [#3959](https://github.com/NVIDIA/NVFlare/issues/3959) | Resolved user expectation: DIFF does not automatically compress zero-valued FP tensors | Closed by reporter; no confirmed protocol defect. |
| [#156](https://github.com/NVIDIA/NVFlare/issues/156) | Confirmed historical NumPy in-place integer/float update failure | PR #172 / `889e8c73f78276e1cc3aa2ae6c71dca1eed260be` included. Current out-of-place addition: full_model_shareable_generator.py:67, fl_model_utils.py:237. |
| [#248](https://github.com/NVIDIA/NVFlare/issues/248) | Confirmed wrong nested collection aggregation-weight fallback | PR #288 / `e10d62c2fbf63818278d5a84b9d6ce65e1e70160` included; missing nested keys now rejected at intime_accumulate_model_aggregator.py:143-149. Collection path is outside built-in Recipe FedAvg. |
| [#291](https://github.com/NVIDIA/NVFlare/issues/291) | Confirmed HE expected-data-kind check hard-coded to WEIGHT_DIFF | PR #292 / `51e57172cc4c375cbed761fa941d7cbc4bd96922` included; HE is outside this slice. |
| [#182](https://github.com/NVIDIA/NVFlare/issues/182) | Test/maintenance request, no independent defect | Closed by #288; does not increase confirmed-bug count. |
| [#790](https://github.com/NVIDIA/NVFlare/issues/790) | Acknowledged design limitation: final aggregate lacks another before-training evaluation | Closed question; explicit extra evaluation is the maintainer's suggested extension. Do not call final-checkpoint/best-checkpoint divergence a new defect. |
| [#1389](https://github.com/NVIDIA/NVFlare/issues/1389) | Confirmed contribution-round header/cookie mismatch in model selector | PR #1401 / `a6ce7d20fc8eb121a1ba1a6332ccc09d3fdf9954` included; current selector reads cookie at intime_model_selector.py:135. |
| [#1718](https://github.com/NVIDIA/NVFlare/issues/1718) | Confirmed FedOpt omitted non-trainable buffers; numerical limitations explicitly discussed | PR #1851 / `75536cd00e45bcaded75a873e5453e546ceca422` included; FedAvg fallback for buffers and filtered-key guards are present. FedOpt/convergence excluded. |
| [#5209](https://github.com/NVIDIA/NVFlare/issues/5209) | Optional heterogeneity-aware weighting research request | Open; #5273 is draft/unmerged. No defect in default FedAvg established. |

Especially relevant current fixes remain **reference only**: `b1b06ad45528` (#4907 definitive acceptance and stale-stat clearing), `924593206d90` (#4384 preserve context attrs), `bdaabc014185` (#4520 release raw result context), `bd8dee34a17c` (#4226 selector events), `a0ad9b625d18`/`af2e8a588a4f` (unsupported/absent metrics), and `bba3f4801fa0` (#1123 helper locking). PR #4907's maintainer review explicitly required definitive post-consumer acceptance, and the author confirmed conversion-failure/skip regressions. It does not claim transactional rollback of a consumer that partially changed state.

## Current candidates and verification boundaries

### FA-MC1: Consumer failure can leave rejected contribution data in the aggregate

**Source-supported candidate, pending local regression and model checking.** Severity if confirmed: Medium functional model/result integrity. This is about accepted/applied contribution provenance, not numerical convergence.

Path and ordinary trigger:

1. Current Recipe FedAvg permits disk-offloaded tensor results (`fedavg.py:90-93,156-164`). Actual `_LazyRef.materialize()` performs `safe_open(...).get_tensor(...)` (`nvflare/app_opt/pt/lazy_tensor_dict.py:77-80`). An ordinary local file/resource failure can occur during a later materialization after earlier keys were consumed. Memory-allocation/arithmetic failure after earlier completed operations is another implementation boundary; no crafted or hostile input is needed for the hypothesis.
2. `WeightedAggregationHelper.add` modifies each key's count before materialization (`weighted_aggregation_helper.py:168-175`), then commits its aggregate total/denominator before processing the next key (`:179-216`). Contributor history is appended only after all keys succeed (`:218-224`). There is no rollback on a later exception.
3. FedAvg also commits all parameter aggregation before metrics processing (`fedavg.py:299-326`), and increments its accepted-result count only at `:328`. Thus an ordinary later metric-consumer failure can leave parameter data/history present while the callback fails. `_params_type` and site-weight metadata are written even earlier (`:275-297`).
4. BaseModelController catches the callback exception and logs it (`base_model_controller.py:281-286`), leaves `accepted=False`, publishes rejection (`:290-291`), and clears references (`:292-294`). It does not revert helper state or invoke the dynamic error policy for conversion/callback failure.
5. The communicator still records the task receipt (`wf_comm_server.py:521`). Once all selected clients have responded, BcastTaskManager reports OK (`bcast_manager.py:64-66`), the monitor retires the task, and FedAvg reads the helper's residual data (`fedavg.py:233,346-364`) and updates/saves (`:238-259`) without checking `_received_count` against the target count or checking a consumer-failure flag.

**Compensating mechanisms checked:** locks prevent concurrent contributions interleaving inside a helper call, but do not undo earlier statements when that call raises. A rejected empty result is skipped before any mutation (`fedavg.py:270-273`) and is not this scenario. `_get_num_steps_weight` sanitizes invalid step counts (`base_fedavg.py:93-104`), and unsupported metrics are filtered (`weighted_aggregation_helper.py:20-71`); neither compensates an ordinary later runtime failure. Fresh helpers isolate subsequent rounds, but the affected current round is finalized before that reset. The client return-code policy (`base_model_controller.py:338-362`) applies before consumer execution and does not see a later consumer exception.

**Useful abstraction:** per-task `responded`, per-result definitive `accepted`, per-key `appliedContributors`, consumer phase `notStarted/partial/done/failed`, and `modelCommitted`. An invariant can require that a committed contribution's data belong to the definitively accepted set, or that any partial-consumer failure prevents committing that round. Preserve actual helper ordering; do not undo historical fixes or introduce malicious contributions. A future local check should validate real supported input and the actual ordinary exception boundary, then trace the complete task-to-round path.

**Existing-test boundary:** fedavg_test.py:942 checks pre-mutation empty skip; :1504 checks callback False; :1528 checks conversion failure; :964 checks custom lazy payload preservation. None runs a real built-in helper through a partial mutation followed by ordinary failure and round finalization. No tests were executed here.

### FA-MC2: Abnormal task retirement can be mistaken for ordinary round completion

**Source-supported candidate, pending local regression and model checking.** Severity if confirmed: Medium functional incomplete-round commit.

A concrete supported path exists independently of client error return codes: a configured server task-data filter raises an ordinary runtime exception while preparing a client's assignment. ServerRunner catches the exception, invokes communicator `handle_exception(task_id, fl_ctx)`, removes the per-client processing marker and replies TRY_AGAIN (`nvflare/private/fed/server/server_runner.py:333-356`). `WFCommServer.handle_exception` finds the assigned client task and cancels its entire parent task (`wf_comm_server.py:372-390`); cancellation only sets completion status (`:794-812`), without triggering the job's abort signal. The monitor subsequently removes the task (`:1068-1070,1100-1109`).

If at least one other selected client already contributed, FedAvg's standing-task loop ends (`fedavg.py:224-228`) and it obtains, updates and saves that partial aggregate (`:230-259`). The nonblocking `send_model` API returns no Task handle (`model_controller.py:94-105`), `_prepare_task` installs no task-done callback (`base_model_controller.py:213-221`), and no status check guards finalization. The same structural concern applies to ERROR/CLIENT_DEAD retirement; distinguish each actual trigger when validating instead of assuming one covers all.

**Compensating mechanisms checked:** dynamic result-error policy panics when a client result code makes the all-client target impossible (`base_model_controller.py:150-154,338-362`, `error_handling_utils.py:58-61`); this filter path never reaches that policy. The workflow's abort check runs only while the task count remains nonzero. Cancellation and cleanup prevent additional results being accepted for the retired task (`wf_comm_server.py:488-491`); they do not prevent the workflow committing earlier partial results. Errors escaping `run()` do panic (`base_model_controller.py:376-387`), but this path's errors are already caught below it. With no earlier accepted result, empty aggregation may itself fail later; this does not compensate the case with a nonempty partial aggregate.

**Useful abstraction:** retain a distinct terminal task status `OK/CANCELLED/ERROR/CLIENT_DEAD`, task removal, workflow observation, aggregate/update/persist stages, and abort observation. A proposed invariant should prohibit ordinary successful round commit after an abnormal terminal task status unless an explicit controller continuation policy authorizes it. No assumption that zero task count certifies successful work. No deployment/crash recovery model is needed.

### FA-TV1: Mixed FULL/DIFF results lack a built-in compatibility guard

**Test-verifiable configuration-consistency candidate; not a new MC target.** Recipe documents and implements per-site `params_transfer_type` overrides (`nvflare/recipe/fedavg.py:156-174,414-443`). Per-site validation at `:498-499` checks targets, while `nvflare/recipe/utils.py:87-89` intentionally treats `FLModel.params_type` as authoritative rather than inferring it from transfer configuration. The client computes DIFF only for configured DIFF plus FULL model input (`nvflare/client/in_process/api.py:186-202,276-296`). These individually supported paths can therefore return distinct model-state representations under ordinary configuration.

Conversion preserves each incoming kind (`nvflare/app_common/utils/fl_model_utils.py:108-121`). Built-in FedAvg keeps only the first kind (`fedavg.py:275-277`), then accumulates all incoming parameter dictionaries in the same domain (`:299-304`). Aggregate type is that first kind (`:355-358`); model update replaces on FULL and adds on DIFF (`fl_model_utils.py:233-239`). BaseFedAvg has the same first-result convention (`base_fedavg.py:208-222`). Arrival order can change the final interpretation, beyond ordinary floating-point rounding.

**Boundary:** per-site override support does not by itself establish that mixed result kinds are a promised algorithm feature. No same-round homogeneity validation or explicit prohibition was found in the scoped implementation/docs searches; custom aggregators may enforce their own contracts. A small ordinary configuration test and clearer contract assessment should precede reporting a product defect. Recipe `aggregator_data_kind` checks only a custom aggregator's declared expected kind at construction (`recipe/utils.py:91-150`), not each built-in runtime contribution. Full fedavg_test.py has no mixed-kind case.

### FA-CR1: Custom accept_model return False has no documented rejection semantics

`ModelAggregator.accept_model` specifies adding to sum/count but has no boolean return contract (`model_aggregator.py:39-42`). Its ScatterAndGather bridge always returns True after calling it (`:54-58`). FedAvg ignores the return at `fedavg.py:282`, then increments count and returns True at `:328-330`. Although BaseModelController's own callback supports explicit False, that contract does not automatically extend through a custom aggregator. This is a code-review-only API question, **not a confirmed defect** and not grounds to invent a rejection policy in the model.

### FA-CR2: Unknown-task path retains TRAINING_RESULT and uses misleading aggregation wording

After a legitimate late result for a retired, previously unresponded task (e.g. ordinary cancellation), the completed-task cache does not contain it because only responded tasks are remembered (`wf_comm_server.py:397-406`). Unknown submission dispatch reaches `base_model_controller.py:298-306`. For an OK result, `_accept_train_result` stores `TRAINING_RESULT` (`:364`) and this path lacks the known-result path's `finally` cleanup (`:292-294`). It also logs that the result was sent to the aggregator, although no conversion, consumer callback or helper add is called.

This is a code-review-only late-result lifetime/reporting observation. A current-runtime memory-lifetime check would be needed before assigning impact. Do **not** infer that unknown/late results contaminate the next round: the actual callback/aggregation path is absent. Current duplicate completed results are dropped before unknown dispatch (`wf_comm_server.py:454-473`), a material compensating mechanism. Known #4520 cleanup remains reference; this distinct untouched branch is recorded for inexpensive review, not a historical-fix recreation model target.

## Explicit false positives, exclusions and safe abstractions

- Receipt is not definitive acceptance, and definitive acceptance is not necessarily a transactional guarantee against partial state. Keep all three concepts separate.
- Do not flag current definite acceptance publication as still preceding conversion/callback: #4907 fixed that.
- Do not flag callback concurrency as an unsynchronized helper race without accounting for WFCommServer controller/callback locks and the helper lock; #1123 is already present.
- Do not flag stale round context from differing sticky flags without accounting for `_set_ctx_prop_preserving_attrs`; #4384 is present.
- Do not import ScatterAndGather's late-result accumulation or quorum/grace semantics into Recipe FedAvg. Unknown Recipe results do not reach its consumer callback.
- Empty result skip and absent-metric suppression are explicit current policies. Metric dicts may contain unsupported values or different key sets, with filtering/per-key denominators; that alone is not a defect.
- Per-site step count is sanitized, but bitwise floating-point reproducibility is explicitly not guaranteed. Numeric convergence, quantization, HE, FedOpt/BatchNorm, and adaptive weighting remain outside the lifecycle model.
- Existing tests often mock task completion and aggregate retrieval. Reading their assertions establishes coverage intent, not full workflow correctness or runtime success.
- No invalid theorem restriction, synthetic Byzantine contribution, reverted historical fix, or arbitrary injected protocol shortcut is proposed. Only the source-mapped ordinary consumer-failure and abnormal-retirement mechanisms should enter the first bounded model.
