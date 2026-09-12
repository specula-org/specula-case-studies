#!/usr/bin/env bash
set -euo pipefail

REPO="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-update-20260909-restart-1600/temporal-update/.specula-output/confirmation/CR-3/worktree"
TMP_TEST="$REPO/tests/cr3_repro_external_test.go"
LOG_DIR="${TMPDIR:-/home/ubuntu/tmp}/cr3-repro-logs"
LOG="$LOG_DIR/test_bugCR-3_mixed_outcomes.log"

mkdir -p "$LOG_DIR"
rm -f "$TMP_TEST"
trap 'rm -f "$TMP_TEST"' EXIT

cat > "$TMP_TEST" <<'GOEOF'
package tests

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	commandpb "go.temporal.io/api/command/v1"
	enumspb "go.temporal.io/api/enums/v1"
	failurepb "go.temporal.io/api/failure/v1"
	historypb "go.temporal.io/api/history/v1"
	protocolpb "go.temporal.io/api/protocol/v1"
	updatepb "go.temporal.io/api/update/v1"
	workflowservice "go.temporal.io/api/workflowservice/v1"
	"go.temporal.io/server/chasm"
	"go.temporal.io/server/common/config"
	"go.temporal.io/server/common/dynamicconfig"
	"go.temporal.io/server/common/persistence"
	"go.temporal.io/server/common/testing/protoutils"
	"go.temporal.io/server/common/testing/testvars"
	"go.temporal.io/server/tests/testcore"
)

func TestCR3MixedUpdateBatchResponseLink(t *testing.T) {
	env := testcore.NewEnv(t)
	base := env.Tv().WithRunID(mustStartWorkflow(env, env.Tv()))
	tvSuccess := base.WithUpdateIDNumber(1).WithMessageIDNumber(1)
	tvFailure := base.WithUpdateIDNumber(2).WithMessageIDNumber(2)
	tvRejected := base.WithUpdateIDNumber(3).WithMessageIDNumber(3)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	successCh := sendUpdate(ctx, env, tvSuccess)
	failureCh := sendUpdate(ctx, env, tvFailure)
	rejectedCh := sendUpdate(ctx, env, tvRejected)

	_, err := env.TaskPoller().PollAndHandleWorkflowTask(base, func(task *workflowservice.PollWorkflowTaskQueueResponse) (*workflowservice.RespondWorkflowTaskCompletedRequest, error) {
		require.Len(t, task.Messages, 3)

		successMsg := cr3MessageByUpdateID(t, task.Messages, tvSuccess)
		failureMsg := cr3MessageByUpdateID(t, task.Messages, tvFailure)
		rejectedMsg := cr3MessageByUpdateID(t, task.Messages, tvRejected)

		failureMessages := env.UpdateAcceptCompleteMessages(tvFailure, failureMsg)
		failureResponse := protoutils.UnmarshalAny[*updatepb.Response](t, failureMessages[1].Body)
		failureResponse.Outcome = &updatepb.Outcome{
			Value: &updatepb.Outcome_Failure{
				Failure: &failurepb.Failure{
					Message: "accepted handler failed",
					FailureInfo: &failurepb.Failure_ApplicationFailureInfo{
						ApplicationFailureInfo: &failurepb.ApplicationFailureInfo{Type: "CR3AcceptedHandlerFailure"},
					},
				},
			},
		}
		failureMessages[1].Body = protoutils.MarshalAny(t, failureResponse)

		commands := append([]*commandpb.Command{}, env.UpdateAcceptCompleteCommands(tvSuccess)...)
		commands = append(commands, env.UpdateAcceptCompleteCommands(tvFailure)...)
		commands = append(commands, cr3CompleteWorkflowCommand())

		messages := append([]*protocolpb.Message{}, env.UpdateAcceptCompleteMessages(tvSuccess, successMsg)...)
		messages = append(messages, failureMessages...)
		messages = append(messages, env.UpdateRejectMessages(tvRejected, rejectedMsg)...)

		return &workflowservice.RespondWorkflowTaskCompletedRequest{
			Commands: commands,
			Messages: messages,
			Identity: base.WorkerIdentity(),
		}, nil
	})
	require.NoError(t, err)

	success := cr3TakeUpdateResult(t, ctx, successCh)
	failure := cr3TakeUpdateResult(t, ctx, failureCh)
	rejected := cr3TakeUpdateResult(t, ctx, rejectedCh)

	require.NoError(t, success.err)
	require.Equal(t, enumspb.UPDATE_WORKFLOW_EXECUTION_LIFECYCLE_STAGE_COMPLETED, success.response.GetStage())
	require.NotNil(t, success.response.GetOutcome().GetSuccess())
	require.NotNil(t, success.response.GetLink().GetWorkflowEvent())

	require.NoError(t, failure.err)
	require.Equal(t, enumspb.UPDATE_WORKFLOW_EXECUTION_LIFECYCLE_STAGE_COMPLETED, failure.response.GetStage())
	require.Equal(t, "accepted handler failed", failure.response.GetOutcome().GetFailure().GetMessage())
	require.Nil(t, failure.response.GetLink().GetWorkflowEvent())
	require.Equal(t, "Update rejected", failure.response.GetLink().GetWorkflow().GetReason())

	require.NoError(t, rejected.err)
	require.Equal(t, enumspb.UPDATE_WORKFLOW_EXECUTION_LIFECYCLE_STAGE_COMPLETED, rejected.response.GetStage())
	require.Equal(t, "rejection-of-"+tvRejected.UpdateID(), rejected.response.GetOutcome().GetFailure().GetMessage())
	require.Equal(t, "Update rejected", rejected.response.GetLink().GetWorkflow().GetReason())

	historyEvents := env.GetHistory(env.Namespace().String(), base.WorkflowExecution())
	var acceptedIDs, completedIDs []*historypb.HistoryEvent
	workflowClosed := false
	for _, event := range historyEvents {
		switch event.GetEventType() {
		case enumspb.EVENT_TYPE_WORKFLOW_EXECUTION_UPDATE_ACCEPTED:
			acceptedIDs = append(acceptedIDs, event)
		case enumspb.EVENT_TYPE_WORKFLOW_EXECUTION_UPDATE_COMPLETED:
			completedIDs = append(completedIDs, event)
		case enumspb.EVENT_TYPE_WORKFLOW_EXECUTION_COMPLETED:
			workflowClosed = true
		}
	}
	require.Len(t, acceptedIDs, 2)
	require.Len(t, completedIDs, 2)
	require.Equal(t, tvFailure.UpdateID(), acceptedIDs[1].GetWorkflowExecutionUpdateAcceptedEventAttributes().GetAcceptedRequest().GetMeta().GetUpdateId())
	require.Equal(t, int64(acceptedIDs[1].EventId), completedIDs[1].GetWorkflowExecutionUpdateCompletedEventAttributes().GetAcceptedEventId())

	t.Logf("CR3_REPRO_LEVEL0 mixed_batch success_stage=%s success_link_workflow_event=%t accepted_failure_stage=%s accepted_failure_message=%q accepted_failure_link_workflow_event=%t accepted_failure_link_workflow_reason=%q rejected_stage=%s rejected_link_reason=%q accepted_event_count=%d completed_event_count=%d workflow_closed=%t",
		success.response.GetStage(),
		success.response.GetLink().GetWorkflowEvent() != nil,
		failure.response.GetStage(),
		failure.response.GetOutcome().GetFailure().GetMessage(),
		failure.response.GetLink().GetWorkflowEvent() != nil,
		failure.response.GetLink().GetWorkflow().GetReason(),
		rejected.response.GetStage(),
		rejected.response.GetLink().GetWorkflow().GetReason(),
		len(acceptedIDs),
		len(completedIDs),
		workflowClosed,
	)
}

func TestCR3FailedCloseWriteConflictingOutcome(t *testing.T) {
	var injected atomic.Bool
	faultInjection := &config.FaultInjection{
		Injector: func(target config.FaultInjectionTarget) error {
			request, ok := target.Request.(*persistence.InternalUpdateWorkflowExecutionRequest)
			if ok &&
				target.Store == config.ExecutionStoreName &&
				target.Method == "UpdateWorkflowExecution" &&
				request.UpdateWorkflowMutation.ExecutionState.GetStatus() == enumspb.WORKFLOW_EXECUTION_STATUS_TERMINATED &&
				injected.CompareAndSwap(false, true) {
				return &persistence.TimeoutError{Msg: "cr3: termination write did not execute"}
			}
			return nil
		},
	}
	env := testcore.NewEnv(t,
		testcore.WithHistoryShardCount(1),
		testcore.WithPersistenceFaultInjection(faultInjection),
	)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	tv := env.Tv().WithRunID(mustStartWorkflow(env, env.Tv()))
	resultCh := sendUpdate(ctx, env, tv)

	poll := func() *workflowservice.PollWorkflowTaskQueueResponse {
		task, err := env.FrontendClient().PollWorkflowTaskQueue(ctx, &workflowservice.PollWorkflowTaskQueueRequest{
			Namespace: env.Namespace().String(),
			TaskQueue: tv.TaskQueue(),
			Identity:  tv.WorkerIdentity(),
		})
		require.NoError(t, err)
		require.NotEmpty(t, task.GetTaskToken())
		return task
	}

	firstTask := poll()
	require.Len(t, firstTask.Messages, 1)

	messages := env.UpdateAcceptCompleteMessages(tv, firstTask.Messages[0])
	commands := env.UpdateAcceptCompleteCommands(tv)
	_, err := env.FrontendClient().RespondWorkflowTaskCompleted(ctx, &workflowservice.RespondWorkflowTaskCompletedRequest{
		Namespace:                  env.Namespace().String(),
		TaskToken:                  firstTask.TaskToken,
		Commands:                   commands[:1],
		Messages:                   messages[:1],
		ForceCreateNewWorkflowTask: true,
		Identity:                   tv.WorkerIdentity(),
	})
	require.NoError(t, err)

	secondTask := poll()

	restoreLimit := env.OverrideDynamicConfig(dynamicconfig.HistoryCountLimitError, int(secondTask.StartedEventId))
	restored := false
	defer func() {
		if !restored {
			restoreLimit()
		}
	}()

	completion := &workflowservice.RespondWorkflowTaskCompletedRequest{
		Namespace: env.Namespace().String(),
		TaskToken: secondTask.TaskToken,
		Commands:  commands[1:],
		Messages:  messages[1:],
		Identity:  tv.WorkerIdentity(),
	}
	_, err = env.FrontendClient().RespondWorkflowTaskCompleted(ctx, completion)
	workerErr := err
	require.Error(t, workerErr)
	require.True(t, injected.Load())

	firstResult := cr3TakeUpdateResult(t, ctx, resultCh)
	require.NoError(t, firstResult.err)
	require.Equal(t, enumspb.UPDATE_WORKFLOW_EXECUTION_LIFECYCLE_STAGE_COMPLETED, firstResult.response.GetStage())
	require.Contains(t, firstResult.response.GetOutcome().GetFailure().GetMessage(), "Workflow Update failed because the Workflow completed before the Update completed")

	stored, err := env.GetTestCluster().ExecutionManager().GetWorkflowExecution(ctx, &persistence.GetWorkflowExecutionRequest{
		ShardID:     1,
		NamespaceID: env.NamespaceID().String(),
		WorkflowID:   tv.WorkflowID(),
		RunID:        tv.RunID(),
		ArchetypeID:  chasm.WorkflowArchetypeID,
	})
	require.NoError(t, err)
	storedUpdate := stored.State.ExecutionInfo.UpdateInfos[tv.UpdateID()]
	require.Equal(t, enumspb.WORKFLOW_EXECUTION_STATUS_RUNNING, stored.State.ExecutionState.Status)
	require.NotNil(t, storedUpdate.GetAcceptance())
	require.Nil(t, storedUpdate.GetCompletion())

	t.Logf("CR3_REPRO_LEVEL1 failed_close_write first_caller_stage=%s first_caller_failure=%q durable_status_after_failed_close=%s durable_update_acceptance=%t durable_update_completion=%t termination_write_injected=%t worker_error=%q",
		firstResult.response.GetStage(),
		firstResult.response.GetOutcome().GetFailure().GetMessage(),
		stored.State.ExecutionState.Status,
		storedUpdate.GetAcceptance() != nil,
		storedUpdate.GetCompletion() != nil,
		injected.Load(),
		workerErr,
	)

	restoreLimit()
	restored = true
	_, err = env.FrontendClient().RespondWorkflowTaskCompleted(ctx, completion)
	require.NoError(t, err)

	pollResult, err := env.FrontendClient().PollWorkflowExecutionUpdate(ctx, &workflowservice.PollWorkflowExecutionUpdateRequest{
		Namespace: env.Namespace().String(),
		UpdateRef: tv.UpdateRef(),
		Identity:  tv.ClientIdentity(),
		WaitPolicy: &updatepb.WaitPolicy{
			LifecycleStage: enumspb.UPDATE_WORKFLOW_EXECUTION_LIFECYCLE_STAGE_COMPLETED,
		},
	})
	require.NoError(t, err)
	require.Equal(t, enumspb.UPDATE_WORKFLOW_EXECUTION_LIFECYCLE_STAGE_COMPLETED, pollResult.GetStage())
	require.NotNil(t, pollResult.GetOutcome().GetSuccess())
	require.Equal(t, "success-result-of-"+tv.UpdateID(), testcore.DecodeString(t, pollResult.GetOutcome().GetSuccess()))

	t.Logf("CR3_REPRO_LEVEL1_AFTER_RECOVERY same_update_id=%q poll_stage=%s poll_success=%q",
		tv.UpdateID(),
		pollResult.GetStage(),
		testcore.DecodeString(t, pollResult.GetOutcome().GetSuccess()),
	)
}

func cr3CompleteWorkflowCommand() *commandpb.Command {
	return &commandpb.Command{
		CommandType: enumspb.COMMAND_TYPE_COMPLETE_WORKFLOW_EXECUTION,
		Attributes: &commandpb.Command_CompleteWorkflowExecutionCommandAttributes{
			CompleteWorkflowExecutionCommandAttributes: &commandpb.CompleteWorkflowExecutionCommandAttributes{},
		},
	}
}

func cr3MessageByUpdateID(t *testing.T, messages []*protocolpb.Message, tv *testvars.TestVars) *protocolpb.Message {
	t.Helper()
	for _, message := range messages {
		request := protoutils.UnmarshalAny[*updatepb.Request](t, message.Body)
		if request.GetMeta().GetUpdateId() == tv.UpdateID() {
			return message
		}
	}
	t.Fatalf("update message %q not found", tv.UpdateID())
	return nil
}

func cr3TakeUpdateResult(t *testing.T, ctx context.Context, ch <-chan updateResponseErr) updateResponseErr {
	t.Helper()
	select {
	case result := <-ch:
		return result
	case <-ctx.Done():
		t.Fatalf("timed out waiting for update result: %v", ctx.Err())
		return updateResponseErr{}
	}
}

GOEOF

cd "$REPO"
echo "CR3_REPRO_COMMAND: timeout 10m env TMPDIR=/home/ubuntu/tmp GOTMPDIR=/home/ubuntu/tmp go test -tags=test_dep ./tests -run '^(TestCR3MixedUpdateBatchResponseLink|TestCR3FailedCloseWriteConflictingOutcome)$' -count=1 -v"
set +e
timeout 10m env TMPDIR=/home/ubuntu/tmp GOTMPDIR=/home/ubuntu/tmp go test -tags=test_dep ./tests -run '^(TestCR3MixedUpdateBatchResponseLink|TestCR3FailedCloseWriteConflictingOutcome)$' -count=1 -v >"$LOG" 2>&1
status=$?
set -e
echo "CR3_REPRO_EXIT: $status"
echo "CR3_REPRO_LOG: $LOG"
grep -E 'CR3_REPRO_|--- (PASS|FAIL): TestCR3|^PASS$|^FAIL$|^ok[[:space:]]+go.temporal.io/server/tests' "$LOG" || true
exit "$status"
