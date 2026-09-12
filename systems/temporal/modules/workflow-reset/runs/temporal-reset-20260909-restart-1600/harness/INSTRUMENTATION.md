# temporal-reset instrumentation

This is a Category A recorder for Temporal `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`. Run from `.specula-output`:

```sh
bash harness/run.sh
```

`SOURCE_RESET` can select another checkout of that revision. `TLC_CLASSPATH` can supply compatible TLC and CommunityModules jars. Python 3, Go 1.27, and Java are required. The script applies a checked, idempotent patch, builds with `test_dep`, runs six public-API functional scenarios against file SQLite, normalizes observations, and invokes TLC on every trace. All commands have outer timeouts. Scratch directories are under the workspace.

**Current result: 8/8 public-API functional scenarios and 8/8 complete traces pass.** They contain 619 records, 53/64 base action types, and 42 independently checked durable checkpoints with no mismatch. See evidence/validation.json and evidence/execution-summary.json. The source remains the pinned revision with instrumentation only.

The current harness additionally records first-CAN-WFT scheduling, begins and commits shard acquisition separately, and records database request issuance. SQL COMMIT is observed immediately before tx.Commit through a private read-only WAL connection; history transactions are filtered from that metadata event. The real RangeID update and its snapshot share one observer interval. None of these hooks repairs Reset behavior.

## Files and capture points

`patches/instrumentation.patch` contains only changes to tracked source files. `src/*.go` are copied into the checkout. Earlier analysis tests are preserved. `evidence/probes.txt` lists exact source lines after apply.

| Source | Capture |
|---|---|
| `common/resettrace/trace.go` | Mutex-serialized observation writer, real timestamps, scoped fault callbacks, I/O-context tags; capture errors fail the test at recorder close. |
| `common/persistence/sql/reset_trace.go` | Direct SQL execution/current/shard reads, separately read history-tree registrations and physical history-node batches. Includes orphan and deleted branch tokens. |
| `service/history/api/startworkflow/api.go` | Allocated Start identity after current lock, response construction, deferred release. |
| `service/history/api/resetworkflow/api.go` | Actual normalized request, base/current lease snapshots, current lookup, dedup comparison, generated UUID, server response, final deferred release. |
| `service/history/ndc/workflow_resetter.go` | Start-ID selection, volatile link, fork tokens, rebuilt state, complete single-page history read, each examined event, successor lookup, scheduled output, optional pause between base update and candidate Create. |
| `service/history/workflow/reset_trace.go`, `service/history/historybuilder/reset_trace.go` | Read-only access to leased mutable state, version, pending events, and buffered reapplication events. |
| `service/history/workflow/mutable_state_impl.go` | Actual parameter received by `addCompletionCallbacks`, including zero-callback calls. |
| `service/history/shard/context_impl.go` | Submitted persistence request after I/O admission, return after semaphore release, real shard stop/acquisition, staged public deletion. |
| `common/persistence/sql/execution.go`, `common/persistence/sql/common.go` | Current/candidate history append boundaries; transaction commit/rollback before result delivery. The committed-timeout fault fires after `tx.Commit()` and before returning to the caller. |
| `common/persistence/history_manager.go` | Actual history-tree reference snapshot and computed deletion ranges. |
| `tests/reset_trace_test.go` | Existing functional suite/testcore reused for supported Start/CAN/Delete, public response receipt/loss, exact replay, faults, direct readback, shard reload, and worker completion. |

## Adjusting captures

Edit canonical files in `harness/src`, then run `run.sh`. For an existing-source probe, edit its patch hunk or make the change in the checkout and regenerate **only the nine tracked instrumentation files** listed in the patch. Do not use `git checkout -- .`; the checkout contains pre-existing analysis tests.

To add a field, capture its actual source value in the Go `resettrace.Fields` argument or SQL observer, then update `src/normalize.py`. Its `durable` method derives database fields from the SQL snapshot; `observe` tracks request/local/write frames. Every emitted state field is checked by `Trace.tla`'s full-record equality. Keep auxiliary implementation details in the raw sidecar.

To add an event, insert `resettrace.Emit(workflowID, name, fields)` in the real path, add its projection in `observe`, and add a scenario that reaches it. Register new run/token identities before they are needed by storage observation. Move the Go probe to change before/after timing; never reorder its records in Python. For reapplication, preserve the original event's provenance and map the buffered event to its assigned persisted event ID at scheduling.

`evidence/raw/*.jsonl` contains actual observations and complete decoded database snapshots. `traces/*.evidence.json` maps every trace line to its raw line, UUIDs to symbols, and real event IDs/versions to normalized positions. It also reports projection gaps and independent checkpoint comparisons. No model execution generates snapshots.

## Validation boundaries

- Full equality remains active for all seven state records, including rt.epoch and runs[r].firstTaskScheduled. No silent actions or permissive state fallback are used. TraceMatched must be checked.
- The current source/model differences and layered DAP evidence are recorded in spec/changelog.md and spec/output/validation-20260909. Original spec-generation generators do not reproduce later repairs; use the checked-in current base/MC/Trace artifacts for this handoff.
- File SQLite uses WAL and synchronous=normal with its ordinary writer pool. The observer opens a separate read-only, private-cache connection to avoid taking the writer's held connection at COMMIT issuance.
- History/cell descriptors remain after deletion, while db.nodes independently tracks physical availability. An absent cell is not restored by keeping its descriptor.
- Captures are single-page history ranges. Multiple pages or more than 10,000 physical rows require extended instrumentation. Multiple conflicting transaction versions remain a reported projection gap.
- CloseShard tests exercise real shard/cache reload and durable readback, not OS process termination. PostgreSQL/MySQL/Cassandra, remote delayed completion, multipage replay, Update producer combinations, callbacks' delivery, and child-completion behavior are not trace-validated.
- Scanner sensitivity probes are separate execution evidence under spec/output/validation-20260909/scanner-probe; they are not added to the accepted trace count. The adapter calls the real age filter and deletion handler with real History RPC/persistence, bypassing periodic worker scheduling only.
- The retained raw SQL snapshots and logs are evidence; testcore removes its temporary databases during cleanup.
- Trace debugger-generated files were archived before clean_traces removed the redundant copies from spec/. Counterexamples and raw implementation traces are retained.

clean.sh reverses only the owned instrumentation patch and unchanged copied main-harness files. It preserves prior analysis tests and the separate scanner probe.
