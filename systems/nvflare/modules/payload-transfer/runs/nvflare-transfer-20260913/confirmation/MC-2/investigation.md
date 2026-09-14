# MC-2 Investigation

Finding: A pipelined EOF can publish COMPLETED source progress after receiver cancellation finalized FAILED.

Source checkout:
- Path: `/home/ubuntu/nvflare-runs-20260913/specula/runs/nvflare-transfer-20260913/nvflare-transfer/.specula-output/confirmation/MC-2/worktree`
- HEAD: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`
- Dirty before confirmation: `nvflare/client/cell/api.py`, `nvflare/fuel/f3/streaming/download_service.py`, `nvflare/fuel/f3/streaming/specula_trace.py`

## Step 1: Code Audit

TLC source:
- `spec/output/MC_hunt_s1_progress_bfs.out` reports `Invariant CompletedProgressHasReceiverSuccess is violated`.
- The counterexample starts a pipelined pull (`futureStarted(ref1,receiver1) = TRUE`) and later reaches a state where source progress observes a terminal state inconsistent with the receiver truth.

Cited code and call chain:
- Receiver-side `download_object()` wraps `_download_object()` and advertises receiver-confirm support on every request when enabled (`download_service.py:2074`, `download_service.py:2157`, `download_service.py:2252`).
- The pipelined loop submits the next request before `consumer.consume()` runs when `consumer.supports_pipelining` is true (`download_service.py:2271`, `download_service.py:2287`, `download_service.py:2393`).
- If `consumer.consume()` raises after a pipelined request is already running, the loop attempts to cancel the future, sends receiver cancellation when the producer advertised `CANCEL_CAPABLE`, calls `consumer.download_failed()`, and emits receiver-side failed progress (`download_service.py:2403`, `download_service.py:2406`, `download_service.py:2409`, `download_service.py:2410`, `download_service.py:2411`).
- Producer-side cancellation is a normal control message handled by `_handle_cancel()`. It is accepted only after the receiver has acquired the transaction, then finalizes FAILED for every ref in the transaction and invokes `_finish_transaction_if_complete()` (`download_service.py:1888`, `download_service.py:1902`, `download_service.py:1906`, `download_service.py:1914`, `download_service.py:1920`).
- `_finalize_receiver()` records the receiver status under `_progress_lock`, then runs `downloaded_to_one()` and `downloaded_to_all()` callbacks outside that lock. `obj_cancelled()` emits FAILED progress only after `_finalize_receiver()` returns (`download_service.py:308`, `download_service.py:316`, `download_service.py:334`, `download_service.py:347`, `download_service.py:436`, `download_service.py:440`).
- A racing pipelined EOF request enters `_handle_download()`, sees `expect_confirm=True`, calls `obj_served()`, and gets `None` if cancellation already finalized the receiver. The terminal handler then falls through to the legacy/disabled-confirm branch and emits COMPLETED progress for EOF (`download_service.py:1776`, `download_service.py:1795`, `download_service.py:1799`, `download_service.py:1804`, `download_service.py:1815`).
- `_make_progress_event_locked()` latches the first terminal event for a receiver; subsequent terminal events are dropped (`download_service.py:588`, `download_service.py:609`, `download_service.py:633`).
- The aggregate outcome path separately snapshots locked receiver statuses, so the final `TransferOutcome` remains FAILED when the receiver status is FAILED (`transfer_outcome.py:220`, `transfer_outcome.py:244`, `transfer_outcome.py:250`, `transfer_outcome.py:259`).

Reachability:
- The path is reachable through normal producer and receiver APIs: create a `DownloadService` transaction, add a `Downloadable`, call `download_object()` from a `Consumer` with `supports_pipelining=True`, consume one DATA reply, let the speculative EOF request start, then have `consumer.consume()` fail and send the ordinary cancellation control message.
- No illegal state construction is required. The timing-sensitive window is the supported callback gap between `_finalize_receiver()` committing FAILED and `obj_cancelled()` emitting FAILED progress.

Safeguards observed:
- The operation gate (`begin_op()`/`end_op()`) prevents settlement from snapshotting before in-flight serve/cancel operations finish (`download_service.py:850`, `download_service.py:871`, `download_service.py:940`).
- This gate preserves the final `TransferOutcome` as FAILED, but it does not prevent the already-running EOF handler from emitting source progress while cancellation is inside user callback code.
- `TransferWaiter` and `TrainerSession._wait_for_result_transfers()` guard the higher-level "send returned success" outcome (`download_service.py:1093`, `client/cell/api.py:626`), so this reproduction does not establish false successful strict receipt or false trainer-send success.

## Step 2: Developer Knowledge

Comments and tests:
- The receiver-confirm design comment says confirm-capable receivers should be provisional until receiver confirmation, and receiver truth wins (`download_service.py:377`, `download_service.py:409`).
- The receiver-side comment says finalization failure after EOF is exactly what receiver-confirmed completion exists to surface (`download_service.py:2362`, `download_service.py:2367`).
- Existing tests cover the baseline receiver-truth path (`receiver_confirm_test.py:292`), late duplicate serve guard (`receiver_confirm_test.py:341`), and cancellation racing an in-flight serve (`receiver_confirm_test.py:210`), but the in-flight-serve test does not attach a source progress callback and therefore does not check the terminal progress stream.
- Existing source-progress tests assert EOF produces completed progress in the ordinary legacy path (`download_service_test.py:1017`) and that terminal events latch (`download_service_test.py:1121`).

Commit / PR history:
- PR #4865 introduced receiver-confirmed completion and states the intended contract: receiver confirmation decides stored-OK/store-failed truth, and `waiter.wait()` returns only after a settled outcome. Link: https://github.com/NVIDIA/NVFlare/pull/4865
- PR #4973 introduced the pipelined download loop and states that only value-stable consumers opt into pipelining. Link: https://github.com/NVIDIA/NVFlare/pull/4973
- PR #5097 introduced capability-negotiated cancellation and includes tests for pipelined abort/cancel, but it does not report or fix the source terminal-progress contradiction. Link: https://github.com/NVIDIA/NVFlare/pull/5097
- Linked issue #5099 is about orphaned external trainer processes during CJ teardown, not the same source-progress mechanism. Link: https://github.com/NVIDIA/NVFlare/issues/5099

## Step 3: Known Status / Precedent

Issue/PR search performed:
- GitHub issue/PR search in `NVIDIA/NVFlare` for `download_service cancel completed progress`: no results.
- GitHub issue/PR search for `receiver confirm pipelining EOF`: no results.
- GitHub issue/PR search for `CONFIRM_EXPECTED CANCEL_CAPABLE`: no results.
- GitHub issue/PR search for `"served EOF" "download_completed"`: PR #4865 only.
- GitHub issue/PR search for `"receiver truth" progress`: PRs #4853 and #4865 only.
- GitHub issue/PR search for `"consumer changed state despite enabling download pipelining"`: no results.
- GitHub issue/PR search for `"receiver-confirmed completion" "cancel"`: no results.
- Recent local history since the pipelining PR shows #5097 and #4973 touching the area; neither is an exact filed report for this progress race.

Known-status record:
- No existing issue/PR/CVE/advisory found for this exact mechanism at this site.
- Novelty evidence supports `NEW`, not `KNOWN`.
