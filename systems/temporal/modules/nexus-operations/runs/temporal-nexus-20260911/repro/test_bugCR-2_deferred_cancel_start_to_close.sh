#!/usr/bin/env bash
set -euo pipefail

WORKTREE="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-nexus-20260911/temporal-nexus/.specula-output/confirmation/CR-2/worktree"
TEST_FILE="$WORKTREE/tests/cr2_deferred_cancel_start_to_close_repro_test.go"

cleanup() {
  rm -f "$TEST_FILE"
}
trap cleanup EXIT

cat > "$TEST_FILE" <<'GOEOF'
package tests

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/nexus-rpc/sdk-go/nexus"
	"github.com/stretchr/testify/require"
	commandpb "go.temporal.io/api/command/v1"
	commonpb "go.temporal.io/api/common/v1"
	enumspb "go.temporal.io/api/enums/v1"
	historypb "go.temporal.io/api/history/v1"
	taskqueuepb "go.temporal.io/api/taskqueue/v1"
	workflowservice "go.temporal.io/api/workflowservice/v1"
	"go.temporal.io/sdk/client"
	adminservice "go.temporal.io/server/api/adminservice/v1"
	persistencespb "go.temporal.io/server/api/persistence/v1"
	"go.temporal.io/server/chasm"
	chasmnexus "go.temporal.io/server/chasm/lib/nexusoperation"
	"go.temporal.io/server/common/dynamicconfig"
	"go.temporal.io/server/common/nexus/nexustest"
	"go.temporal.io/server/tests/testcore"
	"google.golang.org/protobuf/types/known/durationpb"
)

func TestBugCR2DeferredCancellationOmitsStartToCloseTimer(t *testing.T) {
	env := newNexusTestEnv(t, true,
		testcore.WithDynamicConfig(dynamicconfig.EnableChasm, false),
		testcore.WithDynamicConfig(dynamicconfig.EnableCHASMCallbacks, false),
		testcore.WithDynamicConfig(dynamicconfig.EnableCHASMSignalBacklinks, false),
		testcore.WithDynamicConfig(chasmnexus.EnableChasmWorkflowOperations, false),
		testcore.WithDynamicConfig(chasmnexus.ChasmWorkflowOperationsRolloutPercent, 0),
	)
	ctx := env.Context()
	taskQueue := testcore.RandomizeStr(t.Name())
	execution := &commonpb.WorkflowExecution{}

	canStartCh := make(chan struct{})
	cancelSentCh := make(chan struct{}, 1)
	h := nexustest.Handler{
		OnStartOperation: func(ctx context.Context, service, operation string, input *nexus.LazyValue, options nexus.StartOperationOptions) (nexus.HandlerStartOperationResult[any], error) {
			select {
			case <-canStartCh:
			case <-ctx.Done():
				return nil, ctx.Err()
			}
			return &nexus.HandlerStartOperationResultAsync{OperationToken: "cr2-token"}, nil
		},
		OnCancelOperation: func(ctx context.Context, service, operation, token string, options nexus.CancelOperationOptions) error {
			select {
			case cancelSentCh <- struct{}{}:
			default:
			}
			return nil
		},
	}
	endpointName := env.createRandomExternalNexusServer(ctx, t, h)

	run, err := env.SdkClient().ExecuteWorkflow(ctx, client.StartWorkflowOptions{
		TaskQueue:           taskQueue,
		WorkflowTaskTimeout: 30 * time.Second,
	}, "workflow")
	require.NoError(t, err)
	execution.WorkflowId = run.GetID()
	execution.RunId = run.GetRunID()
	defer func() {
		_ = env.SdkClient().TerminateWorkflow(testcore.NewContext(), run.GetID(), run.GetRunID(), "cr2 repro cleanup")
	}()

	firstTask := pollWorkflowTaskCR2(t, env, ctx, taskQueue)
	_, err = env.FrontendClient().RespondWorkflowTaskCompleted(ctx, &workflowservice.RespondWorkflowTaskCompletedRequest{
		Identity:  "cr2-repro",
		TaskToken: firstTask.TaskToken,
		Commands: []*commandpb.Command{
			{
				CommandType: enumspb.COMMAND_TYPE_SCHEDULE_NEXUS_OPERATION,
				Attributes: &commandpb.Command_ScheduleNexusOperationCommandAttributes{
					ScheduleNexusOperationCommandAttributes: &commandpb.ScheduleNexusOperationCommandAttributes{
						Endpoint:            endpointName,
						Service:             "service",
						Operation:           "operation",
						Input:               testcore.MustToPayload(t, "input"),
						StartToCloseTimeout: durationpb.New(4 * time.Second),
					},
				},
			},
			{
				CommandType: enumspb.COMMAND_TYPE_START_TIMER,
				Attributes: &commandpb.Command_StartTimerCommandAttributes{
					StartTimerCommandAttributes: &commandpb.StartTimerCommandAttributes{
						TimerId:            "force-second-workflow-task",
						StartToFireTimeout: durationpb.New(10 * time.Millisecond),
					},
				},
			},
		},
	})
	require.NoError(t, err)

	secondTask := pollWorkflowTaskCR2(t, env, ctx, taskQueue)
	scheduledEventID := findEventIDCR2(secondTask.History.Events, enumspb.EVENT_TYPE_NEXUS_OPERATION_SCHEDULED)
	require.Positive(t, scheduledEventID, "expected NexusOperationScheduled before cancellation")
	require.Equal(t, int64(0), findEventIDCR2(secondTask.History.Events, enumspb.EVENT_TYPE_NEXUS_OPERATION_STARTED), "start is still blocked, so cancellation is before Started")
	t.Logf("event_order_before_start=NexusOperationScheduled(%d), NexusOperationCancelRequested(next), NexusOperationStarted(blocked)", scheduledEventID)

	_, err = env.FrontendClient().RespondWorkflowTaskCompleted(ctx, &workflowservice.RespondWorkflowTaskCompletedRequest{
		Identity:  "cr2-repro",
		TaskToken: secondTask.TaskToken,
		Commands: []*commandpb.Command{
			{
				CommandType: enumspb.COMMAND_TYPE_REQUEST_CANCEL_NEXUS_OPERATION,
				Attributes: &commandpb.Command_RequestCancelNexusOperationCommandAttributes{
					RequestCancelNexusOperationCommandAttributes: &commandpb.RequestCancelNexusOperationCommandAttributes{
						ScheduledEventId: scheduledEventID,
					},
				},
			},
		},
	})
	require.NoError(t, err)

	require.Eventually(t, func() bool {
		desc, err := env.SdkClient().DescribeWorkflowExecution(ctx, run.GetID(), run.GetRunID())
		if err != nil || len(desc.PendingNexusOperations) != 1 || desc.PendingNexusOperations[0].CancellationInfo == nil {
			return false
		}
		return desc.PendingNexusOperations[0].ScheduledEventId == scheduledEventID
	}, 10*time.Second, 50*time.Millisecond, "cancel request should be durable before start is released")

	close(canStartCh)
	select {
	case <-cancelSentCh:
	case <-time.After(10 * time.Second):
		t.Fatal("cancel request was not transmitted after async Started")
	}

	require.Eventually(t, func() bool {
		desc, err := env.SdkClient().DescribeWorkflowExecution(ctx, run.GetID(), run.GetRunID())
		if err != nil || len(desc.PendingNexusOperations) != 1 {
			return false
		}
		op := desc.PendingNexusOperations[0]
		return op.State == enumspb.PENDING_NEXUS_OPERATION_STATE_STARTED &&
			op.CancellationInfo != nil &&
			op.CancellationInfo.State == enumspb.NEXUS_OPERATION_CANCELLATION_STATE_SUCCEEDED
	}, 10*time.Second, 50*time.Millisecond, "cancel request acknowledgement should leave operation STARTED")

	db := describeDBMutableStateCR2(t, env, ctx, execution)
	timers := db.GetExecutionInfo().GetStateMachineTimers()
	t.Logf("state_after_cancel_ack=STARTED cancellation=SUCCEEDED persisted_hsm_timer_groups=%d timer_types=%v", len(timers), stateMachineTimerTypesCR2(timers))
	require.Len(t, timers, 0, "bug triggered: no HSM timer group was persisted for StartToCloseTimeout after deferred cancellation")

	time.Sleep(5 * time.Second)
	hist := env.GetHistory(env.Namespace().String(), execution)
	require.Equal(t, int64(0), findEventIDCR2(hist, enumspb.EVENT_TYPE_NEXUS_OPERATION_TIMED_OUT), "ordinary execution did not emit the start-to-close timeout after the deadline")
	t.Logf("past_deadline_without_refresh=5s timeout_event_present=false workflow_status=%s", db.GetExecutionState().GetStatus())

	_, err = env.AdminClient().RefreshWorkflowTasks(ctx, &adminservice.RefreshWorkflowTasksRequest{
		NamespaceId: env.NamespaceID().String(),
		Execution:   execution,
	})
	require.NoError(t, err)

	var timeoutType enumspb.TimeoutType
	require.Eventually(t, func() bool {
		hist = env.GetHistory(env.Namespace().String(), execution)
		for _, event := range hist {
			if attrs := event.GetNexusOperationTimedOutEventAttributes(); attrs != nil {
				timeoutType = attrs.GetFailure().GetCause().GetTimeoutFailureInfo().GetTimeoutType()
				return timeoutType == enumspb.TIMEOUT_TYPE_START_TO_CLOSE
			}
		}
		return false
	}, 10*time.Second, 50*time.Millisecond, "explicit refresh should regenerate the missing StartToClose timer and let it fire")
	t.Logf("after_explicit_refresh_timeout_event_present=true timeout_type=%s", timeoutType.String())
}

func pollWorkflowTaskCR2(t *testing.T, env *NexusTestEnv, ctx context.Context, taskQueue string) *workflowservice.PollWorkflowTaskQueueResponse {
	t.Helper()
	resp, err := env.FrontendClient().PollWorkflowTaskQueue(ctx, &workflowservice.PollWorkflowTaskQueueRequest{
		Namespace: env.Namespace().String(),
		TaskQueue: &taskqueuepb.TaskQueue{
			Name: taskQueue,
			Kind: enumspb.TASK_QUEUE_KIND_NORMAL,
		},
		Identity: "cr2-repro",
	})
	require.NoError(t, err)
	require.NotEmpty(t, resp.TaskToken)
	return resp
}

func describeDBMutableStateCR2(t *testing.T, env *NexusTestEnv, ctx context.Context, execution *commonpb.WorkflowExecution) *persistencespb.WorkflowMutableState {
	t.Helper()
	resp, err := env.AdminClient().DescribeMutableState(ctx, &adminservice.DescribeMutableStateRequest{
		Namespace: env.Namespace().String(),
		Execution: execution,
		Archetype: chasm.WorkflowArchetype,
	})
	require.NoError(t, err)
	require.NotNil(t, resp.GetDatabaseMutableState())
	return resp.GetDatabaseMutableState()
}

func findEventIDCR2(events []*historypb.HistoryEvent, eventType enumspb.EventType) int64 {
	for _, event := range events {
		if event.GetEventType() == eventType {
			return event.GetEventId()
		}
	}
	return 0
}

func stateMachineTimerTypesCR2(groups []*persistencespb.StateMachineTimerGroup) []string {
	var out []string
	for _, group := range groups {
		for _, info := range group.GetInfos() {
			out = append(out, fmt.Sprintf("%s@%s", info.GetType(), group.GetDeadline().AsTime().Format(time.RFC3339Nano)))
		}
	}
	return out
}
GOEOF

cd "$WORKTREE"
timeout 10m go test -tags=test_dep ./tests -run TestBugCR2DeferredCancellationOmitsStartToCloseTimer -count=1 -v
