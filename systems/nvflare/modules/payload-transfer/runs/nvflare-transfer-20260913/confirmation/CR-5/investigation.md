# CR-5 Investigation

## Scope

Finding source: Code Review. No model-checking counterexample is supplied for CR-5.
I did not read spec files, bug-report.md, other finding reports, confirmed-bugs.md,
or the shared repair-requests queue.

Worktree under test:
`/home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-transfer-20260913/nvflare-transfer/.specula-output/confirmation/CR-5/worktree`

HEAD: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`

Dirty checkout note: `nvflare/fuel/f3/streaming/download_service.py`,
`nvflare/client/cell/api.py`, and `nvflare/fuel/f3/streaming/specula_trace.py`
were already modified before this confirmation pass. The visible diff is trace
instrumentation on the two production files, so the confirmation tests use the
current checked-out behavior without reverting those changes.

## Step 1: Code Audit

Relevant implementation facts:

- `DownloadService.new_transaction()` registers the `_outcome_owners` entry and
  `_tx_table` entry while holding `_tx_lock`, then `_outcome_lock`; it rejects a
  duplicate id while live, settling, receipted, or under a termination marker.
  It lazily expires an old receipt inline before deciding whether the id is
  still in use (`nvflare/fuel/f3/streaming/download_service.py:1402-1427`).
- `_Transaction.transaction_done()` drains admitted operations, computes an
  aggregate `TransferOutcome`, runs per-object callbacks, runs
  `transaction_done_cb`, runs `outcome_cb`, then releases source objects and only
  then invokes `on_outcome`, which records the receipt and resolves waiters
  (`download_service.py:930-1052`).
- `_record_outcome()` requires the transaction owner object, consumes ownership,
  re-stamps the receipt timestamp at recording time, stores `_tx_outcomes`, and
  resolves all parked waiters under `_outcome_lock`
  (`download_service.py:1644-1663`).
- `get_transaction_outcome()` checks `TransferOutcome.expired(now,
  TX_OUTCOME_TTL)` inline, removes an expired receipt, and returns `None`
  (`download_service.py:1666-1677`).
- `get_transfer_waiter()` first checks `_tx_outcomes`. If any receipt object is
  present, it resolves the new waiter with that receipt without checking expiry;
  only when no receipt is present and the id has no owner does it resolve `None`
  (`download_service.py:1607-1631`).
- `TransferWaiter.acquired_receivers()` delegates to
  `DownloadService.get_acquired_receivers()` (`download_service.py:1123-1126`).
  `get_acquired_receivers()` only reads a live transaction from `_tx_table`, so it
  returns an empty set after the transaction is retired
  (`download_service.py:1633-1642`).
- Receiver acquisition is real runtime state, not progress-callback-only state:
  `_Ref.mark_receiver_active()` updates both the per-ref timestamp and the
  transaction-level `_acquired_receivers` set on every download request
  (`download_service.py:453-464`). The download request handler calls it on the
  normal producer-side wire path (`download_service.py:1733-1850`).
- `CacheableObject.transaction_done()` calls `clear_cache()`, which clears only
  the chunk cache. `CacheableObject.release()` clears `base_obj`. `_get_item()`
  checks the cache and `base_obj`, raising after release; its nearby comment still
  says a concurrent release window cannot open because release is invoked from
  `transaction_done_cb`, but the current implementation calls `release()` from
  `_Transaction.transaction_done()` after callbacks (`cacheable.py:96-141`,
  `download_service.py:985-1045`).
- The high-level result sender creates a waiter at transaction creation time via
  `DownloadService.get_transfer_waiter(transaction.tx_id)` and waits for strict
  terminal success in `CellClientAPI._wait_for_result_transfers()`
  (`nvflare/client/cell/api.py:483-485`, `api.py:626-651`). That production
  caller does not create a new waiter after receipt TTL expiry, and it re-reads
  `waiter.outcome` after observing `done()` to avoid the separate fixed polling
  race.

Reachability:

- Normal receiver pulls reach `_handle_download()`, `mark_receiver_active()`,
  `_acquired_receivers`, provisional/final receiver status recording, monitor or
  eager transaction settlement, `_record_outcome()`, and `TransferWaiter.wait()`.
- A late waiter over an unswept expired receipt is reachable if a caller asks for
  a new waiter after `TX_OUTCOME_TTL` but before `_expire_outcomes()` or
  `get_transaction_outcome()` has removed the receipt. In production the monitor
  sweeps periodically; in a deterministic local test the window is time-compressed
  by lowering `TX_OUTCOME_TTL` on an isolated service.
- Post-retirement `acquired_receivers()` returning empty is reachable after any
  completed, deleted, or timed-out transaction because the acquisition set is
  stored only on the live `_Transaction`.
- The stale `CacheableObject` comment is reachable only as documentation. The
  runtime code has an explicit release method and a guard against post-release
  item access.

Trigger scenario for Phase 2:

1. Create a `DownloadService` transaction with one receiver and one object.
2. Have receiver `r1` issue normal producer-side download requests until EOF.
3. Confirm completion where required and wait for the transaction outcome.
4. Observe callback/release order and waiter resolution.
5. Query `acquired_receivers()` before and after retirement.
6. Time-compress `TX_OUTCOME_TTL`, let a recorded receipt age without a sweep,
   create a late waiter, then compare with `get_transaction_outcome()`.
7. Exercise `CacheableObject.transaction_done()`, `release()`, and post-release
   `_get_item()` behavior.

Safeguards recorded for Phase 2:

- `_record_outcome()` resolves waiters only after callback and release attempts.
- `get_transaction_outcome()`, `_expire_outcomes()`, and duplicate-id creation
  perform expiry cleanup.
- Same-id reuse expires old receipts inline and rejects ids while live/settling.
- `CellClientAPI._wait_for_result_transfers()` uses waiters created during
  result publication rather than late, post-TTL waiter lookup.
- `CacheableObject._get_item()` fails defensively after `base_obj` is released.

## Step 2: Developer Knowledge Search

Local history:

- `git log --all --oneline --grep='receipt|waiter|acquired|release|outcome|DownloadService|CacheableObject' -- ...`
  showed relevant merged commits:
  `0ff5c804b Add F3 payload layer: receiver-confirmed completion, receiver budgets, awaitable transfer facade (#4865)`,
  `c0efa7297 Add Client API execution modes design docs and F3 aggregate transfer outcome (#4853)`,
  and `23f2d9c05 Fix result transfer waiter polling race (#5134)`.
- PR #4865 states that upper layers consume `waiter = downloader.get_waiter()`
  and `outcome = waiter.wait(timeout=...)`; it also documents settle-then-resolve,
  receipt retention for `TX_OUTCOME_TTL`, attempt-scoped ids, `acquired_receivers()`
  as the V1 PAYLOAD_ACQUIRED signal, receiver-confirmed truth, receiver budgets,
  and tests for waiter never-hangs behavior:
  https://github.com/NVIDIA/NVFlare/pull/4865
- PR #5134 reports and fixes a different race in
  `CellClientAPI._wait_for_result_transfers()`: `waiter.wait(timeout)` could return
  `None`, then the event could become done before the caller checked `done()`. The
  fix re-reads `waiter.outcome` after observing done:
  https://github.com/NVIDIA/NVFlare/pull/5134
- PR #4247 includes an older CacheableObject source-release change:
  https://github.com/NVIDIA/NVFlare/pull/4247

Comments and docs:

- `docs/design/client_api_execution_modes.md:217-220` says the Client API
  observes actual `DownloadService` transactions and waits on their outcomes.
- `docs/design/client_api_execution_modes.md:240-252` says the trainer waits for
  the strict terminal outcome of every created transaction before releasing result
  resources or allowing a one-task process to exit.
- `ObjectDownloader.get_waiter()` documents that the waiter blocks until the
  aggregate `TransferOutcome` is recorded and that `COMPLETED` means every
  expected receiver succeeded (`nvflare/fuel/f3/streaming/obj_downloader.py:98-105`).
- `DownloadService.get_transaction_outcome()` explicitly documents `None` for an
  expired receipt (`download_service.py:1666-1677`).

Existing tests:

- `tests/unit_test/fuel/f3/streaming/transfer_waiter_test.py:202-228` asserts a
  waiter returns only after `transaction_done_cb`, `outcome_cb`, and source
  release.
- `tests/unit_test/fuel/f3/streaming/transfer_waiter_test.py:177-183` asserts
  live acquisition visibility before completion.
- `tests/unit_test/fuel/f3/streaming/transfer_outcome_test.py:374-407` asserts
  duplicate-id rejection while receipted and inline freeing after receipt expiry.
- `tests/unit_test/fuel/f3/streaming/transfer_outcome_test.py:749-773` asserts
  receipt TTL starts at recording time, not verdict-computation time.
- `tests/unit_test/fuel/f3/streaming/test_base_obj_cleanup.py` and
  `tests/unit_test/fuel/f3/streaming/cacheable_test.py` cover the `clear_cache()`
  versus `release()` source-lifetime split.

## Step 3: Known Status / Precedent

Issue/PR search performed on 2026-09-13:

- GitHub Search API query `repo:NVIDIA/NVFlare "TX_OUTCOME_TTL"` returned PR
  #4865.
- GitHub Search API query `repo:NVIDIA/NVFlare "acquired_receivers"` returned PR
  #4865.
- GitHub Search API query `repo:NVIDIA/NVFlare "CacheableObject" "release"
  "transaction_done_cb"` returned PRs #4280 and #4247.
- GitHub Search API query `repo:NVIDIA/NVFlare "get_transfer_waiter" "expired"`
  returned PR #4865.
- Web search for NVFlare issues/PRs combining `DownloadService`,
  `get_transfer_waiter`, `TX_OUTCOME_TTL`, `receipt`, and `acquired_receivers`
  did not find a separate filed issue or recently merged/closed PR reporting the
  exact current mechanisms in CR-5 as defects.

Known-status evidence:

- #5134 is a known fixed waiter polling race in the Client API, but it is not the
  CR-5 residual mechanism. It concerns a waiter already held by the caller, where
  a timed poll returns `None` immediately before the event becomes done.
- #4865 is a merged design/feature PR and records several intended contracts
  relevant to CR-5, but I did not find a filed issue/PR that separately reports
  "late waiter resolves from an unswept expired receipt" or
  "post-retirement acquired_receivers returns empty" as current defects at the
  cited sites.

Novelty for this confirmation entry: NEW.
