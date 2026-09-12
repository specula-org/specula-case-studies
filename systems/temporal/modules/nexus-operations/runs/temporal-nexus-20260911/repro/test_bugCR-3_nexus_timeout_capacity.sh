#!/usr/bin/env bash
set -euo pipefail

WORKTREE="${WORKTREE:-/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-nexus-20260911/temporal-nexus/.specula-output/confirmation/CR-3/worktree}"

workflow_test="${WORKTREE}/service/history/hsm/nexusoperations/workflow/cr3_repro_timeout_capacity_test.go"
describe_test="${WORKTREE}/service/history/api/describeworkflow/cr3_repro_timeout_describe_test.go"

cleanup() {
  rm -f "${workflow_test}" "${describe_test}"
}
trap cleanup EXIT

cd "${WORKTREE}"

cat > "${workflow_test}" <<'GO'
package workflow_test

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"testing"
	"time"

	commandpb "go.temporal.io/api/command/v1"
	commonpb "go.temporal.io/api/common/v1"
	enumspb "go.temporal.io/api/enums/v1"
	enumsspb "go.temporal.io/server/api/enums/v1"
	tokenspb "go.temporal.io/server/api/token/v1"
	chasmworkflow "go.temporal.io/server/chasm/lib/workflow"
	"go.temporal.io/server/common/dynamicconfig"
	"go.temporal.io/server/common/metrics"
	"go.temporal.io/server/service/history/hsm"
	"go.temporal.io/server/service/history/hsm/nexusoperations"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/durationpb"
)

type cr3TimeoutEnv struct {
	node *hsm.Node
}

func (e cr3TimeoutEnv) Access(ctx context.Context, ref hsm.Ref, accessType hsm.AccessType, accessor func(*hsm.Node) error) error {
	return accessor(e.node)
}

func (cr3TimeoutEnv) Now() time.Time {
	return time.Now()
}

func TestCR3LiveTimeoutNodeConsumesPendingCapacity(t *testing.T) {
	cfg := *defaultConfig
	cfg.MaxConcurrentOperations = dynamicconfig.GetIntPropertyFnFilteredByNamespace(1)
	tcx := newTestContext(t, &cfg)
	tcx.ms.EXPECT().GetWorkflowType().Return(&commonpb.WorkflowType{Name: "workflow-type"}).AnyTimes()

	schedule := func() error {
		return tcx.scheduleHandler(context.Background(), tcx.ms, commandValidator{maxPayloadSize: 100}, 1, &commandpb.Command{
			Attributes: &commandpb.Command_ScheduleNexusOperationCommandAttributes{
				ScheduleNexusOperationCommandAttributes: &commandpb.ScheduleNexusOperationCommandAttributes{
					Endpoint:               "endpoint",
					Service:                "service",
					Operation:              "op",
					ScheduleToCloseTimeout: durationpb.New(time.Second),
				},
			},
		})
	}

	requireNoError := func(err error) {
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
	}

	requireNoError(schedule())
	if len(tcx.history.Events) != 1 {
		t.Fatalf("expected one schedule event, got %d", len(tcx.history.Events))
	}

	scheduledEventID := tcx.history.Events[0].EventId
	nodeID := strconv.FormatInt(scheduledEventID, 10)
	coll := nexusoperations.MachineCollection(tcx.ms.HSM())
	node, err := coll.Node(nodeID)
	requireNoError(err)
	token, err := proto.Marshal(&tokenspb.HistoryEventRef{EventId: scheduledEventID, EventBatchId: scheduledEventID})
	requireNoError(err)
	requireNoError(hsm.MachineTransition(node, func(op nexusoperations.Operation) (hsm.TransitionOutput, error) {
		op.ScheduledEventToken = token
		return hsm.TransitionOutput{}, nil
	}))

	reg := hsm.NewRegistry()
	requireNoError(nexusoperations.RegisterExecutor(reg, nexusoperations.TaskExecutorOptions{
		MetricsHandler: metrics.NoopMetricsHandler,
		Config:         &nexusoperations.Config{},
	}))
	requireNoError(reg.ExecuteTimerTask(cr3TimeoutEnv{node: node}, node, nexusoperations.ScheduleToCloseTimeoutTask{}))

	op, err := coll.Data(nodeID)
	requireNoError(err)
	if op.State() != enumsspb.NEXUS_OPERATION_STATE_TIMED_OUT {
		t.Fatalf("expected TIMED_OUT state after live timeout, got %v", op.State())
	}
	if coll.Size() != 1 {
		t.Fatalf("expected retained terminal node to keep physical size at 1, got %d", coll.Size())
	}

	err = schedule()
	var failWFTErr chasmworkflow.FailWorkflowTaskError
	if !errors.As(err, &failWFTErr) {
		t.Fatalf("expected workflow task failure from second schedule, got %T: %v", err, err)
	}
	if failWFTErr.Cause != enumspb.WORKFLOW_TASK_FAILED_CAUSE_PENDING_NEXUS_OPERATIONS_LIMIT_EXCEEDED {
		t.Fatalf("expected pending Nexus limit cause, got %v", failWFTErr.Cause)
	}

	fmt.Printf("CR3_CAPACITY_EVIDENCE after_live_timeout_state=%s physical_count=%d second_schedule_cause=%s message=%q\n",
		op.State().String(),
		coll.Size(),
		failWFTErr.Cause.String(),
		failWFTErr.Message,
	)
}
GO

cat > "${describe_test}" <<'GO'
package describeworkflow

import (
	"context"
	"fmt"
	"testing"
	"time"

	enumspb "go.temporal.io/api/enums/v1"
	historypb "go.temporal.io/api/history/v1"
	enumsspb "go.temporal.io/server/api/enums/v1"
	persistencespb "go.temporal.io/server/api/persistence/v1"
	"go.temporal.io/server/common/log"
	"go.temporal.io/server/common/metrics"
	"go.temporal.io/server/common/namespace"
	"go.temporal.io/server/service/history/hsm"
	"go.temporal.io/server/service/history/hsm/hsmtest"
	"go.temporal.io/server/service/history/hsm/nexusoperations"
	historyi "go.temporal.io/server/service/history/interfaces"
	"go.temporal.io/server/service/history/workflow"
	"go.uber.org/mock/gomock"
	"google.golang.org/protobuf/types/known/durationpb"
	"google.golang.org/protobuf/types/known/timestamppb"
)

type cr3Root struct{}

func (cr3Root) IsWorkflowExecutionRunning() bool {
	return true
}

func (cr3Root) IsTransitionHistoryEnabled() bool {
	return false
}

type cr3DescribeEnv struct {
	node *hsm.Node
}

func (e cr3DescribeEnv) Access(ctx context.Context, ref hsm.Ref, accessType hsm.AccessType, accessor func(*hsm.Node) error) error {
	return accessor(e.node)
}

func (cr3DescribeEnv) Now() time.Time {
	return time.Now()
}

func TestCR3DescribeHidesTimedOutNodeRetainedByLiveTimeout(t *testing.T) {
	reg := hsm.NewRegistry()
	if err := workflow.RegisterStateMachine(reg); err != nil {
		t.Fatal(err)
	}
	if err := nexusoperations.RegisterStateMachines(reg); err != nil {
		t.Fatal(err)
	}
	if err := nexusoperations.RegisterExecutor(reg, nexusoperations.TaskExecutorOptions{
		MetricsHandler: metrics.NoopMetricsHandler,
		Config:         &nexusoperations.Config{},
	}); err != nil {
		t.Fatal(err)
	}

	backend := &hsmtest.NodeBackend{}
	root, err := hsm.NewRoot(reg, workflow.StateMachineType, cr3Root{}, make(map[string]*persistencespb.StateMachineMap), backend)
	if err != nil {
		t.Fatal(err)
	}

	scheduled := &historypb.HistoryEvent{
		EventType: enumspb.EVENT_TYPE_NEXUS_OPERATION_SCHEDULED,
		EventId:   1,
		EventTime: timestamppb.New(time.Now()),
		Attributes: &historypb.HistoryEvent_NexusOperationScheduledEventAttributes{
			NexusOperationScheduledEventAttributes: &historypb.NexusOperationScheduledEventAttributes{
				EndpointId:             "endpoint-id",
				Endpoint:               "endpoint",
				Service:                "service",
				Operation:              "operation",
				ScheduleToCloseTimeout: durationpb.New(time.Second),
				RequestId:              "request-id",
			},
		},
	}
	token, err := root.GenerateEventLoadToken(scheduled)
	if err != nil {
		t.Fatal(err)
	}
	node, err := nexusoperations.AddChild(root, "1", scheduled, token)
	if err != nil {
		t.Fatal(err)
	}
	if err := reg.ExecuteTimerTask(cr3DescribeEnv{node: node}, node, nexusoperations.ScheduleToCloseTimeoutTask{}); err != nil {
		t.Fatal(err)
	}

	coll := nexusoperations.MachineCollection(root)
	op, err := coll.Data("1")
	if err != nil {
		t.Fatal(err)
	}
	if op.State() != enumsspb.NEXUS_OPERATION_STATE_TIMED_OUT {
		t.Fatalf("expected TIMED_OUT state after live timeout, got %v", op.State())
	}
	if coll.Size() != 1 {
		t.Fatalf("expected retained terminal node to keep physical size at 1, got %d", coll.Size())
	}

	ctrl := gomock.NewController(t)
	ms := historyi.NewMockMutableState(ctrl)
	ms.EXPECT().HSM().Return(root).AnyTimes()

	infos, err := buildPendingNexusOperationInfosFromHSM(
		namespace.ID("namespace-id"),
		ms,
		&persistencespb.WorkflowExecutionInfo{WorkflowId: "workflow-id"},
		&persistencespb.WorkflowExecutionState{RunId: "run-id"},
		nil,
		log.NewTestLogger(),
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(infos) != 0 {
		t.Fatalf("expected Describe pending Nexus operations to hide terminal node, got %d", len(infos))
	}

	fmt.Printf("CR3_DESCRIBE_EVIDENCE retained_state=%s physical_count=%d describe_pending=%d\n",
		op.State().String(),
		coll.Size(),
		len(infos),
	)
}
GO

echo "[CR-3] running live timeout capacity repro"
timeout 5m go test ./service/history/hsm/nexusoperations/workflow -run TestCR3LiveTimeoutNodeConsumesPendingCapacity -count=1 -v

echo "[CR-3] running describe visibility repro"
timeout 5m go test ./service/history/api/describeworkflow -run TestCR3DescribeHidesTimedOutNodeRetainedByLiveTimeout -count=1 -v
