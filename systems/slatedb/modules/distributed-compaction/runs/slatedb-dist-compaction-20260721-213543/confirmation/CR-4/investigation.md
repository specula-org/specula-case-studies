## Step 1: Code audit

### Cited code

- `slatedb/src/compactor_state_protocols.rs:177-239`
  - `CompactorStateWriter::fence()` fences manifest first, then initializes fenced `.compactions` with the manifest epoch.
  - `load_compactions()` refreshes `.compactions` and merges the remote dirty object into local state.
  - `load_manifest()` separately refreshes manifest and merges remote writer-visible state into local state.
  - `refresh()` preserves the intended load ordering by calling `load_compactions()` before `load_manifest()`.
- `slatedb/src/compactor.rs:743-777`
  - `CompactorEventHandler::handle_ticker()` is the normal coordinator path. Each tick runs `load_compactions()`, then `load_manifest()`, then `reclaim_stale_workers()`, `commit_compacted_entries()`, scheduling, and validation.
- `slatedb/src/compactor_state_protocols.rs:296-318`
  - `write_compactions_safely()` retries `.compactions` writes on sequenced-write conflict by reloading remote `.compactions`, merging it into local state, and retrying with the merged value.
- `slatedb/src/compactor_state.rs:882-944`
  - `merge_remote_compactions()` now explicitly accepts remote `Submitted`, `Compacted`, `Completed`, and `Failed` entries that are absent locally.
  - The inline comment documents the exact retry case: local state may already have committed or pruned an entry while persisted `.compactions` still contains an older `Compacted`/`Completed`/`Failed` view.
  - Remote `Scheduled`/`Running` entries that are absent locally are still treated as anomalous and skipped.
- `slatedb/src/compactor.rs:907-983`
  - `commit_compacted_entries()` is the repair/commit path for merged `Compacted` entries.
  - Valid `Compacted` entries are applied to the manifest and transitioned to `Completed`.
  - If validation fails against the current manifest, the entry is marked `Failed` and persisted, with an explicit recovery comment for the crash-after-manifest-write case.

### Call chain / reachability

- Public/normal entry point:
  - `CompactorEventHandler::new()` constructs `CompactorStateWriter` during coordinator startup (`slatedb/src/compactor.rs:584-631`).
  - Periodic coordinator ticks call `CompactorEventHandler::handle_ticker()` (`slatedb/src/compactor.rs:743-777`).
- Normal execution reaches the cited merge path without any special hooks:
  1. A worker or admin process updates `.compactions`.
  2. The coordinator tick calls `load_compactions()`.
  3. A later `.compactions` write by the coordinator conflicts in `write_compactions_safely()`.
  4. The retry path reloads remote `.compactions` and re-merges it into local state.

### Concrete trigger scenario

1. The coordinator loads `.compactions` and manifest on a normal tick.
2. A worker finishes a compaction and persists `Compacted`, or the coordinator locally completes/prunes an older terminal entry.
3. Before the coordinator persists its next `.compactions` update, another writer wins the next sequenced version, causing `write_compactions_safely()` to hit a conflict.
4. The retry path reloads persisted `.compactions`.
5. At this point, local state can be ahead of persisted state for one compaction id, so the merge sees a remote `Compacted`/`Completed`/`Failed` entry whose local copy was already pruned.
6. Current code admits that remote stale entry and relies on downstream repair:
   - `commit_compacted_entries()` re-validates `Compacted` entries against the current manifest.
   - `retain_active_and_last_finished()` prunes stale terminal entries.

### Safeguards / masking logic observed

- `merge_remote_compactions()` no longer treats vacant remote `Compacted`/terminal entries as impossible; it admits them on purpose and delegates cleanup.
- `commit_compacted_entries()` marks stale `Compacted` entries `Failed` when their sources are already absent from the current manifest.
- `retain_active_and_last_finished()` removes stale terminal history beyond the retained active set / last finished entry.

## Step 2: Developer-knowledge search

### In-code comments and tests

- `slatedb/src/compactor_state.rs:892-903` contains an explicit comment that documents the stale-merge retry case and the intended repair mechanisms (`validate_compaction` for stale `Compacted`, `retain_active_and_last_finished` for stale terminal entries).
- `slatedb/src/compactor.rs:914-929` contains an explicit crash-recovery comment: if the manifest was already written before a crash, a later recovery pass may mark the `.compactions` entry `Failed`, and that is considered correct because the manifest is already durable.
- Existing tests exercise the intended repaired behavior:
  - `test_merge_remote_compactions_accepts_compacted_from_worker` (`slatedb/src/compactor_state.rs:1482-1504`)
  - `test_commit_compacted_entries_marks_failed_when_sources_absent` (`slatedb/src/compactor.rs:6300-6338`)
  - `test_validate_completed_l0_allows_destination_below_global_highest_sr` added by PR `#1836` in the current history, which supports the post-merge validation path for reloaded `Compacted` entries.

### Git history / merged PRs

- `git log` shows an exact upstream fix:
  - Commit `8e8b36cebaa7dd791d9d315c08ec3ee3e8219d24`, authored June 25, 2026:
    - Subject: `fix: merge_remote_compactions should accept stale terminal/compacted entries (#1840)`
- The immediately preceding supporting fix is:
  - Commit `705806b277c57a9fe95956679a8cd28db2569a4c`, authored June 24, 2026:
    - Subject: `Validate compacted compactions against local segment sr IDs (#1836)`

### Issue tracker / PR search result

- GitHub PR `#1840` (`https://github.com/slatedb/slatedb/pull/1840`) was merged on June 25, 2026.
- Its summary matches this finding's mechanism:
  - distributed compaction hit errors when the coordinator retried a conflicting `.compactions` write,
  - local state had already completed/pruned an entry,
  - persisted `.compactions` still held an older `Compacted` or terminal view,
  - the retry merge therefore saw the remote entry as vacant locally.
- The PR change description says the fix is to merge those remote terminal / `Compacted` entries and let downstream validation / retention resolve them.

## Step 3: Known-status / precedent

### Exact-match assessment

- This is not just a similar race class. PR `#1840` reports the same mechanism at the same site:
  - retry path after `.compactions` sequenced-write conflict,
  - local entry already pruned/advanced,
  - persisted remote `Compacted` or terminal entry still present,
  - merge path in `merge_remote_compactions()`.
- The current code in `slatedb/src/compactor_state.rs:892-903` is the landed fix for that report.

### Novelty / pre-filter outcome

- `Novelty: KNOWN (cite: https://github.com/slatedb/slatedb/pull/1840; fix-status: fixed)`
- Because this finding is `Code Review` sourced and upstream PR `#1840` already reported and fixed this exact defect before Tuesday, July 21, 2026, the Phase-1 pre-filter applies.
- `Status: DROPPED (code-review × known, cite: https://github.com/slatedb/slatedb/pull/1840)`

### Reproduction note

- Per the bug-confirmation workflow, a code-review finding that is dropped by the known-bug pre-filter does not proceed to Phase 2 and does not get a new `repro/test_bug*` artifact.
