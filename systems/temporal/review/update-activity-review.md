# Temporal masked Update/Activity review

Review target:

- Temporal source pin: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`.
- Upstream `main` refreshed by read-only fetch: `9ab3a9f770da20df7d94bcc0030f28eec7b0b947`.
- Disposable clone used for tests: `/home/ubuntu/temporal-investigation-20260909/review-20260912-044622/agents/update-activity-masked/source-temporal`.
- Original Specula outputs and original dirty worktrees were read only. All new logs are under `/home/ubuntu/temporal-investigation-20260909/review-20260912-044622/agents/update-activity-masked/logs/`.

Upstream refresh:

- `git ls-remote`/fetch confirmed upstream `main` at `9ab3a9f770da20df7d94bcc0030f28eec7b0b947`; see `logs/09-upstream-refresh.txt` and `logs/12-heads.txt`.
- Diff/log across the involved pinned paths was empty for `0c010ce5f..9ab3a9f77`; see `logs/14-main-diff-stat-involved-paths.txt` and `logs/15-main-log-involved-paths.txt`.
- PR intent refresh:
  - PR #6295, merged 2024-07-22, intentionally clears sticky task queue on speculative WFT completion error.
  - PR #6308, merged 2024-07-19, fixed a prior speculative WFT timeout executor/context-clear issue.
  - PR #5869, merged 2024-05-07, introduced `ExecuteAndTimeout`, explicitly modeling "operation executed but caller receives timeout".
  - PR #11203, merged 2026-07-23, concerns activity retry projection behavior and does not change the CR-5 recorder/product boundary.
  - Raw PR output is in `logs/45-gh-pr-refresh.jsonl`.

## CR-2A: stale speculative WFT completion cleanup clears replacement sticky state

Verdict: **MASKED engine behavior, not a confirmed product correctness bug**.

The behavior is real. In `RespondWorkflowTaskCompleted`, a stale completion fails the task identity check and returns `Workflow task not found`, but the deferred speculative-error cleanup still calls `clearStickyTaskQueue` when the current task looked speculative and sticky at lease acquisition. The relevant pinned code is in `logs/47-code-line-excerpts.txt`: the cleanup is at `api.go:167-198`, while identity rejection is at `api.go:203-212`.

The focused test was rerun in the disposable clone:

```bash
cd /home/ubuntu/temporal-investigation-20260909/review-20260912-044622/agents/update-activity-masked/source-temporal
timeout 10m env PATH=/usr/local/go/bin:$PATH GOTOOLCHAIN=go1.27.0 GOMAXPROCS=8 /usr/local/go/bin/go test -p 4 -tags=test_dep ./tests -run '^TestWorkflowUpdateSuite$/^TestAnalysisStaleCompletionReplacementSticky$' -count=1 -v
```

Result: pass. The sticky subcase logged:

- `OBSERVED: stale completion rejected; live sticky replacement completion also rejected`
- `RECOVERY: original Update caller received the expected successful result`

Full log: `logs/33-update-cr2a-stale-completion-suite-go-test.log`; parsed summary: `logs/34-update-cr2a-suite-summary.txt`.

The normal task-queue control completed the live replacement after rejecting the stale completion. The sticky case required one more readmission/retry on the normal task queue, and the public Update caller still received the expected success result. I do not see evidence of lost Update outcome, wrong completion, or an externally promised contract violation.

Axes:

| Axis | Rating | Reason |
|---|---:|---|
| Real-world reachability | Medium | Requires a stale speculative completion racing with a replacement sticky task; the public API path is reachable, but it is a timing/cache/stickiness edge. |
| Impact | Low | Extra rejection/retry/latency; the rerun proves public Update recovery. |
| Confidence | High | Reproduced through Temporal testcore/public API path with both control and sticky cases. |
| Maintainer fix likelihood | Medium | A narrow cleanup-identity guard would be understandable, but current behavior is mostly an efficiency/retry issue because final outcome recovered. |

## CR-2B: stale speculative timer affects replacement normal WFT

Verdict: **NEEDS MORE INFO as a production Update defect; reproduced as an executor-level guard gap**.

The component behavior is real. The active timer executor checks pointer identity with `CheckSpeculativeWorkflowTaskTimeoutTask` only while the current workflow task is still speculative. If the replacement has converted to a normal workflow task, execution falls through to version/attempt checks; those can match the stale timer. The relevant pinned code is in `logs/47-code-line-excerpts.txt`: speculative pointer check at `timer_queue_active_task_executor.go:418-425`, normal branch attempt/version checks at `timer_queue_active_task_executor.go:427-437`, and pointer identity implementation at `mutable_state_impl.go:7478-7482`.

The focused test was rerun in the disposable clone:

```bash
cd /home/ubuntu/temporal-investigation-20260909/review-20260912-044622/agents/update-activity-masked/source-temporal
timeout 10m env PATH=/usr/local/go/bin:$PATH GOTOOLCHAIN=go1.27.0 GOMAXPROCS=8 /usr/local/go/bin/go test -p 4 -tags=test_dep ./service/history -run '^TestAnalysisTimerReplacement$' -count=1 -v
```

Result: pass. The speculative-control subcase returned `workflow task not found`; the converted-normal subcase logged:

- `OLD_EXECUTOR_RESULT error=<nil>`
- `PREMATURE_TIMEOUT_EVENT ... replacement_deadline=...`
- `AFTER_OLD_TIMER normal=true pending_attempt=1 pending_started=0`

Full log: `logs/35-update-cr2b-timer-go-test.log`; parsed summary: `logs/36-update-cr2b-timer-summary.txt`.

This proves a stale in-memory timer task can time out the replacement after conversion to normal, before the replacement deadline. It does not prove a client-visible Update failure, data loss, or the same kind of final public recovery/mask that CR-2A proved. The test is a meaningful executor/state reproduction, but it stops at an intermediate premature timeout event. I would not keep this as a fully confirmed product bug without either a public/integration trace that reaches this state naturally or a follow-up proof that the premature timeout is harmlessly retried.

Axes:

| Axis | Rating | Reason |
|---|---:|---|
| Real-world reachability | Medium | Requires an old speculative timeout task to have entered execution before cancellation while the replacement converts to normal; plausible scheduler race, but not yet shown end to end. |
| Impact | Medium | If reached, it prematurely times out a valid WFT and may add retry/latency; no wrong final Update outcome was shown. |
| Confidence | Medium | High confidence in the component gap; medium confidence in product significance because final consumer behavior is unproven. |
| Maintainer fix likelihood | Medium | Temporal maintainers have fixed speculative timer identity issues before; this still needs a stronger production-facing reproducer to be compelling. |

## CR-5: `HistoryTaskRecorder` omits committed tasks on `ExecuteAndTimeout`

Verdict:

- **Temporal product defect: FALSE POSITIVE.**
- **Specula/test-observer issue: reproduced and masked.**

`HistoryTaskRecorder` is under `tests/testcore`, not production server code. It wraps a persistence `ExecutionManager` for tests and records task writes only when the delegate returns `nil`. The pinned source says "Only record if successful" for `AddHistoryTasks`, `UpdateWorkflowExecution`, and `CreateWorkflowExecution`; see `logs/47-code-line-excerpts.txt`, especially `tests/testcore/history_task_recorder.go:83-113`.

`ExecuteAndTimeout` explicitly models the ambiguous persistence case where the operation executes and then returns a timeout. The pinned source is in `logs/39-cr5-fault-source-excerpt.txt`: `fault.go:42-47` sets `execOp=true`, and `fault.go:61-71` executes the delegate before returning the timeout.

I reran the narrow recorder diagnostic in the disposable clone using the recovered test body from the original CR-5 repro script:

```bash
cd /home/ubuntu/temporal-investigation-20260909/review-20260912-044622/agents/update-activity-masked/source-temporal
timeout 10m env PATH=/usr/local/go/bin:$PATH GOTOOLCHAIN=go1.27.0 GOMAXPROCS=8 /usr/local/go/bin/go test -p 4 ./tests/testcore -run '^TestBugCR5HistoryTaskRecorderDropsCommittedTimeoutTasksReview$' -count=1 -v
```

Result: pass. It logged:

- `CR5_RECORDER_GAP reachable_precondition=ExecuteAndTimeout request_transfer_tasks=1 delegate_error=*persistence.TimeoutError recorder_transfer_tasks=0`

Full log: `logs/43-cr5-recorder-go-test.log`; parsed summary: `logs/44-cr5-recorder-summary.txt`.

The original CR-5 run also showed the trace-level mask: committed-timeout path reached `delegateExecuted=true`, and the Specula activity trace recorded `modelTraceComplete=false`/incomplete evidence instead of treating the recorder-only view as complete. The relevant retained evidence is excerpted in `logs/38-cr5-recorder-log-and-source.txt`.

This is not a Temporal product defect because the affected consumer is a test recorder, not the production engine. A Temporal product user is not promised that `tests/testcore.HistoryTaskRecorder` is a complete oracle under ambiguous persistence errors. The issue matters for Specula/test observation because a recorder-only trace can miss committed tasks; the current Specula harness masks that by using independent SQL/admin/public readbacks and marking the trace incomplete.

Axes:

| Axis | Rating | Reason |
|---|---:|---|
| Real-world reachability | Low | Low for Temporal product users; high only inside tests/Specula setups that enable `HistoryTaskRecorder` and inject `ExecuteAndTimeout`. |
| Impact | Low | No production engine impact shown. Observer impact is medium if someone treats recorder output as complete proof. |
| Confidence | High | Source and focused test agree; boundary is clearly `tests/testcore`. |
| Maintainer fix likelihood | Low | This is a test-observer semantics issue, and current Specula traces already mask it. A comment or recorder enhancement could still be useful for test authors. |

## Exact evidence files

- Original evidence excerpts: `logs/03-original-evidence-excerpts.txt`.
- Reused/generated test material index: `logs/24-test-material-index.txt`, `logs/42-cr5-repro-script-from-run-root.txt`.
- Pinned source excerpts: `logs/47-code-line-excerpts.txt`, `logs/39-cr5-fault-source-excerpt.txt`.
- Upstream/PR refresh: `logs/09-upstream-refresh.txt`, `logs/12-heads.txt`, `logs/14-main-diff-stat-involved-paths.txt`, `logs/15-main-log-involved-paths.txt`, `logs/45-gh-pr-refresh.jsonl`.
- CR-2A rerun: `logs/33-update-cr2a-stale-completion-suite-go-test.log`, `logs/34-update-cr2a-suite-summary.txt`.
- CR-2B rerun: `logs/35-update-cr2b-timer-go-test.log`, `logs/36-update-cr2b-timer-summary.txt`.
- CR-5 rerun: `logs/43-cr5-recorder-go-test.log`, `logs/44-cr5-recorder-summary.txt`.

