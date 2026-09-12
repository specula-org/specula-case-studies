# Temporal: Matching Queue Persistence, Acknowledgement, and Ownership

## Goal

Build a reusable, implementation-grounded formal model of Matching's durable task backlog, and establish how its acceptance, delivery, acknowledgement, cleanup, and ownership contracts compose through failure and recovery.
Apply sustained effort to obtaining complete implementation traces and meaningful bounded verification. Resolve feasible abstraction and observation problems within each assigned phase, and preserve a precise handoff wherever a remaining limitation prevents completion.

## Scope and boundary

- Target `temporalio/temporal` at `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`; record the actual revision, queue configuration, and selected persistence backend.
- Start with a single physical task-queue partition and fixed priority using the priority backlog implementation selected by `matching.useNewMatcher=true` and `matching.enableFairness=false`, the source defaults at this revision.
- Cover durable enqueue, read/bypass interaction, dispatch and completion, re-spooling, acknowledgement, metadata persistence, GC, unload/reload, and owner replacement. Include sync-match success/fallback only where it determines the acceptance contract.
- After the priority path is calibrated, investigate fairness-enabled write/read merging and acknowledgement as an explicitly separate extension. Exclude legacy-queue migration, dynamic partitioning/forwarding, worker-version routing, cross-priority scheduling guarantees, and multi-cluster replication.
- Keep History's internal outbox outside this model. Treat History task-start acceptance/rejection and Worker polling as explicit interface contracts, following their code where needed to justify permitted queue outcomes.

## Prioritized questions

1. When enqueue or dispatch commits or takes effect but its response is lost, what obligation remains after retry and owner reload? Can the implementation account for each accepted, still-eligible task through durable backlog, accepted delivery, or a valid replacement? Distinguish sync matching, durable spooling, and their acknowledgement points.
2. When a database read overlaps newly persisted tasks entering through the reader-bypass path, or task completion occurs before that read is processed, do read and acknowledgement boundaries retain all required work? Follow empty/gapped reads, duplicate observations, and out-of-order completions through subsequent delivery and reload.
3. When acknowledgement advances while GC or queue-metadata persistence is in flight, can cleanup remove work still required by the acceptance contract? Establish which durable boundaries govern restart, replay, task expiry, and deletion rather than assuming every in-memory cursor is already durable.
4. When ownership changes with writes, reads, dispatches, or metadata updates still outstanding, how do range conditions and error handling distinguish old-owner work from new-owner obligations? Exercise definite rejection and uncertain write outcomes through readback and a supported unload/reacquisition path.
5. When dispatch fails and a task must be retried, re-spooled, or recovered by unloading the queue, does eligible work retain a path to delivery once the environment recovers? Include failure of the replacement write and establish which stale/expired task responses legitimately complete the original queue record.

## Interactions that must be followed

- Follow Matching request acceptance through the selected physical queue/backlog manager, writer, store transaction, reader notification or bypass, matcher, History task-start result, and task completion.
- Follow the reader's outstanding work, acknowledgement, metadata synchronization, GC, and owner lease renewal together. Distinguish logical work identity from storage records that may be replaced or redelivered.
- Reconcile actual SQL or Cassandra task-store conditions with `taskQueueDB` error classification. Preserve backend atomicity while exposing genuinely separate asynchronous operations.

## Caller, environment, and fault assumptions

- Duplicate delivery, legitimate expiry, and rejection of already-started or obsolete History work are permitted where the interface specifies them. Establish those cases before interpreting a queue record's disappearance.
- Persisted acknowledgement may lag memory and cause replay after reload; approximate backlog statistics are not exact task conservation counters. Establish the correct per-owner and durable contracts separately.
- Use `writeDefinitelyFailed` and the backend's actual behavior to classify write errors. A generic timeout or unavailable response does not by itself establish noncommit.
- State the stable-owner, available-store, eligible-poller, finite-interference, and eventual-processing conditions needed for progress. Strict global ordering or weighted fairness is outside the initial fixed-priority contract.

## Evidence and completion requirements

- Address every priority question and investigate adjacent implementation-derived questions within this boundary. Establish complete core traces before expanding to fairness or additional queue policies.
- Reuse the priority backlog tests for controlled schedules, then collect traces through the real queue code and a real task store. An in-memory matching fake alone cannot establish ownership fencing, transaction outcomes, or durable recovery.
- Independently observe store results, in-flight reads/writes, reader notifications, accepted deliveries, acknowledgement, and deletion. Validate complete normal, overlapping-operation, and failure/recovery traces; use controls that expose inconsistent task identity or queue boundaries.
- Resolve observation gaps and model/implementation disagreements without inferring a convenient order or generating missing implementation state from the model. Passing snippets do not establish complete-scenario fidelity.
- Complete a meaningful bounded baseline and document each additional check's assumptions, scope, result, and resource limit. Distinguish executed store backends and configurations from modeled alternatives; report incomplete searches and unvalidated extensions explicitly.

## Source entry points

- `service/matching/physical_task_queue_manager.go` and `common/dynamicconfig/constants.go:MatchingUseNewMatcher` / `MatchingEnableFairness`: implementation selection.
- `service/matching/pri_backlog_manager.go`; `service/matching/pri_task_writer.go`; `service/matching/pri_task_reader.go:processTaskBatch`, `signalNewTasks`, `setReadLevelAfterGap`, `ackTaskLocked`, and `doGCAt`.
- `service/matching/db.go:RenewLease`, `CreateTasks`, `SyncState`, `CompleteTasksLessThan`, and `writeDefinitelyFailed`; `common/persistence/sql/task_queues.go`, `common/persistence/sql/task_v2.go`, and the corresponding Cassandra task-store paths.
- `service/matching/backlog_manager_test.go:TestBacklogManager_Pri_Suite` and its bypass/read/ack tests; follow the actual History start acknowledgement in `service/matching/matching_engine.go`.
- For the separate fairness extension, `service/matching/fair_task_reader.go`, `fair_task_writer.go`, `fair_backlog_manager.go`, and `fairness.md`; verify documentation against the implementation and reuse the fairness-specific standing-backlog tests.

## Validation continuation — 2026-09-11

The user explicitly requests continued verification in this existing session. This supersedes the previous handoff-only continuation: completing reports or downstream review does not complete the unfinished model checking.
Reuse the existing model, implementation traces, negative controls, and review feedback. Actively resolve the baseline's search explosion, execute a meaningful bounded baseline to completion, and pursue the pending acceptance/ownership, read/bypass, acknowledgement/deletion, owner-replacement, and conditional-progress checks. Repair relevant observation or model-fidelity gaps and rerun affected trace checks when the model changes.
Choose and justify tractable abstractions or separate checks from the implementation contracts. Preserve the original timed-out result and explain exactly what each completed scope establishes; do not silently drop properties, exclude the critical interactions, or present smaller bounds as completion of the original search. Keep configured resources and agent routing unchanged; choose appropriate per-check time budgets and retain checkpoints where supported.
Make substantive execution progress before handing off. A prior timeout or another unchanged timed-out search is a reason to investigate and adapt, not to stop at a status report. If a check remains infeasible, document the approaches actually attempted and retained evidence, then continue the other feasible checks. After this verification work, refresh validation artifacts and let review and the remaining pipeline stages run.
