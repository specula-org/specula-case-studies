# CR-2 investigation

Finding: Caller receiver declarations can diverge from complete-payload outcome semantics.

Scope/source boundary:
- Source kind: code review. No model-checking counterexample is supplied for this finding.
- Source checkout HEAD: 53ba7ee567468ea7971dad4faccef13c6cb35dc2.
- The checkout was dirty before this investigation: `nvflare/client/cell/api.py` and
  `nvflare/fuel/f3/streaming/download_service.py` had local modifications. I used the
  current worktree contents and did not edit source files.

## Step 1: Code audit

Cited sites:
- `nvflare/fuel/f3/streaming/transfer_outcome.py:156`: `TransferOutcome.quorum_met` computes quorum over receivers that succeeded on every ref, and filters by `receiver_ids` when supplied.
- `nvflare/fuel/f3/streaming/transfer_outcome.py:197`: `_all_receivers_succeeded` falls back to count-based completion when no `receiver_ids` are supplied; a ref with at least `num_receivers` final statuses can complete.
- `nvflare/fuel/f3/cellnet/cell.py:303`: `_broadcast_request` documents why a direct broadcast can declare routing targets as payload receivers.
- `nvflare/fuel/f3/cellnet/cell.py:344`: `_fire_and_forget` encodes the payload before normalizing/using `targets`, and calls `encode_payload` without `num_receivers` or `receiver_ids`.
- `nvflare/fuel/utils/fobs/decomposers/via_downloader.py:779`: `_finalize_download_tx` defaults missing `FOBSContextKey.NUM_RECEIVERS` to 1.

Call chain and receiver declaration facts:
- Public `Cell.fire_and_forget(...)` on a stream channel is routed by `Cell.__getattr__` to `_fire_and_forget`.
- `_fire_and_forget` calls `encode_payload(message, ..., fobs_ctx=self.get_fobs_context())` with no call-scoped receiver metadata, then sends the same encoded message to each target.
- During FOBS serialization, `ViaDownloaderDecomposer._finalize_download_tx()` creates an `ObjectDownloader`. With no `FOBSContextKey.NUM_RECEIVERS`, it uses `num_receivers = ... or 1`; with no receiver ids and count 1, `_get_result_upload_receiver_ids` returns `(None,)`, but `_create_downloader` passes `receiver_ids=None` to `DownloadService` because `(None,)` is treated as unknown identity.
- `DownloadService.new_transaction` therefore creates a count-only transaction with `num_receivers=1` and `receiver_ids=None`.
- `DownloadService._Ref._completion_reached_locked` completes count-only refs once `num_receivers_done >= tx.num_receivers`.
- `DownloadService._finish_transaction_if_complete` retires the transaction and tombstones finished refs when `tx.is_finished()` is true.
- Finished-ref tombstones are requester-scoped: `_get_finished_ref_status` only returns a tombstone status for the requester whose status was recorded.

Reachability:
- A normal caller can send a stream-channel fire-and-forget message to multiple targets. The Cell API accepts one or more target FQCNs.
- A normal payload can use FOBS ViaDownloader decomposers to create a `DownloadService` transaction for large/downloadable values.
- A natural trigger is: sender calls `cell.fire_and_forget(channel=<stream channel>, targets=["receiver-a", "receiver-b"], message=<downloadable payload>)`; only `receiver-a` decodes/materializes the payload first; `receiver-b` has not yet pulled. Because the source transaction was created as one receiver, `receiver-a` completion can retire the source and record a completed outcome before `receiver-b` starts.

Safeguards observed:
- Direct `_broadcast_request` does pass `num_receivers=len(targets)` and `receiver_ids=targets` when not pass-through.
- `DownloadService` is identity-aware if `receiver_ids` are supplied.
- Finished-ref tombstones allow the receiver that already completed to retry EOF, but they do not allow an unrecorded different receiver to download later.
- No downstream resend/sync guard was found in the fire-and-forget path that would re-open or preserve the retired source for the second target.

## Step 2: Developer-knowledge search

Issue/PR search:
- GitHub API search `repo:NVIDIA/NVFlare ViaDownloader receiver_ids` returned PR #4736, "Add progress-aware streaming wait policy".
- GitHub API search `repo:NVIDIA/NVFlare ViaDownloader num_receivers` returned PR #3873, "Downloader rework".
- GitHub API search `repo:NVIDIA/NVFlare fire_and_forget receiver_ids` returned zero results.
- GitHub API search `repo:NVIDIA/NVFlare TransferOutcome receiver_ids` returned PR #4865, "Add F3 payload layer: receiver-confirmed completion, receiver budgets, awaitable transfer facade".
- Local `git log --all --grep` for `fire-and-forget|fire_and_forget|receiver parsing|settlement|receiver ids|receiver_ids` found related PRs including #5179, #5075, #4865, and #4736, but no commit message or PR title for this exact stream `fire_and_forget` multi-target payload declaration site.

Relevant developer intent/evidence:
- PR #4865 states the intended aggregate contract: `COMPLETED` only when every expected receiver of every ref succeeded, and missing receivers fail closed.
- Current comments in `transfer_outcome.py` say expected receiver identities, when present, bound completion/quorum, and `completed` is the strict all-receivers certificate.
- Current comments in `download_service.py` say `TransferWaiter.wait()` is the producer-facing "returns == delivered" primitive and `COMPLETED` only means every expected receiver succeeded.
- Current comments in `cell.py` explicitly distinguish direct broadcast from pass-through and stamp receiver ids in `_broadcast_request`, which supports the interpretation that direct multi-target sends should declare their actual routing targets.
- Current comments in `download_service.py` acknowledge `downloaded_to_all` only works if the producer knows how many receivers exist.

Tests:
- `tests/unit_test/fuel/f3/cellnet/cell_progress_wait_test.py` covers `_encode_message` and `_broadcast_request` receiver metadata.
- `tests/unit_test/fuel/utils/fobs/decomposers/via_downloader_test.py` covers the case where a multi-receiver count exists but identities are missing.
- I found no existing test for multi-target stream `fire_and_forget` carrying a ViaDownloader payload.

## Step 3: Known status / precedent

No existing issue, PR, CVE, advisory, or known local history entry was found that reports this exact mechanism at this exact site: stream-channel `Cell._fire_and_forget` encodes a multi-target downloadable payload without `NUM_RECEIVERS`/`RECEIVER_IDS`, causing `ViaDownloader` to create a one-receiver source transaction.

Related PRs #4736, #4865, and #5179 establish nearby design intent and receiver parsing behavior, but do not report or fix this exact `_fire_and_forget` fanout metadata omission. Known-status evidence therefore supports `Novelty: NEW` for this mechanism.
