# CR-3 Investigation

## Scope

- Source: code review finding CR-3, not an MC counterexample.
- Target repo: `/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-reset-20260909-restart-1600/temporal-reset/.specula-output/confirmation/CR-3/worktree`
- Git HEAD: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`
- Worktree state at investigation time: dirty with pre-existing reset tracing and analysis test files; no source files were edited for this confirmation.

## Code Audit

- Public reset path: `service/history/api/resetworkflow/api.go:92` resolves the current run after the explicit base-run lease. `service/history/api/resetworkflow/api.go:100` tolerates `NotFound` only when the request includes an explicit base run ID. If tolerated, `service/history/api/resetworkflow/api.go:110` leaves `currentWorkflowLease` nil.
- Missing-current persistence path: `service/history/ndc/workflow_resetter.go:388` treats nil current as the missing-current case. The comment at `service/history/ndc/workflow_resetter.go:390` says base->reset and new-current cannot be committed atomically in this path; `service/history/ndc/workflow_resetter.go:403` writes the base mutation with `UpdateWorkflowModeBypassCurrent`, then `service/history/ndc/workflow_resetter.go:420` creates the reset run as brand-new current.
- SQL guard: `common/persistence/sql/execution.go:106` locks the current-executions row if present. For `CreateWorkflowModeBrandNew`, `common/persistence/sql/execution.go:118` permits creation only when there is no current row or it matches `PreviousRunID`; otherwise `common/persistence/sql/execution.go:123` returns `CurrentWorkflowConditionFailedError`. This rejects a stale missing-current create after a competing Start inserts a current row.
- Retry conversion: `service/history/handler.go:2293` converts `CurrentWorkflowConditionFailedError` to `serviceerror.Unavailable`; `common/rpc/interceptor/retry.go:42` retries retryable unary handler failures. On retry, reset re-runs from the public handler and re-resolves current.
- Ordinary current-present reset behavior: if the retry sees the competitor as current, the resetter takes a real current lease and the ordinary reset path terminates the running current before creating the reset run. This is the established Reset behavior, not a write that overwrites current without checking it.

## Reachability

Reachable with normal public operations plus timing assistance:

1. Start workflow run A.
2. Continue/complete into a later current run, then delete that current run through `DeleteWorkflowExecution`, leaving older run A addressable by run ID but no current-executions row.
3. Issue `ResetWorkflowExecution` against run A by explicit run ID.
4. Pause the reset's reset-run create after the base link is written.
5. Issue `StartWorkflowExecution` for the same workflow ID through the frontend; it succeeds because current is missing.
6. Release reset create. The SQL current-row check observes the newly inserted current row and causes the reset attempt to retry.
7. The retry resolves the competing start as current and runs the ordinary Reset path, terminating that current run and installing the reset run.

No direct database edit is needed for the precondition; the missing-current state is built through Start/complete/delete public APIs. The timing point is test-hook assisted.

## Developer Knowledge And Known Status

- Git history shows PR `#10926` / commit `44de0057368a4f5c6bb2e36f7b5c8edf16301ff8` introduced the missing-current path. The PR body says Reset tolerates missing current only with explicit `runId`, persists the reset run as the new current via `CreateWorkflowModeBrandNew`, and writes base-first because the base link and new current cannot be committed atomically. It fixes issue `#10690`, where reset failed with `workflow not found` after the current run was deleted.
- Issue `#10690` reports the older, fixed behavior: reset by older explicit run ID failed when current was deleted. It does not report a competing Start/Reset race or the retry replacing a competing current operation.
- Searches run against Temporal's GitHub tracker and PRs:
  - `gh search issues --repo temporalio/temporal --state open/closed '"workflow reset" "current execution" deleted runId'`
  - `gh search prs --repo temporalio/temporal --state open/closed '"workflow reset" "current execution" deleted runId'`
  - `gh search issues/prs --repo temporalio/temporal --state open/closed 'reset workflow competing start current execution race'`
  - `gh search issues/prs --repo temporalio/temporal --state open/closed '"reset" "competing" "StartWorkflowExecution"'`
  - `gh search prs --repo temporalio/temporal --state closed --merged-at '>=2026-09-01' 'reset workflow current execution'`
  - `gh search prs --repo temporalio/temporal --state closed --merged-at '>=2026-07-15' '"CreateWorkflowModeBrandNew"'`
- Result: no public issue or merged/closed PR was found for this exact competing-current mechanism. The only related exact-site report is `#10690`/`#10926`, which is not this mechanism.

## Reproduction Preflight

- Direct `go test ./tests -run 'TestWorkflowResetSuite/TestAnalysisMissingCurrentRecovery/competing-start$' -count=1 -v -timeout 30s` failed during build with `disk quota exceeded` while writing Go work package archives.
- Space/provenance check: `/home/ubuntu/.cache/go-build` was 47G; `.specula-output/evidence` and `.specula-output/harness/build` contained prebuilt Temporal test binaries. `go version -m` on `.specula-output/harness/build/reset-trace.test` reported `go1.27.0` and package `go.temporal.io/server/tests.test`.
- Reused binary: `.specula-output/harness/build/reset-trace.test` with scenario `RESET_TRACE_SCENARIO=competing-start`.

## Reproduction Findings

- The trace run reached the CR-3 interleaving and emitted a fresh raw trace. The underlying trace test exits nonzero because `rec.Close()` tries to snapshot after the sqlite test database has been dropped and returns `unable to open database file`; the CR-3 checkpoints are still present.
- Captured evidence from the fresh run:
  - Base link was written before competitor start: `checkpoint=base-written`.
  - Competing start committed through the frontend: `checkpoint=start-committed`.
  - Reset returned a run ID in the same public Reset call after retry: `scenario=competing-start ... first=<resetRun> final=<resetRun> faults=1 finalStatus=Completed`.
  - JSON checkpoint `competing-start-ordered-replacement`: competitor status was `TERMINATED(5)`, reset run status was `RUNNING(1)`.
  - JSON checkpoint `healthy-worker-completion`: reset run later reached `COMPLETED(2)` with `faults=1`.

## Consequence Assessment

The alleged stale missing-current create is guarded by the SQL current-row condition. When a competing Start wins the gap, the reset create does not blindly overwrite it; it fails as a current-workflow condition failure and is retried. The successful retry is ordered after the competing Start and performs the ordinary, documented Reset effect of terminating the current run and making the reset run current. The Start caller observes a valid run that is later terminated by a concurrent Reset, which is a permitted outcome for overlapping operations. The Reset caller observes a valid reset run that remains current and can complete. No public caller was shown to observe an impossible successful run ID, an overwritten unrelated current row, or an unrecoverable durable state.
