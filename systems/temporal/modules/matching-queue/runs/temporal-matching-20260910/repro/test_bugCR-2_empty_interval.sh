#!/usr/bin/env bash
set -euo pipefail

REPO="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-matching-20260910/temporal-matching/.specula-output/confirmation/CR-2/worktree"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/bugCR2.XXXXXX")"
MATCHING_TEST="$REPO/service/matching/bugcr2_repro_test.go"
CASSANDRA_TEST="$REPO/common/persistence/tests/bugcr2_cassandra_paging_test.go"

cleanup() {
  rm -f "$MATCHING_TEST" "$CASSANDRA_TEST"
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

echo "CR2_REPRO: repo=$REPO"
echo "CR2_REPRO: head=$(git -C "$REPO" rev-parse HEAD)"
echo "CR2_REPRO: dirty_entries=$(git -C "$REPO" status --short | wc -l | tr -d ' ')"

cat > "$MATCHING_TEST" <<'GO'
package matching

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	commonpb "go.temporal.io/api/common/v1"
	taskqueuepb "go.temporal.io/api/taskqueue/v1"
	"go.temporal.io/api/workflowservice/v1"
	"go.temporal.io/server/api/historyservice/v1"
	"go.temporal.io/server/api/matchingservice/v1"
	persistencespb "go.temporal.io/server/api/persistence/v1"
	"go.temporal.io/server/common"
	"go.temporal.io/server/common/metrics"
	"go.temporal.io/server/common/persistence"
	"go.uber.org/mock/gomock"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/durationpb"
)

func TestBugCR2Level0PublicWorkflowAddPollNoSkip(t *testing.T) {
	s := &matchingEngineSuite{newMatcher: true}
	s.SetT(t)
	s.SetupTest()
	defer s.TearDownTest()

	s.mockHistoryClient.EXPECT().
		IsWorkflowTaskValid(gomock.Any(), gomock.Any()).
		Return(&historyservice.IsWorkflowTaskValidResponse{IsValid: true}, nil).
		AnyTimes()

	namespaceID := s.ns.ID().String()
	taskQueue := "bug-cr2-level0"
	workflowID := "bug-cr2-workflow"
	runID := uuid.NewString()
	scheduledEventID := int64(11)

	s.mockHistoryClient.EXPECT().
		RecordWorkflowTaskStarted(gomock.Any(), gomock.Any(), gomock.Any()).
		DoAndReturn(func(
			_ context.Context,
			req *historyservice.RecordWorkflowTaskStartedRequest,
			_ ...grpc.CallOption,
		) (*historyservice.RecordWorkflowTaskStartedResponse, error) {
			require.Equal(t, workflowID, req.WorkflowExecution.WorkflowId)
			require.Equal(t, scheduledEventID, req.ScheduledEventId)
			return &historyservice.RecordWorkflowTaskStartedResponse{
				WorkflowType:    &commonpb.WorkflowType{Name: "bug-cr2-workflow-type"},
				PreviousStartedEventId: common.EmptyEventID,
				StartedEventId:  scheduledEventID + 100,
				ScheduledEventId: scheduledEventID,
				Attempt:         1,
			}, nil
		}).Times(1)

	_, _, err := s.matchingEngine.AddWorkflowTask(context.Background(), &matchingservice.AddWorkflowTaskRequest{
		NamespaceId: namespaceID,
		Execution: &commonpb.WorkflowExecution{
			WorkflowId: workflowID,
			RunId:      runID,
		},
		TaskQueue: &taskqueuepb.TaskQueue{Name: taskQueue},
		ScheduledEventId: scheduledEventID,
		ScheduleToStartTimeout: durationpb.New(time.Minute),
	})
	require.NoError(t, err)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	resp, err := s.matchingEngine.PollWorkflowTaskQueue(ctx, &matchingservice.PollWorkflowTaskQueueRequest{
		NamespaceId: namespaceID,
		PollRequest: &workflowservice.PollWorkflowTaskQueueRequest{
			TaskQueue: &taskqueuepb.TaskQueue{Name: taskQueue},
			Identity:  "bug-cr2-worker",
		},
	}, metrics.NoopMetricsHandler)
	require.NoError(t, err)
	require.NotNil(t, resp.WorkflowExecution)
	require.Equal(t, workflowID, resp.WorkflowExecution.WorkflowId)
	require.NotEmpty(t, resp.TaskToken)

	fmt.Printf("LEVEL0_RESULT: public AddWorkflowTask/PollWorkflowTaskQueue delivered scheduled_event_id=%d workflow_id=%s\n", scheduledEventID, workflowID)
}

func TestBugCR2Level1RealBypassStaleGapSafety(t *testing.T) {
	s := &BacklogManagerTestSuite{newMatcher: true}
	s.SetT(t)
	s.SetupTest()
	s.setupToCaptureTasks()

	blm, reader, startReadLevel := s.initPriReaderAtEnd()
	createResp := s.createTasksAt(blm, startReadLevel+1, startReadLevel+2)

	reader.signalNewTasks(createResp)
	require.Equal(t, 2, s.capturedTasksLen())
	readBeforeGap, ackBeforeGap := reader.getLevels()
	require.Equal(t, startReadLevel+2, readBeforeGap)
	require.Equal(t, startReadLevel, ackBeforeGap)

	reader.setReadLevelAfterGap(startReadLevel + 1)
	readAfterGap, ackAfterGap := reader.getLevels()
	persisted, err := s.taskMgr.GetTasks(context.Background(), &persistence.GetTasksRequest{
		NamespaceID:         blm.queueKey().NamespaceId(),
		TaskQueue:           blm.queueKey().PersistenceName(),
		TaskType:            blm.queueKey().TaskType(),
		InclusiveMinTaskID:  startReadLevel + 1,
		ExclusiveMaxTaskID:  startReadLevel + 3,
		PageSize:            10,
	})
	require.NoError(t, err)

	fmt.Printf("LEVEL1_RESULT: bypass_deliveries=%d read_before_gap=%d ack_before_gap=%d stale_gap=%d read_after_gap=%d ack_after_gap=%d durable_task_ids=%v\n",
		s.capturedTasksLen(), readBeforeGap, ackBeforeGap, startReadLevel+1, readAfterGap, ackAfterGap, bugCR2TaskIDs(persisted.Tasks))

	require.Equal(t, readBeforeGap, readAfterGap)
	require.Equal(t, ackBeforeGap, ackAfterGap)
	require.Len(t, persisted.Tasks, 2)
}

type bugCR2EmptyPageTaskManager struct {
	*testTaskManager
	emptyOnce bool
}

func (m *bugCR2EmptyPageTaskManager) GetTasks(ctx context.Context, request *persistence.GetTasksRequest) (*persistence.GetTasksResponse, error) {
	if m.emptyOnce {
		m.emptyOnce = false
		fmt.Printf("LEVEL2_INJECTION: returned tasks=0 next_page_token=true min=%d max=%d page_size=%d\n",
			request.InclusiveMinTaskID, request.ExclusiveMaxTaskID, request.PageSize)
		return &persistence.GetTasksResponse{NextPageToken: []byte("nonterminal-empty-page")}, nil
	}
	return m.testTaskManager.GetTasks(ctx, request)
}

func TestBugCR2Level2InjectedEmptyNonterminalPageDiagnostic(t *testing.T) {
	s := &BacklogManagerTestSuite{newMatcher: true}
	s.SetT(t)
	s.SetupTest()
	s.setupToCaptureTasks()

	blm := s.blm.(*priBacklogManagerImpl)
	wrappedStore := &bugCR2EmptyPageTaskManager{testTaskManager: s.taskMgr}
	blm.db.store = wrappedStore

	_, err := blm.db.RenewLease(blm.tqCtx)
	require.NoError(t, err)
	startReadLevel := blm.db.GetMaxReadLevel(subqueueZero)
	reader := newPriTaskReader(blm, subqueueZero, startReadLevel)

	createResp := s.createTasksAt(blm, startReadLevel+1)
	require.Equal(t, startReadLevel, createResp.maxReadLevelBefore)
	require.Equal(t, startReadLevel+1, createResp.maxReadLevelAfter)

	wrappedStore.emptyOnce = true
	batch, err := reader.getTaskBatch(blm.tqCtx)
	require.NoError(t, err)
	require.Empty(t, batch.tasks)
	require.True(t, batch.isReadBatchDone)
	fmt.Printf("LEVEL2_DIAGNOSTIC: getTaskBatch tasks=%d read_level=%d batch_done=%v token_was_ignored=true\n",
		len(batch.tasks), batch.readLevel, batch.isReadBatchDone)

	reader.setReadLevelAfterGap(batch.readLevel)
	readLevel, ackLevel := reader.getLevels()
	persisted, err := s.taskMgr.GetTasks(context.Background(), &persistence.GetTasksRequest{
		NamespaceID:         blm.queueKey().NamespaceId(),
		TaskQueue:           blm.queueKey().PersistenceName(),
		TaskType:            blm.queueKey().TaskType(),
		InclusiveMinTaskID:  startReadLevel + 1,
		ExclusiveMaxTaskID:  startReadLevel + 2,
		PageSize:            10,
	})
	require.NoError(t, err)

	fmt.Printf("LEVEL2_DIAGNOSTIC: after_gap read_level=%d ack_level=%d captured_deliveries=%d durable_task_ids=%v\n",
		readLevel, ackLevel, s.capturedTasksLen(), bugCR2TaskIDs(persisted.Tasks))

	require.Equal(t, startReadLevel+1, readLevel)
	require.Equal(t, startReadLevel+1, ackLevel)
	require.Len(t, persisted.Tasks, 1)
	require.Equal(t, 0, s.capturedTasksLen())
}

func bugCR2TaskIDs(tasks []*persistencespb.AllocatedTaskInfo) []int64 {
	ids := make([]int64, 0, len(tasks))
	for _, task := range tasks {
		ids = append(ids, task.TaskId)
	}
	return ids
}
GO

cat > "$CASSANDRA_TEST" <<'GO'
package tests

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	enumspb "go.temporal.io/api/enums/v1"
	persistencespb "go.temporal.io/server/api/persistence/v1"
	"go.temporal.io/server/common/log"
	"go.temporal.io/server/common/metrics"
	"go.temporal.io/server/common/persistence"
	"go.temporal.io/server/common/persistence/serialization"
	sqlstore "go.temporal.io/server/common/persistence/sql"
	_ "go.temporal.io/server/common/persistence/sql/sqlplugin/sqlite"
	"go.temporal.io/server/common/resolver"
	"go.temporal.io/server/temporal/environment"
	"google.golang.org/protobuf/types/known/timestamppb"
)

func TestBugCR2SQLiteNoEmptyNonterminalTaskPage(t *testing.T) {
	cfg := NewSQLiteMemoryConfig()
	logger := log.NewNoopLogger()
	factory := sqlstore.NewFactory(
		*cfg,
		resolver.NewNoopResolver(),
		testSQLiteClusterName,
		logger,
		metrics.NoopMetricsHandler,
		serialization.NewSerializer(),
	)
	taskQueueStore, err := factory.NewTaskStore()
	require.NoError(t, err)
	defer factory.Close()

	s := NewTaskQueueTaskSuite(t, taskQueueStore, logger)
	s.SetT(t)
	s.SetupTest()
	defer s.TearDownTest()

	rangeID := int64(7)
	taskQueue := s.createTaskQueue(rangeID)
	tasks := make([]*persistencespb.AllocatedTaskInfo, 0, 3)
	for taskID := int64(1); taskID <= 3; taskID++ {
		tasks = append(tasks, s.randomTask(taskID))
	}
	_, err = s.taskManager.CreateTasks(s.ctx, &persistence.CreateTasksRequest{
		TaskQueueInfo: &persistence.PersistedTaskQueueInfo{
			RangeID: rangeID,
			Data:    taskQueue,
		},
		Tasks: tasks,
	})
	require.NoError(t, err)

	var token []byte
	pages := 0
	gotTasks := 0
	emptyWithToken := false
	for {
		resp, err := s.taskManager.GetTasks(s.ctx, &persistence.GetTasksRequest{
			NamespaceID:         s.namespaceID,
			TaskQueue:           s.taskQueueName,
			TaskType:            s.taskQueueType,
			InclusiveMinTaskID:  1,
			ExclusiveMaxTaskID:  4,
			PageSize:            1,
			NextPageToken:      token,
		})
		require.NoError(t, err)
		pages++
		gotTasks += len(resp.Tasks)
		fmt.Printf("SQLITE_PAGE: page=%d tasks=%d next_page_token=%t ids=%v\n",
			pages, len(resp.Tasks), len(resp.NextPageToken) > 0, bugCR2CassandraTaskIDs(resp.Tasks))
		if len(resp.Tasks) == 0 && len(resp.NextPageToken) > 0 {
			emptyWithToken = true
			break
		}
		token = resp.NextPageToken
		if len(token) == 0 {
			break
		}
		require.LessOrEqual(t, pages, 10)
	}

	fmt.Printf("SQLITE_PROBE: pages=%d got_tasks=%d empty_nonterminal_page=%v\n", pages, gotTasks, emptyWithToken)
	require.False(t, emptyWithToken)
	require.Equal(t, 3, gotTasks)
}

func TestBugCR2CassandraNoEmptyNonterminalTaskPage(t *testing.T) {
	testData, tearDown := setUpCassandraTest(t)
	defer tearDown()

	store, err := testData.Factory.NewTaskStore()
	require.NoError(t, err)
	manager := persistence.NewTaskManager(store, serialization.NewSerializer())

	ctx := context.Background()
	namespaceID := uuid.NewString()
	taskQueue := "bug-cr2-" + uuid.NewString()
	taskQueueType := enumspb.TASK_QUEUE_TYPE_WORKFLOW
	taskQueueInfo := &persistencespb.TaskQueueInfo{
		NamespaceId: namespaceID,
		Name:        taskQueue,
		TaskType:    taskQueueType,
	}

	_, err = manager.CreateTaskQueue(ctx, &persistence.CreateTaskQueueRequest{
		RangeID:       1,
		TaskQueueInfo: taskQueueInfo,
	})
	require.NoError(t, err)

	now := time.Now().UTC()
	tasks := make([]*persistencespb.AllocatedTaskInfo, 0, 3)
	for i := int64(1); i <= 3; i++ {
		tasks = append(tasks, &persistencespb.AllocatedTaskInfo{
			TaskId: i,
			Data: &persistencespb.TaskInfo{
				NamespaceId:      namespaceID,
				WorkflowId:       fmt.Sprintf("bug-cr2-workflow-%d", i),
				RunId:            uuid.NewString(),
				ScheduledEventId: i,
				CreateTime:       timestamppb.New(now),
				ExpiryTime:       timestamppb.New(now.Add(time.Hour)),
			},
		})
	}
	_, err = manager.CreateTasks(ctx, &persistence.CreateTasksRequest{
		TaskQueueInfo: &persistence.PersistedTaskQueueInfo{
			RangeID: 1,
			Data:    taskQueueInfo,
		},
		Tasks: tasks,
	})
	require.NoError(t, err)

	var token []byte
	pages := 0
	gotTasks := 0
	emptyWithToken := false
	for {
		resp, err := manager.GetTasks(ctx, &persistence.GetTasksRequest{
			NamespaceID:         namespaceID,
			TaskQueue:           taskQueue,
			TaskType:            taskQueueType,
			InclusiveMinTaskID:  1,
			ExclusiveMaxTaskID:  4,
			PageSize:            1,
			NextPageToken:      token,
		})
		require.NoError(t, err)
		pages++
		gotTasks += len(resp.Tasks)
		fmt.Printf("CASSANDRA_PAGE: page=%d tasks=%d next_page_token=%t ids=%v\n",
			pages, len(resp.Tasks), len(resp.NextPageToken) > 0, bugCR2CassandraTaskIDs(resp.Tasks))
		if len(resp.Tasks) == 0 && len(resp.NextPageToken) > 0 {
			emptyWithToken = true
			break
		}
		token = resp.NextPageToken
		if len(token) == 0 {
			break
		}
		require.LessOrEqual(t, pages, 10)
	}

	fmt.Printf("CASSANDRA_PROBE: address=%s pages=%d got_tasks=%d empty_nonterminal_page=%v\n",
		environment.GetCassandraAddress(), pages, gotTasks, emptyWithToken)
	require.False(t, emptyWithToken)
	require.Equal(t, 3, gotTasks)
}

func bugCR2CassandraTaskIDs(tasks []*persistencespb.AllocatedTaskInfo) []int64 {
	ids := make([]int64, 0, len(tasks))
	for _, task := range tasks {
		ids = append(ids, task.TaskId)
	}
	return ids
}
GO

echo "LEVEL0: public API enqueue/poll"
(cd "$REPO" && timeout 3m go test ./service/matching -run '^TestBugCR2Level0PublicWorkflowAddPollNoSkip$' -count=1 -v)

echo "LEVEL1: real bypass plus stale-gap schedule"
(cd "$REPO" && timeout 3m go test ./service/matching -run '^TestBugCR2Level1RealBypassStaleGapSafety$' -count=1 -v)

echo "LEVEL2: injected empty nonterminal GetTasks diagnostic"
(cd "$REPO" && timeout 3m go test ./service/matching -run '^TestBugCR2Level2InjectedEmptyNonterminalPageDiagnostic$' -count=1 -v)

echo "SQLITE_PROBE: real sqlite task-store paging"
(cd "$REPO" && timeout 3m go test ./common/persistence/tests -run '^TestBugCR2SQLiteNoEmptyNonterminalTaskPage$' -count=1 -v)

echo "CASSANDRA_PREFLIGHT: checking local Cassandra availability"
if timeout 2 bash -c '</dev/tcp/127.0.0.1/9042' 2>/dev/null; then
  echo "CASSANDRA_PROBE: local Cassandra detected"
  (cd "$REPO" && timeout 5m go test ./common/persistence/tests -run '^TestBugCR2CassandraNoEmptyNonterminalTaskPage$' -count=1 -v)
else
  echo "CASSANDRA_PROBE: skipped; no listener on 127.0.0.1:9042"
  if command -v docker >/dev/null 2>&1 && docker image inspect cassandra:5.0 >/dev/null 2>&1; then
    echo "CASSANDRA_PROBE: cassandra:5.0 image is present but no server is running"
  else
    echo "CASSANDRA_PROBE: no local cassandra:5.0 image available"
  fi
fi

echo "CR2_REPRO_DONE"
