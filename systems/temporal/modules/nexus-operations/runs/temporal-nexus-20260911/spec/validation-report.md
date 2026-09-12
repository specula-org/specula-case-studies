# temporal-nexus validation report

**INCOMPLETE — Phase 1 has not passed; the specification has not converged.** The complete semantic post-state join was not finished. The final installed run_trace_validation_parallel gate accepted **0/21 original recordings and 0/11 newly collected recordings**. Every file fails at input conversion before state replay; these failures are not Temporal invariant violations.

The validation-workflow requires all implementation traces to pass before Phase 2. Consequently **MC.cfg and the five hunting configs were not run in this phase**. Earlier generation/review checks belong to their recorded original spec hashes and are not evidence for the revised specification. The five boundary diagnostics below are small source-observation tests, not a substitute convergence run.

## Inputs and executed evidence

- Source HEAD: 0c010ce5fe8c0180aa7573c72fe8fc87c6df7025. The existing instrumentation manifest was checked against every listed source file before recollection. This phase changed the specification and validation artifacts; it did not change the Temporal implementation.
- Backend: real SQL/SQLite, mode=memory, cache=shared, one in-process test cluster with real frontend/history/matching. CHASM workflow operations=false, rollout=0; transition history=true; cancel-ACK events=true; outbound reader enabled; capacity=1; request timeout=10s and minimum=1.5s. The endpoint uses the configured real frontend HTTP callback URL. These tests cover database transactions, cache reload and shard reacquisition, not process/power-loss durability.
- [Initial input hashes](output/validation-20260911/input-manifest.json), [final spec hashes and validation status](output/validation-20260911/validation-summary.json), [exact spec diff](output/validation-20260911/spec-changes.diff).
- [11 fresh functional executions](output/validation-20260911/fresh-results.json): all tests exited 0 and all raw-observer audits passed. Fresh recordings and full logs remain under [fresh-traces](output/validation-20260911/fresh-traces/). Their binary SHA-256 is recorded with every command.
- [Joined independent receipts](output/validation-20260911/joined-summary.json): all 32 recordings were audited; write requests were joined to actual SQL/append receipts, readback IDs, durable HSM/timer/buffer snapshots and physical queue rows. This ledger deliberately does not claim a complete semantic post stream.
- [Nine observer negative controls](output/validation-20260911/evidence/negative-controls.json) rejected forged wire request ID, initial reference, persisted timer omission, queue/DB evidence mismatches, Accepted after definite noncommit, missing receipt, suffix and empty input. These are observer-audit controls; strict TLC negative-control coverage remains incomplete.
- SANY passed for base, MC and Trace with the correct combined tool/community classpath. The installed syntax handler initially omitted the community jar for IOUtils; that tooling error is separately preserved in initial-syntax.json.
- [Final strict replay logs](output/validation-20260911/final-replay/) retain every complete tool output and argument. The aggregate handler labels its 21/11 failures trace_mismatch, but the individual result is an input-decoding **error** (unsupported JSON null), before any model action executes.

## Source-backed specification corrections

Each correction is recorded in [changelog.md](changelog.md). No safety invariant was weakened, no full-state equality was removed and TraceMatched remains enabled.

| Correction | Independent observation and implementation evidence | Diagnostic result |
|---|---|---|
| Bootstrap WFT | All 21 bootstrap DB readbacks observe Started, rather than the original Idle. Init now starts at that explicit first-WFT boundary. | Original rejected; revised passed. |
| Event buffering | healthy_async receipt 53 has a bufferable Started event in memory while no WFT is Started. EventStore.Add buffers by event type; Finish flushes at close according to HasStartedWorkflowTask. AddEvents and close preparation now preserve those boundaries. | Original rejected; revised passed. |
| Timer batch | healthy_timeout receipts 77/80/81 show one timer before and after the inner timeout executor, then zero after the batch finishes. The source updates StateMachineTimers only after its loop. tx.consumed now tracks internal consumption; v.timers remains the actual list until Finish. | Original rejected; revised passed. |
| Full refresh | deferred_cancel's RefreshWorkflowTasks snapshot already contains the regenerated timer and scheduled wake. task_refresher.go generates and filters tasks before returning. The model now does so and retains wake output through later transaction preparation. | Original rejected; revised passed. |
| Definite pre-store failure | The controlled ResourceExhausted fault skips the store: no append or SQL receipt exists and readback remains one version behind the requested version. UpdateWorkflowExecution now permits that identified definite rejection from Prepared. | Original rejected; revised passed. |

[Boundary observations](output/validation-20260911/boundary-observations.json), [bootstrap observations](output/validation-20260911/bootstrap-observations.json), and [before/after results](output/validation-20260911/boundary-results.json) pin the evidence. These tests frame unrelated state synthetically and compare selected source-derived fields; they are explicitly **partial-state diagnostics**, not full implementation traces.

The timer diagnostic also used the installed debugger coarse → fine → evaluation workflow. The original action executes, but the next equality fails: the debugger observes one pre-state timer and zero post-state timers, while the real inner-executor snapshot still has one. See [coarse](output/validation-20260911/debug-timer-coarse.json), [fine](output/validation-20260911/debug-timer-fine.json), and [variable evaluation](output/validation-20260911/debug-timer-evaluate.json).

## Priority questions and retained observations

The following results are real functional executions/raw receipts and source review. None is a model-checking discovery or a formal trace reconfirmation in this phase.

| Question | Checked evidence/result | Remaining gap |
|---|---|---|
| Q1 completion before start/terminal overlap | Fresh healthy and early callbacks pass; early completion removes the operation before the late start save, which is rejected. Duplicate callback results and independent final DB/history readback are recorded. Original buffered-callback and sync Failed/Canceled recordings were re-audited. | Full semantic transaction/callback join, invalid-reference delivery schedules and composed timeout/cancel races. |
| Q2 remote acceptance versus lost response/local persistence | Fresh response_loss records acceptance, loss, another call with stable request identity and endpoint dedup. Start-result definite noncommit and ExecuteAndTimeout both execute, with actual post-reacquisition readback. | The endpoint's stable dedup/token retention is an explicit fixture contract; broader endpoint behavior and all failure compositions remain unchecked. |
| Q3 durable cancellation and ACK | Fresh deferred_cancel retains committed cancel intent before the async response, then ACK leaves the operation running. Past-STC and post-shard-close observations both show Started and no timer; explicit refresh restores the execution path to TimedOut. | This is runtime reconfirmation of source-discovered B1. RequiredTimerPublished and liveness have not been checked on a converged model. Cancel retry/refusal/below-min original recordings were re-audited, not recollected in this phase. |
| Q4 tasks, identity and recovery | Fresh ordinary timeout, explicit refresh and shard/cache reconstruction execute. The original retry/backoff and stale-timer recordings retain source receipts and pass observer audits. | Available-task ownership, deliberate duplicate deliveries, old-generation physical wakes and stale conditional writes still need schedules and a semantic join. |
| Q5 atomic local outcome and observation | Fresh callback definite failure is independently noncommitted, then a successful frontend/history retry masks that failure at the caller. ExecuteAndTimeout executes the underlying SQL write, returns an error, reacquires the shard and reads back the committed completion. | Workflow closure, late completion of uncertain writes, full notification/workflow-observation modeling and publication/ownership replay remain open. |

The fresh **B2** capacity path leaves a TimedOut operation node in DB, rejects another schedule at capacity=1, and retains the node after shard close. The fresh sync_capacity control completes two sequential operations and leaves no operation node. This independently reconfirms the source observation; it is not an MC-first discovery. See the joined fresh-deferred_cancel, fresh-timeout_capacity and fresh-sync_capacity ledgers under [joined-evidence](output/validation-20260911/joined-evidence/).

B3 and TV/CR observations remain in the modeling brief/analysis handoff; this phase makes no new confirmation or novelty claim for them. A narrow upstream web search was refreshed; it did not establish novelty. The current official [Nexus documentation](https://github.com/temporalio/documentation/blob/main/docs/encyclopedia/nexus/nexus-operations.mdx) describes the start-to-close timeout contract, and the [Go feature guide](https://github.com/temporalio/documentation/blob/main/docs/develop/go/nexus/feature-guide.mdx) distinguishes cancellation requests from the operation's terminal result. The pinned source remains the model's ground truth.

## Work still required for convergence

1. Complete the observation-derived semantic join: immutable identity aliases, call/callback ordinals, every state field, independent component receipts, physical task publication plus local delivery/ack ownership, and transaction-return boundaries. Raw physical queue rows include acknowledged tasks and cannot simply be renamed queue. No model-generated post values were substituted.
2. Align WFT completion, subsequent commands and close preparation in one real transaction. The current base still treats CompleteWorkflowTask as a separate transaction; a raw event-name rename cannot fix this. Include frontend-to-history callback retries within the actual caller observation.
3. Resolve the numeric/time abstraction. Exact affine integer conversion of the sampled HSM times plus configured durations already exceeds TLC's int32 range in **19/32 recordings**; some require 10,000,000,000 as a single duration. The join records the GCD proof rather than rounding observations. Additional time samples can only tighten this constraint. Preserve deadline/minimum-budget comparisons and actual retry jitter through a justified representation.
4. Separate logical timer deadlines from physical wake visibility. For example, original healthy_timeout records a logical deadline ending .503616333 and a persisted physical wake ending .504. shard/task_key_generator.go:76-96 rounds/advances physical visibility, while queues.IsTimeExpired compares millisecond-truncated times. The current single at field and equality-based handoff need a source-backed correction; ordinary rounding in a join would hide this distinction.
5. Repair the previously reviewed RequestDeadlineExceeded action: it still lacks a stored deadline/elapsed-time guard, while response_loss is an immediate transport error. Model these different events and adjust justified hunt time horizons without shrinking fault bounds. The deferred progress/fairness and workflow-notification obligations also remain incomplete.
6. Revalidate every complete implementation trace and the required TLC negative controls. Only then run MC.cfg for the prescribed duration, classify any counterexamples, return to traces after spec changes and complete convergence. Run the five unchanged-bound hunting configs with the required BFS/simulation strategy after convergence.

## Reproduction and process status

From spec/output/validation-20260911:

- Run the installed-handler gate with: timeout 5m /home/ubuntu/Specula/.venv/bin/python validate_all.py. Its expected current exit is 2, explicitly INCOMPLETE.
- Run boundary diagnostics with: timeout 5m /home/ubuntu/Specula/.venv/bin/python check_boundaries.py.
- Run raw receipt joins/observer negatives with: timeout 60 python3 join_evidence.py (system Python supports nanosecond RFC3339 parsing used by the audit).
- recollect.py preserves input traces and reuses its already recorded successful executions; fresh-results.json contains the exact underlying binary commands.

The first fresh test passed but its audit was initially run under Python 3.10, whose ISO timestamp parser rejected an eight-digit fraction. The same recording was re-audited under system Python, and the remaining schedules executed there. The test was not rerun to hide a failure; the initial result is retained in fresh-results-python310-audit-error.json. The debugger used a dedicated port. All launched processes were observed through completion.

