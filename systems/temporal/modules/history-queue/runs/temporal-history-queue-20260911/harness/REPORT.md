# Harness evidence

Revision: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`. Category A. SQLite WAL, synchronous FULL.

Implementation replay: 6 scenarios. Negative controls rejected: 8.
Observed model actions: 46/65; Init/Endpoint excluded from that denominator.

| Scenario | Events | Evidence |
|---|---:|---|
| batched_checkpoint | 87 | `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/harness/evidence/run-20260911T193533Z-m3XQAh/batched_checkpoint` |
| cursor_healthy | 88 | `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/harness/evidence/run-20260911T193533Z-m3XQAh/cursor_healthy` |
| cursor_stall | 126 | `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/harness/evidence/run-20260911T193533Z-m3XQAh/cursor_stall` |
| delete_lost_reply | 72 | `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/harness/evidence/run-20260911T193533Z-m3XQAh/delete_lost_reply` |
| healthy | 85 | `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/harness/evidence/run-20260911T193533Z-m3XQAh/healthy` |
| matching_lost_reply | 76 | `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/harness/evidence/run-20260911T193533Z-m3XQAh/matching_lost_reply` |

Each raw record contains fresh queue/shard observations and independent committed-store reads. `reduce.py` assigns identities, projects predicates/keys, records hook control locations, and retains observed historical receipts. It never executes the TLA+ model. Full `post` equality is required at every step; no silent actions or optional state fields are used.

## Coverage limits

Matching is a controlled RPC test boundary that forwards Add requests to the real Temporal SQL TaskManager. The real History cache, mutable-state load, Transfer executor, executable wrapper, queue/reader/slice/tracker, rescheduler, shard UpdateWorkflowExecution, shard acquisition, and SQL persistence run. Namespace/cluster registries and the engine lifecycle shell use test infrastructure. Matching backlog/sync-match, worker RPCs, and DLQ execution are outside these six schedules. Historical Matching acceptance is not worker completion.

Fresh acquisition executes loadShardMetadata, renewRangeLocked, engineFactory reconstruction, the acquired-state transition, and real queue notifications. Old wrappers remain visible after Stop; these schedules do not execute late old-owner callbacks. The callback schedule is serialized; probes may run under existing locks. Reader and rescheduler event loops are driven by test calls to their real methods. Fresh-engine construction uses a lifecycle shell whose Start/Stop do not launch unrelated services.

The native allocator uses RangeSizeBits=20. Fixture workflow histories are prepared before Init; the empty modeled queue starts at the observed allocator frontier. Keys in epoch 1 map from that frontier to 8; epoch 2 starts at 16. This preserves all observed bounds, gaps, pending minima, and adjacency. BatchSize=1, MoveGroupTaskCountBase=2, max readers=2, unlimited predicate bytes, shrink keys=2, unexpected-error threshold=2, DLQ disabled. Complete raw namespace IDs, task keys, request metadata, pointer identities, page responses, and SQLite blobs remain in the sidecars.

## Priority questions

| Question | Executed evidence | Remaining gap |
|---|---|---|
| Publication/read frontier | Real singleton workflow mutation, append, atomic commit, condition-failure noncommit, pending tracker, dropped hint and periodic polling | Uncertain publication and delayed writer across takeover require held-request schedules |
| Reader obligations | Split, compact, Clear cancellation, reread, out-of-order ACK, group split/merge, predicate shrink, cursor sampling, reload | Two complete real-executor traces now cover detached reader1 cursor abandonment, a healthy scheduling control, and fresh-acquisition recovery; byte-size predicate inflation and read-buffer/error paths remain untraced |
| Checkpoint/delete | Definite DELETE rollback, committed DELETE with lost reply, retry, volatile/durable checkpoint divergence, reload readback | Reordered concurrent shard snapshots and UpdateShard reply loss are untraced |
| Ownership | Real fresh acquire, RangeID transaction, reconstruction, post-reload dispatch; old wrappers retained | Late executor callbacks and outstanding stale snapshots remain untraced |
| Disposition/retry | Workflow and Activity dispatch, SQL Matching acceptance, lost response, finite APS throttling, rescheduler and duplicate acceptance | No worker completion, sync-match terminal discard, or durable DLQ schedule |

## Uncovered actions

- `EnqueueTaskCommit`
- `EnqueueTaskLostReply`
- `EnqueueTaskReply`
- `ExecuteTerminalError`
- `ExecuteUnexpectedError`
- `HandleErrTerminal`
- `MatchingTerminalDiscard`
- `ProcessTransferTaskObsolete`
- `RecordTaskStarted`
- `RenewRangeLockedFenced`
- `SetQueueStateClosed`
- `TaskRequestTimeout`
- `UpdateShardFail`
- `UpdateShardFenced`
- `UpdateShardInfoSnapshot`
- `UpdateShardLostReply`
- `UpdateWorkflowExecutionFenced`
- `WorkerComplete`
- `WorkflowNoLongerNeedsTask`

These actions are untested by trace replay. Publication timeouts/epoch-fence errors require a controlled outstanding-request schedule across ownership change; concurrent shard snapshots also need more than the single in-flight snapshot slot used here. DLQ/terminal/obsolete/worker-start/completion events require different executor or downstream fixtures and observation hooks. The bounded initial harness does not implement those schedules; this is a coverage gap, not evidence that the actions are unreachable.

## Adapter changes

- Trace tag aligned with the skill: `trace` replaces `temporal-history-queue`; the full envelope and state checks remain mandatory.
- Trace.cfg uses the actual test overrides and finite identity capacities.
- `MatchingLostReply` now records `unexpected`: `context.DeadlineExceeded` reaches the unexpected branch of real executable.HandleErr and increments its budget. The old `retry` projection failed full-state replay; the observer retains the measured counter. Other base actions and all invariants remain enabled.
- Multi-slice Clear is modeled as one reader-locked loop; each preceding tracker is cleared before the next selected slice. The removed cursor slice is sampled at the SelectTasks hook after its final iterator is exhausted.
- Original input copies and the exact spec diff are retained under `harness/evidence/` and `harness/patches/`.

## Reproduction

```bash
cd /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output
bash harness/run.sh
```

Latest run: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/harness/evidence/run-20260911T193533Z-m3XQAh`. Read `validation/validation.json`, `validation/coverage.json`, `go-test.log`, and each scenario's `raw.ndjson` and `history.sqlite`. Validation logs contain the exact TLC state counts.

## Additional checks

- `evidence/lint-final-02.log`: `timeout 600 make lint-code-fast GOLANGCI_LINT_BASE_REV=HEAD GOLANGCI_LINT_FIX=false`, zero issues.
- `evidence/regression-final.log`: queue, reader, slice, executable, task-key/tracker, and real Transfer executor regression suites.
- `evidence/native-sqlite-regressions.log`: existing native batch-100 cursor and SQLite checkpoint/recovery probes; these use controlled ACKs and are supplemental code/API evidence, not complete implementation traces or new MC discoveries.
- `evidence/apply-clean-final.log`: clean pinned worktree apply, repeated apply, selective clean, and empty checkout status; original source worktree retained.
