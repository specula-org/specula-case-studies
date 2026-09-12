# Phase 2.5 evidence and unresolved work

**Result:** nine real functional scenarios pass. No complete implementation trace has passed `Trace.tla`. Eight admission prefixes, three transitions each, pass its unchanged L2 validator. These are 24 recorded admission transitions across eight runs, covering only three distinct model actions. No new Temporal bug is confirmed by this phase.

## Source/model disagreements corrected in Phase 3

The three base-spec disagreements below were corrected in Phase 3, with synthetic regression checks and fresh functional evidence. They are **not TLC-discovered implementation bugs**. Full observer reconstruction is still incomplete; see [validation-handoff.md](../spec/validation-handoff.md). The paragraphs below retain the original diagnosis for provenance. `evidence/coverage.json` contains scenario names and exact raw line numbers.

1. **Normal response construction precedes persistence.** `recordworkflowtaskstarted.Invoke` builds the response and calls Registry.Send inside the action passed to `GetAndUpdateWorkflowWithNew`. Only afterward does `UpdateWorkflowWithNew` persist non-Noop actions. The normal control observes a Sent Update before `ExecutionTransactionCommit`. Model `RecordWorkflowTaskStarted` instead enters `persist`, and permits `CreateRecordWorkflowTaskStartedResponse` only at `startResponse` after commit. Moving the probe after commit would hide the actual registry/failure boundary.
2. **Acceptance writes the host cache.** `MutableStateImpl.ApplyWorkflowExecutionUpdateAcceptedEvent` calls `writeEventToCache`. The healthy trace records cache event type 41 (UpdateAccepted) immediately before `OnAcceptanceMsg`. Model `OnAcceptanceMsg` does not update `s.cache`; its stated cache contract includes every observed entry. Full equality cannot represent this observation by dropping the accepted cache entry.
3. **The in-memory record version advances at transaction close.** `MutableStateImpl.closeTransaction` advances `dbRecordVersion` before the execution store call. The preparation probe records the advanced RV while the database still has the previous RV. Model `UpdateWorkflowExecutionWithNew` leaves `ctx.rv` unchanged and uses it as the write expectation. Phase 3 must distinguish the actual next mutable version from the expected database version, or explicitly justify a different mapping. A constant baseline offset alone cannot reconcile the time of change.

The narrow envelope adapter solves only the skill/spec tag/timestamp conflict; it does not solve these semantic differences.

## Scenario results and priority questions

| Priority | Real checked paths and evidence | Result | Remaining gap |
|---|---|---|---|
| 1: commit/recovery | `healthy`, `normal_control`, `noncommit`, `Timeout`, `ExecuteAndTimeout`; SQL append/commit markers, independent post-transaction query, public History/readback and same-ID retry after shard closure | Noncommit and pre-execution timeout leave no committed Update completion before retry; ExecuteAndTimeout has committed completion despite worker error; recovery returns the expected result | No late-settling asynchronous backend transaction, separate DB-process restart/reopen, backend internal-task readback, lost response, or later response-assembly fault schedule |
| 2: stale work | `stale_completion`: same scheduled/started IDs, distinct start timestamps, real old worker completion, sticky replacement cleanup, client retry | Old completion rejected; the sticky replacement is also invalidated; further normal delivery completes and the caller/retry obtains the expected result | No two simultaneously active owners, process crash, submitted-old-timer/conversion schedule, or canonical full replay |
| 3: outcomes/closure | `healthy`, `rejection_skip`, `accepted_close`; individual Set/Get probes and committed History | Rejection leaves next event 5 and no durable UpdateInfo; acceptance plus final close returns the legitimate closing failure; healthy acceptance/completion returns worker success | No forced waiter schedule between both Sets, two-Update interleaving, callback-buffer ignore path, or forced-limit termination |
| 4: dispatch/fallback | `dispatch_failure`; scoped real Matching request failure, actual due STS timer, normal WFT and final same-ID lookup | Fault fires; timer fallback delivers the Update and caller recovery succeeds | No accepted-by-Matching/lost-return schedule, callback dedup suppression schedule, or exact acceptance/transfer ledger |

All scenarios use the repository's real functional cluster, service handlers, Matching and SQLite persistence with `CGO_ENABLED=0`. Protocol builders and setup are reused from existing tests. Injected errors and barriers affect the selected operation's return/schedule; no protocol simulator, mocked persistence implementation, or hand-written execution trace is used.

The SQL commit marker is after the actual transaction returns successfully. The subsequent query uses the SQL store outside that transaction. It is not a database restart or proof that every internal task was read back. `Timeout` is marked as a selected pre-execution injected timeout; the real shard error handler still treats that error as uncertain. `ExecuteAndTimeout` is independently correlated with the actual SQL commit marker. Raw serialized mutations preserve History node/batch/transaction lineage; physical append is never relabeled as durable logical history.

## Capture gaps that block complete replay

- No complete merged `s` observer after admission: Matching acceptance and transfer acknowledgement, command/effect/rollback cursors, all normal timer states, detached object/host state, and all caller identities still need exact mapping.
- Matching request/return probes do not prove the acceptance instant. The scheduler-submit probe may follow a concurrently started executor. Their timestamps must not be sorted or used to infer a favorable total order.
- Raw Future.Set markers capture publication. Some `BufferApplySecond` probes precede registry removal, and clear-abort first publications currently share the general first-publication marker. They require source-specific wrapper correction for exact model actions, not renaming a raw observation after the fact.
- `OnAcceptanceMsg`/`OnResponseMsg` capture the Update object. Adjacent `probe.MessageApplied` has leased Mutable State, but the full observer has not merged these into a single proven semantic boundary.
- The normal control deliberately uses the first normal WFT; it does not satisfy the model's post-event-4 bootstrap and is not admitted into prefix replay.
- The one-node label `h1` denotes the in-process History host. This run does not exercise Cassandra or the two-host cache-alias hypothesis.

The supplied instrumentation handoff explicitly says: “If a genuinely unobserved concurrent mutation cannot be assigned to a point consistent with captured snapshots, stop and report the capture gap.” The raw evidence and incomplete status implement that boundary; no unconstrained silent actions or model-generated replacement states were introduced.

## Verification and reproduction

- `bash harness/run.sh` performs apply, build, all scenarios, trace audit and eight quick TLC prefix replays; expected final exit is 2 until complete replay is implemented.
- `evidence/run-command.json` records source, patch hash, compiler, environment and commands. `evidence/run.log` and `scenarios.log` preserve outputs.
- `evidence/replay-prefixes/*.provenance.json` binds each replay prefix to its raw file hash, exact raw lines and normalization offsets.
- `evidence/trace-validation-*.log` are real TLC results. Their success concerns only the bounded prefixes.
- `evidence/lint.log` records the required repository lint command. See `evidence/final-status.json` for its final exit.
- Apply/reapply/cleanup were verified on a clean pinned worktree without the prior phase's six untracked test files. They are hashed in `evidence/preserved-analysis-tests.json`.
- An initial scheduling attempt failed before injecting noncommit because the sticky poller was not registered. Its evidence is retained in `evidence/attempt-1/`. A poller-ready barrier fixes that harness race; the normal control waits for admission before polling its already-scheduled task. All final selected scenarios pass. No outer test/build timeout fired.

## Upstream refresh

The six requested discussions were refreshed via GitHub read APIs in `evidence/upstream-refresh.json`. [#5349](https://github.com/temporalio/temporal/pull/5349), [#5784](https://github.com/temporalio/temporal/pull/5784), and [#6308](https://github.com/temporalio/temporal/pull/6308) are merged historical changes concerning immediate effect application, registry clearing, and speculative timers. [#10478](https://github.com/temporalio/temporal/issues/10478), [#10775](https://github.com/temporalio/temporal/issues/10775), and [#11254](https://github.com/temporalio/temporal/pull/11254) remain open in this refresh. The first concerns stale ownership, the second assignment/logging differences, and the third concurrent Nexus Update callers. The selected tests neither establish nor close those reports.
