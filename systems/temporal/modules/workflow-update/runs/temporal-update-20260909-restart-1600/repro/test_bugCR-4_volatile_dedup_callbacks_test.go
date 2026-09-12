package bugcr4

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	commonpb "go.temporal.io/api/common/v1"
	enumspb "go.temporal.io/api/enums/v1"
	updatepb "go.temporal.io/api/update/v1"
	"go.temporal.io/api/workflowservice/v1"
	"go.temporal.io/server/chasm/lib/callback"
	"go.temporal.io/server/common/dynamicconfig"
	"go.temporal.io/server/common/payloads"
	"go.temporal.io/server/common/testing/testvars"
	"go.temporal.io/server/tests/testcore"
	"google.golang.org/protobuf/types/known/durationpb"
)

type updateResponseErr struct {
	response *workflowservice.UpdateWorkflowExecutionResponse
	err      error
}

func TestBugCR4VolatileDedupCallbackPreventsUnprocessedTerminal(t *testing.T) {
	env := testcore.NewEnv(t, bugCR4CallbackOpts()...)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	tv := env.Tv()
	startReq := bugCR4StartWorkflowRequest(env, tv)
	startReq.WorkflowTaskTimeout = durationpb.New(2 * time.Second)
	startResp, err := env.FrontendClient().StartWorkflowExecution(ctx, startReq)
	require.NoError(t, err)
	tv = tv.WithRunID(startResp.GetRunId())

	poll := func(identity string) *workflowservice.PollWorkflowTaskQueueResponse {
		t.Helper()
		task, pollErr := env.FrontendClient().PollWorkflowTaskQueue(ctx, &workflowservice.PollWorkflowTaskQueueRequest{
			Namespace: env.Namespace().String(),
			TaskQueue: tv.TaskQueue(),
			Identity:  identity,
		})
		require.NoError(t, pollErr)
		require.NotEmpty(t, task.GetTaskToken())
		return task
	}
	completeWithoutProcessingUpdates := func(task *workflowservice.PollWorkflowTaskQueueResponse, identity string) {
		t.Helper()
		_, completeErr := env.FrontendClient().RespondWorkflowTaskCompleted(ctx, &workflowservice.RespondWorkflowTaskCompletedRequest{
			Namespace: env.Namespace().String(),
			TaskToken: task.GetTaskToken(),
			Identity:  identity,
		})
		require.NoError(t, completeErr)
	}
	recvUpdate := func(ch <-chan updateResponseErr, label string) updateResponseErr {
		t.Helper()
		select {
		case result := <-ch:
			require.NoError(t, result.err)
			require.NotNil(t, result.response)
			return result
		case <-time.After(5 * time.Second):
			t.Fatalf("%s did not return", label)
			return updateResponseErr{}
		}
	}

	firstTask := poll("bugcr4-first-worker")
	completeWithoutProcessingUpdates(firstTask, "bugcr4-first-worker")

	waitAccepted := &updatepb.WaitPolicy{LifecycleStage: enumspb.UPDATE_WORKFLOW_EXECUTION_LIFECYCLE_STAGE_ACCEPTED}
	originalReq := bugCR4UpdateWorkflowRequest(env, tv, waitAccepted)
	originalCh := make(chan updateResponseErr, 1)
	go func() {
		resp, callErr := env.FrontendClient().UpdateWorkflowExecution(ctx, originalReq)
		originalCh <- updateResponseErr{response: resp, err: callErr}
	}()
	bugCR4WaitUpdateAdmitted(t, env, tv)

	heldTask := poll("bugcr4-worker-that-received-update")
	require.Len(t, heldTask.GetMessages(), 1)
	require.Equal(t, tv.UpdateID(), heldTask.GetMessages()[0].GetProtocolInstanceId())
	t.Logf("LEVEL1_SENT update_id=%s message_id=%s event_id=%d", tv.UpdateID(), heldTask.GetMessages()[0].GetId(), heldTask.GetMessages()[0].GetEventId())

	duplicateWithCallback := bugCR4UpdateWorkflowRequest(env, tv, waitAccepted)
	duplicateWithCallback.Request.RequestId = tv.RequestID()
	duplicateWithCallback.Request.CompletionCallbacks = []*commonpb.Callback{{
		Variant: &commonpb.Callback_Nexus_{Nexus: &commonpb.Callback_Nexus{Url: "http://localhost:12345/callback"}},
	}}
	dupResp, dupErr := env.FrontendClient().UpdateWorkflowExecution(ctx, duplicateWithCallback)
	require.NoError(t, dupErr)
	require.Equal(t, enumspb.UPDATE_WORKFLOW_EXECUTION_LIFECYCLE_STAGE_ADMITTED, dupResp.GetStage())
	t.Logf("LEVEL1_DUPLICATE_CALLBACK stage=%v outcome=%v", dupResp.GetStage(), dupResp.GetOutcome())

	completeWithoutProcessingUpdates(heldTask, "bugcr4-old-sdk-worker")
	original := recvUpdate(originalCh, "original update call")
	require.Equal(t, enumspb.UPDATE_WORKFLOW_EXECUTION_LIFECYCLE_STAGE_ADMITTED, original.response.GetStage())
	require.Nil(t, original.response.GetOutcome())
	t.Logf("BUG_TRIGGERED original caller saw stage=%v outcome=%v after worker completed without processing the update", original.response.GetStage(), original.response.GetOutcome())

	for attempt := 1; attempt <= 2; attempt++ {
		redelivery := poll("bugcr4-old-sdk-worker")
		require.Len(t, redelivery.GetMessages(), 1)
		require.Equal(t, tv.UpdateID(), redelivery.GetMessages()[0].GetProtocolInstanceId())
		t.Logf("REDELIVERY_%d update_id=%s message_id=%s event_id=%d", attempt, tv.UpdateID(), redelivery.GetMessages()[0].GetId(), redelivery.GetMessages()[0].GetEventId())
		completeWithoutProcessingUpdates(redelivery, "bugcr4-old-sdk-worker")

		retryResp, retryErr := env.FrontendClient().UpdateWorkflowExecution(ctx, originalReq)
		require.NoError(t, retryErr)
		require.Equal(t, enumspb.UPDATE_WORKFLOW_EXECUTION_LIFECYCLE_STAGE_ADMITTED, retryResp.GetStage())
		require.Nil(t, retryResp.GetOutcome())
		t.Logf("STILL_STUCK_%d same-ID retry stage=%v outcome=%v", attempt, retryResp.GetStage(), retryResp.GetOutcome())
	}

	env.CloseShard(env.NamespaceID().String(), tv.WorkflowID())
	rescueCh := make(chan updateResponseErr, 1)
	go func() {
		resp, callErr := env.FrontendClient().UpdateWorkflowExecution(ctx, originalReq)
		rescueCh <- updateResponseErr{response: resp, err: callErr}
	}()
	bugCR4WaitUpdateAdmitted(t, env, tv)
	rescueTask := poll("bugcr4-cache-clear-rescue-worker")
	require.Len(t, rescueTask.GetMessages(), 1)
	completeWithoutProcessingUpdates(rescueTask, "bugcr4-cache-clear-rescue-worker")
	rescued := recvUpdate(rescueCh, "rescue update call")
	require.Equal(t, enumspb.UPDATE_WORKFLOW_EXECUTION_LIFECYCLE_STAGE_COMPLETED, rescued.response.GetStage())
	require.Equal(t, "UnprocessedUpdate", rescued.response.GetOutcome().GetFailure().GetApplicationFailureInfo().GetType())
	t.Logf("MANUAL_CACHE_CLEAR_RECOVERY stage=%v failure_type=%s", rescued.response.GetStage(), rescued.response.GetOutcome().GetFailure().GetApplicationFailureInfo().GetType())
}

func TestBugCR4HealthyUnprocessedUpdateControl(t *testing.T) {
	env := testcore.NewEnv(t, bugCR4CallbackOpts()...)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	tv := env.Tv()
	startReq := bugCR4StartWorkflowRequest(env, tv)
	startReq.WorkflowTaskTimeout = durationpb.New(2 * time.Second)
	startResp, err := env.FrontendClient().StartWorkflowExecution(ctx, startReq)
	require.NoError(t, err)
	tv = tv.WithRunID(startResp.GetRunId())

	firstTask, err := env.FrontendClient().PollWorkflowTaskQueue(ctx, &workflowservice.PollWorkflowTaskQueueRequest{
		Namespace: env.Namespace().String(),
		TaskQueue: tv.TaskQueue(),
		Identity:  "bugcr4-control-first-worker",
	})
	require.NoError(t, err)
	_, err = env.FrontendClient().RespondWorkflowTaskCompleted(ctx, &workflowservice.RespondWorkflowTaskCompletedRequest{
		Namespace: env.Namespace().String(),
		TaskToken: firstTask.GetTaskToken(),
		Identity:  "bugcr4-control-first-worker",
	})
	require.NoError(t, err)

	waitAccepted := &updatepb.WaitPolicy{LifecycleStage: enumspb.UPDATE_WORKFLOW_EXECUTION_LIFECYCLE_STAGE_ACCEPTED}
	updateCh := make(chan updateResponseErr, 1)
	go func() {
		resp, callErr := env.FrontendClient().UpdateWorkflowExecution(ctx, bugCR4UpdateWorkflowRequest(env, tv, waitAccepted))
		updateCh <- updateResponseErr{response: resp, err: callErr}
	}()
	bugCR4WaitUpdateAdmitted(t, env, tv)

	taskWithUpdate, err := env.FrontendClient().PollWorkflowTaskQueue(ctx, &workflowservice.PollWorkflowTaskQueueRequest{
		Namespace: env.Namespace().String(),
		TaskQueue: tv.TaskQueue(),
		Identity:  "bugcr4-control-old-sdk-worker",
	})
	require.NoError(t, err)
	require.Len(t, taskWithUpdate.GetMessages(), 1)
	_, err = env.FrontendClient().RespondWorkflowTaskCompleted(ctx, &workflowservice.RespondWorkflowTaskCompletedRequest{
		Namespace: env.Namespace().String(),
		TaskToken: taskWithUpdate.GetTaskToken(),
		Identity:  "bugcr4-control-old-sdk-worker",
	})
	require.NoError(t, err)

	var result updateResponseErr
	select {
	case result = <-updateCh:
	case <-time.After(5 * time.Second):
		t.Fatal("control update call did not return")
	}
	require.NoError(t, result.err)
	require.Equal(t, enumspb.UPDATE_WORKFLOW_EXECUTION_LIFECYCLE_STAGE_COMPLETED, result.response.GetStage())
	require.Equal(t, "UnprocessedUpdate", result.response.GetOutcome().GetFailure().GetApplicationFailureInfo().GetType())
	t.Logf("CONTROL_OK stage=%v failure_type=%s", result.response.GetStage(), result.response.GetOutcome().GetFailure().GetApplicationFailureInfo().GetType())
}

func bugCR4CallbackOpts() []testcore.TestOption {
	return []testcore.TestOption{
		testcore.WithDedicatedCluster(),
		testcore.WithDisableTestloggerFailure(),
		testcore.WithDynamicConfig(dynamicconfig.HistoryLongPollExpirationInterval, 300*time.Millisecond),
		testcore.WithDynamicConfig(dynamicconfig.EnableChasm, true),
		testcore.WithDynamicConfig(dynamicconfig.EnableCHASMCallbacks, true),
		testcore.WithDynamicConfig(dynamicconfig.EnableWorkflowUpdateCallbacks, true),
		testcore.WithDynamicConfig(
			callback.AllowedAddresses,
			[]any{map[string]any{"Pattern": "*", "AllowInsecure": true}},
		),
	}
}

func bugCR4StartWorkflowRequest(env *testcore.TestEnv, tv *testvars.TestVars) *workflowservice.StartWorkflowExecutionRequest {
	return &workflowservice.StartWorkflowExecutionRequest{
		RequestId:           tv.Any().String(),
		Namespace:           env.Namespace().String(),
		WorkflowId:          tv.WorkflowID(),
		WorkflowType:        tv.WorkflowType(),
		TaskQueue:           tv.TaskQueue(),
		WorkflowTaskTimeout: durationpb.New(2 * time.Second),
	}
}

func bugCR4UpdateWorkflowRequest(
	env *testcore.TestEnv,
	tv *testvars.TestVars,
	waitPolicy *updatepb.WaitPolicy,
) *workflowservice.UpdateWorkflowExecutionRequest {
	return &workflowservice.UpdateWorkflowExecutionRequest{
		Namespace:         env.Namespace().String(),
		WorkflowExecution: tv.WorkflowExecution(),
		WaitPolicy:        waitPolicy,
		Request: &updatepb.Request{
			Meta: &updatepb.Meta{UpdateId: tv.UpdateID()},
			Input: &updatepb.Input{
				Name: tv.HandlerName(),
				Args: payloads.EncodeString("args-value-of-" + tv.UpdateID()),
			},
		},
	}
}

func bugCR4WaitUpdateAdmitted(t *testing.T, env *testcore.TestEnv, tv *testvars.TestVars) {
	t.Helper()
	require.Eventually(t, func() bool {
		pollResp, pollErr := env.FrontendClient().PollWorkflowExecutionUpdate(testcore.NewContext(), &workflowservice.PollWorkflowExecutionUpdateRequest{
			Namespace:  env.Namespace().String(),
			UpdateRef:  tv.UpdateRef(),
			WaitPolicy: &updatepb.WaitPolicy{LifecycleStage: enumspb.UPDATE_WORKFLOW_EXECUTION_LIFECYCLE_STAGE_UNSPECIFIED},
		})
		return pollErr == nil && pollResp.GetStage() >= enumspb.UPDATE_WORKFLOW_EXECUTION_LIFECYCLE_STAGE_ADMITTED
	}, 5*time.Second, 10*time.Millisecond, "update %s did not reach Admitted stage", tv.UpdateID())
}
