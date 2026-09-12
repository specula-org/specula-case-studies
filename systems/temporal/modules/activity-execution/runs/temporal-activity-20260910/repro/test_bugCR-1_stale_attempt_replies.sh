#!/usr/bin/env bash
set -euo pipefail

SOURCE_REPO=${SOURCE_REPO:-/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-activity-20260910/temporal-activity/.specula-output/confirmation/CR-1/worktree}
TEST_FILE="$SOURCE_REPO/tests/cr1_stale_attempt_replies_test.go"

cleanup() {
  rm -f "$TEST_FILE"
}
trap cleanup EXIT

cat > "$TEST_FILE" <<'GO_TEST'
package tests

import (
	"context"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	commandpb "go.temporal.io/api/command/v1"
	commonpb "go.temporal.io/api/common/v1"
	enumspb "go.temporal.io/api/enums/v1"
	failurepb "go.temporal.io/api/failure/v1"
	"go.temporal.io/api/serviceerror"
	taskqueuepb "go.temporal.io/api/taskqueue/v1"
	"go.temporal.io/api/workflowservice/v1"
	"go.temporal.io/server/common/payloads"
	"go.temporal.io/server/tests/testcore"
	"google.golang.org/grpc/codes"
	"google.golang.org/protobuf/types/known/durationpb"
)

func TestCR1WorkflowActivityStaleAttemptRepliesAreRejected(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()

	env := testcore.NewEnv(t)
	client := env.FrontendClient()
	namespace := env.Namespace().String()
	tv := env.Tv()
	identity := tv.WorkerIdentity()
	activityID := "cr1-activity"
	activityType := "cr1-activity-type"

	startResp, err := client.StartWorkflowExecution(ctx, &workflowservice.StartWorkflowExecutionRequest{
		RequestId:           uuid.NewString(),
		Namespace:           namespace,
		WorkflowId:          tv.WorkflowID(),
		WorkflowType:        tv.WorkflowType(),
		TaskQueue:           tv.TaskQueue(),
		WorkflowRunTimeout:  durationpb.New(time.Minute),
		WorkflowTaskTimeout: durationpb.New(5 * time.Second),
		Identity:            identity,
	})
	require.NoError(t, err)
	t.Logf("started workflow runID=%s", startResp.GetRunId())

	workflowTask, err := client.PollWorkflowTaskQueue(ctx, &workflowservice.PollWorkflowTaskQueueRequest{
		Namespace: namespace,
		TaskQueue: tv.TaskQueue(),
		Identity:  identity,
	})
	require.NoError(t, err)
	require.NotEmpty(t, workflowTask.GetTaskToken())

	_, err = client.RespondWorkflowTaskCompleted(ctx, &workflowservice.RespondWorkflowTaskCompletedRequest{
		Namespace: namespace,
		TaskToken: workflowTask.GetTaskToken(),
		Identity:  identity,
		Commands: []*commandpb.Command{{
			CommandType: enumspb.COMMAND_TYPE_SCHEDULE_ACTIVITY_TASK,
			Attributes: &commandpb.Command_ScheduleActivityTaskCommandAttributes{
				ScheduleActivityTaskCommandAttributes: &commandpb.ScheduleActivityTaskCommandAttributes{
					ActivityId:             activityID,
					ActivityType:           &commonpb.ActivityType{Name: activityType},
					TaskQueue:              tv.TaskQueue(),
					Input:                  payloads.EncodeString("attempt-identity"),
					ScheduleToCloseTimeout: durationpb.New(30 * time.Second),
					ScheduleToStartTimeout: durationpb.New(10 * time.Second),
					StartToCloseTimeout:    durationpb.New(10 * time.Second),
					HeartbeatTimeout:       durationpb.New(10 * time.Second),
					RetryPolicy: &commonpb.RetryPolicy{
						InitialInterval:    durationpb.New(100 * time.Millisecond),
						MaximumInterval:    durationpb.New(100 * time.Millisecond),
						BackoffCoefficient: 1,
						MaximumAttempts:    3,
					},
				},
			},
		}},
	})
	require.NoError(t, err)
	t.Log("scheduled retryable workflow activity")

	attempt1, err := pollActivity(ctx, client, namespace, tv.TaskQueue(), identity)
	require.NoError(t, err)
	require.EqualValues(t, 1, attempt1.GetAttempt())
	require.NotEmpty(t, attempt1.GetTaskToken())
	t.Logf("polled attempt=%d tokenLen=%d", attempt1.GetAttempt(), len(attempt1.GetTaskToken()))

	_, err = client.RespondActivityTaskFailed(ctx, &workflowservice.RespondActivityTaskFailedRequest{
		Namespace: namespace,
		TaskToken: attempt1.GetTaskToken(),
		Identity:  identity,
		Failure: &failurepb.Failure{
			Message: "retryable failure from attempt 1",
			FailureInfo: &failurepb.Failure_ApplicationFailureInfo{
				ApplicationFailureInfo: &failurepb.ApplicationFailureInfo{
					NonRetryable:   false,
					NextRetryDelay: durationpb.New(100 * time.Millisecond),
				},
			},
		},
	})
	require.NoError(t, err)
	t.Log("failed attempt 1 retryably")

	attempt2, err := pollActivity(ctx, client, namespace, tv.TaskQueue(), identity)
	require.NoError(t, err)
	require.EqualValues(t, 2, attempt2.GetAttempt())
	require.NotEmpty(t, attempt2.GetTaskToken())
	t.Logf("polled retry attempt=%d tokenLen=%d", attempt2.GetAttempt(), len(attempt2.GetTaskToken()))

	assertNotFound(t, "heartbeat with stale attempt-1 token", func() error {
		_, err := client.RecordActivityTaskHeartbeat(ctx, &workflowservice.RecordActivityTaskHeartbeatRequest{
			Namespace: namespace,
			TaskToken: attempt1.GetTaskToken(),
			Identity:  identity,
			Details:   payloads.EncodeString("late-heartbeat"),
		})
		return err
	})
	assertNotFound(t, "duplicate failure with stale attempt-1 token", func() error {
		_, err := client.RespondActivityTaskFailed(ctx, &workflowservice.RespondActivityTaskFailedRequest{
			Namespace: namespace,
			TaskToken: attempt1.GetTaskToken(),
			Identity:  identity,
			Failure: &failurepb.Failure{
				Message: "late failure from attempt 1",
				FailureInfo: &failurepb.Failure_ApplicationFailureInfo{
					ApplicationFailureInfo: &failurepb.ApplicationFailureInfo{NonRetryable: false},
				},
			},
		})
		return err
	})
	assertNotFound(t, "completion with stale attempt-1 token", func() error {
		_, err := client.RespondActivityTaskCompleted(ctx, &workflowservice.RespondActivityTaskCompletedRequest{
			Namespace: namespace,
			TaskToken: attempt1.GetTaskToken(),
			Identity:  identity,
			Result:    payloads.EncodeString("late-completion"),
		})
		return err
	})

	describeResp, err := client.DescribeWorkflowExecution(ctx, &workflowservice.DescribeWorkflowExecutionRequest{
		Namespace: namespace,
		Execution: &commonpb.WorkflowExecution{
			WorkflowId: tv.WorkflowID(),
			RunId:      startResp.GetRunId(),
		},
	})
	require.NoError(t, err)
	require.Len(t, describeResp.GetPendingActivities(), 1)
	require.Equal(t, activityID, describeResp.GetPendingActivities()[0].GetActivityId())
	require.EqualValues(t, 2, describeResp.GetPendingActivities()[0].GetAttempt())
	t.Logf("pending activity after stale replies: activityID=%s attempt=%d",
		describeResp.GetPendingActivities()[0].GetActivityId(),
		describeResp.GetPendingActivities()[0].GetAttempt())

	_, err = client.RespondActivityTaskCompleted(ctx, &workflowservice.RespondActivityTaskCompletedRequest{
		Namespace: namespace,
		TaskToken: attempt2.GetTaskToken(),
		Identity:  identity,
		Result:    payloads.EncodeString("attempt-2-completion"),
	})
	require.NoError(t, err)
	t.Log("completed attempt 2 successfully")

	finalWorkflowTask, err := client.PollWorkflowTaskQueue(ctx, &workflowservice.PollWorkflowTaskQueueRequest{
		Namespace: namespace,
		TaskQueue: tv.TaskQueue(),
		Identity:  identity,
	})
	require.NoError(t, err)
	require.NotEmpty(t, finalWorkflowTask.GetTaskToken())

	_, err = client.RespondWorkflowTaskCompleted(ctx, &workflowservice.RespondWorkflowTaskCompletedRequest{
		Namespace: namespace,
		TaskToken: finalWorkflowTask.GetTaskToken(),
		Identity:  identity,
		Commands: []*commandpb.Command{{
			CommandType: enumspb.COMMAND_TYPE_COMPLETE_WORKFLOW_EXECUTION,
			Attributes: &commandpb.Command_CompleteWorkflowExecutionCommandAttributes{
				CompleteWorkflowExecutionCommandAttributes: &commandpb.CompleteWorkflowExecutionCommandAttributes{
					Result: payloads.EncodeString("done"),
				},
			},
		}},
	})
	require.NoError(t, err)
	t.Log("workflow completed after valid attempt-2 completion")
}

func pollActivity(
	ctx context.Context,
	client workflowservice.WorkflowServiceClient,
	namespace string,
	taskQueue *taskqueuepb.TaskQueue,
	identity string,
) (*workflowservice.PollActivityTaskQueueResponse, error) {
	for {
		resp, err := client.PollActivityTaskQueue(ctx, &workflowservice.PollActivityTaskQueueRequest{
			Namespace: namespace,
			TaskQueue: taskQueue,
			Identity:  identity,
		})
		if err != nil {
			return nil, err
		}
		if len(resp.GetTaskToken()) != 0 {
			return resp, nil
		}
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
	}
}

func assertNotFound(t *testing.T, label string, call func() error) {
	t.Helper()
	err := call()
	require.Error(t, err, label)
	status := serviceerror.ToStatus(err)
	require.Equal(t, codes.NotFound, status.Code(), "%s: %v", label, err)
	t.Logf("%s rejected as %s: %s", label, status.Code(), status.Message())
}
GO_TEST

echo "Running: go test -count=1 -tags test_dep ./tests -run TestCR1WorkflowActivityStaleAttemptRepliesAreRejected -timeout 2m -v"
cd "$SOURCE_REPO"
go test -count=1 -tags test_dep ./tests -run TestCR1WorkflowActivityStaleAttemptRepliesAreRejected -timeout 2m -v
