# temporal-update instrumentation

**Phase 2.5 status: INCOMPLETE.** The harness runs nine real Temporal/SQLite scenarios and emits implementation observations. Full replay against the supplied `Trace.tla` is not complete. Eight measured admission prefixes pass its strict whole-state validator; each prefix contains exactly three transitions. See [HANDOFF.md](HANDOFF.md) for blockers and evidence limits.

## Run and source

Category A: network/RPC, persistence and asynchronous History tasks; one mutex-protected NDJSON writer per scenario. Target revision is `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`.

From `.specula-output/`:

```bash
bash harness/run.sh
```

This applies the patch, compiles with `test_dep,disable_grpc_modules`, runs real functional tests using SQLite, audits traces, and validates the bounded prefixes. It deliberately exits **2** for incomplete full replay. Build/test/validation failures also propagate; a passing functional test is never substituted for complete trace validation. Set `TEMPORAL_SOURCE` or `TLA_TOOLS_DIR` to override the recorded defaults.

`apply.sh [source]` checks the pinned revision, refuses conflicts, and preserves unrelated files. `clean.sh [source]` reverses only this exact patch and removes only matching harness-owned files. The six prior investigation test files are preserved. Apply, reapply and cleanup were checked in an isolated clean worktree; see `evidence/apply-check.log`.

## Files and capture boundaries

The authoritative, post-apply **file:line list** is [evidence/probe-locations.txt](evidence/probe-locations.txt). Production changes are in `patches/instrumentation.patch`; copied Go files mirror source-relative paths under `src/`.

| Source file | Capture |
|---|---|
| `common/speculatrace/trace.go` | Open/Emit/Publication/Close; mutex, real RFC3339Nano timestamps, flushing and error handling |
| `service/history/workflow/specula_trace.go` | Leased Mutable State, registry, task tuple, range/RV, exact timer pointer; selected-run baseline cache removal |
| `service/history/workflow/update/specula_trace.go` | Actual Update pointers, provisional state, callback count, independently ready future values |
| `service/history/api/updateworkflow/api.go` | Admission/dedup/scheduling; dispatch failures and response assembly |
| `service/history/workflow/update/update.go` | Protocol handlers; individual future Set and unlocked waiter Get observations |
| `service/history/workflow/update/registry.go` | Removal, clearing and automatic rejection |
| `service/history/workflow/workflow_task_state_machine.go` | Start and WFT completion |
| `service/history/api/recordworkflowtaskstarted/api.go` | Registry.Send response construction, including the real precommit normal path |
| `service/history/api/respondworkflowtaskcompleted/{api.go,workflow_task_completed_handler.go}` | Token/current-task guards, messages, effects, returned write result |
| `service/history/workflow/context.go` | Transaction preparation, Clear and load |
| `common/persistence/sql/execution.go` | Physical append boundary, execution submission/settlement, independent post-transaction SQL query |
| `common/persistence/faultinjection/execution_store_gen.go` | Actual selected timeout result and execute-before-error flag |
| `service/history/events/cache.go` | Real Put/Get hit/miss/Delete with the complete cache key and payload |
| `service/history/{queues/memory_scheduled_queue.go,tasks/workflow_task_timer.go,timer_queue_active_task_executor.go}` | Eligibility, scheduler acceptance, cancellation, exact timer/current-state comparison |
| `service/matching/matching_engine.go` | Raw request and return evidence; these are not fabricated acceptance events |
| `tests/specula_update_trace_test.go` | Existing functional framework/protocol builders, controlled faults, worker/client receipt, History and execution readback |

## Schema and L2 limits

`traces/*.ndjson` retain the skill's mandatory `tag: "trace"`, real `ts`, and `event: {name,nid,state}`. Supplemental probes have `tag: "evidence"`; configuration has `tag: "config"`. Transition ordinals are contiguous. Raw pointer identities and protobuf payloads remain available for lossless normalization.

These **raw snapshots are specialized observations, not complete model `s` snapshots**. Mutable State is read under the real lease. Waiters read only returned future values and immutable pointer identity. `Publication` serializes one Set plus snapshot against waiter observations. It does not acquire a lease or wait for backend/RPC work.

The supplied instrumentation envelope instead requires `tag: "temporal-update"` and forbids additional timestamp fields. `admission_prefix.py` adapts only the three fully observed admission transitions to that envelope, retaining raw timestamps/line numbers in provenance sidecars. It independently normalizes observed baseline RV/range and copies every model post-state field. It does not run the model to manufacture state, choose successor actions, or replay the unhandled suffix. The actual first four cache keys are removed only for the selected run under its first Update lease.

`ValidatePostState` is full-state equality, not `TRUE`, and all wrappers call it. Full-trace L2 remains incomplete; raw evidence beyond the prefixes is not claimed as state validation. Phase 3 corrected base action domains, normal start-response ordering, acceptance cache insertion, precommit record-version advancement, and append-timeout submission ordering. Full post-state equality and zero silent actions are preserved.

## Adjusting instrumentation

- Add a leased field in `SpeculaSnapshot` or an Update field in `Update.SpeculaSnapshot`; preserve absence/zero values explicitly. Extend the real snapshot-to-model mapper only after identifying its source and validation check.
- For a waiter field, capture the thread-safe method's returned value. Never call the leased snapshot helper from a waiter.
- Add a boundary probe in the real caller/callee, using `SpeculaEmit` for leased state or `speculatrace.Emit` for immutable evidence. Match the model event name only when the trigger is the same. Use `probe.` names for supplemental evidence.
- To move a capture, edit the inserted call in the patch. Future publication captures are inside `speculaPublish`; never hold its observer mutex across another Emit, a lease, I/O or Future.Get waiting.
- Keep copied files under `src/` synchronized with the source. Regenerate the patch only for paths in `evidence/changed-files.txt`; do not include unrelated edits.
- Run `bash harness/run.sh` again. Inspect `evidence/scenarios.log`, `coverage.json`, `validation-result.json` and the individual TLC logs.

## Event coverage

The final selected runs observed **44 of 90 model action names**; this counts name occurrences, not validated transitions or implementation coverage. The exact current probe count and unobserved names are in the coverage JSON. [evidence/instrumentation-coverage.json](evidence/instrumentation-coverage.json) enumerates every observed/unobserved model action and every instrumented-but-untriggered action with its reason. Remaining model actions lack a complete observer implementation or selected schedule; none are silently accepted by replay.

## Validation-phase update

The start API now emits `RecordWorkflowTaskStartedReturn` after successful History assembly, outside the lease; its immutable response is captured at the actual return. The model has 90 actions. The rerun passed all nine real scenarios and eight admission prefixes; complete replay remains blocked. Use `GOMAXPROCS=8 bash harness/run.sh`; the script uses an isolated build temporary directory by default. A prior Go linker SIGBUS is preserved under `spec/output/validation-round-1/build-attempt-1/`; the isolated-directory rerun succeeded. Current results and exact remaining work are in [validation-handoff.md](../spec/validation-handoff.md).
