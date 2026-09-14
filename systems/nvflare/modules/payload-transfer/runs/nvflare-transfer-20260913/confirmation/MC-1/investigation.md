# MC-1 Investigation

## Code audit

Primary location: `nvflare/fuel/f3/streaming/download_service.py:1492`.

`DownloadService._finish_transaction_if_complete()` removes a completed transaction from `_tx_table` under `_tx_lock`, then calls `_submit_finished_settlement()`. That method calls `callback_thread_pool.submit(cls._settle_finished_transaction, tx)` and falls back to inline settlement on `RuntimeError` or `None` (`download_service.py:1485-1505`). `_settle_finished_transaction()` invokes `tx.transaction_done(..., on_outcome=_record_outcome)` and then `_sync_termination_marker()` (`download_service.py:1508-1513`).

`CheckedExecutor.submit()` preserves non-shutdown `RuntimeError`s. Its inline comment explicitly names `Thread.start()` failing after work was enqueued as a visible, non-stopping RuntimeError (`stream_utils.py:60-78`). The existing upstream unit test `tests/unit_test/fuel/f3/streaming/stream_utils_test.py:143-166` asserts this CPython queue-before-start behavior and verifies a later recovered submission drains the first queued item.

`_Transaction.transaction_done()` performs all settlement side effects before outcome ownership is consumed: object `transaction_done` (`download_service.py:993-1003`), transaction callback (`download_service.py:1006-1016`), outcome callback (`download_service.py:1018-1020`), source release (`download_service.py:1027-1034`), and only then `on_outcome` / `_record_outcome` (`download_service.py:1044-1045`). `_record_outcome()` has an owner guard (`download_service.py:1645-1653`), but that guard only protects the stored receipt and waiter resolution after the side effects already ran.

Reachable path: public/normal producer flow uses `ObjectDownloader` to create a transaction with `DownloadService.new_transaction()` and optional `transaction_done_cb`/`outcome_cb` (`obj_downloader.py:21-79`), callers can obtain a `TransferWaiter` (`obj_downloader.py:98-105`), and receiver-confirmed completion reaches `_handle_confirm()` via ordinary download messages. Accepted confirmation calls `_finish_transaction_if_complete()` after the operation gate exits (`download_service.py:1853-1885`).

Concrete trigger scenario:

1. A producer creates a receiver-confirmed transaction with one ref and one expected receiver.
2. The receiver pulls data and then receives terminal EOF with a confirmation nonce.
3. The receiver sends a legitimate confirmation echoing that nonce.
4. `_finish_transaction_if_complete()` retires the transaction and calls `_submit_finished_settlement()`.
5. `ThreadPoolExecutor.submit()` publishes the settlement work item to the callback pool queue, but `Thread.start()` raises `RuntimeError("can't start new thread")`.
6. `_submit_finished_settlement()` catches the `RuntimeError` and settles inline; after resource pressure clears, the queued worker also runs the same transaction settlement.
7. Both settlement entrants execute object, transaction, outcome callback, and release side effects. `_record_outcome()` drops the stale second receipt, so the stored outcome is single but the side effects are duplicated.

The supplied counterexample matches this sequence: state 54 has `queued |-> TRUE` and `submitPC |-> "enqueued"`, state 62 takes `MCCheckedExecutorSubmitRuntimeError` and moves to fallback, and state 77 shows both `inline` and `worker` in `objectDone` with `objectDoneCalls(ref1) = 2`.

## Developer-knowledge search

Comments near `_submit_finished_settlement()` state the intended fallback is to complete cleanup rather than strand source and termination marker when the shared executor races shutdown (`download_service.py:1496-1505`). Comments near `transaction_done()` state it "Runs exactly once per transaction" (`download_service.py:937-938`) and that waiters should resolve only after callbacks and source release (`download_service.py:935-937`). This supports a single-settlement intent.

`git blame` attributes eager async settlement to PR #4906 (`2c63764cce`, 2026-07-24) and the non-shutdown RuntimeError preservation in `CheckedExecutor` to PR #5097 (`9b5dddfd2d`, 2026-08-19). PR #5097 documents preserving non-shutdown `RuntimeError`s and preventing a live but resource-starved pool from being permanently stopped; it does not report duplicate settlement effects in `DownloadService`.

Existing tests assert related contracts: `transfer_outcome_test.py:204-222` asserts outcome recording happens after `done_cb`, `outcome_cb`, and release; `stream_utils_test.py:143-166` asserts the queued-item-after-Thread.start-failure behavior that forms the injected precondition. No existing test found asserts that this queued-then-inline settlement path is single-entry.

## Known-status / precedent

Issue tracker / PR searches were run across open and closed entries:

- Issues: `CheckedExecutor RuntimeError submit`, `transaction_done callback_thread_pool submit RuntimeError`, `duplicate settlement DownloadService`, `source release transaction_done callback`, `TransferWaiter outcome recording release`, `download service double callback`.
- PRs: the same search terms.

No issue reported this exact duplicate settlement mechanism at `DownloadService._submit_finished_settlement`. PR hits (#4853, #4865, #4906, #5097, and older F3 PRs) are adjacent lifecycle/transfer changes, not an existing report of the same post-enqueue submit failure causing duplicate object/transaction/outcome callbacks and release attempts.

Novelty: NEW.

## Reproduction record

Reproduction file: `/home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-transfer-20260913/nvflare-transfer/.specula-output/repro/test_bugMC-1_post_enqueue_settlement.py`.

Command executed:

```sh
timeout 2m env PYTHONPATH=/home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-transfer-20260913/nvflare-transfer/.specula-output/confirmation/MC-1/worktree python /home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-transfer-20260913/nvflare-transfer/.specula-output/repro/test_bugMC-1_post_enqueue_settlement.py
```

Escalation:

- Level 0 normal public flow: one object callback, one transaction callback, one outcome callback, one release.
- Level 1 timing-only control: delayed transaction callback; still one object callback, one transaction callback, one outcome callback, one release.
- Level 2 state/fault injection: injects the MC counterexample's admissible post-enqueue submit failure by raising from the first callback-pool `Thread.start()` after queue publication, then starts a recovered worker to drain the queued settlement item. This reproduces duplicate settlement side effects with a single stored receipt.
