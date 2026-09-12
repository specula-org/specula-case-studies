# Verification summary

Working directory: `/home/ubuntu/temporal-investigation-20260909/parallel-20260911/source-nexus`. Pin: `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`. All outputs redirected to the linked files with `> PATH 2>&1`.

PASS in behavioral probes verifies the observed anomaly plus its control; it does not mean the system satisfies the disputed property. SQLite is memory/shared with real SQL transactions, and process stays alive across shard close. No TLC or persistence-fault experiment ran.

## hsm-unit-tests.jsonl

[Raw output](hsm-unit-tests.jsonl)

```sh
GOMAXPROCS=4 go test -tags test_dep -p 4 ./service/history/hsm/nexusoperations/... -count=1 -json
```

Named test/subtest/suite records: `{'pass': 153}`. Package result: `[{'Package': 'go.temporal.io/server/service/history/hsm/nexusoperations/workflow', 'Action': 'pass', 'Elapsed': 0.025}, {'Package': 'go.temporal.io/server/service/history/hsm/nexusoperations', 'Action': 'pass', 'Elapsed': 0.327}]`.

## hsm-functional-tests.jsonl

[Raw output](hsm-functional-tests.jsonl)

```sh
GOMAXPROCS=4 go test -tags test_dep -p 4 ./tests -run '^TestNexusWorkflowTestSuiteHSM$/(TestNexusOperationSyncCompletion|TestNexusOperationRetriesAfterHTTPFault|TestNexusOperationAsyncCompletion|TestNexusOperationAsyncCompletionBeforeStart|TestNexusOperationCancelBeforeStarted_CancelationEventuallyDelivered|TestNexusOperationScheduleToCloseTimeout|TestNexusOperationScheduleToStartTimeout|TestNexusOperationStartToCloseTimeout|TestNexusCallbackAfterCallerComplete)$' -count=1 -parallel=2 -timeout=15m -json -args -persistenceType=sql -persistenceDriver=sqlite
```

Named test/subtest/suite records: `{'pass': 10}`. Package result: `[{'Package': 'go.temporal.io/server/tests', 'Action': 'pass', 'Elapsed': 10.361}]`.

## nexus-api-tests.jsonl

[Raw output](nexus-api-tests.jsonl)

```sh
GOMAXPROCS=4 go test -tags test_dep -p 4 ./tests -run '^TestNexusApiTestSuiteWithTemporalFailures$/(TestNexusStartOperation_Outcomes|TestNexusCancelOperation_Outcomes)$' -count=1 -parallel=2 -timeout=5m -json -args -persistenceType=sql -persistenceDriver=sqlite
```

Named test/subtest/suite records: `{'pass': 28}`. Package result: `[{'Package': 'go.temporal.io/server/tests', 'Action': 'pass', 'Elapsed': 2.205}]`.

## max-timeout-probe-initial-shared-cluster.jsonl

[Raw output](max-timeout-probe-initial-shared-cluster.jsonl)

```sh
GOMAXPROCS=4 go test -tags test_dep -p 4 -overlay /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-nexus-20260911/temporal-nexus/.specula-output/analysis-evidence/max-timeout-overlay.json ./tests -run '^TestNexusWorkflowTestSuiteHSM$/TestSpeculaNexusMaxTimeoutOmitted$' -count=1 -parallel=1 -timeout=3m -json -args -persistenceType=sql -persistenceDriver=sqlite
```

Named test/subtest/suite records: `{'fail': 2}`. Package result: `[{'Package': 'go.temporal.io/server/tests', 'Action': 'fail', 'Elapsed': 3.141}]`.

```text
nexus_workflow_test.go:3655: ENDPOINT_ACCEPT request_id=d424206d-69b8-4d52-bc52-d5a4abbc0b9a
nexus_workflow_test.go:3655: ENDPOINT_ACCEPT request_id=61418f69-24ec-49fd-80eb-6d8c4c52bfb3
nexus_workflow_test.go:3681: HEALTHY_CONTROL requested=60s scheduled=3s terminal=TimedOut
```

## durable-probes.jsonl

[Raw output](durable-probes.jsonl)

```sh
GOMAXPROCS=4 go test -tags test_dep -p 4 -overlay /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-nexus-20260911/temporal-nexus/.specula-output/analysis-evidence/max-timeout-overlay.json ./tests -run '^TestNexusWorkflowTestSuiteHSM$/(TestSpeculaNexusMaxTimeoutOmitted|TestSpeculaPrestartCancelStartToClose)$' -count=1 -parallel=1 -timeout=3m -json -args -persistenceType=sql -persistenceDriver=sqlite
```

Named test/subtest/suite records: `{'pass': 1, 'fail': 2}`. Package result: `[{'Package': 'go.temporal.io/server/tests', 'Action': 'fail', 'Elapsed': 7.237}]`.

```text
nexus_workflow_test.go:3655: ENDPOINT_ACCEPT request_id=ed0f89f2-3eb7-44f8-ac1e-e85555a15847
nexus_workflow_test.go:3655: ENDPOINT_ACCEPT request_id=706eb238-d33d-4f41-b704-a2044c3735d4
nexus_workflow_test.go:3681: HEALTHY_CONTROL requested=60s scheduled=3s terminal=TimedOut
nexus_workflow_test.go:3705: POST_RELOAD_DB op_id=5 request_id=ed0f89f2-3eb7-44f8-ac1e-e85555a15847 token=ed0f89f2-3eb7-44f8-ac1e-e85555a15847 state=Started schedule_to_close=0s regenerated_tasks=0 buffered=0
nexus_workflow_test.go:3711: OBSERVED omitted=0 configured_max=3s persisted=0 survived_shard_close=true
nexus_workflow_test.go:3769: DURABLE_CANCEL_REQUEST_OBSERVED before_start_response=true
nexus_workflow_test.go:3729: ENDPOINT_ASYNC operation=prestart-cancel request_id=fb7d8756-b8ab-40bb-9aba-11ba73a37634
nexus_workflow_test.go:3733: ENDPOINT_CANCEL_ACK token=fb7d8756-b8ab-40bb-9aba-11ba73a37634 terminal_callback=false
nexus_workflow_test.go:3729: ENDPOINT_ASYNC operation=control request_id=beb7df36-c71c-49df-84c7-05b655f8f7ce
nexus_workflow_test.go:3778: HEALTHY_CONTROL no_prestart_cancel start_to_close=3s terminal=TimedOut
nexus_workflow_test.go:3795: DB_READ stage=past_deadline op_id=5 state=Started token=fb7d8756-b8ab-40bb-9aba-11ba73a37634 configured_stc=3s persisted_timer_groups=0 regenerated_tasks=1
nexus_workflow_test.go:3795: DB_READ stage=after_shard_close op_id=5 state=Started token=fb7d8756-b8ab-40bb-9aba-11ba73a37634 configured_stc=3s persisted_timer_groups=0 regenerated_tasks=1
```

## cancel-retention-probes.jsonl

[Raw output](cancel-retention-probes.jsonl)

```sh
GOMAXPROCS=4 go test -tags test_dep -p 4 -overlay /home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-nexus-20260911/temporal-nexus/.specula-output/analysis-evidence/max-timeout-overlay.json ./tests -run '^TestNexusWorkflowTestSuiteHSM$/(TestSpeculaPrestartCancelStartToClose|TestSpeculaTimedOutNodeConsumesCapacity)$' -count=1 -parallel=1 -timeout=3m -json -args -persistenceType=sql -persistenceDriver=sqlite
```

Named test/subtest/suite records: `{'pass': 3}`. Package result: `[{'Package': 'go.temporal.io/server/tests', 'Action': 'pass', 'Elapsed': 8.373}]`.

```text
nexus_workflow_test.go:3769: DURABLE_CANCEL_REQUEST_OBSERVED before_start_response=true
nexus_workflow_test.go:3729: ENDPOINT_ASYNC operation=prestart-cancel request_id=fcd26910-d3d5-4b12-9303-f7a1feb39e6d
nexus_workflow_test.go:3733: ENDPOINT_CANCEL_ACK token=fcd26910-d3d5-4b12-9303-f7a1feb39e6d terminal_callback=false
nexus_workflow_test.go:3729: ENDPOINT_ASYNC operation=control request_id=c5f7522e-919f-47d5-8a23-50a13c5270a9
nexus_workflow_test.go:3778: HEALTHY_CONTROL no_prestart_cancel start_to_close=3s terminal=TimedOut
nexus_workflow_test.go:3795: DB_READ stage=past_deadline op_id=5 state=Started token=fcd26910-d3d5-4b12-9303-f7a1feb39e6d configured_stc=3s persisted_timer_groups=0 regenerated_tasks=1
nexus_workflow_test.go:3795: DB_READ stage=after_shard_close op_id=5 state=Started token=fcd26910-d3d5-4b12-9303-f7a1feb39e6d configured_stc=3s persisted_timer_groups=0 regenerated_tasks=1
nexus_workflow_test.go:3807: HISTORY_ORDER cancel=11 started=12 cancel_ack=16
nexus_workflow_test.go:3816: EXPLICIT_TASK_REFRESH_COMPENSATED terminal=TimedOut
nexus_workflow_test.go:3853: HEALTHY_CONTROL max_pending=1 two_sequential_sync_operations=success terminal_nodes=0
nexus_workflow_test.go:3828: ENDPOINT_ASYNC_NO_COMPLETION request_id=e644bdb3-f56c-4fee-ac16-fa6f74d4edee
nexus_workflow_test.go:3882: POST_RELOAD_DB terminal_node=5 state=TimedOut request_id=e644bdb3-f56c-4fee-ac16-fa6f74d4edee describe_pending=0 next_schedule=PendingNexusOperationsLimitExceeded
nexus_workflow_test.go:3886: OBSERVED timeout_terminal_retained=true blocks_next_schedule=true survived_shard_close=true
```

## Harness corrections

- Initial max-timeout probe requested CloseShard on a shared test cluster; the test environment rejected that operation before it ran. Added WithDedicatedCluster, preserving the failed log.
- First combined probe passed B3 and established B1 database/timer facts, then failed because ContainsHistoryEvents requires a contiguous sequence and real WorkflowTask events intervene. Replaced that assertion with exact cancel < started < ACK event-ID comparisons. No production code or failure trigger changed.
- Final fixture is the original pinned test file plus three probe methods and the protobuf decoder import. The patch and individual method fragments preserve the small additions; the overlay substitutes only test source.
- B3 passed in durable-probes.jsonl despite that enclosing suite failure. The final B1/B2 run passed completely. No failed test aggregate is reported as a pass.
