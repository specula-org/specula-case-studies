package history

import (
	"context"
	stdsql "database/sql"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/google/uuid"
	commonpb "go.temporal.io/api/common/v1"
	enumspb "go.temporal.io/api/enums/v1"
	"go.temporal.io/api/serviceerror"
	taskqueuepb "go.temporal.io/api/taskqueue/v1"
	"go.temporal.io/api/workflowservice/v1"
	"go.temporal.io/server/api/historyservice/v1"
	"go.temporal.io/server/api/matchingservice/v1"
	persistencespb "go.temporal.io/server/api/persistence/v1"
	"go.temporal.io/server/chasm"
	"go.temporal.io/server/common/collection"
	"go.temporal.io/server/common/config"
	"go.temporal.io/server/common/dynamicconfig"
	"go.temporal.io/server/common/hqtrace"
	"go.temporal.io/server/common/metrics"
	"go.temporal.io/server/common/namespace"
	"go.temporal.io/server/common/persistence"
	"go.temporal.io/server/common/persistence/faultinjection"
	"go.temporal.io/server/common/persistence/serialization"
	persistencesql "go.temporal.io/server/common/persistence/sql"
	_ "go.temporal.io/server/common/persistence/sql/sqlplugin/sqlite"
	"go.temporal.io/server/common/resolver"
	"go.temporal.io/server/common/testing/testhooks"
	"go.temporal.io/server/service/history/events"
	historyi "go.temporal.io/server/service/history/interfaces"
	"go.temporal.io/server/service/history/queues"
	"go.temporal.io/server/service/history/shard"
	"go.temporal.io/server/service/history/tasks"
	"go.temporal.io/server/service/history/workflow"
	wcache "go.temporal.io/server/service/history/workflow/cache"
	"go.uber.org/mock/gomock"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/durationpb"
	"google.golang.org/protobuf/types/known/timestamppb"
)

type hqRecoveryEngine struct {
	historyi.Engine
	driver *queues.HQDriver
}

func (e *hqRecoveryEngine) Start() {}
func (e *hqRecoveryEngine) Stop()  {}
func (e *hqRecoveryEngine) NotifyNewTasks(ts map[tasks.Category][]tasks.Task) {
	for _, t := range ts[tasks.CategoryTransfer] {
		e.driver.Hint(t)
	}
}

type hqPrepared struct {
	id            int
	kind          string
	workflow, run string
	mutation      *persistence.WorkflowMutation
	events        []*persistence.WorkflowEvents
}

func (s *transferQueueActiveTaskExecutorSuite) TestHQTraceHealthy() { s.hqScenario("healthy") }
func (s *transferQueueActiveTaskExecutorSuite) TestHQTraceDeleteLostReply() {
	s.hqScenario("delete_lost_reply")
}
func (s *transferQueueActiveTaskExecutorSuite) TestHQTraceBatchedCheckpoint() {
	s.hqScenario("batched_checkpoint")
}
func (s *transferQueueActiveTaskExecutorSuite) TestHQTraceMatchingLostReply() {
	s.hqScenario("matching_lost_reply")
}

func (s *transferQueueActiveTaskExecutorSuite) TestHQTraceCursorStall() {
	s.hqScenario("cursor_stall")
}
func (s *transferQueueActiveTaskExecutorSuite) TestHQTraceCursorHealthy() {
	s.hqScenario("cursor_healthy")
}

func (s *transferQueueActiveTaskExecutorSuite) hqScenario(schedule string) {
	root := os.Getenv("HQ_EVIDENCE_DIR")
	if root == "" {
		s.T().Skip("HQ_EVIDENCE_DIR is required")
	}
	dir := filepath.Join(root, schedule)
	s.Require().NoError(os.MkdirAll(dir, 0755))
	dbFile := filepath.Join(dir, "history.sqlite")
	s.Require().NoFileExists(dbFile)
	ctx := context.Background()
	serializer := serialization.NewSerializer()
	cfg := config.SQL{PluginName: "sqlite", DatabaseName: dbFile, MaxConns: 4, MaxIdleConns: 4, ConnectAttributes: map[string]string{"setup": "true", "cache": "private", "journal_mode": "wal", "synchronous": "full", "busy_timeout": "10000"}}
	open := func() (*persistencesql.Factory, persistence.ExecutionManager, persistence.ShardManager) {
		f := persistencesql.NewFactory(cfg, resolver.NewNoopResolver(), "active", s.logger, metrics.NoopMetricsHandler, serializer)
		es, err := f.NewExecutionStore()
		s.Require().NoError(err)
		ss, err := f.NewShardStore()
		s.Require().NoError(err)
		return f, persistence.NewExecutionManager(es, serializer, nil, s.logger, dynamicconfig.GetIntPropertyFn(4*1024*1024), dynamicconfig.GetBoolPropertyFn(false)), persistence.NewShardManager(ss, serializer)
	}
	f, manager, sm := open()
	defer f.Close()
	defer manager.Close()
	defer sm.Close()
	initial := &persistencespb.ShardInfo{ShardId: 1, RangeId: 1, Owner: "s1", QueueStates: map[int32]*persistencespb.QueueState{int32(tasks.CategoryTransfer.ID()): {ExclusiveReaderHighWatermark: &persistencespb.TaskKey{TaskId: 1 << 20, FireTime: timestamppb.New(tasks.DefaultFireTime)}, ReaderStates: map[int64]*persistencespb.QueueReaderState{}}}}
	_, err := sm.GetOrCreateShard(ctx, &persistence.GetOrCreateShardRequest{ShardID: 1, InitialShardInfo: initial})
	s.Require().NoError(err)
	s.mockShard.HQConfigure(manager, sm, 20)
	s.mockShard.HQBootstrap(proto.Clone(initial).(*persistencespb.ShardInfo))
	s.mockShard.GetConfig().ShardUpdateMinInterval = dynamicconfig.GetDurationPropertyFn(0)
	s.mockShard.GetConfig().ShardUpdateMinTasksCompleted = dynamicconfig.GetIntPropertyFn(0)

	prepared := []hqPrepared{}
	for i, kind := range []string{"Workflow", "Activity", "Workflow", "Workflow"} {
		wf := fmt.Sprintf("hq-%s-%d", schedule, i+1)
		run := uuid.NewString()
		ms := workflow.TestGlobalMutableState(s.mockShard, s.mockShard.GetEventsCache(), s.logger, s.version, wf, run)
		execution := &commonpb.WorkflowExecution{WorkflowId: wf, RunId: run}
		_, err := ms.AddWorkflowExecutionStartedEvent(execution, &historyservice.StartWorkflowExecutionRequest{Attempt: 1, NamespaceId: s.namespaceID.String(), StartRequest: &workflowservice.StartWorkflowExecutionRequest{WorkflowType: &commonpb.WorkflowType{Name: "harness"}, TaskQueue: &taskqueuepb.TaskQueue{Name: "ordinary", Kind: enumspb.TASK_QUEUE_KIND_NORMAL}, WorkflowExecutionTimeout: durationpb.New(time.Hour), WorkflowTaskTimeout: durationpb.New(time.Minute)}})
		s.Require().NoError(err)
		if kind == "Activity" {
			wt := addWorkflowTaskScheduledEvent(ms)
			ev := addWorkflowTaskStartedEvent(ms, wt.ScheduledEventID, "ordinary", uuid.NewString())
			wt.StartedEventID = ev.EventId
			addWorkflowTaskCompletedEvent(&s.Suite, ms, wt.ScheduledEventID, wt.StartedEventID, "harness")
		}
		snap, evs, err := ms.CloseTransactionAsSnapshot(ctx, historyi.TransactionPolicyActive)
		s.Require().NoError(err)
		snap.Tasks = nil
		_, err = manager.CreateWorkflowExecution(ctx, &persistence.CreateWorkflowExecutionRequest{ShardID: 1, RangeID: 1, Mode: persistence.CreateWorkflowModeBrandNew, ArchetypeID: chasm.WorkflowArchetypeID, NewWorkflowSnapshot: *snap, NewWorkflowEvents: evs})
		s.Require().NoError(err)
		if kind == "Workflow" {
			addWorkflowTaskScheduledEvent(ms)
		} else {
			addActivityTaskScheduledEvent(ms, 4, "activity-1", "harness", "ordinary", &commonpb.Payloads{}, time.Hour, time.Hour, time.Hour, time.Hour)
		}
		mutation, evs, err := ms.CloseTransactionAsMutation(ctx, historyi.TransactionPolicyActive)
		s.Require().NoError(err)
		transfer := mutation.Tasks[tasks.CategoryTransfer]
		s.Require().Len(transfer, 1)
		mutation.Tasks = map[tasks.Category][]tasks.Task{tasks.CategoryTransfer: transfer}
		prepared = append(prepared, hqPrepared{i + 1, kind, wf, run, mutation, evs})
	}
	// Bootstrap an empty modeled queue at the real allocator frontier after fixture construction.
	keyOrigin := s.mockShard.CurrentVectorClock().Clock
	initial.QueueStates[int32(tasks.CategoryTransfer.ID())].ExclusiveReaderHighWatermark.TaskId = keyOrigin
	s.Require().NoError(sm.UpdateShard(ctx, &persistence.UpdateShardRequest{ShardInfo: initial, PreviousRangeID: 1}))
	s.mockShard.HQInstallMetadata(proto.Clone(initial).(*persistencespb.ShardInfo))
	rf, rm, rsm := open()
	defer rf.Close()
	defer rm.Close()
	defer rsm.Close()
	independent, err := stdsql.Open("sqlite", "file:"+dbFile+"?mode=ro")
	s.Require().NoError(err)
	defer func() { s.Require().NoError(independent.Close()) }()
	ts, err := f.NewTaskStore()
	s.Require().NoError(err)
	tm := persistence.NewTaskManager(ts, serializer)
	defer tm.Close()
	rts, err := rf.NewTaskStore()
	s.Require().NoError(err)
	rtm := persistence.NewTaskManager(rts, serializer)
	defer rtm.Close()
	tq := map[enumspb.TaskQueueType]*persistencespb.TaskQueueInfo{}
	for _, kind := range []enumspb.TaskQueueType{enumspb.TASK_QUEUE_TYPE_WORKFLOW, enumspb.TASK_QUEUE_TYPE_ACTIVITY} {
		info := &persistencespb.TaskQueueInfo{NamespaceId: s.namespaceID.String(), Name: "ordinary", TaskType: kind, Kind: enumspb.TASK_QUEUE_KIND_NORMAL, LastUpdateTime: timestamppb.Now()}
		_, err = tm.CreateTaskQueue(ctx, &persistence.CreateTaskQueueRequest{TaskQueueInfo: info, RangeID: 1})
		s.Require().NoError(err)
		tq[kind] = info
	}
	matchingID := int64(0)
	lost := false
	throttled := false
	accept := func(kind enumspb.TaskQueueType, wf *commonpb.WorkflowExecution, eventID int64) error {
		if schedule == "matching_lost_reply" && lost && !throttled {
			throttled = true
			return &serviceerror.ResourceExhausted{Cause: enumspb.RESOURCE_EXHAUSTED_CAUSE_APS_LIMIT, Message: "injected finite APS throttling before CreateTasks"}
		}
		matchingID++
		allocated := &persistencespb.AllocatedTaskInfo{TaskId: matchingID, Data: &persistencespb.TaskInfo{NamespaceId: s.namespaceID.String(), WorkflowId: wf.WorkflowId, RunId: wf.RunId, ScheduledEventId: eventID, CreateTime: timestamppb.Now()}}
		_, err := tm.CreateTasks(ctx, &persistence.CreateTasksRequest{TaskQueueInfo: &persistence.PersistedTaskQueueInfo{Data: tq[kind], RangeID: 1}, Tasks: []*persistencespb.AllocatedTaskInfo{allocated}})
		if err != nil {
			return err
		}
		if schedule == "matching_lost_reply" && !lost {
			lost = true
			err = context.DeadlineExceeded
			return err
		}
		return nil
	}
	s.mockMatchingClient.EXPECT().AddWorkflowTask(gomock.Any(), gomock.Any(), gomock.Any()).DoAndReturn(func(_ context.Context, r *matchingservice.AddWorkflowTaskRequest, _ ...grpc.CallOption) (*matchingservice.AddWorkflowTaskResponse, error) {
		err := accept(enumspb.TASK_QUEUE_TYPE_WORKFLOW, r.Execution, r.ScheduledEventId)
		return &matchingservice.AddWorkflowTaskResponse{}, err
	}).AnyTimes()
	s.mockMatchingClient.EXPECT().AddActivityTask(gomock.Any(), gomock.Any(), gomock.Any()).DoAndReturn(func(_ context.Context, r *matchingservice.AddActivityTaskRequest, _ ...grpc.CallOption) (*matchingservice.AddActivityTaskResponse, error) {
		err := accept(enumspb.TASK_QUEUE_TYPE_ACTIVITY, r.Execution, r.ScheduledEventId)
		return &matchingservice.AddActivityTaskResponse{}, err
	}).AnyTimes()
	provider := func(r queues.Range) collection.PaginationFn[tasks.Task] {
		return func(token []byte) ([]tasks.Task, []byte, error) {
			resp, err := manager.GetHistoryTasks(ctx, &persistence.GetHistoryTasksRequest{ShardID: 1, TaskCategory: tasks.CategoryTransfer, InclusiveMinTaskKey: r.InclusiveMin, ExclusiveMaxTaskKey: r.ExclusiveMax, BatchSize: 1, NextPageToken: token})
			if err != nil {
				return nil, nil, err
			}
			hqtrace.Extra["last_page"] = hqtrace.M{"lo": r.InclusiveMin.TaskID, "hi": r.ExclusiveMax.TaskID, "input_token": token, "next_token": resp.NextPageToken, "tasks": resp.Tasks}
			return resp.Tasks, resp.NextPageToken, nil
		}
	}
	d := queues.HQNew(s.mockShard, s.transferQueueActiveTaskExecutor, queues.HQOptions(), provider)
	defer d.Close()
	hqtrace.Probes = map[string]func() any{"shard": s.mockShard.HQObserve, "queue": d.Observe}
	hqtrace.Extra = hqtrace.M{}
	hqtrace.Owner = 1
	hqtrace.Task = 0
	hqtrace.Exec = ""
	hqtrace.Before = func(name string, _ hqtrace.M, _ hqtrace.M) {
		if name == "RangeCompleteTasksFail" {
			hqtrace.Extra["delete_noncommit"] = true
		}
		if name == "RangeCompleteTasksCommit" {
			hqtrace.Extra["delete_noncommit"] = false
		}
		if name == "MatchingSpoolCommit" {
			hqtrace.Extra["matching_committed"] = true
		}
		if name == "Execute" {
			hqtrace.Extra["matching_committed"] = false
			hqtrace.Extra["outcome_done"] = false
		}
		if name == "TaskRequestCompletion" && hqtrace.Task > 0 && hqtrace.Task != 4 {
			d.Hint(prepared[hqtrace.Task-1].mutation.Tasks[tasks.CategoryTransfer][0])
		}
	}
	hqtrace.Probes["db"] = func() any {
		loaded, err := rsm.GetOrCreateShard(ctx, &persistence.GetOrCreateShardRequest{ShardID: 1})
		s.Require().NoError(err)
		rows, err := independent.QueryContext(ctx, "SELECT task_id, data, data_encoding FROM transfer_tasks WHERE shard_id=1 ORDER BY task_id")
		s.Require().NoError(err)
		transfer := []any{}
		for rows.Next() {
			var key int64
			var blob []byte
			var enc string
			s.Require().NoError(rows.Scan(&key, &blob, &enc))
			transfer = append(transfer, hqtrace.M{"key": key, "blob": blob, "encoding": enc})
		}
		s.Require().NoError(rows.Err())
		s.Require().NoError(rows.Close())
		workflows := []any{}
		for _, p := range prepared {
			resp, err := rm.GetWorkflowExecution(ctx, &persistence.GetWorkflowExecutionRequest{ShardID: 1, NamespaceID: s.namespaceID.String(), WorkflowID: p.workflow, RunID: p.run, ArchetypeID: chasm.WorkflowArchetypeID})
			s.Require().NoError(err)
			workflows = append(workflows, hqtrace.M{"id": p.id, "kind": p.kind, "state": resp.State})
		}
		matching := []any{}
		for _, kind := range []enumspb.TaskQueueType{enumspb.TASK_QUEUE_TYPE_WORKFLOW, enumspb.TASK_QUEUE_TYPE_ACTIVITY} {
			resp, err := rtm.GetTasks(ctx, &persistence.GetTasksRequest{NamespaceID: s.namespaceID.String(), TaskQueue: "ordinary", TaskType: kind, InclusiveMinTaskID: 0, ExclusiveMaxTaskID: 100, PageSize: 100})
			s.Require().NoError(err)
			for _, t := range resp.Tasks {
				matching = append(matching, t)
			}
		}
		var dlqRows int
		s.Require().NoError(independent.QueryRowContext(ctx, "SELECT COUNT(*) FROM queue_messages").Scan(&dlqRows))
		s.Require().Zero(dlqRows)
		return hqtrace.M{"shard": loaded.ShardInfo, "rows": transfer, "workflows": workflows, "matching": matching, "dlq_message_count": dlqRows}
	}
	hqtrace.Extra["manifest"] = hqtrace.M{"revision": "0c010ce5fe8c0180aa7573c72fe8fc87c6df7025", "backend": "sqlite-wal", "database": dbFile, "group_mapping": map[string]string{s.namespaceID.String(): "g1", s.targetNamespaceID.String(): "g2"}, "range_size_bits": 20, "key_origin": keyOrigin, "scenario": schedule}
	s.Require().NoError(hqtrace.Open(filepath.Join(dir, "raw.ndjson")))
	defer func() {
		s.Require().NoError(hqtrace.Close())
		hqtrace.Before = nil
		hqtrace.Probes = map[string]func() any{}
	}()
	hqtrace.Emit("Init", nil, nil)
	for _, p := range prepared {
		if p.id == 4 && schedule != "healthy" {
			continue
		}
		if p.id == 4 {
			p.mutation.DBRecordVersion += 2
		}
		hqtrace.Task = p.id
		_, err = s.mockShard.UpdateWorkflowExecution(ctx, &persistence.UpdateWorkflowExecutionRequest{ShardID: 1, Mode: persistence.UpdateWorkflowModeUpdateCurrent, ArchetypeID: chasm.WorkflowArchetypeID, UpdateWorkflowMutation: *p.mutation, UpdateWorkflowEvents: p.events})
		if p.id == 4 {
			var conflict *persistence.WorkflowConditionFailedError
			s.Require().ErrorAs(err, &conflict)
		} else {
			s.Require().NoError(err)
		}
		hqtrace.Task = 0
		if p.id == 1 && schedule == "healthy" {
			d.Process()
		}
	}
	if schedule == "healthy" {
		d.DropHint()
		d.Poll()
	} else {
		d.Process()
	}
	if schedule == "cursor_stall" || schedule == "cursor_healthy" {
		d.Split(0, keyOrigin+1)
		d.Split(0, keyOrigin+2)
		for range 6 {
			d.Load(0)
		}
		s.Require().Len(d.Executables, 3)
		s.Require().NoError(d.Run(d.Executables[1]))
		d.Checkpoint()
		observed := d.Observe().(hqtrace.M)
		readers := observed["readers"].([]any)
		s.Require().Len(readers[1].(hqtrace.M)["lists"].([]any), 2)
		d.Clear(1)
		d.Load(1)
		s.Require().Len(d.Executables, 4)
		s.Require().NoError(d.Run(d.Executables[3]))
		if schedule == "cursor_healthy" {
			d.Load(1)
		}
		d.Checkpoint()
		d.Load(1)
		if schedule == "cursor_stall" {
			s.Require().Len(d.Executables, 4)
			for range 3 {
				d.Poll()
				d.Checkpoint()
				d.Notify(1)
				d.Load(1)
			}
			s.Require().Len(d.Executables, 4)
			observed = d.Observe().(hqtrace.M)
			readers = observed["readers"].([]any)
			s.Require().Empty(readers[1].(hqtrace.M)["cursor"])
			s.Require().Len(readers[1].(hqtrace.M)["lists"].([]any), 1)
			s.Require().Equal(int64(2), matchingID)
			var retained int
			lastKey := prepared[2].mutation.Tasks[tasks.CategoryTransfer][0].GetTaskID()
			s.Require().NoError(independent.QueryRowContext(ctx, "SELECT COUNT(*) FROM transfer_tasks WHERE shard_id=1 AND task_id=?", lastKey).Scan(&retained))
			s.Require().Equal(1, retained)
			loaded, err := rsm.GetOrCreateShard(ctx, &persistence.GetOrCreateShardRequest{ShardID: 1})
			s.Require().NoError(err)
			scopes := loaded.ShardInfo.QueueStates[int32(tasks.CategoryTransfer.ID())].ReaderStates[1].Scopes
			s.Require().Len(scopes, 1)
			s.Require().Equal(lastKey, scopes[0].Range.InclusiveMin.TaskId)
			_, err = independent.ExecContext(ctx, "VACUUM INTO ?", filepath.Join(dir, "stalled.sqlite"))
			s.Require().NoError(err)
			s.T().Logf("CR-1 real_executor=true injected_checkpoint_before_cursor_advance=true matching_acceptances=2 eligible_workflow=%s retained_row=%d durable_reader1_scope=true cursor_nil=true poll_checkpoint_notify_rounds=3", prepared[2].workflow, lastKey)
			s.mockShard.UnloadForOwnershipLost()
			d.Stop()
			next := shard.NewTestContextWithTimeSource(s.controller, proto.Clone(initial).(*persistencespb.ShardInfo), s.mockShard.GetConfig(), s.timeSource)
			defer next.StopForTest()
			next.HQConfigure(manager, sm, 20)
			next.Resource.ClusterMetadata.EXPECT().GetAllClusterInfo().Return(s.mockClusterMetadata.GetAllClusterInfo()).AnyTimes()
			next.Resource.ClusterMetadata.EXPECT().GetCurrentClusterName().Return(s.mockClusterMetadata.GetCurrentClusterName()).AnyTimes()
			next.Resource.ClusterMetadata.EXPECT().GetClusterID().Return(s.mockClusterMetadata.GetClusterID()).AnyTimes()
			next.Resource.ClusterMetadata.EXPECT().ClusterNameForFailoverVersion(gomock.Any(), gomock.Any()).Return(s.mockClusterMetadata.GetCurrentClusterName()).AnyTimes()
			next.Resource.ClusterMetadata.EXPECT().IsGlobalNamespaceEnabled().Return(true).AnyTimes()
			next.Resource.NamespaceCache.EXPECT().GetNamespaceByID(s.namespaceID).Return(s.namespaceEntry, nil).AnyTimes()
			next.Resource.NamespaceCache.EXPECT().GetNamespaceName(s.namespaceID).Return(s.namespace, nil).AnyTimes()
			next.Resource.NamespaceCache.EXPECT().GetNamespace(namespace.Name(s.namespace)).Return(s.namespaceEntry, nil).AnyTimes()
			next.SetStateMachineRegistry(s.mockShard.StateMachineRegistry())
			next.SetEventsCacheForTesting(events.NewHostLevelEventsCache(manager, next.GetConfig(), metrics.NoopMetricsHandler, s.logger, false))
			var d2 *queues.HQDriver
			hqtrace.Probes["shard2"] = next.HQObserve
			hqtrace.Probes["queue2"] = func() any {
				if d2 == nil {
					return nil
				}
				return d2.Observe()
			}
			hqtrace.Owner = 2
			next.HQAcquireFresh(func(sc historyi.ShardContext) historyi.Engine {
				cache := wcache.NewHostLevelCache(next.GetConfig(), s.logger, metrics.NoopMetricsHandler, testhooks.TestHooks{})
				executor := newTransferQueueActiveTaskExecutor(sc, cache, nil, s.logger, metrics.NoopMetricsHandler, next.GetConfig(), s.mockHistoryClient, s.mockMatchingClient, s.mockVisibilityManager, s.mockChasmEngine, nil, testhooks.TestHooks{})
				d2 = queues.HQNew(sc, executor, queues.HQOptions(), provider)
				return &hqRecoveryEngine{driver: d2}
			})
			s.Require().NotNil(d2)
			defer d2.Close()
			d2.Process()
			d2.Load(1)
			d2.Load(1)
			d2.Load(1)
			d2.Load(1)
			s.Require().Len(d2.Executables, 1)
			for _, e := range d2.Executables {
				s.Require().NoError(d2.Run(e))
			}
			next.GetConfig().ShardUpdateMinInterval = dynamicconfig.GetDurationPropertyFn(0)
			d2.Checkpoint()
			s.T().Log("CR-1 fresh_acquire=true real_executor_after_reload=true matching_acceptances=3")
		} else {
			s.Require().Len(d.Executables, 5)
			s.Require().NoError(d.Run(d.Executables[4]))
			d.Load(1)
			d.Checkpoint()
			s.T().Log("CR-1 healthy_control=true cursor_advance_before_checkpoint=true real_executor=true matching_acceptances=3")
		}
		s.Require().Equal(int64(3), matchingID)
		var rows int
		s.Require().NoError(independent.QueryRowContext(ctx, "SELECT COUNT(*) FROM transfer_tasks WHERE shard_id=1").Scan(&rows))
		s.Require().Zero(rows)
		hqtrace.Emit("Endpoint", nil, hqtrace.M{"complete": true, "independent_readback": true, "outstanding_calls": 0})
		return
	}

	if schedule == "healthy" {
		d.Split(0, keyOrigin+1)
		d.Compact(0)
		d.Load(0)
		d.Clear(0)
	}
	d.Load(0)
	d.Load(0)
	d.Load(0)
	d.Load(0)
	if schedule == "healthy" {
		s.Require().Len(d.Executables, 4)
	} else {
		s.Require().Len(d.Executables, 3)
	}
	live := d.Executables
	if schedule == "healthy" {
		live = live[1:]
		d.Notify(0)
	}
	// Out-of-order completion leaves task 1 tracked while the later tasks are ACKed.
	firstErr := d.Run(live[2])
	if schedule == "matching_lost_reply" {
		s.Require().Error(firstErr)
	} else {
		s.Require().NoError(firstErr)
	}
	if schedule == "batched_checkpoint" {
		s.mockShard.GetConfig().ShardUpdateMinInterval = dynamicconfig.GetDurationPropertyFn(time.Hour)
	}
	d.Checkpoint()
	if schedule == "matching_lost_reply" {
		s.Require().True(lost)
		d.Retry()
		s.Require().Error(d.Run(live[2]))
		s.Require().True(throttled)
		d.Retry()
		s.Require().NoError(d.Run(live[2]))
	}
	if schedule == "batched_checkpoint" {
		s.Require().NoError(d.Run(live[0]))
	} else {
		s.Require().NoError(d.Run(live[1]))
	}
	if schedule == "batched_checkpoint" {
		d.Checkpoint()
		s.mockShard.UnloadForOwnershipLost()
		d.Stop()
		next := shard.NewTestContextWithTimeSource(s.controller, proto.Clone(initial).(*persistencespb.ShardInfo), s.mockShard.GetConfig(), s.timeSource)
		defer next.StopForTest()
		next.HQConfigure(manager, sm, 20)
		next.Resource.ClusterMetadata.EXPECT().GetAllClusterInfo().Return(s.mockClusterMetadata.GetAllClusterInfo()).AnyTimes()
		next.Resource.ClusterMetadata.EXPECT().GetCurrentClusterName().Return(s.mockClusterMetadata.GetCurrentClusterName()).AnyTimes()
		next.Resource.ClusterMetadata.EXPECT().GetClusterID().Return(s.mockClusterMetadata.GetClusterID()).AnyTimes()
		next.Resource.ClusterMetadata.EXPECT().ClusterNameForFailoverVersion(gomock.Any(), gomock.Any()).Return(s.mockClusterMetadata.GetCurrentClusterName()).AnyTimes()
		next.Resource.ClusterMetadata.EXPECT().IsGlobalNamespaceEnabled().Return(true).AnyTimes()
		next.Resource.NamespaceCache.EXPECT().GetNamespaceByID(s.namespaceID).Return(s.namespaceEntry, nil).AnyTimes()
		next.Resource.NamespaceCache.EXPECT().GetNamespaceName(s.namespaceID).Return(s.namespace, nil).AnyTimes()
		next.Resource.NamespaceCache.EXPECT().GetNamespace(namespace.Name(s.namespace)).Return(s.namespaceEntry, nil).AnyTimes()
		next.SetStateMachineRegistry(s.mockShard.StateMachineRegistry())
		next.SetEventsCacheForTesting(events.NewHostLevelEventsCache(manager, next.GetConfig(), metrics.NoopMetricsHandler, s.logger, false))
		var d2 *queues.HQDriver
		hqtrace.Probes["shard2"] = next.HQObserve
		hqtrace.Probes["queue2"] = func() any {
			if d2 == nil {
				return nil
			}
			return d2.Observe()
		}
		hqtrace.Owner = 2
		next.HQAcquireFresh(func(sc historyi.ShardContext) historyi.Engine {
			cache := wcache.NewHostLevelCache(next.GetConfig(), s.logger, metrics.NoopMetricsHandler, testhooks.TestHooks{})
			executor := newTransferQueueActiveTaskExecutor(sc, cache, nil, s.logger, metrics.NoopMetricsHandler, next.GetConfig(), s.mockHistoryClient, s.mockMatchingClient, s.mockVisibilityManager, s.mockChasmEngine, nil, testhooks.TestHooks{})
			d2 = queues.HQNew(sc, executor, queues.HQOptions(), provider)
			return &hqRecoveryEngine{driver: d2}
		})
		s.Require().NotNil(d2)
		defer d2.Close()
		d2.Process()
		d2.Load(1)
		d2.Load(1)
		d2.Load(1)
		d2.Load(1)
		s.Require().Len(d2.Executables, 2)
		for _, e := range d2.Executables {
			s.Require().NoError(d2.Run(e))
		}
		next.GetConfig().ShardUpdateMinInterval = dynamicconfig.GetDurationPropertyFn(0)
		d2.Checkpoint()
	} else {
		s.Require().NoError(d.Run(live[0]))
	}
	if schedule == "delete_lost_reply" {
		ff := faultinjection.NewFaultInjectionDatastoreFactory((&config.FaultInjection{}).WithError(config.ExecutionStoreName, "RangeCompleteHistoryTasks", "ExecuteAndTimeout", 1), f)
		es, err := ff.NewExecutionStore()
		s.Require().NoError(err)
		fm := persistence.NewExecutionManager(es, serializer, nil, s.logger, dynamicconfig.GetIntPropertyFn(4*1024*1024), dynamicconfig.GetBoolPropertyFn(false))
		defer fm.Close()
		s.mockShard.HQConfigure(fm, sm, 20)
		d.Checkpoint()
		s.mockShard.HQConfigure(manager, sm, 20)
	}
	if schedule == "healthy" {
		injectionDB, err := stdsql.Open("sqlite", dbFile)
		s.Require().NoError(err)
		_, err = injectionDB.ExecContext(ctx, "CREATE TRIGGER hq_delete_failure BEFORE DELETE ON transfer_tasks BEGIN SELECT RAISE(ABORT, 'injected definite DELETE noncommit'); END")
		s.Require().NoError(err)
		d.Checkpoint()
		s.Require().Equal(true, hqtrace.Extra["delete_noncommit"])
		_, err = injectionDB.ExecContext(ctx, "DROP TRIGGER hq_delete_failure")
		s.Require().NoError(err)
		s.Require().NoError(injectionDB.Close())
	}
	if schedule != "batched_checkpoint" {
		d.Checkpoint()
	}
	s.Require().GreaterOrEqual(matchingID, int64(3))
	hqtrace.Emit("Endpoint", nil, hqtrace.M{"complete": true, "independent_readback": true, "outstanding_calls": 0})
	var mode string
	var synchronous int
	s.Require().NoError(independent.QueryRow("PRAGMA journal_mode").Scan(&mode))
	s.Require().NoError(independent.QueryRow("PRAGMA synchronous").Scan(&synchronous))
	s.Require().Equal("wal", mode)
	s.T().Logf("scenario=%s database=%s journal=%s read_connection_synchronous=%d real_executor=true durable_matching_rows=%d", schedule, dbFile, mode, synchronous, matchingID)
}
