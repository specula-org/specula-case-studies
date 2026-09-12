package matching

import (
	"context"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
	commonpb "go.temporal.io/api/common/v1"
	enumspb "go.temporal.io/api/enums/v1"
	"go.temporal.io/api/serviceerror"
	persistencespb "go.temporal.io/server/api/persistence/v1"
	"go.temporal.io/server/common/config"
	"go.temporal.io/server/common/dynamicconfig"
	"go.temporal.io/server/common/metrics"
	"go.temporal.io/server/common/persistence"
	"go.temporal.io/server/common/persistence/serialization"
	sqlstore "go.temporal.io/server/common/persistence/sql"
	"go.temporal.io/server/common/resolver"
	"go.temporal.io/server/common/testing/await"
	"go.temporal.io/server/common/testing/testlogger"
	"go.temporal.io/server/common/tqid"
	"go.temporal.io/server/service/matching/counter"
	"go.uber.org/mock/gomock"
	"google.golang.org/protobuf/types/known/timestamppb"
)

type speculaFairReadGate struct {
	persistence.TaskStore
	hold    atomic.Bool
	entered chan struct{}
	release chan struct{}
}

func (s *speculaFairReadGate) GetTasks(ctx context.Context, r *persistence.GetTasksRequest) (*persistence.InternalGetTasksResponse, error) {
	if s.hold.Load() {
		select {
		case s.entered <- struct{}{}:
		default:
		}
		select {
		case <-s.release:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return s.TaskStore.GetTasks(ctx, r)
}

// This diagnostic exercises real fair reader/writer and SQLite V2 persistence.
// The physical matcher and History completion results are controlled interfaces.
func TestSpeculaFairLateCompletionSQLite(t *testing.T) {
	path := os.Getenv("SPECULA_FAIR_EVIDENCE")
	control := os.Getenv("SPECULA_FAIR_CONTROL") == "1"
	if path == "" {
		t.Skip("set SPECULA_FAIR_EVIDENCE to run the fairness diagnostic")
	}
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0755))
	logger := testlogger.NewTestLogger(t, testlogger.FailOnAnyUnexpectedError)
	logger.Expect(testlogger.Error, "loadedTasks went negative")
	serializer := serialization.NewSerializer()
	dbfile := path + "-" + uuid.NewString() + ".sqlite"
	factory := sqlstore.NewFactory(config.SQL{PluginName: "sqlite", DatabaseName: dbfile, TaskScanPartitions: 1,
		ConnectAttributes: map[string]string{"setup": "true", "journal_mode": "wal", "synchronous": "full", "busy_timeout": "10000"}}, resolver.NewNoopResolver(), "active", logger, metrics.NoopMetricsHandler, serializer)
	defer factory.Close()
	store, err := factory.NewFairTaskStore()
	require.NoError(t, err)
	gated := &speculaFairReadGate{TaskStore: store, entered: make(chan struct{}, 1), release: make(chan struct{})}
	raw := persistence.NewTaskManager(store, serializer)
	manager := persistence.NewTaskManager(gated, serializer)
	namespaceID := uuid.NewString()
	family, err := tqid.NewTaskQueueFamily(namespaceID, "specula-fair-late-completion")
	require.NoError(t, err)
	partition := family.TaskQueue(enumspb.TASK_QUEUE_TYPE_WORKFLOW).NormalPartition(0)
	key := UnversionedQueueKey(partition)
	dc := dynamicconfig.NewMemoryClient()
	dc.OverrideValue(dynamicconfig.MatchingEnableFairness.Key(), true)
	tc := newTaskQueueConfig(partition.TaskQueue(), NewConfig(dynamicconfig.NewCollection(dc, logger)), "fair-diagnostic")
	tc.RangeSize = 16
	tc.GetTasksBatchSize = func() int { return 3 }
	tc.GetTasksReloadAt = func() int { return 0 }
	tc.MaxTaskBatchSize = func() int { return 1 }
	tc.MaxTaskDeleteBatchSize = func() int { return 100 }
	tc.TaskDeleteInterval = func() time.Duration { return time.Hour }
	tc.UpdateAckInterval = func() time.Duration { return time.Hour }
	tc.FairnessPassDither = func() bool { return false }
	ctrl := gomock.NewController(t)
	pq := NewMockphysicalTaskQueueManager(ctrl)
	pq.EXPECT().QueueKey().Return(key).AnyTimes()
	pq.EXPECT().ProcessSpooledTask(gomock.Any(), gomock.Any()).Return(nil).AnyTimes()
	pq.EXPECT().GetFairnessWeightOverrides().Return(fairnessWeightOverrides{}).AnyTimes()
	pq.EXPECT().StartScaleManager(gomock.Any()).AnyTimes()
	pq.EXPECT().SetupDraining().AnyTimes()
	var captureMu sync.Mutex
	captured := map[string]*internalTask{}
	pq.EXPECT().AddSpooledTask(gomock.Any()).DoAndReturn(func(task *internalTask) error {
		captureMu.Lock()
		defer captureMu.Unlock()
		captured[task.event.Data.WorkflowId] = task
		return nil
	}).AnyTimes()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	b := newFairBacklogManager(ctx, pq, tc, manager, logger, logger, nil, metrics.NoopMetricsHandler, func() counter.Counter { return counter.NewMapCounter(1000) }, false)
	defer b.Stop()
	b.Start()
	require.NoError(t, b.WaitUntilInitialized(ctx))
	var tr *fairTaskReader
	b.subqueueLock.Lock()
	tr = b.subqueues[0]
	b.subqueueLock.Unlock()
	await.RequireTrue(t, func() bool { tr.lock.Lock(); defer tr.lock.Unlock(); return tr.atEnd && !tr.readPending }, 5*time.Second, time.Millisecond)
	task := func(name, key string) *persistencespb.TaskInfo {
		return &persistencespb.TaskInfo{NamespaceId: namespaceID, WorkflowId: name, RunId: uuid.NewString(), ScheduledEventId: 1,
			CreateTime: timestamppb.Now(), ExpiryTime: timestamppb.New(time.Now().Add(time.Hour)), Priority: &commonpb.Priority{PriorityKey: 3, FairnessKey: key, FairnessWeight: 1}}
	}
	get := func(name string) *internalTask { captureMu.Lock(); defer captureMu.Unlock(); return captured[name] }
	infos := map[string]*persistencespb.TaskInfo{}
	for _, name := range []string{"A", "B", "C"} {
		infos[name] = task(name, "shared")
		require.NoError(t, b.SpoolTask(infos[name]))
	}
	require.NotNil(t, get("A"))
	require.NotNil(t, get("B"))
	require.NotNil(t, get("C"))
	snapshots := []smap{}
	snapshot := func(label string) {
		tr.lock.Lock()
		defer tr.lock.Unlock()
		entries := []smap{}
		live := 0
		tr.outstandingTasks.Scan(func(e outstandingTask) bool {
			if e.task != nil {
				live++
			}
			entries = append(entries, smap{"pass": e.level.pass, "id": e.level.id, "acked": e.acked()})
			return true
		})
		snapshots = append(snapshots, smap{"event": label, "loaded": tr.loadedTasks, "live": live, "entries": entries, "ack": smap{"pass": tr.ackLevel.pass, "id": tr.ackLevel.id}, "read": smap{"pass": tr.readLevel.pass, "id": tr.readLevel.id}, "readPending": tr.readPending, "pin": tr.ackLevelPinnedByWriter, "bufferedWrites": len(tr.newlyWrittenTasks)})
	}
	snapshot("ABC-persisted-and-dispatched")
	blocked, release := make(chan struct{}), make(chan struct{})
	speculaCallbacks.Store(&speculaTraceCallbacks{owner: func(*taskQueueDB) int { return 0 }, probe: func(point string, args ...any) {
		if point == "FairRespoolGate" && args[1].(*persistencespb.TaskInfo) == infos["C"] {
			close(blocked)
			select {
			case <-release:
			case <-ctx.Done():
			}
		}
	}})
	defer speculaCallbacks.Store(nil)
	cdone := make(chan struct{})
	go func() {
		defer close(cdone)
		get("C").finish(taskFinishResult{err: &serviceerror.ResourceExhausted{Cause: enumspb.RESOURCE_EXHAUSTED_CAUSE_RPS_LIMIT, Scope: enumspb.RESOURCE_EXHAUSTED_SCOPE_NAMESPACE, Message: "controlled History namespace RPS rejection"}, consumedToken: true})
	}()
	waitSpecula(t, blocked)
	snapshot("C-callback-unlocked")
	if control {
		close(release)
		waitSpecula(t, cdone)
		snapshot("C-completed-before-merge")
	}
	for _, name := range []string{"Y", "Z"} {
		infos[name] = task(name, name)
		require.NoError(t, b.SpoolTask(infos[name]))
	}
	snapshot("YZ-evicted-BC")
	tr.lock.Lock()
	_, bPresent := tr.outstandingTasks.Get(outstandingTask{level: get("B").fairLevel()})
	_, cPresent := tr.outstandingTasks.Get(outstandingTask{level: get("C").fairLevel()})
	tr.lock.Unlock()
	require.False(t, bPresent)
	require.False(t, cPresent)
	get("B").finish(taskFinishResult{err: &serviceerror.ResourceExhausted{Cause: enumspb.RESOURCE_EXHAUSTED_CAUSE_RPS_LIMIT, Scope: enumspb.RESOURCE_EXHAUSTED_SCOPE_NAMESPACE, Message: "independently rejected before History start"}, consumedToken: true})
	gated.hold.Store(true)
	if !control {
		close(release)
		waitSpecula(t, cdone)
	}
	snapshot("C-completion-and-merge-settled")
	afterC := snapshots[len(snapshots)-1]
	if control {
		require.Equal(t, afterC["loaded"], afterC["live"])
	} else {
		require.NotEqual(t, afterC["loaded"], afterC["live"], "candidate not reproduced")
	}
	for _, name := range []string{"A", "Y", "Z"} {
		get(name).finish(taskFinishResult{consumedToken: true})
		snapshot("complete-" + name)
	}
	waitSpecula(t, gated.entered)
	require.NoError(t, b.db.SyncState(ctx))
	info, err := raw.GetTaskQueue(ctx, &persistence.GetTaskQueueRequest{NamespaceID: namespaceID, TaskQueue: key.PersistenceName(), TaskType: key.TaskType()})
	require.NoError(t, err)
	persisted := fairLevelFromProto(info.TaskQueueInfo.Subqueues[0].FairAckLevel)
	bLevel := get("B").fairLevel()
	if control {
		require.True(t, persisted.less(bLevel), "control skipped B")
	} else {
		require.False(t, persisted.less(bLevel), "ack did not cross B")
	}
	request := &persistence.GetTasksRequest{NamespaceID: namespaceID, TaskQueue: key.PersistenceName(), TaskType: key.TaskType(), Subqueue: 0, InclusiveMinPass: 1, PageSize: 100, ExclusiveMaxTaskID: math.MaxInt64, UseLimit: true}
	all, err := raw.GetTasks(ctx, request)
	require.NoError(t, err)
	storeRows := []smap{}
	bRows := 0
	for _, r := range all.Tasks {
		storeRows = append(storeRows, smap{"id": r.TaskId, "pass": r.TaskPass, "work": r.Data.WorkflowId, "namespace": r.Data.NamespaceId, "run": r.Data.RunId, "event": r.Data.ScheduledEventId, "stamp": r.Data.Stamp})
		if r.Data.WorkflowId == "B" {
			bRows++
		}
	}
	require.Equal(t, 1, bRows)
	request.InclusiveMinPass = persisted.pass
	request.InclusiveMinTaskID = persisted.id + 1
	replay, err := raw.GetTasks(ctx, request)
	require.NoError(t, err)
	replayRows := []smap{}
	bOnReplay := false
	for _, r := range replay.Tasks {
		bOnReplay = bOnReplay || r.Data.WorkflowId == "B"
		replayRows = append(replayRows, smap{"id": r.TaskId, "pass": r.TaskPass, "work": r.Data.WorkflowId, "namespace": r.Data.NamespaceId, "run": r.Data.RunId, "event": r.Data.ScheduledEventId, "stamp": r.Data.Stamp})
	}
	require.Equal(t, control, bOnReplay)
	report := smap{"revision": "0c010ce5fe8c0180aa7573c72fe8fc87c6df7025", "backend": "file-backed SQLite SQL TaskStore V2", "database": dbfile, "fairness": true, "priority": 3, "batch": 3, "reloadAt": 0, "writeBatch": 1, "counter": "exact map 1000", "dither": false, "accepted": []string{"A", "B", "C", "Y", "Z"}, "historyAccepted": []string{"A", "Y", "Z"}, "BEligible": true, "snapshots": snapshots, "durableAck": smap{"pass": persisted.pass, "id": persisted.id}, "BLevel": smap{"pass": bLevel.pass, "id": bLevel.id}, "storeRows": storeRows, "restartRead": replayRows, "reproduced": !control, "controlWindowClosed": control, "historyError": "namespace RPS ResourceExhausted, definite no-start in controlled interface", "limits": "controlled matcher and History-result interfaces; no full public API or independent Phase 4 confirmation"}
	data, err := json.MarshalIndent(report, "", "  ")
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(path, data, 0644))
	close(gated.release)
	await.RequireTrue(t, func() bool { tr.lock.Lock(); defer tr.lock.Unlock(); return !tr.readPending }, 5*time.Second, time.Millisecond)
}
