# CR-2 Investigation

## Step 1: Code Audit

Relevant sites:
- `slatedb/src/compactor_state_protocols.rs:93-101`: `CompactorStateReader::read_view()` reads `.compactions` before the latest manifest.
- `slatedb/src/compactor_state_protocols.rs:247-329`: `CompactorStateWriter` writes a checkpoint, then the manifest, then `.compactions`.
- `slatedb/src/compactor.rs:907-1019`: `commit_compacted_entries()` documents the crash window and the restart behavior for `Compacted` entries whose sources are already absent from the manifest.
- `slatedb/src/compactor_state.rs:882-944`: `merge_remote_compactions()` accepts remote `Compacted`/`Completed`/`Failed` entries that are absent locally and retains the last finished compaction.
- `slatedb/src/garbage_collector/compacted_gc.rs:103-112, 200-259`: compacted-SST GC computes the low watermark from persisted compactions, reads compactions before the manifest, and still filters manifest/checkpoint-reachable SSTs out of deletion.

Normal call chains:
- Coordinator commit path:
  `CompactorEventHandler::handle()` / `handle_ticker()` or `CompactorMessage::CommitCompacted`
  → `commit_compacted_entries()`
  → `CompactorState::finish_compaction()`
  → `CompactorStateWriter::write_state_safely()`
  → `write_manifest_safely()` then `write_compactions_safely()`.
- GC read path:
  `GarbageCollector::run_gc_once()`
  → `CompactedGcTask::collect()`
  → `CompactorStateReader::read_view()`
  → `list_active_l0_and_compacted_ssts()`.

Reachable trigger scenario:
1. A worker finishes a real compaction and persists a `Compacted` entry plus output SSTs to `.compactions`.
2. The coordinator observes that entry, applies `finish_compaction()` to its in-memory manifest view, writes a checkpoint of the pre-compaction manifest, then publishes the post-compaction manifest.
3. The coordinator crashes before `write_compactions_safely()` records the terminal state.
4. On restart, the new coordinator loads the still-`Compacted` entry from `.compactions`; `validate_compaction()` now fails because the manifest no longer contains the sources, so the retained entry is rewritten as `Failed`.

Safeguards and observable consumers:
- The checkpoint written in `write_manifest()` preserves the source SSTs during the publication window.
- The restart path explicitly treats “manifest already updated, `.compactions` still `Compacted`” as an admissible recovery state.
- GC still consults the active manifest plus checkpoints before deleting SSTs, so a manifest-visible output remains live even if the retained `.compactions` entry becomes `Failed`.
- Admin/state readers consume the same compactions-first view through `Admin::read_compactor_state_view()`.

## Step 2: Developer-Knowledge Search

Local history:
- `dbc91c0c` (`Distributed compaction (RFC-0025) Phase 2: Manifest commit protocol`, merged May 27, 2026) added the exact `Compacted -> Completed/Failed` restart logic and its tests.
- `a7067426` (`Move compactor persistence logic to CompactorStateWriter`, merged Dec 29, 2025) centralized the manifest-before-compactions ordering.
- `47cceb5a` / PR `#1071` (`Use compaction state to calculate low watermark in GarbageCollector`, merged Dec 19, 2025) moved GC protection from in-memory stats to persisted compaction state.
- `223e6eb8` / PR `#1194` (`fix stuck compactions after restart by persisting recovery state`, merged Jan 13, 2026) fixed a different restart bug involving stale `Running` entries.

Tracker / review evidence:
- PR `#1701` states that when sources are already absent, the manifest must have been committed before the crash and the retained entry is intentionally rewritten as `Failed` on restart. It also added `test_commit_compacted_entries_marks_failed_when_sources_absent`.
  https://github.com/slatedb/slatedb/pull/1701
- In the same PR review thread on May 23, 2026, the author described this as a simplicity-over-observability tradeoff: a truly completed job may be rewritten as `Failed`, but only for status tracking after recovery, not for manifest correctness.
  https://github.com/slatedb/slatedb/pull/1701
- Issue `#1044` and PR `#1071` discuss a nearby but different bug: GC deleting outputs that are not yet in the manifest when GC and compactor run separately. Their fix was to read persisted compaction state from object storage.
  https://github.com/slatedb/slatedb/issues/1044
  https://github.com/slatedb/slatedb/pull/1071

Existing tests that matter:
- `test_commit_compacted_entries_writes_manifest`
- `test_commit_compacted_entries_marks_failed_when_sources_absent`
- `test_should_leave_checkpoint_when_removing_ssts_after_compaction`
- `test_compacted_gc_respects_compaction_barrier`
- `test_compacted_gc_skips_running_compaction_output_without_watermark`

## Step 3: Known-Status / Precedent Search

Searches run on July 21, 2026:
- GitHub issue search for `is:issue is:open manifest compaction Failed crash` returned no results for this mechanism.
- GitHub issue search for `is:issue is:closed manifest compaction Failed crash` returned no matching report for this mechanism.
- GitHub PR search for `is:pr manifest compaction Failed crash` and `is:pr "compacted" "Failed" manifest` returned the implementation PRs (`#1701`, `#1071`) but no separate bug report describing “post-manifest crash leaves `.compactions` at `Compacted`/`Failed` and breaks recovery safety”.

Precedent assessment:
- Issue `#1044` is not the same defect. It concerns GC deleting outputs that are not yet manifest-visible; CR-2 concerns outputs that are already manifest-visible but whose retained `.compactions` entry may later become `Failed`.
- PR `#1701` is implementation and design discussion for the exact site, but not a pre-existing bug report claiming recovery unsafety at that site.

Known-status result for this mechanism:
- No prior issue or PR was found that reports this exact post-manifest / post-crash recovery-safety defect at these sites.
