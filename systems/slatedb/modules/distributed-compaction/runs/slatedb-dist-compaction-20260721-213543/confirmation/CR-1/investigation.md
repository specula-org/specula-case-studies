# CR-1 Investigation

## Step 1: Code audit

- Relevant code:
  - `slatedb/src/admin.rs:192`: `Admin::submit_compaction()` persists an external request through `Compactor::submit()`.
  - `slatedb/src/compactor.rs:478`: `Compactor::submit()` appends a new `Submitted` entry directly to `.compactions`.
  - `slatedb/src/compactor_state.rs:882`: `CompactorState::merge_remote_compactions()` accepts unknown remote `Submitted` entries into local state without routing them through `add_compaction()`.
  - `slatedb/src/compactor_state.rs:988`: `CompactorState::add_compaction()` is the only place that enforces active cross-compaction conflicts such as global destination collisions and same-segment concurrent drains.
  - `slatedb/src/compactor.rs:1022`: `validate_compaction()` checks manifest/spec validity, same-segment parallel-L0 conflicts, and scheduler policy, but it does not re-check the global active-destination collision logic from `add_compaction()`.
  - `slatedb/src/compactor.rs:1308`: `maybe_validate_submitted_compactions()` promotes every valid `Submitted` entry to `Scheduled`.
  - `slatedb/src/compactor.rs:930`: `commit_compacted_entries()` re-validates `Compacted` entries and marks losers `Failed`.

- Call chain:
  - Public/external path: `Admin::submit_compaction()` -> `Compactor::submit()` -> `.compactions`
  - Coordinator path on poll: `CompactorEventHandler::handle_ticker()` -> `state_writer.load_compactions()` -> `CompactorState::merge_remote_compactions()` -> `maybe_validate_submitted_compactions()` -> `validate_compaction()`

- Reachability:
  - A same-segment duplicate L0 submission no longer reproduces the old review concern: `validate_compaction()` now rejects a `Submitted` L0 compaction when a `Scheduled`/`Running` L0 compaction already exists in the same segment (`slatedb/src/compactor.rs:1136-1149`).
  - A cross-segment collision on the same fresh destination is still reachable because `merge_remote_compactions()` bypasses `add_compaction()` and `validate_compaction()` scopes its L0 conflict check to the target segment, not to the global destination reservation.

- Concrete trigger scenario:
  - Segment `aaa` already has a locally scheduled L0 compaction reserving fresh destination SR `200`.
  - An external caller submits a `Submitted` L0 compaction for segment `bbb` with the same destination SR `200`.
  - `merge_remote_compactions()` merges the external `Submitted` entry into local state without `add_compaction()` conflict checks.
  - `maybe_validate_submitted_compactions()` promotes it to `Scheduled`, so two disjoint-segment compactions now reserve the same destination concurrently.
  - If both later reach `Compacted`, `commit_compacted_entries()` commits the first and marks the second `Failed` after the destination-overwrite check sees SR `200` already committed.

- Safeguards observed:
  - `commit_compacted_entries()` re-runs `validate_compaction()` on `Compacted` entries and prevents duplicate durable publication by marking the loser `Failed`.

## Step 2: Developer-knowledge search

- RFC `0013-compaction-state-persistence.md` states that external compactions are written as `Submitted` and then handled by the regular compactor flow on the next poll tick; it explicitly says submit-time scheduler validation does not happen.
- RFC `0025-distributed-compaction.md` says the coordinator alone should promote `Submitted -> Scheduled` after validation and after updating local state to know about the job.
- PR `#1197` ("Make `CompactorState::merge_remote_compactions` more paranoid", merged January 20, 2026) records the intent that unknown post-startup compactions should only arrive through the `submit_compaction` path and should therefore appear as `Submitted`: https://github.com/slatedb/slatedb/pull/1197
- PR `#1650` ("Add support for draining segments", merged May 13, 2026) includes review discussion noting that external/admin compactions write directly to `.compactions` and therefore must be validated in the coordinator path; the author describes a split between `add_compaction()` and `validate_compaction()`: https://github.com/slatedb/slatedb/pull/1650
- PR `#1836` ("Validate compacted compactions against local segment sr IDs", merged June 25, 2026) shows the maintainers intentionally rely on `commit_compacted_entries()` re-validation as a later safety check: https://github.com/slatedb/slatedb/pull/1836

## Step 3: Known-status / precedent

- Tracker / recent-PR search performed:
  - GitHub issues query for `submit_compaction`: https://github.com/slatedb/slatedb/issues?q=submit_compaction
  - GitHub issues query for `validate_compaction Submitted`: https://github.com/slatedb/slatedb/issues?q=validate_compaction+Submitted
  - Reviewed recent merged PRs `#1197`, `#1650`, and `#1836`.
- Result:
  - I found related developer discussion about external validation gaps and later `Compacted`-time validation, but I did not find an upstream issue or PR that reports this exact mechanism: a cross-segment external `Submitted` compaction bypassing `add_compaction()`'s global active-destination collision check at `merge_remote_compactions()` / `maybe_validate_submitted_compactions()`.
- Novelty candidate:
  - `NEW`
