package tests

import (
	"context"
	"math/rand"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	commandpb "go.temporal.io/api/command/v1"
	enumspb "go.temporal.io/api/enums/v1"
	protocolpb "go.temporal.io/api/protocol/v1"
	"go.temporal.io/api/serviceerror"
	taskqueuepb "go.temporal.io/api/taskqueue/v1"
	updatepb "go.temporal.io/api/update/v1"
	"go.temporal.io/api/workflowservice/v1"
	"go.temporal.io/server/api/matchingservice/v1"
	"go.temporal.io/server/chasm"
	"go.temporal.io/server/common/config"
	"go.temporal.io/server/common/persistence"
	"go.temporal.io/server/common/speculatrace"
	"go.temporal.io/server/common/testing/await"
	"go.temporal.io/server/common/testing/protoutils"
	"go.temporal.io/server/tests/testcore"
)

// These schedules reuse Temporal's functional cluster, request constructors and
// protocol builders. All server operations, persistence and RPCs remain real.
func TestSpeculaUpdateTrace(t *testing.T) {
	dir := os.Getenv("SPECULA_TRACE_DIR")
	if dir == "" {
		t.Skip("SPECULA_TRACE_DIR not configured")
	}
	scenarios := []string{"healthy", "normal_control", "noncommit", "Timeout", "ExecuteAndTimeout", "rejection_skip", "accepted_close", "dispatch_failure", "stale_completion"}
	for _, scenario := range scenarios {
		t.Run(scenario, func(t *testing.T) {
			var injected atomic.Bool
			var dispatchFaults atomic.Int32
			fi := &config.FaultInjection{Injector: func(target config.FaultInjectionTarget) error {
				req, ok := target.Request.(*persistence.InternalUpdateWorkflowExecutionRequest)
				if !ok {
					return nil
				}
				mutation := req.UpdateWorkflowMutation
				if scenario == "noncommit" && len(mutation.ExecutionInfo.GetUpdateInfos()) > 0 && injected.CompareAndSwap(false, true) {
					err := &serviceerror.ResourceExhausted{Cause: enumspb.RESOURCE_EXHAUSTED_CAUSE_SYSTEM_OVERLOADED, Message: "specula: execution mutation not submitted"}
					speculatrace.Emit(mutation.WorkflowID, "ExecutionTransactionNoncommit", map[string]any{"request": req, "error": speculatrace.Error(err), "backendExecuted": false})
					return err
				}
				return nil
			}}
			if scenario == "Timeout" || scenario == "ExecuteAndTimeout" {
				fi.WithError(config.ExecutionStoreName, "UpdateWorkflowExecution", scenario, 0.5).
					WithMethodSeed(config.ExecutionStoreName, "UpdateWorkflowExecution", speculaCommitSeed(3))
			}
			env := testcore.NewEnv(t, testcore.WithHistoryShardCount(1), testcore.WithPersistenceFaultInjection(fi))
			ctx, cancel := context.WithTimeout(t.Context(), 45*time.Second)
			defer cancel()
			tv := env.Tv().WithRunID(mustStartWorkflow(env, env.Tv()))
			key := tv.WorkflowID()
			require.NoError(t, speculatrace.Open(filepath.Join(dir, scenario+".ndjson"), key, []string{tv.UpdateID()}, map[string]any{
				"sourceRevision": "0c010ce5fe8c0180aa7573c72fe8fc87c6df7025", "scenario": scenario,
				"namespaceID": env.NamespaceID().String(), "workflowID": key, "runID": tv.RunID(), "updates": []string{tv.UpdateID()},
				"hosts": []string{"h1"}, "historyShards": 1, "persistence": testcore.GetPersistenceTestDefaults(),
				"faultSeed": speculaCommitSeed(3), "faultTargetWrite": 3,
			}))
			defer func() { require.NoError(t, speculatrace.Close()) }()
			poll := func(queue *taskqueuepb.TaskQueue) *workflowservice.PollWorkflowTaskQueueResponse {
				task, err := env.FrontendClient().PollWorkflowTaskQueue(ctx, &workflowservice.PollWorkflowTaskQueueRequest{
					Namespace: env.Namespace().String(), TaskQueue: queue, Identity: tv.WorkerIdentity(),
				})
				require.NoError(t, err)
				require.NotEmpty(t, task.GetTaskToken())
				speculatrace.Emit(key, "probe.WorkerReceipt", task)
				return task
			}
			complete := func(task *workflowservice.PollWorkflowTaskQueueResponse, commands []*commandpb.Command, messages []*protocolpb.Message, bootstrap bool) error {
				req := &workflowservice.RespondWorkflowTaskCompletedRequest{Namespace: env.Namespace().String(), TaskToken: task.TaskToken, Identity: tv.WorkerIdentity(), Commands: commands, Messages: messages}
				if bootstrap || scenario != "normal_control" {
					req.StickyAttributes = tv.StickyExecutionAttributes(2 * time.Second)
				}
				for _, message := range messages {
					switch {
					case message.Body.MessageIs(&updatepb.Acceptance{}):
						speculatrace.Emit(key, "WorkerAcceptance", map[string]any{"token": task.TaskToken, "message": message})
					case message.Body.MessageIs(&updatepb.Response{}):
						decoded := protoutils.UnmarshalAny[*updatepb.Response](t, message.Body)
						speculatrace.Emit(key, "WorkerResponse", map[string]any{"token": task.TaskToken, "message": message, "response": decoded})
					case message.Body.MessageIs(&updatepb.Rejection{}):
						speculatrace.Emit(key, "WorkerRejection", map[string]any{"token": task.TaskToken, "message": message})
					default:
						t.Fatalf("unexpected protocol message %s", message.Body.TypeUrl)
					}
				}
				event := "WorkerSendCompletion"
				for _, command := range commands {
					if command.CommandType == enumspb.COMMAND_TYPE_COMPLETE_WORKFLOW_EXECUTION {
						event = "WorkerCloseWorkflow"
					}
				}
				speculatrace.Emit(key, event, req)
				response, err := env.FrontendClient().RespondWorkflowTaskCompleted(ctx, req)
				speculatrace.Emit(key, "probe.WorkerCompletionReceipt", map[string]any{"response": response, "error": speculatrace.Error(err)})
				return err
			}
			readback := func(marker string) *persistence.GetWorkflowExecutionResponse {
				stored, err := env.GetTestCluster().ExecutionManager().GetWorkflowExecution(ctx, &persistence.GetWorkflowExecutionRequest{
					ShardID: 1, NamespaceID: env.NamespaceID().String(), WorkflowID: key, RunID: tv.RunID(), ArchetypeID: chasm.WorkflowArchetypeID,
				})
				require.NoError(t, err)
				history := env.GetHistory(env.Namespace().String(), tv.WorkflowExecution())
				speculatrace.Emit(key, marker, map[string]any{"stored": stored, "history": history})
				return stored
			}
			normal := scenario == "normal_control"
			queue := tv.StickyTaskQueue()
			if normal {
				queue = tv.TaskQueue()
			} else {
				require.NoError(t, complete(poll(tv.TaskQueue()), nil, nil, true))
				baseline := readback("probe.Bootstrap")
				require.Equal(t, int64(5), baseline.State.NextEventId)
				require.Empty(t, baseline.State.ExecutionInfo.UpdateInfos)
				require.NotEmpty(t, baseline.State.ExecutionInfo.StickyTaskQueue)
			}
			if scenario == "dispatch_failure" {
				env.InjectRequestFault(func(req any) error {
					if r, ok := req.(*matchingservice.AddWorkflowTaskRequest); ok && r.GetExecution().GetWorkflowId() == key && r.GetScheduledEventId() == 5 {
						dispatchFaults.Add(1)
						speculatrace.Emit(key, "probe.DispatchFault", r)
						return serviceerror.NewUnavailable("specula: direct speculative dispatch failed")
					}
					return nil
				})
				queue = tv.TaskQueue()
			}
			polledTask := make(chan *workflowservice.PollWorkflowTaskQueueResponse, 1)
			if !normal {
				go func() { polledTask <- poll(queue) }()
				await.RequireTrue(t, func() bool {
					response, err := env.FrontendClient().DescribeTaskQueue(ctx, &workflowservice.DescribeTaskQueueRequest{
						Namespace: env.Namespace().String(), TaskQueue: queue, TaskQueueType: enumspb.TASK_QUEUE_TYPE_WORKFLOW,
					})
					return err == nil && len(response.Pollers) > 0
				}, 5*time.Second, 10*time.Millisecond)
			}
			request := updateWorkflowRequest(env, tv, &updatepb.WaitPolicy{LifecycleStage: enumspb.UPDATE_WORKFLOW_EXECUTION_LIFECYCLE_STAGE_COMPLETED})
			result := make(chan updateResponseErr, 1)
			go func() {
				speculatrace.Emit(key, "UpdateWorkflowExecution", request)
				response, err := env.FrontendClient().UpdateWorkflowExecution(ctx, request)
				speculatrace.Emit(key, "ReceiveUpdateResponse", map[string]any{"response": response, "error": speculatrace.Error(err)})
				result <- updateResponseErr{response: response, err: err}
			}()
			if normal {
				waitUpdateAdmitted(env, tv)
				go func() { polledTask <- poll(queue) }()
			}
			task := <-polledTask
			require.Len(t, task.Messages, 1)
			commands := env.UpdateAcceptCompleteCommands(tv)
			messages := env.UpdateAcceptCompleteMessages(tv, task.Messages[0])
			switch scenario {
			case "rejection_skip":
				commands = nil
				messages = env.UpdateRejectMessages(tv, task.Messages[0])
			case "accepted_close":
				commands = append(commands[:1], &commandpb.Command{CommandType: enumspb.COMMAND_TYPE_COMPLETE_WORKFLOW_EXECUTION, Attributes: &commandpb.Command_CompleteWorkflowExecutionCommandAttributes{CompleteWorkflowExecutionCommandAttributes: &commandpb.CompleteWorkflowExecutionCommandAttributes{}}})
				messages = messages[:1]
			default:
			}
			if scenario == "stale_completion" {
				speculatrace.Emit(key, "LoseShardOwnership", map[string]any{"controller": "Admin.CloseShard", "oldToken": task.TaskToken})
				env.CloseShard(env.NamespaceID().String(), key)
				waitUpdateAdmitted(env, tv)
				replacement := poll(tv.StickyTaskQueue())
				require.Equal(t, task.StartedEventId, replacement.StartedEventId)
				require.NotEqual(t, task.StartedTime, replacement.StartedTime)
				require.ErrorAs(t, complete(task, commands, messages, false), new(*serviceerror.NotFound))
				require.ErrorAs(t, complete(replacement, env.UpdateAcceptCompleteCommands(tv), env.UpdateAcceptCompleteMessages(tv, replacement.Messages[0]), false), new(*serviceerror.NotFound))
				waitUpdateAdmitted(env, tv)
				task = poll(tv.TaskQueue())
				commands, messages = env.UpdateAcceptCompleteCommands(tv), env.UpdateAcceptCompleteMessages(tv, task.Messages[0])
			}
			workerErr := complete(task, commands, messages, false)
			faulted := scenario == "noncommit" || scenario == "Timeout" || scenario == "ExecuteAndTimeout"
			if faulted {
				require.Error(t, workerErr)
			} else {
				require.NoError(t, workerErr)
			}
			after := readback("probe.ReadbackAfterWorker")
			info := after.State.ExecutionInfo.UpdateInfos[tv.UpdateID()]
			switch scenario {
			case "noncommit", "Timeout":
				if scenario == "noncommit" {
					require.True(t, injected.Load())
				}
				require.Nil(t, info)
				replacement := poll(tv.TaskQueue())
				require.Len(t, replacement.Messages, 1)
				require.NoError(t, complete(replacement, env.UpdateAcceptCompleteCommands(tv), env.UpdateAcceptCompleteMessages(tv, replacement.Messages[0]), false))
			case "ExecuteAndTimeout":
				require.Contains(t, workerErr.Error(), "fault injection error")
				require.NotNil(t, info.GetCompletion())
			default:
			}
			select {
			case original := <-result:
				require.NoError(t, original.err)
				require.Equal(t, enumspb.UPDATE_WORKFLOW_EXECUTION_LIFECYCLE_STAGE_COMPLETED, original.response.GetStage())
				if scenario == "rejection_skip" || scenario == "accepted_close" {
					require.NotNil(t, original.response.GetOutcome().GetFailure())
				} else {
					require.Equal(t, "success-result-of-"+tv.UpdateID(), testcore.DecodeString(t, original.response.GetOutcome().GetSuccess()))
				}
			case <-ctx.Done():
				t.Fatal("Update caller did not return")
			}
			if scenario == "dispatch_failure" {
				require.Positive(t, dispatchFaults.Load())
			}
			if scenario != "rejection_skip" && scenario != "accepted_close" {
				speculatrace.Emit(key, "LoseShardOwnership", map[string]any{"controller": "Admin.CloseShard"})
				env.CloseShard(env.NamespaceID().String(), key)
				speculatrace.Emit(key, "RetryUpdateWorkflowExecution", request)
				response, err := env.FrontendClient().UpdateWorkflowExecution(ctx, request)
				speculatrace.Emit(key, "ReceiveUpdateResponse", map[string]any{"response": response, "error": speculatrace.Error(err), "retry": true})
				require.NoError(t, err)
				require.Equal(t, "success-result-of-"+tv.UpdateID(), testcore.DecodeString(t, response.GetOutcome().GetSuccess()))
			}
			final := readback("probe.FinalReadback")
			if scenario == "rejection_skip" {
				require.Nil(t, final.State.ExecutionInfo.UpdateInfos[tv.UpdateID()])
				require.Equal(t, int64(5), final.State.NextEventId)
			}
		})
	}
}

// Seed selection is reused from update_analysis_commit_test.go, retained here
// so apply.sh also works on a clean pinned checkout without prior-phase files.
func speculaCommitSeed(target int) int64 {
	for seed := int64(1); ; seed++ {
		rng := rand.New(rand.NewSource(seed))
		matches := true
		for i := 1; i <= target+10; i++ {
			if (rng.Float64() < 0.5) != (i == target) {
				matches = false
				break
			}
		}
		if matches {
			return seed
		}
	}
}
