# Validation report — temporal-history-queue

The six complete implementation traces and eight negative controls pass. CR-1's live-reader stall is reproduced through the real Transfer executor with durable workflow/task/queue-state evidence, a healthy scheduling control, and fresh-acquisition recovery. The broad `MC.cfg` search is recorded separately below; trace acceptance and finite diagnostic schedules do not establish convergence.

## Revision, backend, and execution boundary

- Temporal: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`, verified from the source checkout. Existing investigation changes were preserved; added changes are test instrumentation, harnesses, specification repairs, and evidence.
- Backend: real Temporal SQL stores backed by file SQLite, WAL, synchronous FULL. Independent readers use other SQL connections. A standalone post-test decoder also reads the retained stalled snapshot and final database, including protobuf workflow/queue state and Matching rows.
- Modeled boundary: one History shard and immediate Transfer queue. The complete traces use actual workflow mutations, History cache and ordinary Workflow/Activity Transfer executors, queue/readers/slices/trackers, executable disposition, rescheduler, shard acquisition, checkpoint and SQL stores. Matching is a controlled RPC adapter forwarding to Temporal's SQL TaskManager. Namespace registries and the engine lifecycle shell use test infrastructure; reader/executor turns are deliberately scheduled. This is not an uncontrolled whole-service crash experiment.
- Trace overrides: batch1, two readers, move threshold2, two namespace groups, no predicate-byte limit, shrink keys2, unexpected-error threshold2, DLQ disabled, native allocator RangeSizeBits20. The order-preserving key mapping retains frontier/gap/adjacency relationships. Production batch100/move500 are exercised separately by the existing native cursor probe with controlled ACKs.
- Baseline MC: three task identities, two owner instances/epochs, two groups, 10 slice slots, six executable slots, two simultaneous snapshot slots, batch1 and the supplied fault budgets. Ordinary neighboring snapshot initiation is now repeatable. MC uses 16 workers, 12 GiB heap and 24 GiB off-heap within the configured 112 GiB / 32-worker run allocation, with a 30-minute deadline. No task/fault bounds were reduced to fit BFS.

## Method and repairs

The supplied `validation-workflow`, `tla-trace-workflow`, and `tla-checking-workflow` guides and their referenced debugging/report formats were read. `TraceMatched` is active, every event checks complete `s' = DecodeState(e.post)`, and Endpoint requires complete independent readback. All raw observations remain available; negative controls are labelled synthetic.

The MCP server's installed SDK is incompatible with its `Server.list_tools` API. Its failure is retained in `output/validation-20260911/round1-traces.log`. The installed `run_trace_validation`, `run_trace_validation_parallel`, and `run_trace_debugging` handlers were invoked directly with their original schemas and implementations. Full raw TLC logs complement those structured results. This changes transport, not checking semantics.

All repairs and evidence are in [changelog.md](changelog.md):

1. **Case B — acquisition lifecycle:** a completed renewal no longer revives a stopped owner. Durable renewal/key-reset effects remain distinct from rejected engine publication. The source transition rejects acquired requests after stopping/stopped. A finite replay now reaches its required endpoint and preserves stopped mode (8 states).
2. **Case B — batch order:** executable bindings follow persisted task-key order, rather than logical identity order. A reversed-allocation two-task replay reaches its endpoint and passes (11 states). The atomic successful-read projection requires active-shard admission; prefetched pages and partial read failures remain outside its coverage.
3. **Case B — MC fairness assignments:** the six fairness service actions now preserve `faults`, completing their primed-state assignment. A previously failing fairness diagnostic now evaluates without the runtime exception. Its 19-state finite prefix does **not** establish dispatch liveness or a recurring Clear schedule.
4. **MC representation/workload:** ordinary snapshot initiation is no longer charged to a finite fault counter; reusable slots bound concurrency. The S2 coverage config now has three groups. A 26-state endpoint-checked diagnostic reaches actual widening of a proper subset and overlapping coverage of the third group's task; semantic cardinality still abstracts actual predicate bytes.
5. **Trace inconsistency — Clear loop:** real `ReaderImpl.ClearSlices` clears several selected slices under one reader lock. The model previously insisted each new slice began at idle. Layered debugger evidence at healthy trace line45/state44 isolates this guard. Ordered continuation clears the preceding tracker and retains the lock until the final cursor reset.
6. **Capture defect — detached object:** at stalled trace line67/state66 the base selection succeeds but full post-state equality fails. After the cursor becomes nil, the old probe loses the selected detached object and retains its prior iterator. The existing selection hook now records the actual `loadSlice` after exhaustion; regeneration resolves the mismatch without loosening equality.
7. **Stale synthetic fixture:** the late-DLQ witness still used HandleErrRetry after MatchingLostReply had been corrected to the implementation's unexpected-error classification. Only the fixture choreography/tag was repaired. Its 56-state endpoint now passes.

No invariant was weakened to hide the cursor defect, and no Case C discovery was established by the baseline.

## Implementation trace results

Latest reproducible run: `../harness/evidence/run-20260911T193533Z-m3XQAh/`.

| Trace | Records, including Init/Endpoint | Result |
|---|---:|---|
| healthy | 85 | PASS: Workflow/Activity dispatch, dropped hint/poll, split/compact/Clear, definite DELETE rollback and retry |
| batched_checkpoint | 87 | PASS: memory/durable checkpoint divergence, fresh acquisition, post-reload dispatch |
| delete_lost_reply | 72 | PASS: actual DELETE commit, injected ExecuteAndTimeout response, retry and cleanup |
| matching_lost_reply | 76 | PASS: SQL Matching acceptance before timeout, unexpected-error count, finite APS throttling, retry/duplicate acceptance |
| cursor_healthy | 88 | PASS: read advancement precedes shrinking; later workflow dispatch succeeds |
| cursor_stall | 126 | PASS: reader1 cursor is detached then nil, retained eligible work, ineffective polling/Notify, durable scope and reload recovery |

Total: **534 records; 46/65 named model actions observed**. Passing an adverse trace means the model faithfully accepts the measured adverse behavior; it does not assert that the system is correct. All eight corruptions are rejected: unsupported ACK responsibility, omitted original row, wrong predicate, wrong cursor, volatile checkpoint falsely labelled durable, missing Endpoint, omitted commit, and omitted reply.

Unobserved actions: EnqueueTaskCommit/LostReply/Reply; ExecuteTerminalError/UnexpectedError; HandleErrTerminal; MatchingTerminalDiscard; ProcessTransferTaskObsolete; RecordTaskStarted; RenewRangeLockedFenced; SetQueueStateClosed; TaskRequestTimeout; UpdateShardFail/Fenced/InfoSnapshot/LostReply; UpdateWorkflowExecutionFenced; WorkerComplete; WorkflowNoLongerNeedsTask. These remain trace gaps, not unreachable actions.

## Independent source observations

### CR-1 — confirmed live-reader progress failure, source-discovered

A real singleton workflow transaction publishes each of three tasks. Range splits and actual move-group processing create two disjoint reader1 slices after the middle task is dispatched. Clear cancels the old wrappers. The first replacement wrapper executes successfully; a full batch leaves its exhausted iterator in place. Checkpoint shrinking removes this cursor element without resetting `nextReadSlice`. The next reader turn follows the removed list element to nil, leaving the later slice unread. Three poll/checkpoint/Notify cycles do not dispatch the later workflow.

The stalled snapshot contains **task1048598**, a running workflow with WorkflowTaskScheduledEventID2 and StartedEventID0, a durable reader1 scope beginning at1048598, and only two other Matching entries. The later workflow has no Matching entry. Fresh shard acquisition advances RangeID1→2, rebuilds the reader, executes that task, durably accepts the third Matching entry, and subsequently deletes the original Transfer row. The healthy control changes the scheduling order so cursor advancement precedes checkpoint shrink and dispatches without reload.

Evidence: latest harness `go-test.log`, `cursor_stall/raw.ndjson`, `cursor_stall/stalled.sqlite`, and `cursor_stall/history.sqlite`; standalone `output/validation-20260911/stalled-protobuf-readback.json`, `history-protobuf-readback.json`, and `independent-sqlite-readback.json`. Relevant source: `reader.go:ShrinkSlices/loadAndSubmitTasks`, `slice.go:SelectTasks/ShrinkScope`, `queue_base.go:checkpoint`, and shard acquisition/newQueueBase reconstruction. **This is delayed recovery/live inaccessibility, not physical task loss.** The adverse test reaches actual executor eligibility and durable transport acceptance after recovery; it does not run a worker to complete that same stalled workflow. The separate functional control completes a Workflow/Activity exchange.

Upstream refresh: PR[11353](https://github.com/temporalio/temporal/pull/11353) is a merged AppendSlices locking repair and concerns a distinct race. Two fresh repository issue/PR searches for `nextReadSlice` and `ShrinkSlices` returned zero results; that bounded keyword search does not establish novelty. Raw GitHub API replies and commands are under `output/validation-20260911/upstream/`. CR-1 was already discovered by source review and reproduced in the input investigation; this phase strengthens reproduction and trace fidelity rather than claiming an MC-first finding.

### CR-2 — accounting inflation reproduced; harmful consequence unestablished

Controlled duplicate wrappers with the same task key are merged through the real executable tracker. The retained executable map has one key while its group count is2; after the retained wrapper ACKs, the map is empty but the count remains1. A disjoint-key control ends with both map and counts empty. The real Slice ShrinkScope still yields an empty scope in both cases. This confirms the source accounting observation while preserving its empty-range compensation. It does not establish a reachable production mitigation decision causing lost work.

Evidence: `output/validation-20260911/tracker-observation.log` and the final whole-package regression. Test source: `../harness/src/validation_tracker_test.go`. Exact predicate-byte inflation and production overlap generation remain outside this controlled test/model arithmetic.

### CR-3 — proposed finite-contention failure narrowed to shutdown

`updateShardInfo` advances batching bookkeeping before semaphore acquisition, but passes the shard lifecycle context to that acquisition. This context has no deadline. With positive capacity, real PrioritySemaphore acquisition waits through contention and succeeds after release; it does not manufacture a transient timeout. The cancellation control uses the actual shard stop transition, which cancels that context; no persistence write occurs and the context is already stopping. The observed advanced bookkeeping therefore does not establish delayed checkpoint retry on a healthy shard under finite contention. Zero/invalid semaphore capacity is a different configuration assumption.

Evidence: `TestValidationCheckpointSemaphoreLifecycle` in the final whole-package regression; source `../harness/src/validation_checkpoint_test.go`, `ContextImpl.ioSemaphoreAcquire/transition/updateShardInfo`, and `PrioritySemaphoreImpl.Acquire`. Persistence call counts use the existing shard test mock; this test establishes the cancellation/control-flow condition, not durable recovery.

## Priority question matrix

| Question | Checked paths and result | Remaining gap |
|---|---|---|
| Q1 publication/read frontier | Complete normal workflow publication, SQL atomic commit/noncommit, pending keys, dropped hints and polling pass trace replay. Existing native ExecuteAndTimeout AddHistoryTasks probe was rerun: ambiguous row9 persists, watermark stays9, renewal exposes16 and fences old writer10. Finite model composition combines unknown publication, checkpoint, and renewal. | Full workflow mutation with uncertain receipt/delayed writer through actual Context acquisition is not a complete implementation trace. Cross-product BFS is incomplete. |
| Q2 scope/cursor preservation | Split/merge/compact/Clear/out-of-order completion and reconstruction are traced. CR-1 establishes an eligible live-reader stall while durable scope/row survive. Three-group finite model schedule demonstrates widening/overlap. | Partial persistence-page failures, buffered read/DELETE races, exact predicate bytes and production mitigation guards/counts are incomplete. |
| Q3 deletion/checkpoint recovery | Definite DELETE rollback, committed DELETE/lost reply, batched metadata lag and reload dispatch have independent SQLite evidence. Native checkpoint controls and CR-3 lifecycle controls pass. A finite model schedule covers reordered snapshots and lost replies. | Actual reordered concurrent shard snapshots and UpdateShard reply-loss reconstruction are not in the implementation trace suite. Universal cleanup/liveness is unproved. |
| Q4 late owner effects | Fresh acquisition/reconstruction and old-wrapper retention are traced. Native store checks reject late protected writes/checkpoints; unfenced predecessor prefix DELETE preserves successor task16. A finite late-DLQ composition passes. | No complete trace of late old-owner Matching/DLQ callbacks, pending snapshots across takeover, or a read admitted before ownership loss. |
| Q5 responsibility/progress | Ordinary Workflow/Activity executors, Matching SQL acceptance, lost reply, retry, rescheduler and duplicates are traced. Separate real SQLite functional Workflow/Activity control passes. Existing durable DLQ lost-reply controls were rerun with queues tests. | DLQ/terminal/obsolete/start/completion are not covered by the complete trace suite. Matching acceptance differs from workflow completion; operator DLQ replay is still needed for business progress. Actual mitigation policy/fairness needs further validation before temporal verdicts. |

Known DLQ/operator-recovery behavior remains separate from new findings; upstream issue[11402](https://github.com/temporalio/temporal/issues/11402) and open PR[11403](https://github.com/temporalio/temporal/pull/11403) were refreshed.

## Bounded diagnostic coverage and limits

Completed endpoint-checked model schedules: cursor62, healthy68, recovery72, publication33, checkpoint66, late-DLQ56 states; widening26; stopped-owner8; reversed allocation order11. These are explicit finite schedules with completion properties, not exploration of every interaction in the broad baseline. The cursor schedule is source-guided reconfirmation. Five unrelated schedules cannot be composed into a proof of their simultaneous cross-product. The fairness smoke probe only evaluates a finite prefix; it is not a completed temporal hunt.

Native verification: entire queues package PASS4.473s and shard package PASS6.280s, including native batch100 cursor, publication fencing, DLQ controls, and CR-2/CR-3 tests (`native-regressions/go-test-final02.log`); Transfer executor suite PASS; SQLite functional `TestActivityHeartBeatWorkflow_Success` PASS; `make lint-code-fast ... GOLANGCI_LINT_FIX=false` PASS with zero reported changed-line issues. Fast lint filters existing issues and does not certify a clean whole repository.

## Reproduction and handoff

Run `timeout 900 bash harness/run.sh` from `.specula-output` to regenerate all six traces, replay them, and reject all eight controls. It records its Go command, source revision, raw sidecars, SQLite files, and hashes. Direct tool invocation scripts, debugger arguments/results, MC launch logs, deterministic diagnostic drivers, native outputs, upstream responses, and readback programs are retained in `spec/output/validation-20260911/`.

Do not use the earlier one-task generation contract as proof of this changed model: its hash/bounds are historical. Do not start post-convergence hunts until the required baseline has genuinely completed and all current implementation traces still pass. Preserve the missing read-buffer/admission and mitigation-policy paths when planning the next model extension.

Harness reproducibility check: the final patch and helper manifest applied twice to a clean isolated checkout of the pin; `git diff --check` passed, selective clean restored an empty status, and the temporary worktree was removed. Evidence: `output/validation-20260911/apply-clean.json` and `apply-clean.log`. The user's original dirty checkout was preserved.

## Final baseline status

**INCOMPLETE / NOT CONVERGED.** MC.cfg ran to its 30-minute limit and exited124. Last progress: 130,208,773 generated, 40,246,046 distinct, 36,081,667 queued, depth13. No invariant violation was observed in that unfinished search. The growing shallow frontier prevents an exhaustive safety verdict. Inputs equal the frozen Round 2 copies. Post-convergence hunting was not run (0/9 configs), as required by the workflow gate. [bug-report.md](bug-report.md), [findings.json](findings.json), and [validation-status.json](validation-status.json) retain this distinction.
