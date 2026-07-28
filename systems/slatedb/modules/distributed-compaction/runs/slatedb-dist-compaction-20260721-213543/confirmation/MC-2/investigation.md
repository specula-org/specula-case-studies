# MC-2 Investigation

## Step 1: Code audit

### Relevant code

- `slatedb/src/admin.rs:192-204`
  - `Admin::submit_compaction()` is a public admin entry point. It calls `Compactor::submit()` and persists a new `Compaction` directly into `.compactions`.
- `slatedb/src/compactor.rs:1238-1289`
  - `CompactorEventHandler::maybe_schedule_compactions()` computes `available_capacity` from `max_concurrent_compactions - running_compaction_count()`, but that budget only applies to scheduler-proposed specs.
- `slatedb/src/compactor.rs:1308-1355`
  - `maybe_validate_submitted_compactions()` iterates every `Submitted` compaction and promotes each valid tiered job to `Scheduled`. There is no capacity check in this loop.
- `slatedb/src/compactor.rs:1428-1432`
  - `running_compaction_count()` only counts `Running` entries.
- `slatedb/src/compaction_worker.rs:304-307`
  - Worker capacity is local: `worker.max_concurrent_compactions - job_progress.len()`.
- `slatedb/src/compaction_worker.rs:314-430`
  - `poll_and_claim()` scans all `Scheduled` entries and CAS-claims up to the worker-local capacity, turning them into `Running`.
- `slatedb/src/config.rs:1110-1111`
  - `CompactorOptions.max_concurrent_compactions` is documented as “The maximum number of concurrent compactions to execute at once”.
- `slatedb/src/config.rs:1190-1192`
  - `CompactionWorkerOptions.max_concurrent_compactions` is explicitly per-worker: “How many jobs a single worker may hold simultaneously.”
- `slatedb/src/size_tiered_compaction.rs:188-195,239-246`
  - The internal size-tiered scheduler counts `Submitted`, `Scheduled`, and `Running` active jobs against its own budget, but that logic only covers scheduler-generated work.

### Call chain

Normal reachable path for external/manual compactions:

1. `Admin::submit_compaction()` persists a `Submitted` compaction (`slatedb/src/admin.rs:192-204`).
2. On the next coordinator poll tick, `CompactorEventHandler::handle_ticker()` calls `maybe_schedule_compactions()` and then `maybe_validate_submitted_compactions()` (`slatedb/src/compactor.rs:773-777`).
3. `maybe_validate_submitted_compactions()` promotes each valid `Submitted` tiered compaction to `Scheduled` without checking the global compactor capacity (`slatedb/src/compactor.rs:1308-1355`).
4. Each standalone worker runs `poll_and_claim()`, which only enforces its own local `CompactionWorkerOptions.max_concurrent_compactions` (`slatedb/src/compaction_worker.rs:304-307,314-430`).
5. A caller can observe the resulting `Running` entries through `Admin::read_compactions()` (`slatedb/src/admin.rs:121-139`).

### Reachability assessment

This path is reachable through normal usage:

- external submissions are part of the public admin API;
- standalone coordinator + standalone workers are supported deployment modes;
- the cited code explicitly allows multiple standalone workers;
- no injected or fabricated state is required to reach `Submitted -> Scheduled -> Running`.

### Trigger scenario

Concrete naturally reachable scenario:

1. Create a DB with segmented data so two disjoint segments each have a valid L0-only compaction candidate.
2. Run a standalone coordinator with `CompactorOptions { max_concurrent_compactions: 1, worker: None, ... }`.
3. Submit two valid external compactions through `Admin::submit_compaction()`, one per segment.
4. Let the coordinator validate them; both become `Scheduled`.
5. Start two standalone workers, each with `CompactionWorkerOptions { max_concurrent_compactions: 1, ... }`.
6. Each worker claims one `Scheduled` job, producing two `Running` compactions while the coordinator-wide limit is still configured as `1`.

### Safeguards / checks encountered

- `validate_compaction()` rejects parallel L0 compactions only within the same target segment (`slatedb/src/compactor.rs:1133-1150`). That does not stop two disjoint-segment submissions.
- The size-tiered scheduler already counts active jobs for its own proposals (`slatedb/src/size_tiered_compaction.rs:188-195,239-246`), but external submissions bypass that path entirely.
- No later coordinator-side check re-applies `CompactorOptions.max_concurrent_compactions` before `Submitted` entries are promoted to `Scheduled`.

## Step 2: Developer-knowledge search

### Comments / docs / RFCs

- `slatedb/src/config.rs:1110-1111` documents the coordinator option as a global execution bound.
- `slatedb/src/config.rs:1190-1192` distinguishes the worker option as per-worker, which makes the split accounting material rather than cosmetic.
- `rfcs/0013-compaction-state-persistence.md:103` lists “Manual Compaction Gaps: No coordination mechanism for operator-triggered compactions (Issue #288)”.
- The same RFC’s flow description for external compactions says the regular compactor flow should enforce capacity for submitted work (`rfcs/0013-compaction-state-persistence.md:293-298`). The document still names the older `maybe_start_compactions`, but it is evidence that externally submitted work was expected to respect the global coordinator capacity.

### Git history / recent fixes

- `git log --oneline --decorate -- slatedb/src/compactor.rs slatedb/src/compactor_state.rs slatedb/src/compaction_worker.rs`
  - shows `cc69461d fix accounting for max_concurrent_compactions (#1926)` at `HEAD`.
- Reading that change shows it updated `CompactionStatus::counts_against_max_concurrent()` so `Compacted` no longer consumes execution capacity. That is a different mechanism from this finding, which concerns external `Submitted` jobs being promoted/claimed beyond the coordinator-wide bound before they ever reach `Compacted`.

### Existing tests

- `slatedb/src/compactor.rs:5096-5138` tests that `maybe_validate_submitted_compactions()` promotes valid `Submitted` work to `Scheduled`.
- I did not find an existing test that asserts externally submitted jobs respect `CompactorOptions.max_concurrent_compactions` across multiple standalone workers.

## Step 3: Known-status / precedent

### Tracker / PR search performed

- Searched upstream issues and PR history for:
  - `max_concurrent_compactions`
  - `submit_compaction`
  - manual compaction coordination
  - recent merged fixes touching compaction accounting
- Relevant findings:
  - Issue `#288` covers manual-compaction coordination gaps in general, but not this exact mechanism.
  - PR `#1926` / commit `cc69461d` fixes a different accounting bug where `Compacted` jobs still consumed the concurrency budget after execution finished.

### Known-status result

I did not locate an upstream issue, PR, advisory, or prior in-repo reference that already reports this exact mechanism: externally submitted `Submitted` compactions being promoted and then claimed past the global `CompactorOptions.max_concurrent_compactions` bound because the coordinator capacity check is separated from submitted-job validation and worker claims are only per-worker.

Phase 2 reproduction is required.
