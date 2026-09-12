package tests

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	commandpb "go.temporal.io/api/command/v1"
	commonpb "go.temporal.io/api/common/v1"
	enumspb "go.temporal.io/api/enums/v1"
	"go.temporal.io/api/serviceerror"
	"go.temporal.io/api/workflowservice/v1"
	"go.temporal.io/server/chasm"
	"go.temporal.io/server/common/dynamicconfig"
	"go.temporal.io/server/common/persistence"
	"go.temporal.io/server/common/resettrace"
	"go.temporal.io/server/common/testing/await"
	"go.temporal.io/server/tests/testcore"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/durationpb"
)

//parallelize:ignore
func (s *WorkflowResetSuite) TestTraceReset() {
	scenario := os.Getenv("RESET_TRACE_SCENARIO")
	if scenario == "" {
		s.T().Skip("run through harness/run.sh")
	}
	t := s.T()
	env := testcore.NewEnv(t, testcore.WithHistoryShardCount(1),
		testcore.WithDynamicConfig(dynamicconfig.ShardIOConcurrency, 1),
		testcore.WithDynamicConfig(dynamicconfig.TransferProcessorUpdateAckInterval, time.Second),
		testcore.WithDynamicConfig(dynamicconfig.VisibilityProcessorUpdateAckInterval, time.Second))
	tv := env.Tv()
	wf := tv.WorkflowID()
	ns := env.Namespace().String()
	mgr := env.GetTestCluster().ExecutionManager()
	rec, err := resettrace.Open(wf, filepath.Join(os.Getenv("RESET_TRACE_RAW_DIR"), scenario+".jsonl"))
	require.NoError(t, err)
	defer func() { require.NoError(t, rec.Close()) }()
	ctx, cancel := context.WithTimeout(t.Context(), 90*time.Second)
	defer cancel()
	// A supported read of a fresh workflow acquires the shard without creating an execution.
	_, err = env.FrontendClient().DescribeWorkflowExecution(ctx, &workflowservice.DescribeWorkflowExecutionRequest{Namespace: ns, Execution: &commonpb.WorkflowExecution{WorkflowId: wf}})
	var missing *serviceerror.NotFound
	require.ErrorAs(t, err, &missing)
	currentReq := &persistence.GetCurrentExecutionRequest{ShardID: 1, NamespaceID: env.NamespaceID().String(), WorkflowID: wf, ArchetypeID: chasm.WorkflowArchetypeID}
	_, err = mgr.GetCurrentExecution(ctx, currentReq)
	require.ErrorAs(t, err, &missing)
	resettrace.Emit(wf, "Bootstrap", resettrace.Fields{"scenario": scenario, "revision": "0c010ce5fe8c0180aa7573c72fe8fc87c6df7025", "ioConcurrency": 1, "historyLimit": 64, "startMapPresent": true, "scannerAfterRequestDeadline": true})
	startID := uuid.NewString()
	started, err := env.FrontendClient().StartWorkflowExecution(ctx, &workflowservice.StartWorkflowExecutionRequest{Namespace: ns, WorkflowId: wf, WorkflowType: tv.WorkflowType(), TaskQueue: tv.TaskQueue(), RequestId: startID, WorkflowRunTimeout: durationpb.New(5 * time.Minute), WorkflowTaskTimeout: durationpb.New(time.Minute)})
	require.NoError(t, err)
	base := started.RunId
	resettrace.Emit(wf, "ReceiveResetResponse", resettrace.Fields{"run": base, "kind": "start"})
	read := func(run string) *persistence.GetWorkflowExecutionResponse {
		v, e := mgr.GetWorkflowExecution(ctx, &persistence.GetWorkflowExecutionRequest{ShardID: 1, NamespaceID: env.NamespaceID().String(), WorkflowID: wf, RunID: run, ArchetypeID: chasm.WorkflowArchetypeID})
		require.NoError(t, e)
		return v
	}
	poll := func() *workflowservice.PollWorkflowTaskQueueResponse {
		v, e := env.FrontendClient().PollWorkflowTaskQueue(ctx, &workflowservice.PollWorkflowTaskQueueRequest{Namespace: ns, TaskQueue: tv.TaskQueue(), Identity: tv.WorkerIdentity()})
		require.NoError(t, e)
		return v
	}
	complete := func(task *workflowservice.PollWorkflowTaskQueueResponse, can bool) {
		command := &commandpb.Command{CommandType: enumspb.COMMAND_TYPE_COMPLETE_WORKFLOW_EXECUTION, Attributes: &commandpb.Command_CompleteWorkflowExecutionCommandAttributes{CompleteWorkflowExecutionCommandAttributes: &commandpb.CompleteWorkflowExecutionCommandAttributes{}}}
		if can {
			command = &commandpb.Command{CommandType: enumspb.COMMAND_TYPE_CONTINUE_AS_NEW_WORKFLOW_EXECUTION, Attributes: &commandpb.Command_ContinueAsNewWorkflowExecutionCommandAttributes{ContinueAsNewWorkflowExecutionCommandAttributes: &commandpb.ContinueAsNewWorkflowExecutionCommandAttributes{WorkflowType: tv.WorkflowType(), TaskQueue: tv.TaskQueue()}}}
		}
		_, e := env.FrontendClient().RespondWorkflowTaskCompleted(ctx, &workflowservice.RespondWorkflowTaskCompletedRequest{Namespace: ns, TaskToken: task.TaskToken, Commands: []*commandpb.Command{command}})
		require.NoError(t, e)
	}
	baseFault := scenario == "base-rejected" || scenario == "base-commit-lost"
	missingScenario := scenario == "missing-rejected" || scenario == "missing-commit-lost" || scenario == "competing-start" || baseFault
	task := poll()
	require.Equal(t, base, task.WorkflowExecution.RunId)
	complete(task, missingScenario || scenario == "can-chain")
	if missingScenario || scenario == "can-chain" {
		c, e := mgr.GetCurrentExecution(ctx, currentReq)
		require.NoError(t, e)
		require.NotEqual(t, base, c.RunID)
		if scenario == "can-chain" {
			_, e = env.FrontendClient().SignalWorkflowExecution(ctx, &workflowservice.SignalWorkflowExecutionRequest{Namespace: ns, WorkflowExecution: &commonpb.WorkflowExecution{WorkflowId: wf, RunId: c.RunID}, SignalName: "trace-signal", RequestId: uuid.NewString()})
			require.NoError(t, e)
		}
		task = poll()
		require.Equal(t, c.RunID, task.WorkflowExecution.RunId)
		complete(task, false)
		if missingScenario {
			_, e = env.FrontendClient().DeleteWorkflowExecution(ctx, &workflowservice.DeleteWorkflowExecutionRequest{Namespace: ns, WorkflowExecution: &commonpb.WorkflowExecution{WorkflowId: wf, RunId: c.RunID}})
			require.NoError(t, e)
			resettrace.Emit(wf, "DeleteWorkflowExecution", resettrace.Fields{"run": c.RunID})
			await.RequireTrue(t, func() bool { _, e := mgr.GetCurrentExecution(ctx, currentReq); return errors.As(e, &missing) }, 30*time.Second, 50*time.Millisecond)
			await.RequireTrue(t, func() bool {
				_, e := mgr.GetWorkflowExecution(ctx, &persistence.GetWorkflowExecutionRequest{ShardID: 1, NamespaceID: env.NamespaceID().String(), WorkflowID: wf, RunID: c.RunID, ArchetypeID: chasm.WorkflowArchetypeID})
				return errors.As(e, &missing)
			}, 30*time.Second, 50*time.Millisecond)
			resettrace.Emit(wf, "Checkpoint", resettrace.Fields{"name": "supported-CAN-delete-missing-current", "base": read(base).State})
		}
	}
	req := &workflowservice.ResetWorkflowExecutionRequest{Namespace: ns, WorkflowExecution: &commonpb.WorkflowExecution{WorkflowId: wf, RunId: base}, RequestId: uuid.NewString(), Reason: "Specula real SQL trace", WorkflowTaskFinishEventId: 4}
	var faults atomic.Int32
	var injectedRun string
	var competitor string
	if missingScenario {
		rec.SetFault(func(point string, data resettrace.Fields) error {
			if scenario == "competing-start" && point == "between-writes" && faults.CompareAndSwap(0, 1) {
				injectedRun = data["candidate"].(string)
				resettrace.Emit(wf, "InterleaveGate", resettrace.Fields{"candidate": injectedRun, "point": point})
				start, e := env.FrontendClient().StartWorkflowExecution(ctx, &workflowservice.StartWorkflowExecutionRequest{Namespace: ns, WorkflowId: wf, WorkflowType: tv.WorkflowType(), TaskQueue: tv.TaskQueue(), RequestId: uuid.NewString(), WorkflowTaskTimeout: durationpb.New(time.Minute)})
				if e != nil {
					return e
				}
				competitor = start.RunId
				resettrace.Emit(wf, "ReceiveResetResponse", resettrace.Fields{"run": competitor, "kind": "start"})
				return nil
			}
			var candidate string
			if baseFault {
				request, ok := data["request"].(*persistence.InternalUpdateWorkflowExecutionRequest)
				if !ok || request.Mode != persistence.UpdateWorkflowModeBypassCurrent || request.NewWorkflowSnapshot != nil {
					return nil
				}
				candidate = request.UpdateWorkflowMutation.ExecutionInfo.ResetRunId
			} else {
				request, ok := data["request"].(*persistence.InternalCreateWorkflowExecutionRequest)
				if !ok || request.NewWorkflowSnapshot.ExecutionInfo.GetBaseExecutionInfo() == nil {
					return nil
				}
				candidate = request.NewWorkflowSnapshot.RunID
			}
			wanted := "before-metadata"
			if scenario == "missing-commit-lost" || scenario == "base-commit-lost" {
				wanted = "after-commit"
			}
			if point != wanted || !faults.CompareAndSwap(0, 1) {
				return nil
			}
			injectedRun = candidate
			resettrace.Emit(wf, "FaultFired", resettrace.Fields{"point": point, "candidate": candidate, "mode": scenario})
			if wanted == "after-commit" {
				return &persistence.TimeoutError{Msg: "Specula: committed SQL metadata response withheld"}
			}
			return &serviceerror.ResourceExhausted{Cause: enumspb.RESOURCE_EXHAUSTED_CAUSE_SYSTEM_OVERLOADED, Message: "Specula: definite rejection before metadata"}
		})
	}
	var hidden string
	var discard func()
	if scenario == "response-loss" {
		discard = env.InjectResponseFault(func(request, response any, handlerErr error) error {
			r, ok := request.(*workflowservice.ResetWorkflowExecutionRequest)
			if ok && r.RequestId == req.RequestId && handlerErr == nil && faults.CompareAndSwap(0, 1) {
				hidden = response.(*workflowservice.ResetWorkflowExecutionResponse).RunId
				resettrace.Emit(wf, "LoseResetResponse", resettrace.Fields{"run": hidden})
				return serviceerror.NewUnavailable("Specula: successful frontend response discarded")
			}
			return nil
		})
	}
	first, err := env.FrontendClient().ResetWorkflowExecution(ctx, proto.Clone(req).(*workflowservice.ResetWorkflowExecutionRequest))
	if missingScenario && err != nil {
		require.EqualValues(t, 1, faults.Load())
		resettrace.Emit(wf, "Checkpoint", resettrace.Fields{"name": "failed-attempt-public-error", "error": resettrace.Error(err), "base": read(base), "candidate": injectedRun})
		if scenario == "base-rejected" {
			require.Empty(t, read(base).State.ExecutionInfo.ResetRunId)
		} else {
			require.Equal(t, injectedRun, read(base).State.ExecutionInfo.ResetRunId)
		}
		if scenario == "missing-rejected" || baseFault {
			_, e := mgr.GetWorkflowExecution(ctx, &persistence.GetWorkflowExecutionRequest{ShardID: 1, NamespaceID: env.NamespaceID().String(), WorkflowID: wf, RunID: injectedRun, ArchetypeID: chasm.WorkflowArchetypeID})
			require.ErrorAs(t, e, &missing)
			_, e = mgr.GetCurrentExecution(ctx, currentReq)
			require.ErrorAs(t, e, &missing)
		}
		rec.SetFault(nil)
		env.CloseShard(env.NamespaceID().String(), wf)
		_, e := env.FrontendClient().DescribeWorkflowExecution(ctx, &workflowservice.DescribeWorkflowExecutionRequest{Namespace: ns, Execution: &commonpb.WorkflowExecution{WorkflowId: wf, RunId: base}})
		require.NoError(t, e)
		first, err = env.FrontendClient().ResetWorkflowExecution(ctx, proto.Clone(req).(*workflowservice.ResetWorkflowExecutionRequest))
	}
	if discard != nil {
		discard()
		require.Error(t, err)
		require.NotEmpty(t, hidden)
		first = &workflowservice.ResetWorkflowExecutionResponse{RunId: hidden}
	} else {
		require.NoError(t, err)
		resettrace.Emit(wf, "ReceiveResetResponse", resettrace.Fields{"run": first.RunId, "kind": "reset"})
	}
	rec.SetFault(nil)
	if missingScenario || discard != nil {
		require.EqualValues(t, 1, faults.Load())
	}
	firstState := read(first.RunId)
	require.Equal(t, startID, firstState.State.ExecutionState.CreateRequestId)
	require.NotContains(t, firstState.State.ExecutionState.RequestIds, req.RequestId)
	current, e := mgr.GetCurrentExecution(ctx, currentReq)
	require.NoError(t, e)
	require.Equal(t, first.RunId, current.RunID)
	resettrace.Emit(wf, "Checkpoint", resettrace.Fields{"name": "first-reset-durable-readback", "base": read(base), "result": firstState, "current": current})
	last := first.RunId
	if scenario == "same-replay" || scenario == "response-loss" {
		if scenario == "same-replay" {
			resettrace.Emit(wf, "ReplayResetRequest", resettrace.Fields{"request": req})
		}
		second, e := env.FrontendClient().ResetWorkflowExecution(ctx, proto.Clone(req).(*workflowservice.ResetWorkflowExecutionRequest))
		require.NoError(t, e)
		resettrace.Emit(wf, "ReceiveResetResponse", resettrace.Fields{"run": second.RunId, "kind": "reset"})
		require.NotEqual(t, first.RunId, second.RunId, "record pinned implementation's repeated Reset behavior")
		require.Equal(t, enumspb.WORKFLOW_EXECUTION_STATUS_TERMINATED, read(first.RunId).State.ExecutionState.Status)
		last = second.RunId
	}
	require.Equal(t, last, read(base).State.ExecutionInfo.ResetRunId)
	if scenario == "competing-start" {
		require.NotEmpty(t, competitor)
		require.Equal(t, enumspb.WORKFLOW_EXECUTION_STATUS_TERMINATED, read(competitor).State.ExecutionState.Status)
		resettrace.Emit(wf, "Checkpoint", resettrace.Fields{"name": "competing-start-ordered-replacement", "competitor": read(competitor), "result": read(last)})
	}

	if scenario == "missing-rejected" {
		_, e = env.FrontendClient().DeleteWorkflowExecution(ctx, &workflowservice.DeleteWorkflowExecutionRequest{Namespace: ns, WorkflowExecution: &commonpb.WorkflowExecution{WorkflowId: wf, RunId: base}})
		require.NoError(t, e)
		resettrace.Emit(wf, "DeleteWorkflowExecution", resettrace.Fields{"run": base})
		await.RequireTrue(t, func() bool {
			_, e := mgr.GetWorkflowExecution(ctx, &persistence.GetWorkflowExecutionRequest{ShardID: 1, NamespaceID: env.NamespaceID().String(), WorkflowID: wf, RunID: base, ArchetypeID: chasm.WorkflowArchetypeID})
			return errors.As(e, &missing)
		}, 30*time.Second, 50*time.Millisecond)
	}
	resettrace.Emit(wf, "Checkpoint", resettrace.Fields{"name": "before-shard-reload", "result": last})
	// Close the real shard and reacquire through a public read; this is a cache/ownership reload, not a process kill.
	env.CloseShard(env.NamespaceID().String(), wf)
	_, err = env.FrontendClient().DescribeWorkflowExecution(ctx, &workflowservice.DescribeWorkflowExecutionRequest{Namespace: ns, Execution: &commonpb.WorkflowExecution{WorkflowId: wf, RunId: last}})
	require.NoError(t, err)
	resettrace.Emit(wf, "ShardReloadReadback", resettrace.Fields{"result": read(last)})
	task = poll()
	require.Equal(t, last, task.WorkflowExecution.RunId)
	complete(task, false)
	require.Equal(t, enumspb.WORKFLOW_EXECUTION_STATUS_COMPLETED, read(last).State.ExecutionState.Status)
	history, err := env.FrontendClient().GetWorkflowExecutionHistory(ctx, &workflowservice.GetWorkflowExecutionHistoryRequest{Namespace: ns, Execution: &commonpb.WorkflowExecution{WorkflowId: wf, RunId: last}})
	require.NoError(t, err)
	resettrace.Emit(wf, "Checkpoint", resettrace.Fields{"name": "healthy-worker-completion", "result": read(last), "history": history, "faults": faults.Load()})
	t.Logf("scenario=%s start=%s reset=%s first=%s final=%s faults=%d finalStatus=%s", scenario, startID, req.RequestId, first.RunId, last, faults.Load(), read(last).State.ExecutionState.Status)
}
