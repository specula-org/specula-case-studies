# CR-5 Investigation

## Step 1: Code audit

### Cited code and behavior

- `slatedb/src/compactor.rs:1238` `maybe_schedule_compactions()` computes `available_capacity` from the coordinator's current `Running` count, then asks the scheduler for internal proposals.
- `slatedb/src/size_tiered_compaction.rs:188` the size-tiered scheduler already budgets internally proposed work against `Submitted | Scheduled | Running` via `CompactionStatus::counts_against_max_concurrent()`.
- `slatedb/src/compactor_state.rs:278` defines `Submitted`, `Scheduled`, and `Running` as consuming global compaction slots.
- `slatedb/src/compactor.rs:1308` `maybe_validate_submitted_compactions()` walks every `Submitted` compaction and promotes each valid tiered spec to `Scheduled`.
- `slatedb/src/compaction_worker.rs:304` `poll_and_claim()` claims `Scheduled` jobs up to the worker's local `max_concurrent_compactions`.
- `slatedb/src/compactor.rs:474` `Compactor::submit()` persists a new `Submitted` compaction directly into `.compactions` without consulting the coordinator's current slot usage.
- `slatedb/src/admin.rs:192` `Admin::submit_compaction()` is the public API that exposes `Compactor::submit()`.

### Call chain

1. A caller uses `Admin::submit_compaction()` (`slatedb/src/admin.rs:192`) to persist a `Submitted` compaction through `Compactor::submit()` (`slatedb/src/compactor.rs:474`).
2. The coordinator tick (`CompactorEventHandler::handle_ticker()`, `slatedb/src/compactor.rs:753`) runs `maybe_validate_submitted_compactions()` after manifest/compactions refresh.
3. `maybe_validate_submitted_compactions()` (`slatedb/src/compactor.rs:1308`) promotes every valid tiered `Submitted` entry to `Scheduled`; it does not re-check `max_concurrent_compactions`.
4. Each worker executes `poll_and_claim()` (`slatedb/src/compaction_worker.rs:304`) and CAS-claims `Scheduled` jobs up to its own local capacity.

### Reachability

This path is reachable through normal public operations:

1. Open a DB with a segment extractor and create valid sorted runs through ordinary writes and flushes.
2. Start a standalone coordinator with `max_concurrent_compactions = 1`.
3. Submit two valid, non-conflicting segment compactions through `Admin::submit_compaction()`.
4. Start two standalone workers with local capacity `1` each.

No fabricated metadata, unreachable states, or source patches are required.

### Safeguards recorded

- Internal scheduler proposals are budgeted by `SizeTieredCompactionScheduler::propose()` (`slatedb/src/size_tiered_compaction.rs:183`), but that safeguard only applies to internally generated proposals.
- Worker `capacity()` (`slatedb/src/compaction_worker.rs:298`) is per-worker, not global.
- `maybe_validate_submitted_compactions()` (`slatedb/src/compactor.rs:1308`) validates spec correctness but does not impose the global concurrency bound before promotion to `Scheduled`.

### Concrete trigger scenario

1. Prepare two disjoint named segments (`aaa`, `bbb`) that each contain one valid sorted run.
2. Run a standalone coordinator with `CompactorOptions::max_concurrent_compactions = 1` and `worker = None`.
3. Submit one valid full-segment compaction for `aaa` and one for `bbb` through `Admin::submit_compaction()`.
4. The coordinator promotes both `Submitted` entries to `Scheduled`.
5. Two standalone workers each claim one job, yielding two simultaneous `Running` compactions even though the configured global limit is `1`.

## Step 2: Developer-knowledge search

### Code comments / docs

- `slatedb/src/config.rs:1111` documents `max_concurrent_compactions` as "The maximum number of concurrent compactions to execute at once."
- `slatedb/src/compactor.rs:1294` documents `maybe_validate_submitted_compactions()` as the coordinator's promotion chokepoint for `Submitted -> Scheduled`, but the comment does not claim it enforces the global concurrency cap.

### Git history / blame

- `git blame` on `slatedb/src/size_tiered_compaction.rs:188-195` and `slatedb/src/compactor_state.rs:278-281` points to commit `cc69461d902560bb5f4407a506f32cd154ede79d` from July 14, 2026.
- `git show cc69461d` shows that PR `#1926` added `counts_against_max_concurrent()` and changed only scheduler-side accounting (`slatedb/src/compactor_state.rs`, `slatedb/src/size_tiered_compaction.rs`).
- The PR body for `#1926` states the pre-patch problem was that `Compacted` jobs were counted against `max_concurrent_compactions`, starving new scheduling. It does not mention admin-submitted `Submitted` jobs or `maybe_validate_submitted_compactions()`.

### Existing tests

- `slatedb/src/compactor.rs:5065` verifies that `maybe_schedule_compactions()` persists `Submitted`.
- `slatedb/src/compactor.rs:5096` verifies that `maybe_validate_submitted_compactions()` promotes a single `Submitted` compaction to `Scheduled`.
- `slatedb/src/compactor.rs:5183` verifies that a pre-existing `Submitted` compaction is promoted on a ticker.
- I found no existing test that checks multiple admin-submitted compactions against the global `max_concurrent_compactions` bound.

## Step 3: Known-status / precedent

### Tracker / PR search performed on July 21, 2026

Searches run against `slatedb/slatedb`:

- `gh issue list --state all --search 'submit_compaction Submitted max_concurrent_compactions'`
- `gh issue list --state all --search 'max_concurrent_compactions Submitted Scheduled'`
- `gh issue list --state all --search 'concurrent compaction accounting worker submission'`
- `gh pr list --state all --search 'submit_compaction Submitted max_concurrent_compactions'`
- `gh pr list --state all --search 'max_concurrent_compactions Submitted Scheduled'`
- `gh pr list --state all --search 'concurrent compaction accounting worker submission'`
- `git log --grep='max_concurrent_compactions\|Submitted\|Scheduled\|submit compaction\|concurrent compaction'`

### Results

- Issue `#1838` ("Compaction worker can panic when concurrent jobs share the same destination sorted run") is a different mechanism and site.
- PR `#1926` ("fix accounting for max_concurrent_compactions", merged July 14, 2026) is a scheduler-underutilization fix, not a report about externally submitted jobs bypassing the global bound.
- Older scheduler-side precedents such as commit `56edc2d1` ("Use max_concurrent_compactions in size tiered compaction. (#675)") also target internal scheduling, not the `Submitted -> Scheduled` admission path.

### Known-status conclusion

I found no prior issue, PR, CVE, advisory, or Specula dataset citation describing this exact mechanism: externally submitted compactions being promoted through `maybe_validate_submitted_compactions()` without a global capacity gate, allowing multiple workers to run more jobs than `CompactorOptions::max_concurrent_compactions`.

Novelty for this mechanism/site: `NEW`.
