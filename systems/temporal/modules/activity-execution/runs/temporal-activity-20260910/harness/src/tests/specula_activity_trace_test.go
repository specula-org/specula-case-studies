package tests

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	commandpb "go.temporal.io/api/command/v1"
	commonpb "go.temporal.io/api/common/v1"
	enumspb "go.temporal.io/api/enums/v1"
	failurepb "go.temporal.io/api/failure/v1"
	historypb "go.temporal.io/api/history/v1"
	"go.temporal.io/api/serviceerror"
	taskqueuepb "go.temporal.io/api/taskqueue/v1"
	"go.temporal.io/api/workflowservice/v1"
	"go.temporal.io/server/api/adminservice/v1"
	"go.temporal.io/server/common/config"
	"go.temporal.io/server/common/dynamicconfig"
	"go.temporal.io/server/common/payloads"
	"go.temporal.io/server/common/speculatrace"
	"go.temporal.io/server/common/tasktoken"
	"go.temporal.io/server/common/testing/await"
	"go.temporal.io/server/tests/testcore"
	"google.golang.org/protobuf/types/known/durationpb"
)

type speculaScenario struct {
	name, mode        string
	stamp             bool
	stc, sts, sct, hb time.Duration
	attempts          int32
	count             int
}

// Uses the same low-level Workflow/Activity RPC testing pattern as
// ActivityTestSuite.TestActivityHeartBeatWorkflow_Success and TestActivityRetry.
func TestSpeculaActivityTrace(t *testing.T) {
	root := os.Getenv("SPECULA_TRACE_ROOT")
	if root == "" {
		t.Skip("SPECULA_TRACE_ROOT is required")
	}
	cases := []speculaScenario{
		{name: "healthy_buffered_reload", mode: "healthy"},
		{name: "retry_stale_stamp_off", mode: "retry"},
		{name: "retry_stale_stamp_on", mode: "retry", stamp: true},
		{name: "shared_heartbeat_extension", mode: "shared", count: 2, hb: 1300 * time.Millisecond, attempts: 1},
		{name: "shared_atomic_timeout", mode: "shared_atomic", count: 2, hb: 300 * time.Millisecond, attempts: 1},
		{name: "shared_heartbeat_duplicate_timer", mode: "shared_duplicate", count: 2, hb: 1300 * time.Millisecond, attempts: 1},
		{name: "start_retry_same_request", mode: "RetryStartResponse"},
		{name: "buffered_close_rejected", mode: "buffered_close_rejected"},
		{name: "timeout_heartbeat", mode: "timeout", hb: 300 * time.Millisecond, attempts: 1},
		{name: "timeout_start_to_close", mode: "timeout", stc: 300 * time.Millisecond, attempts: 1},
		{name: "timeout_schedule_to_close", mode: "timeout", sct: 300 * time.Millisecond, attempts: 1},
		{name: "timeout_schedule_to_start", mode: "scheduled_timeout", sts: 300 * time.Millisecond, attempts: 1},
		{name: "cancel_scheduled", mode: "cancel_scheduled"},
		{name: "cancel_running_ack", mode: "cancel_ack"},
		{name: "cancel_running_complete", mode: "cancel_complete"},
		{name: "cancel_retry_backoff", mode: "cancel_backoff"},
		{name: "start_response_loss", mode: "LoseStartResponse", stc: 300 * time.Millisecond},
		{name: "write_commit_internal_retry", mode: "CommitThenUnavailable"},
		{name: "write_delayed_fenced", mode: "DelayedTimeout"},
		{name: "write_timeout_before", mode: "Timeout"},
		{name: "write_commit_response_timeout", mode: "ExecuteAndTimeout"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) { runSpeculaActivity(t, root, c) })
	}
}

func runSpeculaActivity(t *testing.T, root string, c speculaScenario) {
	checks := require.New(t)
	if c.stc == 0 {
		c.stc = 20 * time.Second
	}
	if c.sts == 0 {
		c.sts = 20 * time.Second
	}
	if c.sct == 0 {
		c.sct = 60 * time.Second
	}
	if c.hb == 0 {
		c.hb = 10 * time.Second
	}
	if c.attempts == 0 {
		c.attempts = 2
	}
	if c.count == 0 {
		c.count = 1
	}
	// Frontend normalizes per-attempt timeouts to schedule-to-close.
	c.stc = min(c.stc, c.sct)
	c.sts = min(c.sts, c.sct)
	opts := []testcore.TestOption{testcore.WithHistoryShardCount(1),
		testcore.WithDynamicConfig(dynamicconfig.EnableActivityRetryStampIncrement, c.stamp),
		testcore.WithDynamicConfig(dynamicconfig.EnableCancelActivityWorkerCommand, false),
		testcore.WithDynamicConfig(dynamicconfig.TimerProcessorUpdateAckInterval, 50*time.Millisecond),
		testcore.WithDynamicConfig(dynamicconfig.TransferProcessorUpdateAckInterval, 50*time.Millisecond),
		testcore.WithDynamicConfig(dynamicconfig.MatchingNumTaskqueueReadPartitions, 1),
		testcore.WithDynamicConfig(dynamicconfig.MatchingNumTaskqueueWritePartitions, 1)}
	if c.mode == "Timeout" || c.mode == "ExecuteAndTimeout" || c.mode == "CommitThenUnavailable" || c.mode == "DelayedTimeout" {
		fi := &config.FaultInjection{}
		fi.WithError(config.ExecutionStoreName, "UpdateWorkflowExecution", "Timeout", 0)
		opts = append(opts, testcore.WithPersistenceFaultInjection(fi))
	}
	env := testcore.NewEnv(t, opts...)
	ctx, cancel := context.WithTimeout(t.Context(), 90*time.Second)
	defer cancel()
	client := env.FrontendClient()
	wf := "specula-activity-" + c.name + "-" + uuid.NewString()
	tq := &taskqueuepb.TaskQueue{Name: wf, Kind: enumspb.TASK_QUEUE_KIND_NORMAL}
	worker := "specula-worker-1"
	cfg := speculatrace.Fields{"scenario": c.name, "backend": "sqlite", "journalMode": "wal", "synchronous": "normal",
		"ActivityCount": c.count, "Workers": []string{worker}, "NamespaceVersion": int64(0), "IncrementRetryStamp": c.stamp, "HasRetryPolicy": true,
		"MaximumAttempts": c.attempts, "InitialInterval": 1000, "BackoffCoefficient": 1, "MaximumInterval": 1000,
		"ScheduleToStart": c.sts.Milliseconds(), "StartToClose": c.stc.Milliseconds(), "ScheduleToClose": c.sct.Milliseconds(), "Heartbeat": c.hb.Milliseconds(),
		"WorkflowExpiration": 0, "KeepInitialWFT": true, "eagerRequest": false, "workerControlCancellation": false, "administrativeExtensions": false,
		"persistenceConfig": env.GetTestCluster().SpeculaPersistenceConfig(), "fault": c.mode}
	checks.NoError(speculatrace.Start(root, c.name, env.NamespaceID().String(), wf, cfg))
	defer func() { checks.NoError(speculatrace.Stop()) }()
	start, err := client.StartWorkflowExecution(ctx, &workflowservice.StartWorkflowExecutionRequest{Namespace: env.Namespace().String(), WorkflowId: wf, RequestId: uuid.NewString(),
		WorkflowType: &commonpb.WorkflowType{Name: "specula-activity"}, TaskQueue: tq, WorkflowTaskTimeout: durationpb.New(40 * time.Second), Identity: worker})
	checks.NoError(err)
	speculatrace.SetRun(start.RunId)
	execution := &commonpb.WorkflowExecution{WorkflowId: wf, RunId: start.RunId}
	pollWFT := func() *workflowservice.PollWorkflowTaskQueueResponse {
		r, e := client.PollWorkflowTaskQueue(ctx, &workflowservice.PollWorkflowTaskQueueRequest{Namespace: env.Namespace().String(), TaskQueue: tq, Identity: worker})
		checks.NoError(e)
		checks.NotEmpty(r.TaskToken)
		speculatrace.Emit(wf, "RecordWorkflowTaskStarted", speculatrace.Fields{"boundary": "worker-history-receipt", "response": speculatrace.Proto(r)})
		return r
	}
	completeWFT := func(r *workflowservice.PollWorkflowTaskQueueResponse, commands []*commandpb.Command, force bool) {
		req := &workflowservice.RespondWorkflowTaskCompletedRequest{Namespace: env.Namespace().String(), TaskToken: r.TaskToken, Commands: commands, Identity: worker, ForceCreateNewWorkflowTask: force}
		out, e := client.RespondWorkflowTaskCompleted(ctx, req)
		checks.NoError(e)
		speculatrace.Emit(wf, "RespondWorkflowTaskCompleted", speculatrace.Fields{"boundary": "worker-completion-receipt", "inputHistory": speculatrace.Proto(r.History), "request": speculatrace.Proto(req), "response": speculatrace.Proto(out)})
	}
	readback := func(label string) *adminservice.DescribeMutableStateResponse {
		r, e := env.AdminClient().DescribeMutableState(ctx, &adminservice.DescribeMutableStateRequest{Namespace: env.Namespace().String(), Execution: execution, SkipForceReload: false})
		checks.NoError(e)
		speculatrace.Emit(wf, "ReadWorkflowExecution", speculatrace.Fields{"boundary": "admin-force-reload-receipt", "label": label, "response": speculatrace.Proto(r)})
		return r
	}
	first := pollWFT()
	initial := readback("bootstrap")
	checks.Empty(initial.DatabaseMutableState.ActivityInfos)
	checks.NotZero(initial.DatabaseMutableState.ExecutionInfo.WorkflowTaskStartedEventId)
	speculatrace.Emit(wf, "Bootstrap", speculatrace.Fields{"response": speculatrace.Proto(initial), "workflowTask": speculatrace.Proto(first), "config": cfg})
	cmds := []*commandpb.Command{}
	for i := 1; i <= c.count; i++ {
		cmds = append(cmds, &commandpb.Command{CommandType: enumspb.COMMAND_TYPE_SCHEDULE_ACTIVITY_TASK, Attributes: &commandpb.Command_ScheduleActivityTaskCommandAttributes{
			ScheduleActivityTaskCommandAttributes: &commandpb.ScheduleActivityTaskCommandAttributes{ActivityId: fmt.Sprint(i), ActivityType: &commonpb.ActivityType{Name: "specula-activity"}, TaskQueue: tq,
				ScheduleToStartTimeout: durationpb.New(c.sts), StartToCloseTimeout: durationpb.New(c.stc), ScheduleToCloseTimeout: durationpb.New(c.sct), HeartbeatTimeout: durationpb.New(c.hb), RequestEagerExecution: false,
				RetryPolicy: &commonpb.RetryPolicy{InitialInterval: durationpb.New(time.Second), BackoffCoefficient: 1, MaximumInterval: durationpb.New(time.Second), MaximumAttempts: c.attempts}}}})
	}
	completeWFT(first, cmds, true)
	scheduled := readback("scheduled").DatabaseMutableState
	var scheduledID int64
	for id := range scheduled.ActivityInfos {
		scheduledID = id
	}
	checks.NotZero(scheduledID)
	held := pollWFT()
	pollAT := func() *workflowservice.PollActivityTaskQueueResponse {
		r, e := client.PollActivityTaskQueue(ctx, &workflowservice.PollActivityTaskQueueRequest{Namespace: env.Namespace().String(), TaskQueue: tq, Identity: worker})
		checks.NoError(e)
		checks.NotEmpty(r.TaskToken)
		tok, e := tasktoken.NewSerializer().Deserialize(r.TaskToken)
		checks.NoError(e)
		checks.Equal(wf, tok.WorkflowId)
		checks.Equal(start.RunId, tok.RunId)
		checks.Equal(env.NamespaceID().String(), tok.NamespaceId)
		speculatrace.Emit(wf, "DeliverPollActivityTaskQueueResponse", speculatrace.Fields{"response": speculatrace.Proto(r), "token": speculatrace.Proto(tok)})
		return r
	}
	send := func(at *workflowservice.PollActivityTaskQueueResponse, kind string) error {
		token, e := tasktoken.NewSerializer().Deserialize(at.TaskToken)
		checks.NoError(e)
		speculatrace.Emit(wf, "SendActivityRequest", speculatrace.Fields{"token": speculatrace.Proto(token), "kind": kind, "details": 1})
		var resp any
		switch kind {
		case "Heartbeat":
			r, x := client.RecordActivityTaskHeartbeat(ctx, &workflowservice.RecordActivityTaskHeartbeatRequest{Namespace: env.Namespace().String(), TaskToken: at.TaskToken, Identity: worker, Details: payloads.EncodeString("checkpoint")})
			e = x
			resp = speculatrace.Proto(r)
			if e == nil && strings.HasPrefix(c.mode, "cancel_") {
				checks.True(r.CancelRequested)
			}
		case "Completed":
			r, x := client.RespondActivityTaskCompleted(ctx, &workflowservice.RespondActivityTaskCompletedRequest{Namespace: env.Namespace().String(), TaskToken: at.TaskToken, Identity: worker, Result: payloads.EncodeString("result")})
			e = x
			resp = speculatrace.Proto(r)
		case "Failed":
			r, x := client.RespondActivityTaskFailed(ctx, &workflowservice.RespondActivityTaskFailedRequest{Namespace: env.Namespace().String(), TaskToken: at.TaskToken, Identity: worker,
				Failure: &failurepb.Failure{Message: "retry", FailureInfo: &failurepb.Failure_ApplicationFailureInfo{ApplicationFailureInfo: &failurepb.ApplicationFailureInfo{Type: "trace"}}}, LastHeartbeatDetails: payloads.EncodeString("checkpoint")})
			e = x
			resp = speculatrace.Proto(r)
		case "Canceled":
			r, x := client.RespondActivityTaskCanceled(ctx, &workflowservice.RespondActivityTaskCanceledRequest{Namespace: env.Namespace().String(), TaskToken: at.TaskToken, Identity: worker, Details: payloads.EncodeString("checkpoint")})
			e = x
			resp = speculatrace.Proto(r)
		default:
			t.Fatalf("unsupported request %s", kind)
		}
		speculatrace.Emit(wf, "DeliverActivityResponse", speculatrace.Fields{"token": speculatrace.Proto(token), "kind": kind, "response": resp, "error": speculatrace.Error(e)})
		return e
	}
	cancelActivity := func() {
		completeWFT(held, []*commandpb.Command{{CommandType: enumspb.COMMAND_TYPE_REQUEST_CANCEL_ACTIVITY_TASK, Attributes: &commandpb.Command_RequestCancelActivityTaskCommandAttributes{RequestCancelActivityTaskCommandAttributes: &commandpb.RequestCancelActivityTaskCommandAttributes{ScheduledEventId: scheduledID}}}}, false)
		held = nil
	}
	want := enumspb.EVENT_TYPE_ACTIVITY_TASK_COMPLETED
	switch c.mode {
	case "scheduled_timeout":
		want = enumspb.EVENT_TYPE_ACTIVITY_TASK_TIMED_OUT
	case "cancel_scheduled":
		cancelActivity()
		want = enumspb.EVENT_TYPE_ACTIVITY_TASK_CANCELED
	default:
		if c.mode == "LoseStartResponse" || c.mode == "RetryStartResponse" {
			speculatrace.ArmFault(wf, c.mode)
		}
		at := pollAT()
		if c.mode == "LoseStartResponse" {
			checks.Equal(int32(2), at.Attempt)
		} else {
			checks.Equal(int32(1), at.Attempt)
		}
		switch c.mode {
		case "RetryStartResponse":
			checks.False(speculatrace.TakeSpecificFault(wf, c.mode), "successful start response must actually be lost")
			checks.Nil(at.WorkflowType, "duplicate-start response omits workflow metadata at this revision")
			checks.NoError(send(at, "Completed"))
		case "LoseStartResponse":
			checks.NoError(send(at, "Completed"))
		case "healthy", "buffered_close_rejected":
			checks.NoError(send(at, "Heartbeat"))
			checks.NoError(send(at, "Completed"))
		case "retry":
			checks.NoError(send(at, "Heartbeat"))
			checks.NoError(send(at, "Failed"))
			next := pollAT()
			checks.Equal(int32(2), next.Attempt)
			current := readback("before-stale-token-requests").DatabaseMutableState
			checks.Len(current.ActivityInfos, 1)
			for _, kind := range []string{"Completed", "Failed", "Heartbeat", "Canceled"} {
				err := send(at, kind)
				var nf *serviceerror.NotFound
				checks.ErrorAs(err, &nf)
				after := readback("after-stale-" + kind).DatabaseMutableState
				checks.Equal(current.ActivityInfos, after.ActivityInfos)
			}
			checks.NoError(send(next, "Completed"))
		case "cancel_ack", "cancel_complete":
			cancelActivity()
			checks.NoError(send(at, "Heartbeat"))
			if c.mode == "cancel_ack" {
				checks.NoError(send(at, "Canceled"))
				want = enumspb.EVENT_TYPE_ACTIVITY_TASK_CANCELED
			} else {
				checks.NoError(send(at, "Completed"))
			}
		case "cancel_backoff":
			checks.NoError(send(at, "Failed"))
			before := readback("retry-backoff").DatabaseMutableState
			for _, ai := range before.ActivityInfos {
				checks.Equal(int32(2), ai.Attempt)
				checks.Zero(ai.StartedEventId)
			}
			cancelActivity()
			want = enumspb.EVENT_TYPE_ACTIVITY_TASK_CANCELED
		case "Timeout", "ExecuteAndTimeout", "CommitThenUnavailable", "DelayedTimeout":
			speculatrace.ArmFault(wf, c.mode)
			e := send(at, "Completed")
			if c.mode != "CommitThenUnavailable" {
				checks.Error(e)
			}
			if c.mode == "DelayedTimeout" {
				// A fresh lease read waits for shard reacquisition before readback.
				readback("before-delayed-write-release")
				speculatrace.ReleaseDelayed()
				await.RequireTrue(t, speculatrace.DelayedFinished, 5*time.Second, 10*time.Millisecond)
			}
			after := readback("after-injected-write").DatabaseMutableState
			if c.mode == "Timeout" || c.mode == "DelayedTimeout" {
				checks.Len(after.ActivityInfos, 1)
				checks.NoError(send(at, "Completed"))
			} else {
				checks.Empty(after.ActivityInfos)
				var nf *serviceerror.NotFound
				checks.ErrorAs(send(at, "Completed"), &nf)
			}
		case "shared_atomic":
			second := pollAT()
			checks.Equal(int32(1), second.Attempt)
			want = enumspb.EVENT_TYPE_ACTIVITY_TASK_TIMED_OUT
		case "shared", "shared_duplicate":
			second := pollAT()
			checks.Equal(int32(1), second.Attempt)
			if c.mode == "shared_duplicate" {
				speculatrace.ArmFault(wf, "DuplicateTimerAck")
			}
			timer := time.NewTimer(time.Second)
			select {
			case <-timer.C:
			case <-ctx.Done():
				t.Fatal(ctx.Err())
			}
			checks.NoError(send(at, "Heartbeat"))
			want = enumspb.EVENT_TYPE_ACTIVITY_TASK_TIMED_OUT
		case "timeout":
			want = enumspb.EVENT_TYPE_ACTIVITY_TASK_TIMED_OUT
		default:
			t.Fatalf("unknown scenario mode %s", c.mode)
		}
	}
	// Read-only public progress checks wait for the real timer/queue workers.
	await.RequireTrue(t, func() bool {
		r, e := client.DescribeWorkflowExecution(ctx, &workflowservice.DescribeWorkflowExecutionRequest{Namespace: env.Namespace().String(), Execution: execution})
		return e == nil && len(r.PendingActivities) == 0
	}, 15*time.Second, 20*time.Millisecond)
	terminal := readback("terminal-before-WFT-consumption")
	checks.Empty(terminal.DatabaseMutableState.ActivityInfos)
	if held != nil {
		checks.NotEmpty(terminal.DatabaseMutableState.BufferedEvents)
		if c.mode == "buffered_close_rejected" {
			request := &workflowservice.RespondWorkflowTaskCompletedRequest{Namespace: env.Namespace().String(), TaskToken: held.TaskToken, Identity: worker,
				Commands: []*commandpb.Command{{CommandType: enumspb.COMMAND_TYPE_COMPLETE_WORKFLOW_EXECUTION, Attributes: &commandpb.Command_CompleteWorkflowExecutionCommandAttributes{CompleteWorkflowExecutionCommandAttributes: &commandpb.CompleteWorkflowExecutionCommandAttributes{}}}}}
			response, closeErr := client.RespondWorkflowTaskCompleted(ctx, request)
			var invalid *serviceerror.InvalidArgument
			checks.ErrorAs(closeErr, &invalid)
			speculatrace.Emit(wf, "WorkflowCloseRejectedObservation", speculatrace.Fields{"request": speculatrace.Proto(request), "response": speculatrace.Proto(response), "error": speculatrace.Error(closeErr)})
		} else {
			completeWFT(held, nil, false)
		}
	}
	finalWFT := pollWFT()
	var terminals []*historypb.HistoryEvent
	for _, e := range finalWFT.History.Events {
		if e.EventType == want {
			terminals = append(terminals, e)
		}
	}
	checks.Len(terminals, c.count, "terminal event must be delivered to the workflow worker")
	completeWFT(finalWFT, nil, false)
	final := readback("complete-endpoint")
	checks.Empty(final.DatabaseMutableState.ActivityInfos)
	checks.Empty(final.DatabaseMutableState.BufferedEvents)
	checks.Zero(final.DatabaseMutableState.ExecutionInfo.WorkflowTaskScheduledEventId)
	checks.Zero(final.DatabaseMutableState.ExecutionInfo.WorkflowTaskStartedEventId)
	if c.mode == "shared_duplicate" {
		checks.False(speculatrace.TakeSpecificFault(wf, "DuplicateTimerAck"), "timeout acknowledgement loss must be exercised")
	}
	if c.mode == "scheduled_timeout" || c.mode == "cancel_scheduled" {
		drainCtx, drainCancel := context.WithTimeout(ctx, 3*time.Second)
		response, drainErr := client.PollActivityTaskQueue(drainCtx, &workflowservice.PollActivityTaskQueueRequest{Namespace: env.Namespace().String(), TaskQueue: tq, Identity: worker})
		drainCancel()
		if drainErr == nil {
			checks.Empty(response.GetTaskToken(), "terminal Activity must not start during queue drain")
		}
		speculatrace.Emit(wf, "DrainMatchingObservation", speculatrace.Fields{"error": speculatrace.Error(drainErr), "response": speculatrace.Proto(response)})
		final = readback("after-matching-drain")
	}
	history, err := client.GetWorkflowExecutionHistory(ctx, &workflowservice.GetWorkflowExecutionHistoryRequest{Namespace: env.Namespace().String(), Execution: execution})
	checks.NoError(err)
	checks.NoError(env.GetTestCluster().SpeculaBackupDatabase(ctx, filepath.Join(root, c.name+".sqlite")))
	speculatrace.Emit(wf, "FinishTrace", speculatrace.Fields{"implementationEndpointComplete": true, "terminalEventsConsumed": terminals, "finalReadback": speculatrace.Proto(final), "history": speculatrace.Proto(history), "modelTraceComplete": false})
	b := speculatrace.Freeze(speculatrace.Fields{"scenario": c.name, "namespace": env.Namespace().String(), "namespaceId": env.NamespaceID().String(), "workflowId": wf, "runId": start.RunId, "terminal": want.String(), "endpointComplete": true, "sourceRevision": speculatrace.Revision})
	checks.NoError(os.WriteFile(filepath.Join(root, c.name+".endpoint.json"), b, 0600))
}
