# CR-4 Investigation

Finding: Receiver budget diagnostics and activity clocks remain review-only.

Source: Code Review. The supplied finding says the Scenario 4 model-checking run explored the budget behavior without emitting a violation, so this is not MC-sourced.

Head under test: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`.

Dirty checkout note: before this investigation, `git status --short` showed existing local changes in `nvflare/client/cell/api.py`, `nvflare/fuel/f3/streaming/download_service.py`, and untracked `nvflare/fuel/f3/streaming/specula_trace.py`. The relevant semantic budget/warning lines match `origin/main`; the visible diff in `download_service.py` is trace instrumentation.

## Step 1: Code Audit

Relevant sites:

- `nvflare/fuel/f3/streaming/download_service.py:114-118` documents the transaction timeout as a transaction-wide clock since the last downloading activity on any object from any receiver.
- `nvflare/fuel/f3/streaming/download_service.py:124-132` documents per-receiver lifecycle: unseen receivers can fail by acquire budget and acquired/provisional receivers can fail by idle budget or transaction TTL.
- `nvflare/fuel/f3/streaming/download_service.py:249-255` comments that budgets longer than the transaction timeout can never fire.
- `nvflare/fuel/f3/streaming/download_service.py:453-464` records receiver activity and also refreshes transaction-level activity.
- `nvflare/fuel/f3/streaming/download_service.py:470-534` enforces acquire/idle budgets over declared receivers plus acquired receivers. Idle is computed per receiver from `tx_last_active[receiver]`; enforcement rechecks the receiver timestamp before finalizing failed.
- `nvflare/fuel/f3/streaming/download_service.py:762-767` warns when a receiver budget is greater than or equal to the transaction timeout: "the budget can never fire and is effectively disabled".
- `nvflare/fuel/f3/streaming/download_service.py:890-907` runs receiver budget enforcement from the transaction monitor.
- `nvflare/fuel/f3/streaming/download_service.py:1930-1973` runs budget enforcement before the same monitor iteration checks `now - tx.last_active_time > tx.timeout` and retires expired/finished transactions.
- `nvflare/fuel/f3/streaming/obj_downloader.py:65-78` is the public facade path passing caller timeout and receiver budgets into `DownloadService.new_transaction`.
- `nvflare/fuel/f3/streaming/download_service.py:1093-1152` documents the `TransferWaiter` outcome consumed by upper layers.
- `nvflare/fuel/f3/streaming/transfer_progress.py:199-207` rejects progress updates after a terminal state; no path found where progress state changes the receiver-budget warning.

Reachable call chain:

`ObjectDownloader.__init__` -> `DownloadService.new_transaction` -> `_Transaction.__init__` emits the budget warning. Normal receiver pull messages reach `DownloadService._handle_download`, which calls `ref.mark_active()`, `ref.mark_receiver_active(requester)`, and eventually `tx.enforce_receiver_budgets(now)` from the monitor.

Trigger scenario:

Create a transaction with `timeout=10.0`, declared receivers `("active", "stalled")`, and `receiver_idle_timeout=10.0`. The constructor emits the warning that the idle budget can never fire and is effectively disabled. Then `stalled` pulls once and stops, while `active` pulls again at `t+9`, refreshing the transaction-wide activity clock. At a monitor pass at `t+11`, the transaction-wide inactivity age is only about 2 seconds, so the transaction timeout does not fire; the stalled receiver's idle age is 11 seconds, so the receiver idle budget fires.

Safeguards / masks encountered:

The implementation has a truth-wins recheck at `download_service.py:521-524` so a receiver that became active after the budget snapshot is not incorrectly failed. It does not mask this scenario because the stalled receiver has no later activity. The transfer outcome path records the actual receiver statuses, so downstream transfer consumers observe `active=success`, `stalled=failed`, and `completed=False`; the transfer outcome does not carry the diagnostic lie.

## Step 2: Developer-Knowledge Search

Local commits / blame:

- `git blame -L 758,767 -- nvflare/fuel/f3/streaming/download_service.py` attributes the warning to commit `0ff5c804b0` from PR #4865, "Add F3 payload layer: receiver-confirmed completion, receiver budgets, awaitable transfer facade".
- `git show --no-patch --format=fuller 0ff5c804b0` and `gh pr view 4865` show the feature intent: receiver budgets are opt-in; a stalled receiver should be freed at the idle budget, a never-pulling receiver at the acquire budget, and the absolute worst case remains the transaction TTL. The PR also states that budget failures resolve the outcome on a monitor pass and bound lost confirmations.
- `tests/unit_test/fuel/f3/streaming/receiver_budget_test.py:395-405` pins the warning text with the comment "review-requested pin: a budget >= the transaction timeout can never fire". This records developer intent for the diagnostic, but only tests warning emission, not the multi-receiver sliding transaction-clock schedule.

Docs/comments:

- `docs/programming_guide/timeouts.rst:1219-1235` describes object download transaction timeout as time since last activity and notes timeout occurs if no receiver has activity for the duration.
- `docs/programming_guide/timeouts.rst:1355-1363` says Client API large-payload transfer uses the shared streaming download service and the download idle budget should be aligned with request budgets.

Issue / PR search:

- `gh search issues --repo NVIDIA/NVFlare "receiver_idle_timeout"` -> no results.
- `gh search issues --repo NVIDIA/NVFlare "streaming_receiver_idle_timeout"` -> no results.
- `gh search issues --repo NVIDIA/NVFlare "can never fire"` -> no results.
- `gh search issues --repo NVIDIA/NVFlare "effectively disabled"` -> no results.
- `gh search issues --repo NVIDIA/NVFlare "receiver budget"` -> no results.
- `gh pr list --repo NVIDIA/NVFlare --state all --search "receiver_idle_timeout"` found PR #4865 only.
- `gh pr list --repo NVIDIA/NVFlare --state all --search "receiver budget"` found PR #4865 and later lifecycle PRs (#5097, #5179, etc.). PR #5097 and #5179 address cancellation, source settlement, receiver parsing, and accepted-result lifecycle, not this warning/clock mismatch.
- `git log HEAD..origin/main -- nvflare/fuel/f3/streaming/download_service.py tests/unit_test/fuel/f3/streaming/receiver_budget_test.py nvflare/fuel/f3/streaming/transfer_progress.py` returned no commits after the tested head on those paths. `origin/main` still contains the same warning text.

Known-status result:

No upstream issue, closed/merged PR, CVE, advisory, or searched local git history entry was found reporting this exact defect mechanism at this site. Novelty evidence supports `NEW`.

## Phase 2 Setup Notes

The reproduction should use a normal transaction, normal downloader pull messages, and controlled monitor time only. It should not inject receiver status maps or patch the source. It should capture both the constructor warning and the later receiver-budget enforcement under the multi-receiver schedule.
