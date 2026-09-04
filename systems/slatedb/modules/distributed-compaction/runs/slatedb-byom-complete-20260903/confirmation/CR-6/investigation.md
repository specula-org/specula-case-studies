# CR-6 Investigation

## Code Audit

Finding source: code review. No MC counterexample was supplied.

Cited sites:
- `slatedb/src/compactor.rs:149` defines `CompactionScheduler::validate` with a default implementation returning `Ok(())`. The comments at `slatedb/src/compactor.rs:138-141` state that not all compactions originate from a scheduler and that this method validates external specs against scheduler-specific invariants.
- `slatedb/src/compactor.rs:930-1043` is the compactor-level `validate_compaction` gate. It checks non-empty sources, target segment existence, source existence, destination constraints, drain watermark coverage, and one active L0 compaction per segment, then calls `self.scheduler.validate(...)`. It does not itself check that L0 sources are listed in manifest order.
- `slatedb/src/size_tiered_compaction.rs:283-301` shows the built-in size-tiered scheduler's ordering rule: it builds logical source order from `tree.l0` followed by sorted runs and rejects any compaction whose sources are not a consecutive window of that order.
- `slatedb/src/compactor_state.rs:1072-1115` stores `first_source = spec.sources().first()` and, when that source is an L0 view, sets `tree.last_compacted_l0_sst_view_id = Some(view_id)`. The adjacent comment says the newest L0 must be the first entry in sources and has a TODO to validate it.
- `slatedb/src/compactor_state.rs:1116-1121` stores the matching physical SST ID as `last_compacted_l0_sst_id`.
- `slatedb/src/manifest/mod.rs:86-122` merges writer and compactor tree state. If a compactor watermark is present, it keeps `writer.l0.take_while(...)` until a writer L0 matches the compactor watermark by view ID or physical SST ID. If the watermark names an older compacted source, a newer source that was also compacted remains in L0.
- `slatedb/src/db/builder.rs:298-300` and `slatedb/src/db/builder.rs:1178-1182` expose a real public path to configure a custom compactor and scheduler supplier.
- `slatedb/src/memtable_flusher/tracker.rs:271-321` uses the current tree L0 length and per-key L0 overlap to decide whether an immutable memtable can dispatch to L0. A stale retained L0 therefore consumes real L0 capacity.
- `slatedb/src/db.rs:1789-1790` exposes `Db::flush_with_options`, and `slatedb/src/db.rs:2002-2003` exposes `Db::manifest`, both used by the reproduction.

Reachable call chain:
1. A user builds a database with `Db::builder(...).with_compactor_builder(CompactorBuilder::new(...).with_scheduler_supplier(custom_supplier))`.
2. The custom scheduler's `propose(&CompactorStateView)` returns a `CompactionSpec` over existing L0 sources, but in a permuted order.
3. `CompactorEventHandler::validate_compaction` accepts the spec because all sources exist and the scheduler inherits the trait default `validate()` returning `Ok(())`.
4. The embedded worker compacts the accepted sources and writes a `Compacted` entry.
5. The coordinator commits the `Compacted` entry and calls `CompactorState::finish_compaction`, which sets the L0 watermark from the first source in the permuted list.
6. A writer refresh or later commit runs `LsmTreeState::merge_writer_and_compactor` and trims only up to that stale watermark. Newer compacted L0s before the stale marker remain in writer L0.
7. Later public memtable flushes observe the retained L0 through `can_dispatch` and can stall against `l0_max_ssts` / `l0_max_ssts_per_key` earlier than a correct compaction would.

Trigger scenario:
1. Configure `l0_max_ssts = 2` and a custom scheduler that uses the public `CompactionScheduler` trait, returns one L0-only compaction, and inherits the default `validate`.
2. Write and flush two values to create two L0 SSTs in manifest order `[newest, oldest]`.
3. Let the custom scheduler submit those two source view IDs in reverse order `[oldest, newest]`.
4. Wait for the real embedded compactor/worker path to commit the compacted output, then refresh the writer manifest.
5. Observe that `last_compacted_l0_sst_view_id` and `last_compacted_l0_sst_id` point at the oldest scheduler source while the writer's L0 still contains the newer physical SST that the compaction already consumed.
6. Issue two more normal public `put` plus `flush_with_options(FlushType::MemTable)` calls. The first succeeds, bringing L0 to 2. The second times out because the stale compacted L0 consumes one of the two L0 slots.

Safeguards encountered:
- The built-in size-tiered scheduler rejects this source order, but that check is scheduler-specific and is not applied when a custom scheduler inherits the default `validate`.
- The compactor-level validation rejects missing sources and concurrent same-segment L0 compactions, but not source ordering.
- The writer merge can match by physical SST ID as well as view ID, but that only finds the stale marker. It does not remove newer compacted L0s that precede the stale marker.
- A later compaction of the retained L0 could repair the metadata, but there is no automatic merge-only cleanup. If the custom scheduler does not compact again, the stale L0 remains and continues to affect flush dispatch.

## Developer-Knowledge Search

Issue/PR tracker search was performed against `repo:slatedb/slatedb` using GitHub's issue search API for:
- `last_compacted_l0_sst_view_id`
- `"first entry in sources"`
- `"custom scheduler" compaction`
- `watermark L0 compaction scheduler`
- `"non-consecutive compaction sources"`

Results:
- `last_compacted_l0_sst_view_id` returned related L0/GC/segment PRs including #1957, #1747, #1822, #1650, #1604, #1362, and issue #1662, but none reported custom scheduler L0 source permutation causing a stale merge watermark.
- `"first entry in sources"` returned zero results.
- `"custom scheduler" compaction` returned #1378 and #1117, which discuss segment-oriented compaction and publicizing `CompactorBuilder`, not this defect.
- `watermark L0 compaction scheduler` returned related distributed compaction, drain, GC, and read-path issues including #1802, #1650, #1367, #604, #673, and #228, but not this mechanism.
- `"non-consecutive compaction sources"` returned zero results.

Git history search:
- `git log --all --grep='wrong_order|non-consecutive|custom scheduler|last_compacted_l0|watermark' --extended-regexp` returned no matching commit messages.
- `git show --stat --oneline 4b8d4e08` shows PR #926 moved compaction validation into scheduler-specific logic and retained a provided/default scheduler validation hook. It is related background, not an existing report of the custom-scheduler stale-watermark consequence.
- `git blame -L 1110,1120 -- slatedb/src/compactor_state.rs` attributes the first-source watermark/TODO to existing code around `finish_compaction`.
- Latest upstream `main` was checked for `slatedb/src/compactor.rs`, `slatedb/src/compactor_state.rs`, and `slatedb/src/size_tiered_compaction.rs`; it still has the default `validate`, the first-source watermark, and the built-in size-tiered ordering check. No landed upstream fix for this mechanism was found.

Known-status conclusion: NEW. I found related public reports and PRs, but no existing issue/PR/CVE/advisory or prior public fix that reports this exact same mechanism at the same site.

## Reproduction Evidence

Reproduction file: `<run-output>/repro/test_bugCR-6_custom_scheduler_l0_order.sh`

Executed command:

```sh
timeout 15m <run-output>/repro/test_bugCR-6_custom_scheduler_l0_order.sh
```

Relevant output:

```text
running 1 test
CR6 before compaction L0 newest->oldest: ["01M1M9F051BJC421700KG0RDWH", "01M1M9F050BPKJZR56728Q5ZHV"]
CR6 scheduler manifest L0 view IDs newest->oldest: ["01M1M9F050NHHYRVNXMZP4RXZ0", "01M1M9F04ZTCZ365EQ1BXFQDQ3"]
CR6 scheduler manifest physical SST IDs newest->oldest: ["01M1M9F050NHHYRVNXMZP4RXZ0", "01M1M9F04ZTCZ365EQ1BXFQDQ3"]
CR6 scheduler submitted source view IDs oldest->newest: ["01M1M9F04ZTCZ365EQ1BXFQDQ3", "01M1M9F050NHHYRVNXMZP4RXZ0"]
CR6 after compaction+writer refresh: l0_views=["01M1M9F051BJC421700KG0RDWH"] l0_ssts=["01M1M9F050NHHYRVNXMZP4RXZ0"] watermark_view=Some("01M1M9F04ZTCZ365EQ1BXFQDQ3") watermark_sst=Some("01M1M9F04ZTCZ365EQ1BXFQDQ3") compacted_runs=1
CR6 scheduler source view order was ["01M1M9F050NHHYRVNXMZP4RXZ0", "01M1M9F04ZTCZ365EQ1BXFQDQ3"]; stale retained physical L0 after compaction: 01M1M9F050NHHYRVNXMZP4RXZ0
CR6 L0 after one further public memtable flush: ["01M1M9F06ERXHZVZFTE2NE1JKT", "01M1M9F051BJC421700KG0RDWH"]
CR6 second post-compaction public flush result: Err(Elapsed(()))
BUG TRIGGERED: public Db::flush_with_options(FlushType::MemTable) timed out because the stale compacted L0 still counts against l0_max_ssts
test custom_scheduler_reversed_l0_sources_leave_stale_l0_and_stall_flush ... ok

test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 2.07s
```

Escalation: Level 0. The trigger uses public DB construction, a public custom scheduler extension point, normal `put`, `flush_with_options`, `refresh_manifest`, and `manifest` calls. No state injection or source logic patch was used.
