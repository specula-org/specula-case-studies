# temporal-nexus trace harness

Validation follow-up: [../spec/validation-report.md](../spec/validation-report.md) records five source-backed model corrections, fresh SQLite executions, independent receipt joins and the remaining full-post replay gap. The Phase 2.5 results below are historical; the bootstrap mismatch described there is now corrected in base.Init.

Status: **raw implementation collection works; complete semantic trace joining and strict `Trace.tla` replay are INCOMPLETE.** `run.sh` deliberately returns 2 at that final validation gate. Do not mark these recordings `complete=true`, count their event names as validated actions, or substitute model-generated `post` values.

## Reproduce

From `.specula-output/`:

```sh
bash harness/run.sh
```

This applies instrumentation, builds the real Temporal tests with `test_dep`, runs the existing HSM workflow/API controls, runs the focused schedules, checks raw receipts and negative controls, and attempts TLC. Logs, commands, exit codes, binary hashes, and the bootstrap diagnostic live in `harness/evidence/`. Old recordings are retained under `evidence/previous/` when rerunning. All builds/tests have outer `timeout` limits. A fired outer test timeout stops collection without automatic retry.

`TEMPORAL_SOURCE` can point at another clean checkout of the exact pin. `apply.py` refuses other revisions or unrelated edits to its files. `clean.sh` restores only files matching the harness manifest; it never resets the checkout wholesale. The authoritative source is `harness/src/` plus the anchored edits in `apply.py`. `patches/instrumentation.patch` is a review copy of the tracked source changes; copied new modules are in `src/`.

## Recorder and capture levels

This is Category A. `src/common/speculatrace/trace.go` provides a mutex-protected NDJSON writer, real RFC3339 nanosecond timestamps, namespace filtering, protobuf snapshots with unpopulated fields, and flush/close. Capture failures accumulate and fail test cleanup; they do not panic in the protocol. One fresh process/database/trace file is used for each schedule.

Each raw row has `tag="trace"`, `ts`, `sequence`, `event`, `source`, raw namespace/workflow/run IDs, and `raw`. The first row contains the effective configuration and executable SHA-256. Raw UUIDs/tokens remain unchanged. Endpoint tokens deliberately differ from request IDs; `callback_ref` is decoded independently at the endpoint. A future alias table must preserve that independently observed binding.

- **Workflow-lock capture:** `src/service/history/workflow/specula_trace.go` snapshots the live HSM tree, operation and cancellation protobufs, DBRecordVersion, task generation, insert tasks, actual logical timer groups/Scheduled flags, workflow/WFT status, and compacted transition outputs. The historybuilder helper also captures staged batches, staged buffer, DB buffer, and clear-buffer flag. Deleted-node final state is retained in the `HSMDelete` receipt, with real tree absence in subsequent snapshots.
- **Persistence capture:** `src/common/persistence/specula_trace.go` performs actual `GetWorkflowExecution` and paginated outbound/timer-store reads after each observed write attempt. `readback_id` joins the independent raw DB/queue receipts to the write outcome. SQL append and SQL transaction result have separate hooks. Immediate readback precedes shard fencing; the scenarios separately close/reacquire the shard and read back again. Queue rows are physical storage observations; `QueueExecute`/`QueueAck` preserve local delivery ownership. A semantic available-ticket projection is still required.
- **Transport/endpoint capture:** actual executor arguments/budgets and decoded responses, independently decoded endpoint requests, acceptance/dedup ledger, callback sends and caller responses. These are specialized captures and do not read unlocked mutable state. Endpoint acceptance is recorded before the controlled early-response gate. Cancel ACK leaves the endpoint outcome independent.
- **Recovery capture:** actual cache clearing, DB-to-cache construction, RangeID writes, uncertain-write shard loss, and explicit task refresh. DB reads alone are named `PersistenceReadback`; only actual cache construction is named `LoadMutableState`.

The complete post-state join has not been implemented. Raw snapshots contain evidence outside the model; that is sidecar evidence, not extra unvalidated fields in a purported semantic `post`.

## Source hooks after apply

The exhaustive, generated file:line index is [evidence/instrumentation-points.txt](evidence/instrumentation-points.txt). Main locations:

| Path relative to Temporal | Capture |
|---|---|
| `service/history/hsm/nexusoperations/workflow/commands.go` | schedule, physical capacity rejection, cancellation command |
| `service/history/hsm/nexusoperations/executors.go` | start/cancel argument loads, request budgets, response receipt, save-result branches, backoff/timeout transitions |
| `service/history/hsm/nexusoperations/completion.go` | callback mutation, fabricated start plus terminal deletion, handler-return error |
| `service/history/hsm/tree.go` | serialized real transitions and deleted-node ledger |
| `service/history/statemachine_environment.go` | lock-scoped accessor snapshot and Access return/error |
| `service/history/workflow/{task_generator,mutable_state_impl,workflow_task_state_machine}.go` | filtered task outputs, close-transaction batches, WFT bookkeeping |
| `service/history/timer_queue_task_executor_base.go` | real timer batch entry, skipped stale logical timer, final group removal |
| `common/persistence/{execution_manager,sql/execution,shard_manager}.go` | write input, append, SQL result, independent readback, task reads, RangeID |
| `common/persistence/faultinjection/{store_fault_generator,fault}.go` | targeted selection of the existing ExecuteAndTimeout fault and underlying success/error receipt |
| `service/history/{queues/executable,shard/context_impl,workflow/context,workflow/task_refresher}.go` | execution/ack, uncertain shard loss, cache reload, explicit refresh |
| `tests/specula_trace_test.go` | real endpoint ledger, controlled ordering/fault schedules, post-reload DB/history observations |

## Make an adjustment

1. Add a field to the relevant `raw` map in `src/`, or to an anchored hook in `apply.py`. Use `speculatrace.Proto` for protobufs and capture while the existing workflow lock is held. Keep transport fields at their own observation site.
2. Add an event at the actual source branch, using `node.SpeculaEmit` for a locked snapshot or `speculatrace.Emit` for an independent endpoint/transport/persistence receipt. Add a schedule and required-boundary assertion in `audit.py`; do not allow a test name alone to count as coverage.
3. Move a capture by moving the anchored hook. For compound transactions, inspect real mutation/flush boundaries before splitting events. In particular, WFT completion precedes command handling, and logical timers are removed by group after inner executors return. Do not reorder raw rows to satisfy the model.
4. Run `bash harness/run.sh`. `python3 harness/collect.py <scenario>` reruns selected schedules using the already-built executable; **rebuild first** after source changes.
5. `audit.py` checks observer integrity and rejects deliberately corrupted observations. It does not evaluate base actions. `validate.py` runs the unchanged supplied Trace and a separate bootstrap diagnostic. L2 in the supplied Trace is full state equality, not a stub; those checks have not been exercised by a complete implementation `post` stream.

See [EVIDENCE.md](EVIDENCE.md) for results, schema/boundary gaps, and exact coverage limits.
