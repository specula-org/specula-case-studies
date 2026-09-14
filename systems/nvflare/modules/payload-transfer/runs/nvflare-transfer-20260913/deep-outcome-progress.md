# Deep review: outcome, progress, waiter, and executor publication

Snapshot: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`. Evidence is source reading and existing-test reading only. No tests, failure injection, model checking, or trace validation were performed.

## Reading coverage

Read in full:
- `nvflare/fuel/f3/streaming/transfer_outcome.py` (271 lines).
- `nvflare/fuel/f3/streaming/transfer_progress.py` (465 lines).
- `nvflare/fuel/f3/streaming/stream_utils.py` (166 lines; minimum executor integration).
- `nvflare/fuel/f3/streaming/cacheable.py` (260 lines; minimum source lifetime integration).
- `tests/unit_test/fuel/f3/streaming/transfer_outcome_test.py` (1,019 lines).
- `tests/unit_test/fuel/f3/streaming/transfer_waiter_test.py` (235 lines).

Re-read all relevant DownloadService finalization, progress construction, receipt recording, eager settlement, operation gate, shutdown, and pipelined consume-error paths with exact line numbers. Read targeted `receiver_confirm_test.py:90-280`, `download_service_test.py:1017-1145`, `stream_utils_test.py:118-167`, and current trainer caller `nvflare/client/cell/api.py:453-565,624-657,800-815`. The parent owns full DownloadService/caller analysis. No TODO/FIXME/HACK/XXX/BUG/WARN matches were present in the three outcome/progress/executor files.

## Contract conclusions that are supported

1. **Explicit identity full success is a complete-payload certificate.** `_all_receivers_succeeded` requires a positive receiver count and nonempty refs (`transfer_outcome.py:185-196`), then checks each declared receiver on each ref. The constructor validates count/identity consistency (`download_service.py:706-719`). Unexpected receivers cannot fill missing declared receivers.
2. **Quorum uses the intersection, not independent per-ref cardinalities.** `quorum_met` builds each ref's success set, intersects all sets, intersects the declared identities, then compares k (`transfer_outcome.py:156-179`). This already addresses the historical #4865 mechanism; do not target it by undoing the intersection.
3. **FINISHED is termination, not success.** Failed receivers count as final in `_completion_reached_locked` (`download_service.py:359-367`), while aggregate `completed` depends on `status == completed` (`transfer_outcome.py:152-154`). Known TIMEOUT/DELETED causes may still have completed outcomes if all expected receiver successes were already final (`transfer_outcome.py:242-249`). This is documented intent, not an inconsistency.
4. **Current trainer callers check strict receipt success.** `ClientAPI.send` tracks created transaction waiters; its progress callback is deliberately no-op (`nvflare/client/cell/api.py:481-487`). `_wait_for_result_transfers` handles timeout-vs-terminal-None race by rereading outcome and rejects non-COMPLETED receipts (`api.py:624-648`). Thus a producer progress event alone does not make this caller report send success.
5. **Normal waiter publication follows callback and attempted-release ordering.** `_Transaction.transaction_done` attempts per-object callbacks, transaction callback, outcome callback, each source release, then receipt recording (`download_service.py:955-999`). `outcome_cb` deliberately runs before release and cannot itself be interpreted as a release barrier. The receipt is re-timestamped at recording, and owner identity guards the slot (`download_service.py:1579-1595`).
6. **Release errors do not retroactively negate delivered success.** `_invoke_cb_safely` contains ordinary `Exception` (`download_service.py:645-655`), and each release attempt is independently guarded (`:985-999`). Existing tests explicitly require a COMPLETED receipt despite a raising release (`transfer_outcome_test.py:179-202`). A returned success outcome certifies receiver delivery plus release attempts, not successful physical reclamation by a faulty custom hook.
7. **Shutdown None is a weaker, intentional outcome.** Shutdown clears owners and releases all waiters with None before deferred transaction callbacks and source cleanup (`download_service.py:1463-1497`). The normal callback/release-before-outcome guarantee must be guarded by non-None receipt resolution; `done()` alone is not that guarantee. `transfer_outcome_test.py:888-918` explicitly pins immediate None in this window.
8. **Draining is bounded and has a stated exception.** `_drain_ops` closes admission and waits for active operations until OP_DRAIN_TIMEOUT; transaction settlement proceeds after timeout (`download_service.py:841-851,905-909`). Existing tests retain the transaction ID exclusion until a leaked operation exits, even after receipt expiry (`transfer_outcome_test.py:409-445,671-713,775-816`). A universal invariant claiming release never overlaps any operation would contradict supported bounded-drain behavior.
9. **Progress tracking and budgets are different clocks.** `TransferProgressTracker` only advances last_progress_time when counters increase or a terminal state is observed (`transfer_progress.py:199-223`). DownloadService receiver budgets use request activity across refs of the same receiver; global transaction inactivity is refreshed by any receiver. Tracker is currently not instantiated anywhere else in production (`rg TransferProgressTracker nvflare` only returns its definition); source progress remains a public callback surface.

## DOP-1: asynchronous submission may already own the settlement despite RuntimeError

**Assessment:** Strong source-grounded current candidate; suitable for model checking of queue admission/settlement ownership, followed by a local functional regression. Independently cross-checked from the parent's candidate. No runtime confirmation yet.

**Entry conditions:** A valid receiver-confirmed transaction with declared receivers completes via normal confirmation or receiver cancellation. `_finish_transaction_if_complete` unlinks it once under `_tx_lock` and calls `_submit_finished_settlement` (`download_service.py:1411-1426`). The callback executor has live queued work or can later recover; creating an additional thread fails with ordinary resource-pressure RuntimeError.

**Exact path:**
1. `CheckedExecutor.submit` forwards into ThreadPoolExecutor (`stream_utils.py:60-66`). Its own comment explicitly states thread-start failure can happen after work is enqueued and rethrows that non-shutdown RuntimeError (`:71-78`).
2. Local CPython 3.14.4 source confirms `_work_queue.put(w)` occurs before `_adjust_thread_count()`, which calls `Thread.start()`. The failed submit does not remove the queued work. Saved path/version/excerpts: `analysis-evidence/history/stdlib-executor-source.txt`.
3. DownloadService catches **every** RuntimeError from submission, treats it as a missing submission, and calls `_settle_finished_transaction(tx)` synchronously (`download_service.py:1435-1446`).
4. Existing or later recovered callback workers can execute the original queued `_settle_finished_transaction(tx)` too. `_Transaction.transaction_done` has no settlement-start guard; `_ops_closed` only gates serve/confirm/budget admission and `_settlement_complete` is assigned at the end, never checked at entry (`:822-851,895-1002`).
5. Consequently `obj.transaction_done`, `transaction_done_cb`, `outcome_cb`, and source release attempts can run twice, potentially concurrently (`:955-989`). The `_record_outcome` owner check drops the second **receipt recording** (`:1582-1585`), after those side effects already occurred.

**Compensating mechanisms checked:** Atomic retirement ensures only one normal terminator wins; it does not prevent the one winner from scheduling two callbacks after a partially successful submit. Frozen outcomes prevent mutation, not duplicate callback side effects. The activity gate does not count or exclude settlement work. The receipt-owner guard and termination marker do not gate entry to transaction_done.

**Existing-test evidence:** `stream_utils_test.py:143-166` deliberately injects a Thread.start RuntimeError and asserts the first queued work item executes after a recovered submission. This pins the executor's intentional semantics. It does not connect that failure to DownloadService's synchronous settlement fallback. Existing outcome/waiter tests cover callback exceptions, source-release exceptions, persistent computation errors, and drain leaks; they do not cover enqueued-settlement-plus-fallback.

**Observable consequence:** Public lifecycle callbacks and custom release hooks are documented/assumed to run once (`download_service.py:895-903`). Duplicate callback effects, duplicate cleanup attempts, and callback activity after the first waiter resolution violate that ordering/ownership contract even when only one receipt is retained. Cacheable's own clear/release are mostly idempotent (`cacheable.py:99-120`), which limits the built-in helper's immediate consequence; no claim of double retained outcome or demonstrated production model corruption is warranted.

**Model shape:** Distinguish transaction retirement, settlement enqueue, submission result, synchronous fallback start, queued worker start, callback phase, source-release attempt, and receipt recording. An ordinary failure action may occur after enqueue, without deleting the queued work. Suggested invariants: transaction lifecycle callbacks at most once; each registered source release attempt at most once; no settlement callback after successful waiter publication. Keep receipt-recorded-at-most-once as a separate property expected to survive this counterexample. Do not inject arbitrary duplicate callbacks; derive the duplicate from the current caller/executor boundary.

## DOP-2: cancellation status and terminal progress can disagree

**Assessment:** Source-grounded current race, best kept Test-Verifiable or Code-Review-Only unless a meaningful progress-based observer is established. It does not establish false aggregate success. No runtime confirmation yet.

**Entry conditions:** A pipelined receiver has received a DATA reply, so producer cancellation support is known, and an EOF pull is already admitted while the receiver encounters ordinary consume failure or cancellation. `ItemConsumer.supports_pipelining=True` (`cacheable.py:235-237`); the next pull is submitted before consume and a consume error cancels the Future and sends producer cancellation (`download_service.py:2300-2317`). Cancellation cannot retract a pull that is already running.

**Interleaving:**
1. `_handle_cancel` reaches `_finalize_receiver` and commits receiver FAILED under `_progress_lock` (`download_service.py:1814-1839,313-335`).
2. `_finalize_receiver` releases that lock, invokes downloaded_to_one/all callbacks, and only then returns so `obj_cancelled` can emit FAILED progress (`:337-357,425-429`). Ordinary thread scheduling at this boundary is sufficient; a slow callback makes the window larger but need not exceed the drain timeout.
3. Meanwhile the already-admitted producer EOF returns. `obj_served(expect_confirm=True)` finds a final receiver and returns no nonce (`:391-395`). The handler's no-nonce branch emits COMPLETED based on EOF (`:1733-1748`) despite the final map already containing FAILED.
4. That first terminal progress marks the progress record terminal (`:587-588,611-612`). The later cancellation FAILED event is suppressed. Final TransferOutcome correctly retains FAILED.

**Compensations/limits:** The drain gate ensures both admitted operations finish before normal settlement; it does not order per-receiver final status vs the corresponding progress emission. `_finalize_receiver` correctly prevents map overwrites. Current managed trainer progress callback is no-op and `_wait_for_result_transfers` checks actual outcome, so this is not a demonstrated send-success defect. Sequence handling in TransferProgressTracker prevents stale reordering but cannot repair a wrongly chosen first terminal event.

**Existing-test gap:** `receiver_confirm_test.py:210-243` tests cancellation during an admitted DATA serve and correctly checks release draining, but configures no progress observer and does not pause between receiver-map update and FAILED emission. `download_service_test.py:1017-1145` checks per-receiver progress on ordinary sequential paths. Neither establishes cancellation-vs-EOF progress consistency.

**Suggested local check:** Observe progress and final receiver maps through the supported handler paths while scheduling the above boundary, with receiver IDs declared and confirmation enabled. If the API contract allows terminal progress to be advisory independent of final receiver truth, document it; otherwise derive progress from the winning final receiver record under a shared atomicity boundary. Do not claim the current receipt or quorum becomes successful.

## DOP-3: timeout warning overstates the global transaction clock

**Assessment:** Code-review-only documentation/diagnostic issue. `download_service.py:736-740` warns a receiver budget greater than or equal to transaction timeout can never fire. But transaction timeout is elapsed time since any receiver activity; a healthy receiver can keep that clock fresh while a stalled receiver exceeds its larger idle budget, or a never-started declared receiver exceeds acquisition budget. The enforcement values are not disabled. This must not become a modeling assumption that prevents those budgets from firing.

## Explicitly excluded or limited questions

- **Count-only disjoint receiver subsets:** `_all_receivers_succeeded` falls back to independent per-ref counts (`transfer_outcome.py:197-202`), so without declared identities disjoint subsets can meet the count on different refs. `quorum_met` with an explicit k still intersects. This should be documented as a distinct count-only contract/caller question; it is excluded from the main explicit-identity scenario, and no actual current caller with the required receiver mismatch has been established here.
- **Completed outcome after DELETED/TIMEOUT:** Explicitly intended receiver-truth precedence, covered by tests; no finding.
- **Callback raises / release raises / computation raises:** Existing guards and fail-closed fallback cover ordinary exceptions; source-release attempt failure does not negate receipt delivery. Do not recreate their fixed predecessor behavior.
- **Shutdown None before cleanup:** Intentional absent-receipt termination, not a successful waiter certificate.
- **Operation leaking beyond drain budget:** Acknowledged bounded-drain behavior, not a standalone invariant violation target. Model actual exception and preserve ID isolation.
- **Unsupported late object registration or hand-built malformed outcome metadata:** Excluded by supported registration lifecycle and caller validation; do not exploit low-level constructors to manufacture success.
- **Tracker thread safety in isolation:** The tracker has no internal lock, but no current production instantiation was found. Do not infer a production race from this helper alone.
- **Underlying transport, serialization/security internals, external process-management system:** Outside scope. Only executor queue admission and caller wait interpretation were followed.

## Recommended priority

DOP-1 is the strongest new modelable current interaction: repeated callback/release side effects after partial submission success. DOP-2 remains a narrower progress-surface race needing observer/contract review. DOP-3 belongs in review-only notes. Keep completed/FINISHED/quorum and confirmed/legacy semantics explicit so the model neither invents a stronger legacy contract nor encodes desired correctness as an assumption.
