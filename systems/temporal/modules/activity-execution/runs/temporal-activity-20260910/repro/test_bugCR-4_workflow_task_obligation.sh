#!/usr/bin/env bash
set -euo pipefail

SOURCE_REPO="${SOURCE_REPO:-/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/confirmation/CR-4/worktree}"
RAW_LOG="${RAW_LOG:-/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/confirmation/CR-4/repro_bugCR-4_workflow_task_obligation.raw.log}"
TEST_FILE="$SOURCE_REPO/tests/bugcr4_workflow_task_obligation_test.go"

cleanup() {
  rm -f "$TEST_FILE"
}
trap cleanup EXIT

if [[ -e "$TEST_FILE" ]]; then
  echo "refusing to overwrite existing $TEST_FILE" >&2
  exit 2
fi

cat >"$TEST_FILE" <<'GOEOF'
package tests

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	commandpb "go.temporal.io/api/command/v1"
	commonpb "go.temporal.io/api/common/v1"
	enumspb "go.temporal.io/api/enums/v1"
	failurepb "go.temporal.io/api/failure/v1"
	historypb "go.temporal.io/api/history/v1"
	taskqueuepb "go.temporal.io/api/taskqueue/v1"
	"go.temporal.io/api/workflowservice/v1"
	"go.temporal.io/server/common/dynamicconfig"
	"go.temporal.io/server/common/payloads"
	"go.temporal.io/server/common/tasktoken"
	"go.temporal.io/server/common/testing/await"
	"go.temporal.io/server/tests/testcore"
	"google.golang.org/protobuf/types/known/durationpb"
)

func TestBugCR4WorkflowTaskObligation(t *testing.T) {
	for _, tc := range []struct {
		name string
		kind string
		want enumspb.EventType
	}{
		{name: "Level0CancelThenCompletion", kind: "complete", want: enumspb.EVENT_TYPE_ACTIVITY_TASK_COMPLETED},
		{name: "Level0CancelThenFailure", kind: "fail", want: enumspb.EVENT_TYPE_ACTIVITY_TASK_FAILED},
		{name: "Level0CancelThenCancelAck", kind: "cancel", want: enumspb.EVENT_TYPE_ACTIVITY_TASK_CANCELED},
		{name: "Level0CancelThenStartToCloseTimeout", kind: "timeout", want: enumspb.EVENT_TYPE_ACTIVITY_TASK_TIMED_OUT},
	} {
		t.Run(tc.name, func(t *testing.T) {
			runBugCR4WorkflowTaskObligation(t, tc.kind, tc.want)
		})
	}
}

func runBugCR4WorkflowTaskObligation(t *testing.T, kind string, want enumspb.EventType) {
	t.Helper()

	env := testcore.NewEnv(t,
		testcore.WithHistoryShardCount(1),
		testcore.WithDynamicConfig(dynamicconfig.EnableCancelActivityWorkerCommand, false),
		testcore.WithDynamicConfig(dynamicconfig.TimerProcessorUpdateAckInterval, 50*time.Millisecond),
		testcore.WithDynamicConfig(dynamicconfig.TransferProcessorUpdateAckInterval, 50*time.Millisecond),
		testcore.WithDynamicConfig(dynamicconfig.MatchingNumTaskqueueReadPartitions, 1),
		testcore.WithDynamicConfig(dynamicconfig.MatchingNumTaskqueueWritePartitions, 1),
	)

	ctx, cancel := context.WithTimeout(context.Background(), 80*time.Second)
	defer cancel()

	client := env.FrontendClient()
	identity := "bugcr4-worker"
	workflowID := "bugcr4-" + kind + "-" + uuid.NewString()
	taskQueue := &taskqueuepb.TaskQueue{Name: workflowID, Kind: enumspb.TASK_QUEUE_KIND_NORMAL}
	startToClose := 20 * time.Second
	if kind == "timeout" {
		startToClose = 1500 * time.Millisecond
	}

	startResp, err := client.StartWorkflowExecution(ctx, &workflowservice.StartWorkflowExecutionRequest{
		Namespace:           env.Namespace().String(),
		WorkflowId:          workflowID,
		RequestId:           uuid.NewString(),
		WorkflowType:        &commonpb.WorkflowType{Name: "bugcr4"},
		TaskQueue:           taskQueue,
		WorkflowRunTimeout:  durationpb.New(60 * time.Second),
		WorkflowTaskTimeout: durationpb.New(20 * time.Second),
		Identity:            identity,
	})
	require.NoError(t, err)
	execution := &commonpb.WorkflowExecution{WorkflowId: workflowID, RunId: startResp.GetRunId()}

	pollWFT := func(label string) *workflowservice.PollWorkflowTaskQueueResponse {
		t.Helper()
		deadline := time.Now().Add(15 * time.Second)
		for {
			pollCtx, pollCancel := context.WithTimeout(ctx, 5*time.Second)
			resp, err := client.PollWorkflowTaskQueue(pollCtx, &workflowservice.PollWorkflowTaskQueueRequest{
				Namespace: env.Namespace().String(),
				TaskQueue: taskQueue,
				Identity:  identity,
			})
			pollCancel()
			require.NoError(t, err, "poll workflow task %s", label)
			if len(resp.GetTaskToken()) != 0 {
				return resp
			}
			if time.Now().After(deadline) {
				t.Fatalf("timed out polling workflow task %s", label)
			}
		}
	}

	pollActivity := func() *workflowservice.PollActivityTaskQueueResponse {
		t.Helper()
		deadline := time.Now().Add(15 * time.Second)
		for {
			pollCtx, pollCancel := context.WithTimeout(ctx, 5*time.Second)
			resp, err := client.PollActivityTaskQueue(pollCtx, &workflowservice.PollActivityTaskQueueRequest{
				Namespace: env.Namespace().String(),
				TaskQueue: taskQueue,
				Identity:  identity,
			})
			pollCancel()
			require.NoError(t, err)
			if len(resp.GetTaskToken()) != 0 {
				return resp
			}
			if time.Now().After(deadline) {
				t.Fatal("timed out polling activity task")
			}
		}
	}

	completeWFT := func(task *workflowservice.PollWorkflowTaskQueueResponse, commands []*commandpb.Command) {
		t.Helper()
		_, err := client.RespondWorkflowTaskCompleted(ctx, &workflowservice.RespondWorkflowTaskCompletedRequest{
			Namespace: env.Namespace().String(),
			TaskToken: task.GetTaskToken(),
			Identity:  identity,
			Commands:  commands,
		})
		require.NoError(t, err)
	}

	signalWorkflow := func(name string) {
		t.Helper()
		_, err := client.SignalWorkflowExecution(ctx, &workflowservice.SignalWorkflowExecutionRequest{
			Namespace: env.Namespace().String(),
			WorkflowExecution: &commonpb.WorkflowExecution{
				WorkflowId: workflowID,
				RunId:      startResp.GetRunId(),
			},
			SignalName: name,
			RequestId:  uuid.NewString(),
			Identity:   identity,
		})
		require.NoError(t, err)
	}

	first := pollWFT("first")
	completeWFT(first, []*commandpb.Command{{
		CommandType: enumspb.COMMAND_TYPE_SCHEDULE_ACTIVITY_TASK,
		Attributes: &commandpb.Command_ScheduleActivityTaskCommandAttributes{
			ScheduleActivityTaskCommandAttributes: &commandpb.ScheduleActivityTaskCommandAttributes{
				ActivityId:             "act",
				ActivityType:           &commonpb.ActivityType{Name: "bugcr4-activity"},
				TaskQueue:              taskQueue,
				ScheduleToCloseTimeout: durationpb.New(30 * time.Second),
				StartToCloseTimeout:    durationpb.New(startToClose),
				RetryPolicy: &commonpb.RetryPolicy{
					InitialInterval:    durationpb.New(time.Second),
					BackoffCoefficient: 1,
					MaximumInterval:    durationpb.New(time.Second),
					MaximumAttempts:    1,
				},
			},
		},
	}})

	activity := pollActivity()
	token, err := tasktoken.NewSerializer().Deserialize(activity.GetTaskToken())
	require.NoError(t, err)
	require.Equal(t, workflowID, token.WorkflowId)
	require.Equal(t, startResp.GetRunId(), token.RunId)
	scheduledEventID := token.GetScheduledEventId()
	require.NotZero(t, scheduledEventID)

	signalWorkflow("cancel-activity")
	cancelWFT := pollWFT("cancel request")
	completeWFT(cancelWFT, []*commandpb.Command{{
		CommandType: enumspb.COMMAND_TYPE_REQUEST_CANCEL_ACTIVITY_TASK,
		Attributes: &commandpb.Command_RequestCancelActivityTaskCommandAttributes{
			RequestCancelActivityTaskCommandAttributes: &commandpb.RequestCancelActivityTaskCommandAttributes{
				ScheduledEventId: scheduledEventID,
			},
		},
	}})

	heartbeatResp, err := client.RecordActivityTaskHeartbeat(ctx, &workflowservice.RecordActivityTaskHeartbeatRequest{
		Namespace: env.Namespace().String(),
		TaskToken: activity.GetTaskToken(),
		Identity:  identity,
		Details:   payloads.EncodeString("cancel-observed"),
	})
	require.NoError(t, err)
	require.True(t, heartbeatResp.GetCancelRequested(), "worker must observe the cancel request before the terminal outcome")

	signalWorkflow("hold-wft-before-terminal")
	heldWFT := pollWFT("held before terminal")
	require.NotEmpty(t, heldWFT.GetTaskToken())

	switch kind {
	case "complete":
		_, err = client.RespondActivityTaskCompleted(ctx, &workflowservice.RespondActivityTaskCompletedRequest{
			Namespace: env.Namespace().String(),
			TaskToken: activity.GetTaskToken(),
			Identity:  identity,
			Result:    payloads.EncodeString("result"),
		})
		require.NoError(t, err)
	case "fail":
		_, err = client.RespondActivityTaskFailed(ctx, &workflowservice.RespondActivityTaskFailedRequest{
			Namespace: env.Namespace().String(),
			TaskToken: activity.GetTaskToken(),
			Identity:  identity,
			Failure: &failurepb.Failure{
				Message: "terminal failure after cancellation request",
				FailureInfo: &failurepb.Failure_ApplicationFailureInfo{
					ApplicationFailureInfo: &failurepb.ApplicationFailureInfo{Type: "bugcr4"},
				},
			},
		})
		require.NoError(t, err)
	case "cancel":
		_, err = client.RespondActivityTaskCanceled(ctx, &workflowservice.RespondActivityTaskCanceledRequest{
			Namespace: env.Namespace().String(),
			TaskToken: activity.GetTaskToken(),
			Identity:  identity,
			Details:   payloads.EncodeString("canceled"),
		})
		require.NoError(t, err)
	case "timeout":
		await.RequireTrue(t, func() bool {
			resp, err := client.DescribeWorkflowExecution(ctx, &workflowservice.DescribeWorkflowExecutionRequest{
				Namespace: env.Namespace().String(),
				Execution: execution,
			})
			return err == nil && len(resp.GetPendingActivities()) == 0
		}, 25*time.Second, 20*time.Millisecond)
	default:
		t.Fatalf("unsupported terminal kind %s", kind)
	}

	await.RequireTrue(t, func() bool {
		resp, err := client.DescribeWorkflowExecution(ctx, &workflowservice.DescribeWorkflowExecutionRequest{
			Namespace: env.Namespace().String(),
			Execution: execution,
		})
		return err == nil && len(resp.GetPendingActivities()) == 0
	}, 15*time.Second, 20*time.Millisecond)

	completeWFT(heldWFT, nil)
	finalWFT := pollWFT("post-terminal")
	terminalEventID, followingScheduledID := terminalEventAndFollowingWFT(t, finalWFT.GetHistory().GetEvents(), want)
	fmt.Printf("CR4: post-terminal workflow task delivered kind=%s terminalEventID=%d followingWorkflowTaskScheduledID=%d\n", kind, terminalEventID, followingScheduledID)

	completeWFT(finalWFT, []*commandpb.Command{{
		CommandType: enumspb.COMMAND_TYPE_COMPLETE_WORKFLOW_EXECUTION,
		Attributes: &commandpb.Command_CompleteWorkflowExecutionCommandAttributes{
			CompleteWorkflowExecutionCommandAttributes: &commandpb.CompleteWorkflowExecutionCommandAttributes{
				Result: payloads.EncodeString("terminal consumed"),
			},
		},
	}})

	history := getFullHistoryForBugCR4(t, ctx, client, env.Namespace().String(), execution)
	require.NotZero(t, findEventIDForBugCR4(history, enumspb.EVENT_TYPE_WORKFLOW_EXECUTION_COMPLETED), "workflow must close after consuming terminal outcome")
	fmt.Printf("CR4: workflow closed after consuming terminal outcome kind=%s\n", kind)
}

func terminalEventAndFollowingWFT(t *testing.T, events []*historypb.HistoryEvent, terminalType enumspb.EventType) (int64, int64) {
	t.Helper()
	var terminalID int64
	var scheduledID int64
	for _, event := range events {
		if event.GetEventType() == terminalType {
			terminalID = event.GetEventId()
		}
		if terminalID != 0 && event.GetEventType() == enumspb.EVENT_TYPE_WORKFLOW_TASK_SCHEDULED && event.GetEventId() > terminalID {
			scheduledID = event.GetEventId()
			break
		}
	}
	require.NotZero(t, terminalID, "post-terminal workflow task must deliver terminal activity event %s", terminalType)
	require.NotZero(t, scheduledID, "terminal activity event must be followed by the workflow task that delivered it")
	return terminalID, scheduledID
}

func getFullHistoryForBugCR4(t *testing.T, ctx context.Context, client workflowservice.WorkflowServiceClient, namespace string, execution *commonpb.WorkflowExecution) []*historypb.HistoryEvent {
	t.Helper()
	var events []*historypb.HistoryEvent
	var next []byte
	for {
		resp, err := client.GetWorkflowExecutionHistory(ctx, &workflowservice.GetWorkflowExecutionHistoryRequest{
			Namespace:     namespace,
			Execution:     execution,
			NextPageToken: next,
		})
		require.NoError(t, err)
		events = append(events, resp.GetHistory().GetEvents()...)
		next = resp.GetNextPageToken()
		if len(next) == 0 {
			return events
		}
	}
}

func findEventIDForBugCR4(events []*historypb.HistoryEvent, eventType enumspb.EventType) int64 {
	for _, event := range events {
		if event.GetEventType() == eventType {
			return event.GetEventId()
		}
	}
	return 0
}
GOEOF

gofmt -w "$TEST_FILE"
mkdir -p "$(dirname "$RAW_LOG")"

set +e
(
  cd "$SOURCE_REPO"
  timeout 10m go test -tags=test_dep -v ./tests -run '^TestBugCR4WorkflowTaskObligation$' -count=1 -timeout=3m
) >"$RAW_LOG" 2>&1
status=$?
set -e

grep -E 'CR4:|--- PASS|--- FAIL|^PASS$|^FAIL$|^ok[[:space:]]|^FAIL[[:space:]]' "$RAW_LOG" || true
echo "raw_log=$RAW_LOG"
exit "$status"
