# CR-1 Investigation

## Finding

- Source: Code Review
- Revision checked: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`
- Primary location: `service/history/hsm/nexusoperations/completion.go:218`
- Repro artifact: `.specula-output/repro/test_bugCR-1_lost_start_response.sh`
- Novelty: NEW. I searched upstream issues and PRs for the same Nexus lost-start-response / RequestID / callback-token mechanism and found no exact report or recent merged fix. Local recent merged PR history showed Nexus logging, dispatch classification, callback source header, completion-token conversion, and namespace fixes, but no fix for stale async operation-token completion after retry.

## Source path

`HandleScheduleCommand` generates a `RequestId` for each scheduled Nexus operation and stores it in the scheduled history event. `AddChild` copies that request ID into durable HSM operation state (`statemachine.go:45-60`).

The invocation executor constructs the callback token with the same request ID (`executors.go:213-219`) and sends `StartOperationOptions{RequestID: args.requestID}` to the endpoint (`executors.go:262-269`). The outbound call and the local save cross a failure boundary: after the call returns, `saveResult` performs a separate `env.Access(..., AccessWrite, ...)` commit (`executors.go:416-457`). If the call is reported as timed out or canceled, the executor treats it as retryable and moves the operation to `BACKING_OFF` (`executors.go:531-582`); no started event is persisted.

On retry, the same operation request ID is reused. If the endpoint accepts the retry as a distinct async operation and returns a different operation token, `saveStartedResult` persists only the later token in `NEXUS_OPERATION_STARTED` (`executors.go:459-488`; `statemachine.go:364-400`).

The completion handler correctly rejects completions with the wrong request ID (`completion.go:218-221`), and it fabricates a started event when completion arrives before the start response (`completion.go:123-165`). However, after an operation is already started, `fabricateStartedEventIfMissing` returns without checking the supplied `operationToken` (`completion.go:139-142`), and `Handle` then records success/failure based only on the request ID (`completion.go:215-227`). I found no comparison between the callback's operation token and `operation.OperationToken` before terminal history is recorded.

The workflow SDK consumes the resulting `NEXUS_OPERATION_COMPLETED` history event by scheduled event ID and passes the event payload to the waiting completion callback (`internal_event_handlers.go:2048-2087` in SDK v1.48.0), so the recorded terminal payload is caller-visible.

## Developer intent / contract notes

The Nexus SDK exposes `StartOperationOptions.RequestID` as a value that may be used by the server handler to dedupe a start request (`github.com/nexus-rpc/sdk-go@v0.7.0/nexus/options.go:22-24`). Temporal's workflow-backed Nexus examples say workflow IDs must be deterministic because a request to start an operation may be retried (`go.temporal.io/sdk@v1.48.0/temporalnexus/example_test.go:40-42`). This makes duplicate start delivery reachable and expected under lost responses; exactly-once remote side effects depend on endpoint idempotency. The local Temporal-side issue reproduced here is narrower: once Temporal has persisted operation token `token-2`, it still accepts a callback carrying stale `token-1` so long as the request ID matches.

Existing tests cover async start persistence, transient start errors, callback-before-start fabrication, and wrong-request-ID rejection, but I found no test combining lost accepted start response, retry with the same request ID, a different async token, and late stale-token completion.

## Prior-report search

Commands run:

```text
gh search issues --repo temporalio/temporal 'Nexus RequestId duplicate StartOperation' --state open --limit 10
gh search issues --repo temporalio/temporal 'Nexus RequestId duplicate StartOperation' --state closed --limit 10
gh search issues --repo temporalio/temporal 'Nexus lost start response callback operation token' --state open --limit 10
gh search issues --repo temporalio/temporal 'Nexus lost start response callback operation token' --state closed --limit 10
gh search prs --repo temporalio/temporal 'Nexus RequestId duplicate StartOperation' --state open --limit 10
gh search prs --repo temporalio/temporal 'Nexus RequestId duplicate StartOperation' --state closed --limit 10
gh search prs --repo temporalio/temporal 'Nexus callback before start request id' --state open --limit 10
gh search prs --repo temporalio/temporal 'Nexus callback before start request id' --state closed --limit 10
git log --since='2026-06-01' --oneline --decorate -- service/history/hsm/nexusoperations service/frontend/nexus_completion_http_handler.go service/frontend/nexus_handler.go service/matching | rg -i 'nexus|request|idempot|callback|operation token|completion|retry'
```

Issue and PR searches returned no matching reports. Recent local PR history returned:

```text
0c010ce5f (HEAD, origin/main, origin/HEAD, main) Make Nexus callback source header opt-in (#11965)
30e8ba922 Refactor Nexus dispatch result classification (#11852)
bde624efd Tag Nexus logs by lifecycle stage (#11757)
5aa7a471d Make Nexus log messages aggregatable (#11765)
15f3532ea Add Worker Deployment and BuildID labels to (workflow,activity) task completion metrics (#11348)
2f3cbadee Tag Nexus completion request logs (#11684)
2c48aa571 Annotate Nexus spans (#11561)
f1c8590f6 Add Nexus operation context to handler-side logs (#11663)
63321f08b Un-skip CHASM Nexus workflow tests and fixes (error rehydration & caller-closed completion) (#11139)
6ca52b9be Add idempotency tests for repeated ShutdownWorker/CancelOutstandingWorkerPolls calls (#9818)
dc5b517e8 Ignore versioning attributes in poll request on worker command task queue (#11227)
a813c6193 Convert Nexus completion tokens across HSM and CHASM (#11035)
d3049eb97 Add task queue kind to NexusTask token (#11022)
5a69d7667 Fix Nexus failure conversion data race (#10821)
e594a8f0f Fixed reading of Nexus namespace ID (#10550)
```

No entry matches the stale completion-token acceptance mechanism.

## Reproduction

The repro script writes a temporary Go test into `service/history/hsm/nexusoperations`, runs it, and removes the temporary file on exit. It uses a real `nexustest.NewNexusServer` endpoint and the production `nexusrpc.HTTPClient`/HSM executor path. The first HTTP caller lets the endpoint accept async start `token-1`, then returns `context.DeadlineExceeded` to simulate a lost accepted response. Temporal moves the local operation to `BACKING_OFF` without a started event. Backoff reschedules the operation; retry sends the same request ID and the endpoint returns `token-2`, which Temporal persists. The control completion with a wrong request ID is rejected. A completion with the original request ID but stale `token-1` is accepted and records a terminal success payload.

Executed command:

```text
/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-nexus-20260911/temporal-nexus/.specula-output/repro/test_bugCR-1_lost_start_response.sh
```

Output:

```text
CR-1 repro source revision: 0c010ce5fe8c0180aa7573c72fe8fc87c6df7025
CR-1 repro command: timeout 10m go test -count=1 -run TestCR1LostAcceptedStartResponseAcceptsStaleDuplicateCompletion ./service/history/hsm/nexusoperations -v
=== RUN   TestCR1LostAcceptedStartResponseAcceptsStaleDuplicateCompletion
    cr1_lost_start_response_test.go:57: endpoint accepted StartOperation request_id=d6d09770-7524-4a43-87bb-497b16b58e62 operation_token=token-1
    cr1_lost_start_response_test.go:154: Temporal treated the accepted first response as lost and moved to BACKING_OFF request_id=d6d09770-7524-4a43-87bb-497b16b58e62
    cr1_lost_start_response_test.go:57: endpoint accepted StartOperation request_id=d6d09770-7524-4a43-87bb-497b16b58e62 operation_token=token-2
    cr1_lost_start_response_test.go:180: retry persisted local STARTED with request_id=d6d09770-7524-4a43-87bb-497b16b58e62 operation_token=token-2
    cr1_lost_start_response_test.go:200: control rejected mismatched completion request_id=wrong-d6d09770-7524-4a43-87bb-497b16b58e62 operation_token=token-1
    cr1_lost_start_response_test.go:221: completion accepted request_id=d6d09770-7524-4a43-87bb-497b16b58e62 callback_operation_token=token-1 while persisted_operation_token=token-2 result=completed-by-token-1
--- PASS: TestCR1LostAcceptedStartResponseAcceptsStaleDuplicateCompletion (0.01s)
PASS
ok  	go.temporal.io/server/service/history/hsm/nexusoperations	0.034s
```

## Decision

The behavior is reproduced under a reachable lost-response retry schedule and a real Nexus endpoint that accepts duplicate starts for the same request ID. The wrong terminal result is caller-visible through workflow history and the SDK completion callback path. The finding should be reported as reproduced, with the caveat that avoiding duplicate remote side effects still depends on endpoint idempotency; Temporal should additionally reject or ignore callbacks whose operation token conflicts with the locally persisted async token.
