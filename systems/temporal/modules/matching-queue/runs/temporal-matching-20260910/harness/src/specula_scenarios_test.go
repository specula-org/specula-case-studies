package matching

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	commonpb "go.temporal.io/api/common/v1"
	enumspb "go.temporal.io/api/enums/v1"
	historypb "go.temporal.io/api/history/v1"
	"go.temporal.io/api/serviceerror"
	taskqueuepb "go.temporal.io/api/taskqueue/v1"
	"go.temporal.io/api/workflowservice/v1"
	"go.temporal.io/server/api/historyservice/v1"
	"go.temporal.io/server/api/matchingservice/v1"
	persistencespb "go.temporal.io/server/api/persistence/v1"
	historyclient "go.temporal.io/server/client/history"
	"go.temporal.io/server/common"
	"go.temporal.io/server/common/backoff"
	"go.temporal.io/server/common/config"
	"go.temporal.io/server/common/dynamicconfig"
	"go.temporal.io/server/common/metrics"
	"go.temporal.io/server/common/persistence"
	"go.temporal.io/server/common/persistence/serialization"
	sqlstore "go.temporal.io/server/common/persistence/sql"
	_ "go.temporal.io/server/common/persistence/sql/sqlplugin/sqlite"
	"go.temporal.io/server/common/quotas"
	"go.temporal.io/server/common/resolver"
	serviceerrors "go.temporal.io/server/common/serviceerror"
	"go.temporal.io/server/common/testing/await"
	"go.temporal.io/server/common/testing/testlogger"
	"go.temporal.io/server/common/tqid"
	"go.uber.org/mock/gomock"
	"google.golang.org/grpc"
	"google.golang.org/protobuf/types/known/durationpb"
)

type speculaFixture struct {
	t                 *testing.T
	s                 *matchingEngineSuite
	c                 *speculaObserver
	pq                *physicalTaskQueueManagerImpl
	namespace         string
	queue             *taskqueuepb.TaskQueue
	requests          []*matchingservice.AddWorkflowTaskRequest
	store             *speculaFaultStore
	historyMu         sync.Mutex
	historyRequests   map[string]string
	historyFaults     []error
	lostHistory       bool
	validationInvalid bool
	validationQueries int
	validityEvidence  []smap
}
type speculaFaultStore struct {
	persistence.TaskStore
	effects      sync.Mutex
	mu           sync.Mutex
	loseCreate   bool
	rejectCreate bool
	rejectMeta   bool
	loseMeta     bool
	loseGC       bool
	rejectRead   bool
}

func (s *speculaFaultStore) CreateTasks(ctx context.Context, req *persistence.InternalCreateTasksRequest) (*persistence.CreateTasksResponse, error) {
	sqlstore.SpeculaProbe(ctx, "CreateTasksStoreGate")
	s.mu.Lock()
	lost, reject := s.loseCreate, s.rejectCreate
	s.loseCreate = false
	s.rejectCreate = false
	s.mu.Unlock()
	if reject {
		sqlstore.SpeculaProbe(ctx, "CreateTasksReject")
		return nil, persistence.ErrPersistenceSystemLimitExceeded
	}
	s.effects.Lock()
	resp, err := s.TaskStore.CreateTasks(ctx, req)
	s.effects.Unlock()
	if err == nil && lost {
		return nil, serviceerror.NewUnavailable("specula: dropped committed CreateTasks response")
	}
	return resp, err
}
func (s *speculaFaultStore) UpdateTaskQueue(ctx context.Context, req *persistence.InternalUpdateTaskQueueRequest) (*persistence.UpdateTaskQueueResponse, error) {
	sqlstore.SpeculaProbe(ctx, "UpdateTaskQueueStoreGate")
	s.mu.Lock()
	reject, lost := s.rejectMeta, s.loseMeta
	s.rejectMeta = false
	s.loseMeta = false
	s.mu.Unlock()
	if reject {
		sqlstore.SpeculaProbe(ctx, "MetadataRejected")
		return nil, persistence.ErrPersistenceSystemLimitExceeded
	}
	s.effects.Lock()
	resp, err := s.TaskStore.UpdateTaskQueue(ctx, req)
	s.effects.Unlock()
	if err == nil && lost {
		sqlstore.SpeculaProbe(ctx, "MetadataLost")
		return nil, serviceerror.NewUnavailable("specula: committed metadata response lost")
	}
	return resp, err
}
func (s *speculaFaultStore) GetTasks(ctx context.Context, req *persistence.GetTasksRequest) (*persistence.InternalGetTasksResponse, error) {
	s.mu.Lock()
	reject := s.rejectRead
	s.rejectRead = false
	s.mu.Unlock()
	if reject {
		return nil, persistence.ErrPersistenceSystemLimitExceeded
	}
	s.effects.Lock()
	resp, err := s.TaskStore.GetTasks(ctx, req)
	s.effects.Unlock()
	sqlstore.SpeculaProbe(ctx, "GetTasksResponseGate")
	return resp, err
}
func (s *speculaFaultStore) CompleteTasksLessThan(ctx context.Context, req *persistence.CompleteTasksLessThanRequest) (int, error) {
	s.effects.Lock()
	n, err := s.TaskStore.CompleteTasksLessThan(ctx, req)
	s.effects.Unlock()
	s.mu.Lock()
	lost := s.loseGC
	s.loseGC = false
	s.mu.Unlock()
	if err == nil && lost {
		return 0, serviceerror.NewUnavailable("specula: committed GC response lost")
	}
	return n, err
}
func newSpeculaFixture(t *testing.T, name string, size int64) *speculaFixture {
	t.Helper()
	dir := os.Getenv("SPECULA_TRACE_DIR")
	if dir == "" {
		t.Skip("run with harness/run.sh to enable trace collection")
	}
	require.NotEmpty(t, dir)
	require.NoError(t, os.MkdirAll(dir, 0755))
	s := &matchingEngineSuite{newMatcher: true}
	s.SetT(t)
	s.SetupTest()
	s.matchingEngine.Stop()
	s.logger.Expect(testlogger.Error, "Persistent store operation failure")
	cfg := s.newConfig()
	cfg.RangeSize = size
	cfg.MaxTaskQueueIdleTime = dynamicconfig.GetDurationPropertyFnFilteredByTaskQueue(time.Hour)
	cfg.GetTasksBatchSize = dynamicconfig.GetIntPropertyFnFilteredByTaskQueue(3)
	cfg.GetTasksReloadAt = dynamicconfig.GetIntPropertyFnFilteredByTaskQueue(1)
	cfg.MaxTaskBatchSize = dynamicconfig.GetIntPropertyFnFilteredByTaskQueue(1)
	cfg.MaxTaskDeleteBatchSize = dynamicconfig.GetIntPropertyFnFilteredByTaskQueue(2)
	cfg.TaskDeleteInterval = dynamicconfig.GetDurationPropertyFnFilteredByTaskQueue(time.Hour)
	cfg.UpdateAckInterval = dynamicconfig.GetDurationPropertyFnFilteredByTaskQueue(time.Hour)
	cfg.LongPollExpirationInterval = dynamicconfig.GetDurationPropertyFnFilteredByTaskQueue(3 * time.Second)
	cfg.NumTaskqueueReadPartitions = dynamicconfig.GetIntPropertyFnFilteredByTaskQueue(1)
	cfg.NumTaskqueueWritePartitions = dynamicconfig.GetIntPropertyFnFilteredByTaskQueue(1)
	dbfile := filepath.Join(dir, name+"-"+uuid.NewString()+".sqlite")
	serializer := serialization.NewSerializer()
	factory := sqlstore.NewFactory(config.SQL{PluginName: "sqlite", DatabaseName: dbfile, TaskScanPartitions: 1,
		ConnectAttributes: map[string]string{"setup": "true", "journal_mode": "wal", "busy_timeout": "10000", "synchronous": "full"}},
		resolver.NewNoopResolver(), "active", s.logger, metrics.NoopMetricsHandler, serializer)
	store, err := factory.NewTaskStore()
	require.NoError(t, err)
	faultStore := &speculaFaultStore{TaskStore: store}
	fair, err := factory.NewFairTaskStore()
	require.NoError(t, err)
	s.matchingEngine = s.newMatchingEngine(cfg, persistence.NewTaskManager(faultStore, serializer), persistence.NewTaskManager(fair, serializer))
	f := &speculaFixture{t: t, s: s, namespace: s.ns.ID().String(), queue: &taskqueuepb.TaskQueue{Name: "specula-" + name, Kind: enumspb.TASK_QUEUE_KIND_NORMAL}, store: faultStore, historyRequests: map[string]string{}}
	works := []string{}
	for i := 0; i < 3; i++ {
		req := &matchingservice.AddWorkflowTaskRequest{NamespaceId: f.namespace, Execution: &commonpb.WorkflowExecution{WorkflowId: fmt.Sprintf("work-%d", i+1), RunId: uuid.NewString()},
			TaskQueue: f.queue, ScheduledEventId: int64(10 + i), ScheduleToStartTimeout: durationpb.New(time.Hour)}
		f.requests = append(f.requests, req)
		works = append(works, workKey(&persistencespb.TaskInfo{NamespaceId: req.NamespaceId, WorkflowId: req.Execution.WorkflowId, RunId: req.Execution.RunId, ScheduledEventId: req.ScheduledEventId}, enumspb.TASK_QUEUE_TYPE_WORKFLOW))
	}
	c := newObserver(t, filepath.Join(dir, name+".ndjson"), works, size)
	f.c = c
	readback, err := sql.Open("sqlite", "file:"+dbfile+"?_pragma=busy_timeout(10000)")
	require.NoError(t, err)
	c.sqlDB = readback
	c.sqlPath = dbfile
	_, err = readback.Exec("CREATE TABLE specula_task_audit(n INTEGER PRIMARY KEY AUTOINCREMENT,op TEXT,task_id INTEGER,data BLOB,data_encoding TEXT,reported INTEGER DEFAULT 0); CREATE TRIGGER specula_insert AFTER INSERT ON tasks BEGIN INSERT INTO specula_task_audit(op,task_id,data,data_encoding) VALUES('insert',NEW.task_id,NEW.data,NEW.data_encoding); END; CREATE TRIGGER specula_delete AFTER DELETE ON tasks BEGIN INSERT INTO specula_task_audit(op,task_id,data,data_encoding) VALUES('delete',OLD.task_id,OLD.data,OLD.data_encoding); END;")
	require.NoError(t, err)
	speculaCallbacks.Store(&speculaTraceCallbacks{probe: c.probe, owner: c.ownerID})
	sqlstore.SpeculaCallback.Store(&sqlstore.SpeculaTraceCallback{Probe: c.sqlProbe})
	t.Cleanup(func() {
		s.matchingEngine.Stop()
		speculaCallbacks.Store(nil)
		sqlstore.SpeculaCallback.Store(nil)
		require.NoError(t, readback.Close())
		factory.Close()
	})
	s.mockHistoryClient.EXPECT().IsWorkflowTaskValid(gomock.Any(), gomock.Any()).DoAndReturn(func(ctx context.Context, req *historyservice.IsWorkflowTaskValidRequest, _ ...grpc.CallOption) (*historyservice.IsWorkflowTaskValidResponse, error) {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		f.historyMu.Lock()
		defer f.historyMu.Unlock()
		require.Equal(t, f.namespace, req.NamespaceId)
		require.Equal(t, f.requests[0].Execution.WorkflowId, req.Execution.WorkflowId)
		require.Equal(t, f.requests[0].ScheduledEventId, req.ScheduledEventId)
		require.Equal(t, f.requests[0].Execution.RunId, req.Execution.RunId)
		require.Equal(t, f.requests[0].GetStamp(), req.GetStamp())
		f.validityEvidence = append(f.validityEvidence, smap{"namespace": req.NamespaceId, "workflow": req.Execution.WorkflowId,
			"run": req.Execution.RunId, "taskType": "workflow", "scheduledEventId": req.ScheduledEventId, "stamp": req.GetStamp(),
			"isValid": !f.validationInvalid, "time": time.Now().UTC().Format(time.RFC3339Nano)})
		f.validationQueries++
		return &historyservice.IsWorkflowTaskValidResponse{IsValid: !f.validationInvalid}, nil
	}).AnyTimes()
	s.mockHistoryClient.EXPECT().RecordWorkflowTaskStarted(gomock.Any(), gomock.Any()).DoAndReturn(
		func(_ context.Context, req *historyservice.RecordWorkflowTaskStartedRequest, _ ...grpc.CallOption) (*historyservice.RecordWorkflowTaskStartedResponse, error) {
			f.historyMu.Lock()
			defer f.historyMu.Unlock()
			var err error
			if len(f.historyFaults) > 0 {
				err = f.historyFaults[0]
				f.historyFaults = f.historyFaults[1:]
			}
			key := historyKey(req)
			if err == nil {
				if prev := f.historyRequests[key]; prev != "" && prev != req.RequestId {
					err = &serviceerrors.TaskAlreadyStarted{}
				} else {
					f.historyRequests[key] = req.RequestId
				}
			}
			c.historyObserved(req, err)
			if err != nil {
				return nil, err
			}
			if f.lostHistory {
				f.lostHistory = false
				return nil, serviceerror.NewUnavailable("specula: History response lost")
			}
			return &historyservice.RecordWorkflowTaskStartedResponse{WorkflowType: &commonpb.WorkflowType{Name: "specula"}, ScheduledEventId: req.ScheduledEventId, StartedEventId: req.ScheduledEventId + 1, NextEventId: req.ScheduledEventId + 2,
				Attempt: 1, WorkflowExecutionTaskQueue: f.queue, History: &historypb.History{}}, nil
		}).AnyTimes()
	f.pq = f.load()
	await.RequireTrue(t, func() bool { c.mu.Lock(); defer c.mu.Unlock(); return c.mgrs[1] != nil && c.loopVisits[1] > 0 }, 5*time.Second, time.Millisecond)
	if d := f.pq.getDrainBacklogMgr(); d != nil {
		b := d.(*fairBacklogManagerImpl)
		await.RequireTrue(t, b.hasFinishedDraining, 5*time.Second, time.Millisecond)
		f.pq.FinishedDraining()
	}
	c.bootstrap()
	return f
}
func (f *speculaFixture) load() *physicalTaskQueueManagerImpl {
	family, err := tqid.NewTaskQueueFamily(f.namespace, f.queue.Name)
	require.NoError(f.t, err)
	pm, _, err := f.s.matchingEngine.getTaskQueuePartitionManager(context.Background(), family.TaskQueue(enumspb.TASK_QUEUE_TYPE_WORKFLOW).NormalPartition(0), true, loadCauseUnspecified)
	require.NoError(f.t, err)
	impl := pm.(*taskQueuePartitionManagerImpl)
	require.NoError(f.t, impl.WaitUntilInitialized(context.Background()))
	pq := impl.defaultQueue().(*physicalTaskQueueManagerImpl)
	require.NoError(f.t, pq.WaitUntilInitialized(context.Background()))
	return pq
}
func (f *speculaFixture) add(i int, lost bool) error {
	_, syncMatch, err := f.s.matchingEngine.AddWorkflowTask(context.Background(), f.requests[i])
	var info *persistencespb.TaskInfo
	await.RequireTrue(f.t, func() bool {
		f.c.mu.Lock()
		defer f.c.mu.Unlock()
		for p, id := range f.c.callByInfo {
			if f.c.calls[id-1]["pc"] == "reply" && p.WorkflowId == f.requests[i].Execution.WorkflowId {
				info = p
				return true
			}
		}
		return false
	}, 5*time.Second, time.Millisecond)
	require.NotNil(f.t, info, "Add reached caller without observed server return (sync=%v, err=%v)", syncMatch, err)
	f.c.callerReply(info, err, lost)
	return err
}
func (f *speculaFixture) poll(p int, lost bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	resp, err := f.s.matchingEngine.PollWorkflowTaskQueue(ctx, &matchingservice.PollWorkflowTaskQueueRequest{NamespaceId: f.namespace, PollRequest: &workflowservice.PollWorkflowTaskQueueRequest{Namespace: f.s.ns.Name().String(), TaskQueue: f.queue, Identity: strconv.Itoa(p)}}, metrics.NoopMetricsHandler)
	require.NoError(f.t, err)
	require.NotNil(f.t, resp)
	require.NotEmpty(f.t, resp.TaskToken)
	token, decodeErr := f.s.matchingEngine.tokenSerializer.Deserialize(resp.TaskToken)
	require.NoError(f.t, decodeErr)
	f.c.mu.Lock()
	expectedWork := f.c.dispatch[p-1]["work"].(string)
	f.c.mu.Unlock()
	var identity []json.RawMessage
	require.NoError(f.t, json.Unmarshal([]byte(expectedWork), &identity))
	require.Len(f.t, identity, 6)
	actual := []any{token.NamespaceId, token.WorkflowId, token.RunId, enumspb.TASK_QUEUE_TYPE_WORKFLOW.String(), token.ScheduledEventId}
	for i, value := range actual {
		encoded, encodeErr := json.Marshal(value)
		require.NoError(f.t, encodeErr)
		require.JSONEq(f.t, string(identity[i]), string(encoded))
	}
	require.Equal(f.t, token.WorkflowId, resp.WorkflowExecution.WorkflowId)
	require.Equal(f.t, token.RunId, resp.WorkflowExecution.RunId)
	f.c.workerReply(p, lost)
}
func (f *speculaFixture) pump(o int) {
	f.c.mu.Lock()
	old := f.c.loopVisits[o]
	ch := f.c.gates[o]
	f.c.mu.Unlock()
	ch <- struct{}{}
	await.RequireTrue(f.t, func() bool { f.c.mu.Lock(); defer f.c.mu.Unlock(); return f.c.loopVisits[o] > old }, 5*time.Second, time.Millisecond)
}
func (f *speculaFixture) gcWait(o int, n int) {
	await.RequireTrue(f.t, func() bool { f.c.mu.Lock(); defer f.c.mu.Unlock(); return f.c.gcFinished[o] >= n }, 5*time.Second, time.Millisecond)
}
func TestSpeculaMatchingNormal(t *testing.T) {
	f := newSpeculaFixture(t, "normal", 2)
	require.NoError(t, f.add(0, false))
	require.NoError(t, f.add(1, false))
	f.poll(1, false)
	f.poll(2, false)
	f.gcWait(1, 1)
	f.pump(1)
	// The actual Stop path selects verify when metadata is clean; it is part of this complete trace.
	f.stop()
	f.c.seal()
}

func waitSpecula(t *testing.T, ch <-chan struct{}) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(10 * time.Second):
		t.Fatal("schedule gate was not reached")
	}
}
func (f *speculaFixture) stop() {
	b := f.pq.backlogMgr.(*priBacklogManagerImpl)
	o := f.c.ownerID(b.db)
	f.pq.UnloadFromPartitionManager(unloadCauseUnspecified)
	await.RequireTrue(f.t, func() bool {
		f.c.mu.Lock()
		exited := f.c.readerExited[o]
		f.c.mu.Unlock()
		tr := b.subqueues[0]
		tr.lock.Lock()
		settled := tr.backoffTimer == nil
		tr.lock.Unlock()
		return exited && settled
	}, 5*time.Second, time.Millisecond)
}
func (f *speculaFixture) reload() {
	f.pq = f.load()
	await.RequireTrue(f.t, func() bool { f.c.mu.Lock(); defer f.c.mu.Unlock(); return f.c.mgrs[2] != nil && f.c.loopVisits[2] > 0 }, 5*time.Second, time.Millisecond)
}
func TestSpeculaMatchingOverlap(t *testing.T) {
	f := newSpeculaFixture(t, "overlap", 2)
	blocked, writerRelease := f.c.arm("BeforeSignalReadersGate", 1)
	addDone := make(chan struct{})
	addErr := make(chan error, 1)
	go func() { defer close(addDone); addErr <- f.add(0, false) }()
	waitSpecula(t, blocked)
	snapshotBlocked, snapshotRelease := f.c.arm("GetTasksSnapshot", 1)
	f.c.gates[1] <- struct{}{}
	waitSpecula(t, snapshotBlocked)
	close(writerRelease)
	waitSpecula(t, addDone)
	require.NoError(t, <-addErr)
	require.NoError(t, f.add(1, false))
	firstBlocked, firstRelease := f.c.arm("BeforeRecordTaskStartedReply", 1)
	firstDone := make(chan struct{})
	go func() { defer close(firstDone); f.poll(1, false) }()
	waitSpecula(t, firstBlocked)
	f.poll(2, false)
	close(snapshotRelease)
	await.RequireTrue(t, func() bool { f.c.mu.Lock(); defer f.c.mu.Unlock(); return f.c.loopVisits[1] >= 2 }, 5*time.Second, time.Millisecond)
	close(firstRelease)
	waitSpecula(t, firstDone)
	f.gcWait(1, 1)
	gapBlocked, gapRelease := f.c.arm("BeforeGapGate", 1)
	f.c.gates[1] <- struct{}{}
	waitSpecula(t, gapBlocked)
	require.NoError(t, f.add(2, false))
	close(gapRelease)
	await.RequireTrue(t, func() bool { f.c.mu.Lock(); defer f.c.mu.Unlock(); return f.c.loopVisits[1] >= 3 }, 5*time.Second, time.Millisecond)
	f.poll(3, false)
	f.gcWait(1, 2)
	f.stop()
	f.reload()
	f.pump(2)
	f.stop()
	f.c.seal()
}
func TestSpeculaMatchingUncertain(t *testing.T) {
	f := newSpeculaFixture(t, "uncertain-write", 2)
	f.store.mu.Lock()
	f.store.loseCreate = true
	f.store.mu.Unlock()
	require.Error(t, f.add(0, false))
	require.NoError(t, f.add(0, true))
	f.pump(1)
	f.poll(1, false)
	// Duplicate start is rejected through Matching's actual TaskAlreadyStarted branch.
	ctx, cancel := context.WithTimeout(context.Background(), 250*time.Millisecond)
	defer cancel()
	_, err := f.s.matchingEngine.PollWorkflowTaskQueue(ctx, &matchingservice.PollWorkflowTaskQueueRequest{NamespaceId: f.namespace, PollRequest: &workflowservice.PollWorkflowTaskQueueRequest{Namespace: f.s.ns.Name().String(), TaskQueue: f.queue, Identity: "2"}}, metrics.NoopMetricsHandler)
	require.NoError(t, err)
	f.gcWait(1, 1)
	f.stop()
	f.reload()
	f.pump(2)
	f.stop()
	f.c.seal()
}
func TestSpeculaMatchingReplacement(t *testing.T) {
	f := newSpeculaFixture(t, "replacement", 2)
	require.NoError(t, f.add(0, false))
	f.historyMu.Lock()
	f.historyFaults = []error{&serviceerror.InvalidArgument{Message: "controlled nontransient History start rejection"}}
	f.historyMu.Unlock()
	f.poll(1, false)
	f.gcWait(1, 1)
	f.pump(1)
	f.stop()
	f.c.seal()
}

func (f *speculaFixture) replaceOwner() {
	old := f.s.matchingEngine
	f.s.matchingEngine = f.s.newMatchingEngine(old.config, old.taskManager, old.fairTaskManager)
	f.t.Cleanup(old.Stop)
	f.reload()
}
func (f *speculaFixture) pollEmpty(p int) {
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	_, err := f.s.matchingEngine.PollWorkflowTaskQueue(ctx, &matchingservice.PollWorkflowTaskQueueRequest{NamespaceId: f.namespace, PollRequest: &workflowservice.PollWorkflowTaskQueueRequest{Namespace: f.s.ns.Name().String(), TaskQueue: f.queue, Identity: strconv.Itoa(p)}}, metrics.NoopMetricsHandler)
	require.NoError(f.t, err)
}
func TestSpeculaMatchingUncertainReplacement(t *testing.T) {
	f := newSpeculaFixture(t, "uncertain-replacement", 2)
	require.NoError(t, f.add(0, false))
	f.historyMu.Lock()
	f.historyFaults = []error{&serviceerror.InvalidArgument{Message: "controlled nontransient History rejection"}}
	f.historyMu.Unlock()
	f.store.mu.Lock()
	f.store.loseCreate = true
	f.store.mu.Unlock()
	done := make(chan struct{})
	go func() { defer close(done); f.poll(1, false) }()
	await.RequireTrue(t, func() bool {
		f.c.mu.Lock()
		defer f.c.mu.Unlock()
		return len(f.c.catalog) == 3 && f.c.dispatch[0]["pc"] == "idle"
	}, 5*time.Second, time.Millisecond)
	f.pump(1)
	waitSpecula(t, done)
	f.gcWait(1, 1)
	f.pollEmpty(2)
	f.gcWait(1, 2)
	f.stop()
	f.c.seal()
}
func TestSpeculaMatchingReplacementFencing(t *testing.T) {
	f := newSpeculaFixture(t, "replacement-fencing", 2)
	require.NoError(t, f.add(0, false))
	f.historyMu.Lock()
	f.historyFaults = []error{&serviceerror.InvalidArgument{Message: "controlled nontransient History rejection"}}
	f.historyMu.Unlock()
	blocked, release := f.c.arm("CreateTasksStoreGate", 1)
	oldPollDone := make(chan struct{})
	go func() { defer close(oldPollDone); f.pollEmpty(1) }()
	waitSpecula(t, blocked)
	f.replaceOwner()
	close(release)
	waitSpecula(t, oldPollDone)
	f.pump(2)
	f.poll(2, false)
	f.stop()
	f.c.seal()
}
func TestSpeculaMatchingMetadataGC(t *testing.T) {
	f := newSpeculaFixture(t, "metadata-gc-takeover", 2)
	require.NoError(t, f.add(0, false))
	require.NoError(t, f.add(1, false))
	blocked, gcRelease := f.c.arm("GCStoreGate", 1)
	f.poll(1, false)
	f.poll(2, false)
	waitSpecula(t, blocked)
	old := f.pq.backlogMgr.(*priBacklogManagerImpl)
	metaBlocked, metaRelease := f.c.arm("UpdateTaskQueueStoreGate", 1)
	metaDone := make(chan struct{})
	metaErr := make(chan error, 1)
	go func() {
		defer close(metaDone)
		err := old.db.SyncState(context.Background())
		metaErr <- err
		old.signalIfFatal(err)
	}()
	waitSpecula(t, metaBlocked)
	f.replaceOwner()
	// Let the old unfenced delete finish under the new lease, then expose the stale metadata CAS.
	close(gcRelease)
	f.gcWait(1, 1)
	close(metaRelease)
	waitSpecula(t, metaDone)
	require.Error(t, <-metaErr)
	f.pump(2)
	f.stop()
	f.c.seal()
}
func TestSpeculaMatchingSyncLoss(t *testing.T) {
	f := newSpeculaFixture(t, "sync-worker-loss", 2)
	polled := make(chan struct{})
	go func() { defer close(polled); f.poll(1, true) }()
	await.RequireTrue(t, func() bool { return f.pq.HasPollerAfter(time.Time{}) }, 5*time.Second, time.Millisecond)
	blocked, release := f.c.arm("BeforeSyncReceiveGate", 1)
	addErr := make(chan error, 1)
	go func() { addErr <- f.add(0, true) }()
	waitSpecula(t, blocked)
	waitSpecula(t, polled)
	close(release)
	require.NoError(t, <-addErr)
	// Exercise the no-write final ownership verification branch.
	f.stop()
	f.c.seal()
}

func TestSpeculaMatchingExpiryRetained(t *testing.T) {
	f := newSpeculaFixture(t, "expiry-retained", 2)
	for _, r := range f.requests {
		r.ScheduleToStartTimeout = durationpb.New(100 * time.Millisecond)
	}
	require.NoError(t, f.add(0, false))
	require.NoError(t, f.add(1, false))
	f.stop()
	f.reload()
	f.c.expireWork(0)
	f.c.expireWork(1)
	f.pump(2)
	f.pump(2)
	f.stop()
	f.c.mu.Lock()
	f.c.readDurable()
	require.Len(t, f.c.durable["rows"], 2)
	f.c.mu.Unlock()
	f.c.seal()
}
func TestSpeculaMatchingExpiryGC(t *testing.T) {
	f := newSpeculaFixture(t, "expiry-matcher-gc", 2)
	for _, r := range f.requests {
		r.ScheduleToStartTimeout = durationpb.New(100 * time.Millisecond)
	}
	require.NoError(t, f.add(0, false))
	require.NoError(t, f.add(1, false))
	f.c.expireWork(0)
	f.c.expireWork(1)
	f.c.allowValidator()
	f.gcWait(1, 1)
	f.stop()
	f.c.seal()
}
func TestSpeculaMatchingHistoryLoss(t *testing.T) {
	f := newSpeculaFixture(t, "history-response-loss", 2)
	require.NoError(t, f.add(0, false))
	require.NoError(t, f.add(1, false))
	f.historyMu.Lock()
	f.lostHistory = true
	f.historyMu.Unlock()
	f.poll(1, false)
	f.pollEmpty(2)
	f.gcWait(1, 1)
	f.stop()
	f.c.seal()
}
func TestSpeculaMatchingStoreErrors(t *testing.T) {
	f := newSpeculaFixture(t, "store-errors", 4)
	f.store.mu.Lock()
	f.store.rejectCreate = true
	f.store.mu.Unlock()
	require.Error(t, f.add(0, false))
	require.NoError(t, f.add(0, false))
	require.NoError(t, f.add(1, false))
	f.store.mu.Lock()
	f.store.rejectMeta = true
	f.store.mu.Unlock()
	require.Error(t, f.pq.backlogMgr.getDB().SyncState(context.Background()))
	f.store.mu.Lock()
	f.store.loseMeta = true
	f.store.mu.Unlock()
	require.Error(t, f.pq.backlogMgr.getDB().SyncState(context.Background()))
	f.pump(1)
	f.store.mu.Lock()
	f.store.loseGC = true
	f.store.mu.Unlock()
	f.poll(1, false)
	f.gcWait(1, 1)
	f.poll(2, false)
	f.gcWait(1, 2)
	f.stop()
	f.c.seal()
}
func TestSpeculaMatchingAppendShutdown(t *testing.T) {
	f := newSpeculaFixture(t, "append-shutdown", 2)
	blocked, release := f.c.arm("CreateTasksStoreGate", 1)
	done := make(chan struct{})
	addErr := make(chan error, 1)
	go func() { defer close(done); addErr <- f.add(0, false) }()
	waitSpecula(t, blocked)
	f.replaceOwner()
	publishBlocked, publishRelease := f.c.arm("BeforeWriterPublishGate", 1)
	close(release)
	waitSpecula(t, publishBlocked)
	waitSpecula(t, done)
	require.Error(t, <-addErr)
	close(publishRelease)
	await.RequireTrue(t, func() bool { f.c.mu.Lock(); defer f.c.mu.Unlock(); return f.c.writer[0]["pc"] == "idle" }, 5*time.Second, time.Millisecond)
	f.pump(2)
	f.stop()
	f.c.seal()
}
func TestSpeculaMatchingInsertionAfterStop(t *testing.T) {
	f := newSpeculaFixture(t, "insertion-after-stop", 2)
	blocked, release := f.c.arm("BeforeSignalReadersGate", 1)
	done := make(chan struct{})
	addErr := make(chan error, 1)
	go func() { defer close(done); addErr <- f.add(0, false) }()
	waitSpecula(t, blocked)
	f.stop()
	waitSpecula(t, done)
	require.Error(t, <-addErr)
	close(release)
	await.RequireTrue(t, func() bool { f.c.mu.Lock(); defer f.c.mu.Unlock(); return f.c.writer[0]["pc"] == "idle" }, 5*time.Second, time.Millisecond)
	f.reload()
	f.pump(2)
	f.poll(1, false)
	f.stop()
	f.c.seal()
}

type speculaHistoryTransport struct {
	historyservice.HistoryServiceClient
	c *speculaObserver
}

func (s *speculaHistoryTransport) RecordWorkflowTaskStarted(ctx context.Context, req *historyservice.RecordWorkflowTaskStartedRequest, opts ...grpc.CallOption) (*historyservice.RecordWorkflowTaskStartedResponse, error) {
	s.c.retryObserved(req)
	return s.HistoryServiceClient.RecordWorkflowTaskStarted(ctx, req, opts...)
}
func TestSpeculaMatchingHistoryRPCRetry(t *testing.T) {
	f := newSpeculaFixture(t, "history-rpc-retry", 2)
	f.s.matchingEngine.historyClient = historyclient.NewRetryableClient(&speculaHistoryTransport{f.s.mockHistoryClient, f.c}, backoff.NewExponentialRetryPolicy(time.Millisecond).WithExpirationInterval(time.Second), common.IsServiceClientTransientError)
	require.NoError(t, f.add(0, false))
	require.NoError(t, f.add(1, false))
	f.historyMu.Lock()
	f.lostHistory = true
	f.historyMu.Unlock()
	f.poll(1, false)
	f.poll(2, false)
	f.gcWait(1, 1)
	f.stop()
	f.c.seal()
}

func TestSpeculaMatchingPrecheckCancel(t *testing.T) {
	f := newSpeculaFixture(t, "precheck-cancel", 2)
	require.NoError(t, f.add(0, false))
	require.NoError(t, f.add(1, false))
	f.s.matchingEngine.rateLimiter = quotas.NewRequestRateLimiterAdapter(quotas.NewRateLimiter(1, 1))
	require.True(t, f.s.matchingEngine.rateLimiter.Allow(time.Now(), quotas.Request{Token: 1}))
	blocked, release := f.c.arm("BeforeHistoryLimiterGate", 1)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	pollErr := make(chan error, 1)
	go func() {
		defer close(done)
		_, err := f.s.matchingEngine.PollWorkflowTaskQueue(ctx, &matchingservice.PollWorkflowTaskQueueRequest{NamespaceId: f.namespace, PollRequest: &workflowservice.PollWorkflowTaskQueueRequest{Namespace: f.s.ns.Name().String(), TaskQueue: f.queue, Identity: "1"}}, metrics.NoopMetricsHandler)
		pollErr <- err
	}()
	waitSpecula(t, blocked)
	cancel()
	close(release)
	waitSpecula(t, done)
	require.Error(t, <-pollErr)
	f.s.matchingEngine.rateLimiter = nil
	f.poll(2, false)
	f.poll(3, false)
	f.gcWait(1, 1)
	f.stop()
	f.c.seal()
}

func TestSpeculaMatchingRenewFailure(t *testing.T) {
	f := newSpeculaFixture(t, "renewal-fencing", 1)
	require.NoError(t, f.add(0, false))
	blocked, release := f.c.arm("BeforeRenewLeaseBegin", 1)
	addErr := make(chan error, 1)
	go func() { addErr <- f.add(1, false) }()
	waitSpecula(t, blocked)
	f.replaceOwner()
	close(release)
	require.Error(t, <-addErr)
	f.pump(2)
	f.poll(2, false)
	f.stop()
	f.c.seal()
}

func TestSpeculaMatchingRenewRetry(t *testing.T) {
	f := newSpeculaFixture(t, "renewal-retry", 1)
	require.NoError(t, f.add(0, false))
	f.poll(1, false)
	f.store.mu.Lock()
	f.store.rejectMeta = true
	f.store.mu.Unlock()
	require.NoError(t, f.add(1, false))
	f.poll(2, false)
	f.stop()
	f.c.seal()
}

func TestSpeculaMatchingBackoffWake(t *testing.T) {
	f := newSpeculaFixture(t, "backoff-write-wakeup", 2)
	f.store.mu.Lock()
	f.store.loseCreate = true
	f.store.rejectRead = true
	f.store.mu.Unlock()
	require.Error(t, f.add(0, false))
	blocked, release := f.c.arm("BeforeBackoffFireGate", 1)
	f.pump(1)
	waitSpecula(t, blocked)
	require.NoError(t, f.add(1, false))
	f.pump(1)
	f.poll(1, false)
	f.poll(2, false)
	close(release)
	f.stop()
	f.c.seal()
}

func TestSpeculaMatchingDefiniteReplacementRetry(t *testing.T) {
	f := newSpeculaFixture(t, "definite-replacement-retry", 2)
	require.NoError(t, f.add(0, false))
	f.historyMu.Lock()
	f.historyFaults = []error{&serviceerror.InvalidArgument{Message: "controlled nontransient rejection"}}
	f.historyMu.Unlock()
	f.store.mu.Lock()
	f.store.rejectCreate = true
	f.store.mu.Unlock()
	done := make(chan struct{})
	go func() { defer close(done); f.poll(1, false) }()
	await.RequireTrue(t, func() bool {
		f.c.mu.Lock()
		defer f.c.mu.Unlock()
		return len(f.c.catalog) == 3 && f.c.dispatch[0]["pc"] == "idle"
	}, 5*time.Second, time.Millisecond)
	f.pump(1)
	waitSpecula(t, done)
	f.gcWait(1, 1)
	f.stop()
	f.c.seal()
}

func (f *speculaFixture) enableValidationTrace() {
	f.c.mu.Lock()
	defer f.c.mu.Unlock()
	f.c.validationMode = true
	for range f.c.owner {
		f.c.validationHolds = append(f.c.validationHolds, smap{"poller": 0, "id": int64(0), "cancelled": false})
	}
}
func TestSpeculaMatchingValidatorRequeue(t *testing.T) {
	f := newSpeculaFixture(t, "validator-requeue", 2)
	f.enableValidationTrace()
	require.NoError(t, f.add(0, false))
	f.c.allowValidator()
	await.RequireTrue(t, func() bool { f.c.mu.Lock(); defer f.c.mu.Unlock(); return f.c.validationCycles > 0 }, 5*time.Second, time.Millisecond)
	f.poll(1, false)
	f.stop()
	f.c.seal()
}
func TestSpeculaMatchingValidatorObsolete(t *testing.T) {
	f := newSpeculaFixture(t, "validator-obsolete", 2)
	f.enableValidationTrace()
	require.NoError(t, f.add(0, false))
	created := time.Now()
	f.historyMu.Lock()
	f.validationInvalid = true
	f.historyMu.Unlock()
	// Exercise the real age guard; do not manufacture a past validator state.
	await.RequireTrue(t, func() bool { return time.Since(created) > taskReaderValidationThreshold }, taskReaderValidationThreshold+10*time.Second, time.Second)
	f.c.allowValidator()
	await.RequireTrue(t, func() bool {
		f.c.mu.Lock()
		defer f.c.mu.Unlock()
		return f.c.history[f.c.config["work"].([]string)[0]].(smap)["obsolete"].(bool) && f.c.validationHolds[0]["poller"] == 0
	}, 30*time.Second, time.Millisecond)
	f.historyMu.Lock()
	require.Positive(t, f.validationQueries)
	evidence, err := json.MarshalIndent(f.validityEvidence, "", "  ")
	f.historyMu.Unlock()
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(f.c.file.Name()+".validity-evidence.json", evidence, 0644))
	f.stop()
	f.c.seal()
}

func TestSpeculaMatchingAcquisitionRetry(t *testing.T) {
	f := newSpeculaFixture(t, "acquisition-retry", 2)
	require.NoError(t, f.add(0, false))
	f.store.mu.Lock()
	f.store.rejectMeta = true
	f.store.mu.Unlock()
	f.replaceOwner()
	f.pump(2)
	f.poll(2, false)
	f.stop()
	f.c.seal()
}

func TestSpeculaMatchingValidatorCancel(t *testing.T) {
	f := newSpeculaFixture(t, "validator-cancel", 2)
	f.enableValidationTrace()
	require.NoError(t, f.add(0, false))
	f.stop()
	f.c.allowValidator()
	await.RequireTrue(t, func() bool { f.c.mu.Lock(); defer f.c.mu.Unlock(); return f.c.validationCycles > 0 }, 5*time.Second, time.Millisecond)
	f.c.seal()
}
