# Modeling Brief: nvflare-transfer

## 1. System Overview

- **System / pin:** NVIDIA/NVFlare, Python; `53ba7ee567468ea7971dad4faccef13c6cb35dc2`, clean `/home/ubuntu/nvflare-runs-20260913/source-transfer`; eight transfer/lifetime/executor core files, 3,884 lines.
- **Category A (Distributed / Message-Passing):** producer requests, receiver confirmations, cancellation, and independent monitors form a message protocol. Apply Category B ownership/atomicity analysis to its threaded callbacks, operation draining, and source release; no BFT overlay.
- **Reference:** local functional API contracts, not a consensus algorithm or paper; `download_service.py:78-130`, `transfer_outcome.py:14-45`, and actual caller `client/cell/api.py:481-550,624-648`.
- **Main configuration:** fixed nonempty refs, explicit expected receiver identities, confirmation enabled on both peers; register every ref before exposing the payload. `transfer_outcome.py:44-45`; `via_downloader.py:774-826`.
- **Concurrency:** Cell request threads, receiver pipeline request worker, five-second transaction monitor, and callback executor; table, ref-status, stats, and operation locks protect different boundaries (`download_service.py:298,746-772,1848-1909`; `stream_utils.py:23-25,84-86`).
- **Evidence:** source and existing-test reading only. No model, TLC counterexample, trace conformance, or local regression execution in this phase. Historical fixes are context, not findings to reproduce.

## 2. Scenarios

### Scenario 1: Receiver truth and terminal progress take different paths

**Mechanism:** the winning receiver status and its progress notification are published in separate critical sections, while a terminal serve independently chooses a progress state.
**Evidence:**
- Historical: [#4865](https://github.com/NVIDIA/NVFlare/pull/4865) already separates served EOF from confirmed success; [#5097](https://github.com/NVIDIA/NVFlare/pull/5097) adds acquired-receiver cancellation across sibling refs.
- Current: `obj_served` remains provisional in confirmed mode; Consumer sends SUCCESS only after `download_completed` returns (`download_service.py:369-423,2273-2283`). This protects the ordinary aggregate-success path (priority question 1).
- Current candidate **MC-2:** cancellation records FAILED, then an admitted pipelined EOF can publish COMPLETED before cancellation publishes FAILED; the first-terminal progress latch suppresses correction (`download_service.py:313-357,425-429,587-612,1724-1748,2300-2317`). The final receiver map and strict receipt remain FAILED.
**Affected code paths:** `_download_object`, `_handle_download`, `_handle_cancel`, `_finalize_receiver`, `obj_served`, `emit_progress`.
**Suggested modeling approach:**
- Variables: per-ref/receiver final status, provisional serve, Consumer state, admitted pull, pending callback phase, first terminal progress event.
- Actions: split final-status commit, callback return, progress selection, and progress delivery; allow the already-running pipeline request to finish after cancellation.
- Granularity: keep the entire `_progress_lock` status update atomic; preserve the unlocked callback gap. Model a supported `ObjectDownloader(progress_cb=...)` observer, not a hypothetical trainer that trusts progress.
**Priority:** Medium.
**Rationale:** public callback inconsistency under ordinary scheduling; current CellClientAPI intentionally ignores source progress and checks strict outcomes (`api.py:485-487,624-648`), so no false trainer-send success is established.

### Scenario 2: Complete-payload receiver sets and caller fanout declarations

**Mechanism:** transaction completion must be interpreted against the receiver declaration actually supplied by the caller, across every registered reference.
**Evidence:**
- Historical: [#4853](https://github.com/NVIDIA/NVFlare/pull/4853) separates FINISHED from success; [#4865](https://github.com/NVIDIA/NVFlare/pull/4865) already implements declared identities and cross-ref quorum intersection.
- Current explicit mode: full success requires every declared receiver on every ref; quorum intersects successful receivers across all refs and then with declared identities (`transfer_outcome.py:156-202`). No phantom complete-payload quorum found in this mode (priority question 2).
- Current **TV-1:** multi-target `Cell._fire_and_forget` omits receiver metadata when encoding once (`cell.py:344-379`), so ViaDownloader defaults to count 1 (`via_downloader.py:779-807`). One receiver can retire refs before the second begins; non-pass-through `broadcast_request` supplies count and identities (`cell.py:303-317`).
**Affected code paths:** `compute_transfer_outcome`, `quorum_met`, `_completion_reached_locked`, Cell encode/broadcast/fire-and-forget, `ViaDownloader._finalize_download_tx`.
**Suggested modeling approach:**
- Main spec uses an explicit declaration and the current per-ref status matrix; retain full-payload aggregation as base semantics needed to interpret other scenarios.
- Keep count-only, unknown-count, and legacy wire modes separate. Do not weaken the current intersection or delete identity checks to manufacture a violation.
- TV-1 is an auxiliary caller regression, not an independent MC extension: test the supported two-target auxiliary-send path with controlled receiver start order.
**Priority:** High for caller regression; no standalone MC hunt for the already-fixed aggregation mechanism.
**Rationale:** source lifetime can end too early when a caller underdeclares recipients; explicit mode itself has the required set-based protections.

### Scenario 3: A submission error can leave two settlement executors

**Mechanism:** transaction retirement has one winner, but post-enqueue submission failure can leave both queued settlement work and an inline fallback.
**Evidence:**
- Historical: [#4906](https://github.com/NVIDIA/NVFlare/pull/4906) moves final-confirm settlement to the callback pool and supplies shutdown fallback; [#4328](https://github.com/NVIDIA/NVFlare/pull/4328) supplies executor-lifecycle context.
- Current **MC-1:** `CheckedExecutor` preserves non-shutdown RuntimeError after enqueue (`stream_utils.py:60-81`); DownloadService catches every RuntimeError and settles inline (`download_service.py:1429-1446`). CPython queue-before-thread-start behavior is explicitly represented in `stream_utils_test.py:143-167` and the saved local stdlib source.
- `_Transaction.transaction_done` has no entry latch; `_record_outcome` guards only the final receipt, after object callbacks, transaction/outcome callbacks, and release attempts (`download_service.py:895-1002,1579-1595`).
**Affected code paths:** `_finish_transaction_if_complete`, `_submit_finished_settlement`, `CheckedExecutor.submit`, `_settle_finished_transaction`, `_Transaction.transaction_done`, `_record_outcome`.
**Suggested modeling approach:**
- Variables: transaction owner, queued settlement task, submission result, inline/worker program counters, callback/release-attempt counters, recorded receipt and waiter state.
- Actions: retire; enqueue; complete submit or raise after enqueue; fallback; run queued task; callback chain; release; record. Preserve the queued task on the specific supported post-enqueue failure.
- Granularity: separate queue ownership from submission acknowledgement; do not inject arbitrary duplicate callbacks or assume retirement makes settlement itself atomic.
**Priority:** High; first MC target.
**Rationale:** independently source-verified current boundary can duplicate public callback/release effects and run them after the first waiter resolves (priority questions 3 and 5). The retained receipt is still protected against duplication; runtime confirmation remains pending.

### Scenario 4: Receiver budgets and transaction inactivity are different clocks

**Mechanism:** acquisition and idleness are scoped per receiver across the transaction, whereas transaction inactivity is refreshed by any receiver.
**Evidence:**
- Historical: [#4865](https://github.com/NVIDIA/NVFlare/pull/4865) already fixes sibling-ref idle escape and live-receiver masking; [#3853](https://github.com/NVIDIA/NVFlare/issues/3853) records a different, fixed download/unzip lifetime problem.
- Current: transaction-level per-receiver activity is independent of progress callbacks; acquisition requires declared identities, and idle checks use the receiver's latest request on any ref (`download_service.py:441-515,767-772,857-873`). Progress counters use a separate advancement rule (`transfer_progress.py:199-223`).
- Current **CR-3:** the warning that a receiver budget >= transaction timeout can never fire is wrong for sliding global inactivity (`download_service.py:736-740,774-775,1880-1883`). Enforcement remains enabled.
**Affected code paths:** `mark_active`, `mark_receiver_active`, `enforce_receiver_budgets`, `_Ref.enforce_budgets`, `_monitor_tx`.
**Suggested modeling approach:**
- Base state distinguishes `txLastRequest`, `receiverLastRequest`, acquisition, and progress counters; receiver activity covers all refs of that receiver, not other receivers.
- Budget check and final-status commit are separate. A timeout decision may legitimately precede a concurrent resumption; do not assert that any later request must undo a selected expiration.
- Use time advancement and monitor scheduling; do not impose an absolute transaction-age limit or disable budgets based on the warning.
**Priority:** Medium for faithful base semantics; diagnostic issue is review-only.
**Rationale:** addresses priority question 4 without reintroducing historical bugs. The freshness-check/write gap alone is not an established nonserializable defect.

### Scenario 5: Source release, receipt retention, and waiter observations

**Mechanism:** final receiver information, callback completion, attempted source release, receipt recording, and shutdown resolution carry different obligations.
**Evidence:**
- Historical: [#4247](https://github.com/NVIDIA/NVFlare/pull/4247), [#4270](https://github.com/NVIDIA/NVFlare/pull/4270), and [#4865](https://github.com/NVIDIA/NVFlare/pull/4865) establish source retention after envelope delivery and callback/release/record ordering.
- Current normal order: snapshot outcome/base objects; object done callbacks; transaction callback; outcome callback; each release attempt; receipt recording/waiter resolution (`download_service.py:895-1002`). Ordinary callback/release Exceptions are contained independently.
- Current limits: operation drain proceeds after 60 seconds; shutdown resolves waiters with None before cleanup; source release can raise; `CacheableObject.release` drops its reference, not all application/future references (`download_service.py:841-851,905-909,1463-1497`; `cacheable.py:99-120`).
- Current known review items **CR-1/CR-2:** unswept expired receipts can resolve new waiters; acquired-receiver queries return empty after retirement (`download_service.py:1544-1576`). Both were already noted in #4865 review.
**Affected code paths:** all terminators, operation gate, callback/release chain, `_record_outcome`, waiter registration, expiry, shutdown, caller `_wait_for_result_transfers`.
**Suggested modeling approach:**
- Carry callback and release phases into MC-1; distinguish non-None receipt resolution from shutdown/unknown-ID None resolution.
- Retain bounded drain and outstanding-operation state. Apply ordering to release attempts, not physical GC or arbitrary user hook success.
- Review/test retention and acquisition-query semantics separately; do not generate standalone hunts for acknowledged drain policy or old exception-handling fixes.
**Priority:** High as part of MC-1; otherwise contract/coverage context.
**Rationale:** a non-None waiter outcome reports the transaction verdict after cleanup attempts; success requires COMPLETED. outcome_cb itself runs before release. `FINISHED`, `done()`, and envelope acceptance alone are weaker observations (priority question 5).

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|---|---|---|
| Fixed payload, explicit receivers, terminal confirmation | Defines the main observation contract for Scenarios 1–3 | One producer, two receivers, two refs; abstract chunks; capability enabled; accepted nonce tied to serve |
| Pipeline overlap and final-status/progress split | MC-2 concerns current cancellation/EOF interleaving | Receiver and producer program counters; separate status commit and event publication |
| Partial executor submission and settlement phases | MC-1 distinguishes retirement from settlement ownership | A queued task can survive a post-enqueue RuntimeError; inline and worker phases remain separate |
| Cancellation, timers, deletion and bounded drain | Needed to interpret current outcomes and lifetime | Admit/end operations; close/drain; snapshot; callback/release/record; no admitted-op cancellation assumption |
| Explicit observer state | Makes the consequences measurable | Count public settlement callbacks and release attempts; record progress events and waiter observations |

### 3.2 Do Not Model (with rationale)

| What | Why |
|---|---|
| Reverted confirmation, quorum, identity, ownership, or exception fixes | Already fixed; historical evidence only, not current MC findings |
| TV-1 argument propagation and CR-1/2/3 diagnostics/API choices as MC hunts | Local regression or code review is sufficient |
| Late additions after earlier refs finish; malformed/adversarial callers | Unsupported registration lifecycle or outside cooperative functional scope |
| Full FedAvg, job scheduling, trainer process management, HA, serializer/byte-transport internals, tensor numerics | Explicit scope exclusions; use abstract ordinary outcomes and the minimal caller barrier |
| Forced physical memory reclamation or unconditional bounded shutdown | Neither is promised by the inspected hooks; a hung callback or executor worker can outlive operation-drain timeout |

## 4. Proposed Extensions

No reference TLA+ model is supplied; these extend a small functional transfer skeleton. Current confirmation/aggregation/budget behavior is base semantics, not an old-fix hunting configuration.

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| Partial asynchronous submission | `queuedSettlement`, `submitResult`, `inlinePC`, `workerPC` | Expose the actual enqueue/error/fallback ownership window | 3 / MC-1 |
| Observable settlement phases | `doneCalls`, `outcomeCbCalls`, `releaseAttempts`, `waiterObservation` | Distinguish single retained receipt from repeated external effects | 3, 5 / MC-1 |
| Independent terminal publication | `receiverFinal`, `pendingTerminalEvent`, `progressTerminal`, `servePC`, `cancelPC` | Preserve cancellation vs terminal-serve notification order | 1 / MC-2 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| TypeOK | Safety | Finite-domain protocol/observer state is well formed; no assumed desired outcome | Base model |
| SingleSettlementEffects | Safety | Each transaction lifecycle callback and each registered source release attempt occurs at most once | MC-1 |
| NoSettlementEffectsAfterReceipt | Safety | A non-None waiter receipt is not followed by another settlement callback or release attempt for that transaction | MC-1 |
| CompletedProgressHasReceiverSuccess | Safety | In confirmed mode, source progress COMPLETED for a receiver/ref implies its winning final status is SUCCESS | MC-2 |
| EventualSettlementObservation | Conditional liveness | With runnable executor/monitor, finite callback execution and a terminating transaction, its waiter eventually receives a receipt or shutdown None | MC-1; no universal wall-clock bound |

Retain current receipt-owner, immutable-status, aggregation and bounded-drain semantics when checking these properties. Do not assume single settlement entry or consistent progress emission; those are the questions being checked.

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Forward-looking current question | Expected violation if confirmed | Scenario |
|---|---|---|---|
| MC-1 | Can an enqueued settlement survive submit failure, run after inline fallback, and repeat callback/release effects after waiter publication? | SingleSettlementEffects; NoSettlementEffectsAfterReceipt | 3, 5 |
| MC-2 | Can ordinary pipelined cancellation interleave final-status commit and terminal EOF progress to leave a permanent COMPLETED notification for a FAILED receiver? | CompletedProgressHasReceiverSuccess | 1 |

Output-value check: MC-1 would establish duplicated public settlement effects at a currently unprotected integration boundary; MC-2 would establish a contradictory public progress notification. Neither predicts a new successful strict receipt, production data corruption, or a replay of an upstream-fixed bug.

### 6.2 Test-Verifiable

| ID | Description | Suggested local test approach |
|---|---|---|
| TV-1 | Supported multi-target fire-and-forget defaults its payload transaction to one receiver (`cell.py:344-379`; `via_downloader.py:779-807`) | Two cooperative receivers, ordinary externalized payload, delay second acquisition; compare direct broadcast and single-target controls |
| TV-2 | Confirm actual runtime reachability/observer effects of MC-1 and MC-2 | Isolated executor/handler regressions; observe callback counts, release attempts, receipt, progress, and real running pipeline request; no resource exhaustion campaign |
| TV-3 | Count-only per-ref full-success differs from common-receiver quorum (`transfer_outcome.py:197-202,169-179`) | Small status matrices plus actual caller identity/count contract; do not apply this weaker mode to the main explicit-identity model |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR-1 | Waiter may return an expired but unswept receipt while outcome query expires it (`download_service.py:1554-1558,1604-1608`); known review item | Reconcile retention API documentation; not stale-attempt certification because ID ownership/exclusion remains separate |
| CR-2 | `acquired_receivers()` loses visible acquisition at retirement (`download_service.py:1568-1576`); known review item | Clarify live-only query versus cumulative waiter metadata; no current trainer misuse found |
| CR-3 | Budget >= global inactivity warning incorrectly says enforcement is disabled (`download_service.py:736-740`) | Correct diagnostic; do not change budget semantics based on it |
| CR-4 | Stale cacheable comment says source release/produce cannot overlap (`cacheable.py:133-140`) | Align wording with documented forced drain and release-attempt limitations; no independent lifetime defect established |

## 7. Reference Pointers

- Detailed audit: [analysis-report.md](analysis-report.md); [history-review.md](history-review.md); [independent outcome/progress audit](deep-outcome-progress.md); [caller audit](analysis-evidence/deep-callers.md); [independent download audit](analysis-evidence/issues-a/deep-download.md).
- Source root: `/home/ubuntu/nvflare-runs-20260913/source-transfer`. Unqualified transfer filenames above are under `nvflare/fuel/f3/streaming/`; `via_downloader.py` under `nvflare/fuel/utils/fobs/decomposers/`; `cell.py` under `nvflare/fuel/f3/cellnet/`; `api.py` under `nvflare/client/cell/`.
- Existing tests read, not run: `receiver_confirm_test.py`, `receiver_budget_test.py`, `transfer_outcome_test.py`, `transfer_waiter_test.py`, `stream_utils_test.py`. `test_pass_through_e2e.py:25-32,92-101,113-130` has two real Cells and a simulated CJ hop; it does not check waiter/outcome ordering or explicit receiver identities.
- Archaeology: 33 core commits reviewed, 21 bug-bearing/mixed commit contexts analyzed, 12 exclusions; 176 distinct issues collected, 30 full issue threads and 32 full PR discussions read; all 15 open PRs inventoried. Counts distinguish ports, discovery-only hits, and current findings in the report.
- Reproducible evidence inventory: [source-manifest.json](analysis-evidence/source-manifest.json), [coverage.json](analysis-evidence/coverage.json), [stdlib executor source](analysis-evidence/history/stdlib-executor-source.txt), and the archived GitHub query/thread manifests under `analysis-evidence/`.
