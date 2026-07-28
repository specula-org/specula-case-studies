# MC-1 Investigation

## Step 1: Code audit

### Cited code

- `slatedb/src/admin.rs:192-205`
  - `Admin::submit_compaction()` is the public entry point for manual/external submission. It calls `Compactor::submit()` and then reads the newly persisted compaction back.
- `slatedb/src/compactor.rs:478-503`
  - `Compactor::submit()` writes a new `Compaction::new(...)` directly into `.compactions` via `dirty.value.insert(compaction.clone())` and retries only on sequenced-write conflict. It does not call `CompactorState::add_compaction()`.
- `slatedb/src/compactor_state.rs:988-1023`
  - `CompactorState::add_compaction()` is where cross-compaction conflict checks live. It rejects duplicate drain-on-segment submissions and duplicate destination sorted-run ids across all active compactions.
- `slatedb/src/compactor.rs:743-778`
  - `CompactorEventHandler::handle_ticker()` runs the coordinator loop: refresh compactions, refresh manifest, reclaim stale workers, commit compacted entries, schedule new compactions, then validate submitted compactions.
- `slatedb/src/compactor_state.rs:878-935`
  - `CompactorState::merge_remote_compactions()` accepts remote `Submitted` compactions that are absent from local state by inserting them into the merged local map without routing them through `add_compaction()`.
- `slatedb/src/compactor.rs:1022-1229`
  - `validate_compaction()` checks manifest/spec validity only: sources exist, segment rules, destination ordering against the manifest, drain rules, scheduler-specific validation. Its own comment explicitly says cross-compaction conflicts are enforced upstream in `CompactorState::add_compaction()` and are not re-checked here.
- `slatedb/src/compactor.rs:1294-1383`
  - `maybe_validate_submitted_compactions()` iterates every `Submitted` compaction, calls `validate_compaction()`, and promotes valid tiered specs to `Scheduled`.
- `slatedb/src/compaction_worker.rs:310-460`
  - Worker claim flow claims `Scheduled` entries and only re-validates them against the post-claim manifest with `build_job_args()`.
- `slatedb/src/compaction_worker.rs:493-556`
  - `build_job_args()` checks destination presence and that sources still exist in the manifest, but it does not check overlap with other active compactions or duplicate destinations.
- `slatedb/src/compactor_executor.rs:885-894`
  - The executor asserts that no already-running task has the same destination sorted run id: `assert!(!tasks.values().any(|task| task.destination == dst));`.

### Call chain and reachability

Normal local scheduling path:

1. `Admin::run_compactor_with_options()` starts the standalone coordinator (`slatedb/src/admin.rs:354-386`).
2. The coordinator ticker calls `CompactorEventHandler::handle_ticker()` (`slatedb/src/compactor.rs:743-778`).
3. `handle_ticker()` calls `maybe_schedule_compactions()` (`slatedb/src/compactor.rs:1235-1292`).
4. `maybe_schedule_compactions()` proposes specs from the scheduler and routes each accepted candidate through `self.state_mut().add_compaction(...)` (`slatedb/src/compactor.rs:1251-1267`), so local scheduling gets the active-conflict checks.

Manual/external submission path:

1. A real caller invokes `Admin::submit_compaction()` (`slatedb/src/admin.rs:192-205`).
2. That calls `Compactor::submit()` (`slatedb/src/compactor.rs:478-503`).
3. `Compactor::submit()` writes a new `Submitted` compaction directly into `.compactions` and returns. No local-state conflict check runs at submission time.
4. On the next coordinator tick, `load_compactions()` refreshes and merges the remote `.compactions` state. `merge_remote_compactions()` accepts an absent remote `Submitted` entry directly into local state (`slatedb/src/compactor_state.rs:892-910`).
5. Later in the same tick, `maybe_validate_submitted_compactions()` validates the just-merged `Submitted` entry against manifest state only and promotes it to `Scheduled` (`slatedb/src/compactor.rs:1323-1348`).

This is reachable through normal usage. The external trigger is a documented public admin API, and the coordinator/worker loops are the standard production protocol.

### Counterexample-to-code mapping

The model-checking trace in `spec/output/MC_hunt_family1_bfs_rerun.out` maps cleanly to the code:

- State 3: `MCMaybeScheduleCompactions("j1")`
  - Matches the local scheduler path that creates a `Submitted` job through `add_compaction()`.
- State 4: `MCExternalSubmit("j2")`
  - Matches `Admin::submit_compaction()` / `Compactor::submit()` persisting another `Submitted` job directly into `.compactions`.
- State 5: `MCCoordinatorRefreshCompactions`
  - Matches `handle_ticker()` calling `load_compactions()` and merging the remote `Submitted` entry.
- States 6 and 7: `MCMaybeValidateSubmittedSchedule("j1")` and `("j2")`
  - Match `maybe_validate_submitted_compactions()` promoting both jobs to `Scheduled`.

### Trigger scenario

Concrete real-world scenario:

1. A database accumulates at least one compaction candidate.
2. The coordinator schedules a compaction normally, which goes through `add_compaction()` and becomes active.
3. Before the manifest changes enough to invalidate that spec, an operator or automation calls `admin.submit_compaction()` with a conflicting or identical manual compaction spec.
4. The manual compaction is durably inserted as `Submitted` in `.compactions`.
5. On the next coordinator tick, the coordinator refreshes `.compactions`, adopts the remote `Submitted` entry into local state, and then promotes it to `Scheduled` because `validate_compaction()` only checks manifest consistency, not active-compaction overlap.
6. A worker can then claim both `Scheduled` jobs and attempt to execute both.

### Safeguards encountered

- Local-only safeguard:
  - `CompactorState::add_compaction()` rejects active destination conflicts, but only for compactions that enter through the local scheduler path.
- No safeguard during remote admission:
  - `Compactor::submit()` and `merge_remote_compactions()` do not call `add_compaction()`.
- No safeguard during `Submitted -> Scheduled` promotion:
  - `validate_compaction()` explicitly omits cross-compaction conflict checks.
- No worker-side safeguard for duplicate destinations:
  - `build_job_args()` revalidates against the manifest only.
- The next observable consequence is not a clean rejection:
  - the executor hard-asserts destination uniqueness (`slatedb/src/compactor_executor.rs:892-894`).

## Step 2: Developer-knowledge search

### Comments / RFC / local tests

- RFC-0025 says: “The coordinator is solely responsible for transitions from `Submitted → Scheduled`, and transitions the state only after validating the compaction against the current manifest and updating its local state to be aware of the newly scheduled jobs.” (`rfcs/0025-distributed-compaction.md:307`)
- The same intent is repeated in the `CompactionStatus` docs: only the coordinator promotes `Submitted -> Scheduled`, workers never act on `Submitted`, and this keeps the coordinator the single gatekeeper (`slatedb/src/compactor_state.rs:238-243`).
- `validate_compaction()` documents that cross-compaction conflicts are enforced “upstream in `CompactorState::add_compaction()` and are not re-checked here” (`slatedb/src/compactor.rs:1024-1029`).
- There is an existing regression test that asserts the local scheduler path must reject a duplicate conflicting compaction:
  - `test_should_not_schedule_conflicting_compaction()` (`slatedb/src/compactor.rs:5331-5347`).
  - This is evidence that the intended behavior is “still only one active compaction,” not “allow both and let a later stage sort it out.”

### Commits / blame

- `91e4322c8d493be754de2bf090b9fc874d792acb` (`Allow users to trigger compactions (#1181)`, committed January 9, 2026) introduced the public manual submission path.
- `943dcc21c4eb26c761b4d024b4d26f0db1f4ff50` (`Distributed compaction (RFC-0025) Phase 3.1: Wire up Compactor to use CompactionWorker and add Scheduled State (#1753)`, committed June 10, 2026) introduced the distributed `Scheduled` promotion path.
- The conflict checks in `add_compaction()` were strengthened later (`791ff4dee0daf2a98410ec64850193f8d13867af`, committed May 12, 2026), but that protection still only covers the local scheduler path.

## Step 3: Known-status / precedent

### Upstream issue-tracker search

I searched the upstream GitHub tracker and recent pull requests for this mechanism.

Related issue:

- `slatedb/slatedb` issue `#1838`, “Compaction worker can panic when concurrent jobs share the same destination sorted run,” opened on June 25, 2026:
  - https://github.com/slatedb/slatedb/issues/1838
  - The issue is about duplicate manual `Full` / `FullSegment` submissions producing two jobs with the same destination sorted run and then reaching the worker.
  - As of Tuesday, July 21, 2026, the issue is still open and the issue page shows no linked branches or pull requests.

This is relevant precedent, but it is not an exact match for this finding’s specific mechanism. MC-1 claims that an externally submitted conflicting compaction can pass the coordinator’s `Submitted -> Scheduled` promotion even when another L0 compaction in the same segment is already active. The current code contains a coordinator-side `validate_compaction()` guard for exactly that case (`slatedb/src/compactor.rs:1136-1150`), so issue `#1838` does not appear to report this exact site/mechanism.
