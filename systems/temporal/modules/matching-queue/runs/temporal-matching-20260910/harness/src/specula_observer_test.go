package matching

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	enumspb "go.temporal.io/api/enums/v1"
	"go.temporal.io/api/serviceerror"
	"go.temporal.io/server/api/historyservice/v1"
	persistencespb "go.temporal.io/server/api/persistence/v1"
	"go.temporal.io/server/common"
	"go.temporal.io/server/common/persistence"
	"go.temporal.io/server/common/persistence/serialization"
	sqlstore "go.temporal.io/server/common/persistence/sql"
	"go.temporal.io/server/common/persistence/sql/sqlplugin"
	serviceerrors "go.temporal.io/server/common/serviceerror"
	"go.temporal.io/server/common/testing/await"
	"go.temporal.io/server/common/tqid"
)

type smap = map[string]any

func emptyInts() []int64 { return []int64{} }
func idleWriter() smap {
	return smap{"pc": "idle", "work": "none", "call": 0, "poller": 0, "parent": int64(0), "id": int64(0), "range": int64(0), "before": int64(0), "outcome": "none", "reply": "none"}
}
func idleReader() smap {
	return smap{"pc": "idle", "low": int64(0), "max": int64(0), "upper": int64(0), "scans": 0, "rows": emptyInts(), "todo": emptyInts()}
}
func idleMetadata() smap {
	return smap{"pc": "idle", "kind": "none", "expect": int64(0), "newRange": int64(0), "ack": int64(0), "outcome": "none"}
}
func idleDispatch() smap {
	return smap{"pc": "idle", "owner": 1, "id": int64(0), "call": 0, "work": "none", "request": 0, "result": "none", "reply": "none", "replacement": int64(0), "appendReply": "none"}
}
func idleCall() smap {
	return smap{"pc": "unused", "owner": 1, "work": "none", "buffer": "none", "response": "none", "receipt": "none"}
}
func emptyOwner(size int64) smap {
	return smap{"life": "cold", "range": int64(0), "nextId": int64(1), "endId": size,
		"read": int64(0), "ack": int64(0), "cachedAck": int64(0), "maxRead": int64(0), "loaded": 0,
		"outstanding": emptyInts(), "done": emptyInts(), "adding": emptyInts(), "queued": emptyInts(),
		"appendQueue": []smap{}, "notify": false, "readerLock": "free", "cacheRead": int64(0), "cachePoller": 0, "backoff": false,
		"skipFinal": false, "dirty": false, "stopStep": "none", "gcPC": "idle", "gcBound": int64(0), "gcLast": int64(0), "gcCount": 0}
}
func workKey(t *persistencespb.TaskInfo, taskType enumspb.TaskQueueType) string {
	b, err := json.Marshal([]any{t.NamespaceId, t.WorkflowId, t.RunId, taskType.String(), t.ScheduledEventId, t.Stamp})
	if err != nil {
		panic(err)
	}
	return string(b)
}
func historyKey(r *historyservice.RecordWorkflowTaskStartedRequest) string {
	return workKey(&persistencespb.TaskInfo{NamespaceId: r.NamespaceId, WorkflowId: r.WorkflowExecution.WorkflowId,
		RunId: r.WorkflowExecution.RunId, ScheduledEventId: r.ScheduledEventId, Stamp: r.Stamp}, enumspb.TASK_QUEUE_TYPE_WORKFLOW)
}
func ids(ts []*persistencespb.AllocatedTaskInfo) []int64 {
	a := emptyInts()
	for _, t := range ts {
		a = append(a, t.TaskId)
	}
	return a
}
func addIDs(a []int64, b ...int64) []int64 {
	for _, v := range b {
		if !slices.Contains(a, v) {
			a = append(a, v)
		}
	}
	slices.Sort(a)
	return a
}
func removeID(a []int64, id int64) []int64 {
	return slices.DeleteFunc(a, func(v int64) bool { return v == id })
}

type speculaObserver struct {
	validationMode                                   bool
	validationHolds                                  []smap
	validationCycles                                 int
	mu                                               sync.Mutex
	changed                                          *sync.Cond
	t                                                *testing.T
	file                                             *os.File
	raw                                              *os.File
	seq                                              int
	enabled                                          bool
	ended                                            bool
	dbs                                              map[*taskQueueDB]int
	mgrs                                             map[int]*priBacklogManagerImpl
	readers                                          map[int]*priTaskReader
	gates                                            map[int]chan struct{}
	validators                                       map[*priTaskMatcher]chan struct{}
	loopVisits                                       map[int]int
	readerExited                                     map[int]bool
	owner, writer, reader, metadata, dispatch, calls []smap
	history                                          smap
	catalog                                          []smap
	durable                                          smap
	queue                                            smap
	config                                           smap
	postKeys                                         map[string][]string
	callByInfo                                       map[*persistencespb.TaskInfo]int
	reqCalls                                         map[*writeTaskRequest]int
	reqPoller                                        map[*writeTaskRequest]int
	published                                        map[*writeTaskRequest]bool
	tasks                                            map[*internalTask]int
	pollByTask                                       map[*internalTask]int
	respool                                          map[*persistencespb.TaskInfo]*internalTask
	startAliases                                     map[string]int
	sqlDB                                            *sql.DB
	sqlPath                                          string
	serializer                                       serialization.Serializer
	condition                                        map[int][2]int64
	gcLaunch                                         map[int]bool
	gcReady                                          map[int]bool
	gcFinished                                       map[int]int
	snapshots                                        int
	gatePoint                                        string
	gateOwner                                        int
	blocked                                          chan struct{}
	release                                          chan struct{}
}

func newObserver(t *testing.T, path string, nwork []string, size int64) *speculaObserver {
	require.NoError(t, os.MkdirAll(filepath.Dir(path), 0755))
	f, err := os.Create(path)
	require.NoError(t, err)
	raw, err := os.Create(path + ".observations.jsonl")
	require.NoError(t, err)
	c := &speculaObserver{t: t, file: f, raw: raw, dbs: map[*taskQueueDB]int{}, mgrs: map[int]*priBacklogManagerImpl{}, readers: map[int]*priTaskReader{},
		gates: map[int]chan struct{}{}, validators: map[*priTaskMatcher]chan struct{}{}, loopVisits: map[int]int{}, readerExited: map[int]bool{}, callByInfo: map[*persistencespb.TaskInfo]int{}, reqCalls: map[*writeTaskRequest]int{},
		reqPoller: map[*writeTaskRequest]int{}, published: map[*writeTaskRequest]bool{}, tasks: map[*internalTask]int{}, pollByTask: map[*internalTask]int{},
		respool: map[*persistencespb.TaskInfo]*internalTask{}, startAliases: map[string]int{}, condition: map[int][2]int64{},
		gcLaunch: map[int]bool{}, gcReady: map[int]bool{}, gcFinished: map[int]int{}, history: smap{}, catalog: []smap{},
		durable: smap{"range": int64(1), "ack": int64(0), "rows": emptyInts()}, postKeys: map[string][]string{}, serializer: serialization.NewSerializer()}
	c.changed = sync.NewCond(&c.mu)
	for range 3 {
		c.owner = append(c.owner, emptyOwner(size))
		c.writer = append(c.writer, idleWriter())
		c.reader = append(c.reader, idleReader())
		c.metadata = append(c.metadata, idleMetadata())
	}
	for range 8 {
		c.dispatch = append(c.dispatch, idleDispatch())
	}
	for range 16 {
		c.calls = append(c.calls, idleCall())
	}
	for _, w := range nwork {
		c.history[w] = smap{"start": 0, "expired": false, "obsolete": false, "worker": false}
	}
	c.config = smap{"backend": "sqlite-v1", "useNewMatcher": true, "enableFairness": false, "priority": 3, "writeBatchSize": 1,
		"owners": []int{1, 2, 3}, "work": nwork, "callIds": []int{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16},
		"pollers": []int{1, 2, 3, 4, 5, 6, 7, 8}, "startIds": []int{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32},
		"initialOwner": 1, "rangeSize": size, "batchSize": 3, "reloadAt": 1, "deleteBatchSize": 2}
	b, err := os.ReadFile(filepath.Join(os.Getenv("SPECULA_HARNESS"), "post-keys.json"))
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal(b, &c.postKeys))
	return c
}
func (c *speculaObserver) all() smap {
	all := smap{"durable": c.durable, "catalog": c.catalog, "owner": c.owner, "writer": c.writer, "reader": c.reader, "metadata": c.metadata, "dispatch": c.dispatch, "calls": c.calls, "history": c.history}
	if c.validationMode {
		all["validationHolds"] = c.validationHolds
	}
	return all
}

func (c *speculaObserver) write(v any) {
	if err := json.NewEncoder(c.file).Encode(smap{"tag": "trace", "ts": time.Now().UTC().Format(time.RFC3339Nano), "record": v}); err != nil {
		panic(err)
	}
}
func (c *speculaObserver) emit(event string, o int, args smap, q smap) {
	if !c.enabled || c.ended {
		return
	}
	keys, ok := c.postKeys[event]
	if !ok {
		panic("unknown event " + event)
	}
	if c.validationMode && event == "TraceEnd" {
		keys = append(append([]string{}, keys...), "validationHolds")
	}
	post := smap{}
	all := c.all()
	for _, k := range keys {
		post[k] = all[k]
	}
	if err := json.NewEncoder(c.raw).Encode(smap{"tag": "trace", "ts": time.Now().UTC().Format(time.RFC3339Nano), "event": event, "owner": o, "queue": q, "args": args}); err != nil {
		panic(err)
	}
	c.seq++
	c.write(smap{"tag": "temporal-matching", "seq": c.seq, "event": event, "node": o, "queue": q, "args": args, "post": post})
	c.changed.Broadcast()
}
func taskTypeName(t enumspb.TaskQueueType) string {
	switch t {
	case enumspb.TASK_QUEUE_TYPE_WORKFLOW:
		return "workflow"
	case enumspb.TASK_QUEUE_TYPE_ACTIVITY:
		return "activity"
	default:
		return t.String()
	}
}
func queueKey(q *PhysicalTaskQueueKey) smap {
	return smap{"namespace": q.NamespaceId(), "physicalName": q.PersistenceName(), "partition": q.Partition().(*tqid.NormalPartition).PartitionId(), "subqueue": 0, "taskType": taskTypeName(q.TaskType())}
}
func (c *speculaObserver) q(o int) smap { return queueKey(c.mgrs[o].queueKey()) }
func (c *speculaObserver) ownerID(db *taskQueueDB) int {
	c.mu.Lock()
	defer c.mu.Unlock()
	if db.isDraining {
		return 0
	}
	if o := c.dbs[db]; o != 0 {
		return o
	}
	o := len(c.dbs) + 1
	if o > len(c.owner) {
		panic("owner pool exhausted")
	}
	c.dbs[db] = o
	c.gates[o] = make(chan struct{}, 100)
	return o
}
func (c *speculaObserver) snapDB(db *taskQueueDB, o int) {
	if len(db.subqueues) == 0 {
		return
	}
	s := c.owner[o-1]
	s["range"] = db.rangeID
	s["cachedAck"] = db.subqueues[0].AckLevel
	s["maxRead"] = db.subqueues[0].maxReadLevel
	s["dirty"] = db.lastChange.After(db.lastWrite)
}
func (c *speculaObserver) snapReader(tr *priTaskReader, o int) {
	s := c.owner[o-1]
	s["read"] = tr.readLevel
	s["ack"] = tr.ackLevel
	s["loaded"] = tr.loadedTasks
	outstanding, done := emptyInts(), emptyInts()
	it := tr.outstandingTasks.Iterator()
	for it.Next() {
		id := it.Key().(int64)
		outstanding = append(outstanding, id)
		if it.Value().(bool) {
			done = append(done, id)
		}
	}
	s["outstanding"] = outstanding
	s["done"] = done
	s["gcLast"] = tr.gcAckLevel
	s["backoff"] = tr.backoffTimer != nil
}
func (c *speculaObserver) waitGate(point string, o int) {
	c.mu.Lock()
	if c.gatePoint != point || c.gateOwner != o {
		c.mu.Unlock()
		return
	}
	ch := c.release
	c.gatePoint = ""
	close(c.blocked)
	c.mu.Unlock()
	select {
	case <-ch:
	case <-time.After(30 * time.Second):
		panic("schedule gate timed out: " + point)
	}
}
func (c *speculaObserver) arm(point string, o int) (<-chan struct{}, chan<- struct{}) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.gatePoint = point
	c.gateOwner = o
	c.blocked = make(chan struct{})
	c.release = make(chan struct{})
	return c.blocked, c.release
}
func replyClass(err error) string {
	if err == nil {
		return "ok"
	}
	if _, ok := err.(*persistence.ConditionFailedError); ok {
		return "condition"
	}
	if writeDefinitelyFailed(err) {
		return "definite"
	}
	return "unknown"
}
func (c *speculaObserver) probe(point string, a ...any) {
	if point == "ValidatorGate" {
		tm := a[0].(*priTaskMatcher)
		ch := make(chan struct{})
		c.mu.Lock()
		c.validators[tm] = ch
		c.mu.Unlock()
		<-ch
		return
	}
	var o int
	switch v := a[0].(type) {
	case *priTaskWriter:
		o = c.ownerID(v.db)
	case *priTaskReader:
		o = c.ownerID(v.backlogMgr.db)
	case *priBacklogManagerImpl:
		o = c.ownerID(v.db)
	case *taskQueueDB:
		o = c.ownerID(v)
	case *physicalTaskQueueManagerImpl:
		if b, ok := v.backlogMgr.(*priBacklogManagerImpl); ok {
			o = c.ownerID(b.db)
		}
	case *internalTask:
		c.mu.Lock()
		o = c.tasks[v]
		if o == 0 && v.event != nil {
			if id := c.callByInfo[v.event.Data]; id != 0 {
				o = c.calls[id-1]["owner"].(int)
			}
		}
		c.mu.Unlock()
	default:
		panic(fmt.Sprintf("unsupported trace source %T", a[0]))
	}
	if o == 0 {
		return
	}
	if point == "ReaderLoopGate" {
		tr := a[0].(*priTaskReader)
		c.mu.Lock()
		c.readers[o] = tr
		c.loopVisits[o]++
		c.changed.Broadcast()
		ch := c.gates[o]
		c.mu.Unlock()
		select {
		case <-ch:
		case <-tr.backlogMgr.tqCtx.Done():
		}
		return
	}
	if point == "GCStoreGate" {
		c.mu.Lock()
		for !c.gcReady[o] && !c.ended {
			c.changed.Wait()
		}
		c.mu.Unlock()
		c.waitGate(point, o)
		return
	}
	c.waitGate("Before"+point, o)
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ended {
		return
	}
	ow, w, r, m := c.owner[o-1], c.writer[o-1], c.reader[o-1], c.metadata[o-1]
	event := point
	args := smap{"o": o}
	q := c.qIfKnown(o)
	switch point {
	case "ReaderExited":
		c.readerExited[o] = true
		c.changed.Broadcast()
		return
	case "SignalReadersGate", "GapGate", "WriterPublishGate", "HistoryLimiterGate", "MetadataLocalUpdated", "SyncReceiveGate", "BackoffFireGate":
		return
	case "RenewLeaseBegin":
		db := a[0].(*taskQueueDB)
		if !c.enabled {
			return
		}
		if db.rangeID == 0 {
			ow["life"] = "acquiring"
			m = idleMetadata()
			m["pc"] = "read"
			m["kind"] = "takeover"
			event = "TakeOverTaskQueueBegin"
		} else {
			m = idleMetadata()
			m["pc"] = "store"
			m["kind"] = "renew"
			m["expect"] = db.rangeID
			m["newRange"] = db.rangeID + 1
			m["ack"] = db.subqueues[0].AckLevel
		}
		c.metadata[o-1] = m
		q = queueKey(db.queue)
	case "TakeOverTaskQueueSnapshot":
		if !c.enabled {
			return
		}
		resp := a[1].(*persistence.GetTaskQueueResponse)
		m["pc"] = "store"
		m["expect"] = resp.RangeID
		m["newRange"] = resp.RangeID + 1
		ack := resp.TaskQueueInfo.AckLevel
		if len(resp.TaskQueueInfo.Subqueues) > 0 {
			ack = resp.TaskQueueInfo.Subqueues[0].AckLevel
		}
		m["ack"] = ack
		q = queueKey(a[0].(*taskQueueDB).queue)
	case "OwnerInitialized":
		tw := a[0].(*priTaskWriter)
		for c.loopVisits[o] == 0 {
			c.changed.Wait()
		}
		c.mgrs[o] = tw.backlogMgr
		q = c.q(o)
		c.snapDB(tw.db, o)
		ow["nextId"] = tw.taskIDBlock.start
		ow["endId"] = tw.taskIDBlock.end
		ow["life"] = "ready"
		if len(tw.backlogMgr.subqueues) > 0 {
			tr := tw.backlogMgr.subqueues[0]
			c.readers[o] = tr
			ow["notify"] = len(tr.notifyC) > 0
			c.snapReader(tr, o)
		}
		c.metadata[o-1] = idleMetadata()
		event = "UpdateTaskQueueReturn"
		if o == 1 {
			return
		}
	case "RenewLeaseAttempt":
		if w["pc"] != "renewError" {
			return
		}
		w["pc"] = "assign"
		w["reply"] = "none"
		event = "RenewLeaseRetry"
	case "RenewLeaseErrorReturn":
		if !c.enabled {
			return
		}
		if m["kind"] == "takeover" {
			ow["life"] = "cold"
			c.metadata[o-1] = idleMetadata()
			event = "UpdateTaskQueueReturn"
			break
		}
		if m["kind"] != "renew" {
			return
		}
		w["pc"] = "renewError"
		w["reply"] = "unknown"
		if m["outcome"] == "condition" {
			w["reply"] = "condition"
			ow["life"] = "unload"
		}
		c.metadata[o-1] = idleMetadata()
		event = "UpdateTaskQueueReturn"
	case "RenewLeaseFailure":
		w["pc"] = "publish"
	case "LeaseBlockReturned":
		tw := a[0].(*priTaskWriter)
		c.snapDB(tw.db, o)
		ow["nextId"] = tw.taskIDBlock.start
		ow["endId"] = tw.taskIDBlock.end
		c.metadata[o-1] = idleMetadata()
		event = "UpdateTaskQueueReturn"
	case "AddTask":
		info := a[1].(*persistencespb.TaskInfo)
		id := 0
		for i, s := range c.calls {
			if s["pc"] == "unused" {
				id = i + 1
				break
			}
		}
		if id == 0 {
			panic("call pool exhausted")
		}
		key := workKey(info, enumspb.TASK_QUEUE_TYPE_WORKFLOW)
		c.callByInfo[info] = id
		call := idleCall()
		call["pc"] = "offer"
		call["owner"] = o
		call["work"] = key
		c.calls[id-1] = call
		args = smap{"a": id, "w": key, "o": o}
	case "TrySyncMatchFallback":
		id := c.callByInfo[a[1].(*persistencespb.TaskInfo)]
		c.calls[id-1]["pc"] = "spool"
		args = smap{"a": id}
	case "SpoolTask":
		req := a[1].(*writeTaskRequest)
		id := c.callByInfo[req.taskInfo]
		p := 0
		parent := int64(0)
		if task := c.respool[req.taskInfo]; task != nil {
			p = c.pollByTask[task]
			parent = task.event.TaskId
			id = 0
			c.reqPoller[req] = p
		}
		c.reqCalls[req] = id
		entry := smap{"work": workKey(req.taskInfo, enumspb.TASK_QUEUE_TYPE_WORKFLOW), "call": id, "poller": p, "parent": parent}
		ow["appendQueue"] = append(ow["appendQueue"].([]smap), entry)
		if p == 0 {
			c.calls[id-1]["pc"] = "appendWait"
			args = smap{"a": id}
		} else {
			d := c.dispatch[p-1]
			event = "RespoolTaskAfterError"
			if d["pc"] == "replacement" {
				event = "RespoolTaskRetry"
			}
			d["pc"] = "replacement"
			d["appendReply"] = "none"
			d["replacement"] = int64(0)
			args = smap{"p": p}
		}
		c.changed.Broadcast()
	case "TaskWriterDequeue":
		req := a[1].([]*writeTaskRequest)[0]
		for {
			if _, ok := c.reqCalls[req]; ok {
				break
			}
			c.changed.Wait()
		}
		entry := ow["appendQueue"].([]smap)[0]
		ow["appendQueue"] = ow["appendQueue"].([]smap)[1:]
		w = idleWriter()
		w["pc"] = "assign"
		w["work"] = workKey(req.taskInfo, enumspb.TASK_QUEUE_TYPE_WORKFLOW)
		w["call"] = c.reqCalls[req]
		w["poller"] = c.reqPoller[req]
		w["parent"] = entry["parent"]
		c.writer[o-1] = w
	case "AssignTaskIDs":
		tw := a[0].(*priTaskWriter)
		req := a[1].(*writeTaskRequest)
		w["pc"] = "create"
		w["id"] = req.id
		ow["nextId"] = tw.taskIDBlock.start
		c.catalog = append(c.catalog, smap{"id": req.id, "work": workKey(req.taskInfo, enumspb.TASK_QUEUE_TYPE_WORKFLOW), "parent": w["parent"]})
	case "CreateTasksBegin":
		db := a[0].(*taskQueueDB)
		w["pc"] = "store"
		w["range"] = db.rangeID
		w["before"] = db.subqueues[0].maxReadLevel
	case "CreateTasksReturn":
		db := a[0].(*taskQueueDB)
		err, _ := a[1].(error)
		reply := replyClass(err)
		c.snapDB(db, o)
		w["reply"] = reply
		w["pc"] = "publish"
		if reply == "ok" {
			w["pc"] = "notify"
		}
		if reply == "unknown" && w["outcome"] == "commit" {
			event = "CreateTasksUncertainReturn"
		} else {
			args["reply"] = reply
		}
		if reply == "condition" {
			ow["life"] = "unload"
		}

	case "SignalNewTasksBypass":
		tr := a[0].(*priTaskReader)
		c.snapReader(tr, o)
		ow["adding"] = addIDs(ow["adding"].([]int64), ids(a[1].([]*persistencespb.AllocatedTaskInfo))...)
		w["pc"] = "adding"
	case "SignalNewTasksWake":
		ow["notify"] = true
		w["pc"] = "publish"
	case "SignalReadersDone":
		if w["pc"] != "adding" {
			return
		}
		w["pc"] = "publish"
	case "AddTaskToMatcherClosed":
		id := a[1].(*internalTask).event.TaskId
		ow["adding"] = removeID(ow["adding"].([]int64), id)
		args["r"] = id
	case "MatcherRegistration":
		c.tasks[a[1].(*internalTask)] = o
		return
	case "AddTaskToMatcher":
		task := a[0].(*internalTask)
		c.tasks[task] = o
		id := task.event.TaskId
		ow["adding"] = removeID(ow["adding"].([]int64), id)
		ow["queued"] = addIDs(ow["queued"].([]int64), id)
		args["r"] = id
	case "TaskWriterPublish":
		req := a[1].(*writeTaskRequest)
		err, _ := a[2].(error)
		c.published[req] = true
		if p := c.reqPoller[req]; p > 0 {
			event = "TaskWriterPublishReplacement"
			d := c.dispatch[p-1]
			if d["pc"] == "replacement" {
				d["replacement"] = req.id
				d["appendReply"] = replyClass(err)
			}
		} else {
			c.calls[c.reqCalls[req]-1]["buffer"] = replyClass(err)
		}
		c.writer[o-1] = idleWriter()
		c.changed.Broadcast()
	case "AppendTaskShutdown":
		info := a[1].(*persistencespb.TaskInfo)
		if task := c.respool[info]; task != nil {
			p := c.pollByTask[task]
			c.dispatch[p-1]["pc"] = "replacementFailed"
			ow["skipFinal"] = true
			event = "RespoolTaskShutdown"
			args = smap{"p": p}
		} else {
			id := c.callByInfo[info]
			c.calls[id-1]["pc"] = "reply"
			c.calls[id-1]["response"] = "error"
			args = smap{"a": id}
		}
	case "AppendTaskReceive":
		req := a[1].(*writeTaskRequest)
		for !c.published[req] {
			c.changed.Wait()
		}
		if c.reqPoller[req] > 0 {
			return
		}
		id := c.reqCalls[req]
		s := c.calls[id-1]
		s["pc"] = "reply"
		s["response"] = "ok"
		if a[2] != nil {
			s["response"] = "error"
		}
		args = smap{"a": id}
	case "GetTasksPump":
		tr := a[0].(*priTaskReader)
		c.snapReader(tr, o)
		ow["notify"] = false
		r = idleReader()
		r["pc"] = "max"
		if tr.loadedTasks > tr.backlogMgr.config.GetTasksReloadAt() {
			r["pc"] = "idle"
		}
		r["low"] = tr.readLevel
		c.reader[o-1] = r
	case "GetTaskBatchMax":
		capturedMax := a[1].(int64)
		r["max"] = capturedMax
		r["pc"] = "gap"
		if r["low"].(int64) < capturedMax {
			r["pc"] = "issue"
		}
	case "GetTasksIssue":
		r["pc"] = "store"
		r["upper"] = a[2].(int64)
	case "GetTaskBatchReturn":
		low, upper, i, ts := a[1].(int64), a[2].(int64), a[3].(int), a[4].([]*persistencespb.AllocatedTaskInfo)
		r["scans"] = i + 1
		r["pc"] = "process"
		if len(ts) == 0 {
			low = upper
			r["pc"] = "gap"
			if upper < r["max"].(int64) && i+1 < 10 {
				r["pc"] = "issue"
			}
		}
		r["low"] = low
	case "ProcessTaskBatch":
		tr := a[0].(*priTaskReader)
		c.snapReader(tr, o)
		fresh := ids(a[1].([]*persistencespb.AllocatedTaskInfo))
		ow["adding"] = addIDs(ow["adding"].([]int64), fresh...)
		r["pc"] = "adding"
		r["todo"] = fresh
	case "ProcessTaskBatchDone":
		ow["notify"] = true
		c.reader[o-1] = idleReader()
	case "BackoffSignal":
		tr := a[0].(*priTaskReader)
		ow["backoff"] = tr.backoffTimer != nil
		ow["notify"] = true
	case "GetTasksError":
		tr := a[0].(*priTaskReader)
		ow["backoff"] = tr.backoffTimer != nil
		c.reader[o-1] = idleReader()
	case "SetReadLevelAfterGapStale":
		c.snapReader(a[0].(*priTaskReader), o)
		ow["notify"] = true
		c.reader[o-1] = idleReader()
	case "SetReadLevelAfterGapAck":
		c.snapReader(a[0].(*priTaskReader), o)
		ow["readerLock"] = "gapCache"
		ow["cacheRead"] = a[1].(int64)
		r["pc"] = "cache"
	case "GapDone":
		c.snapReader(a[0].(*priTaskReader), o)
		if a[1].(bool) {
			event = "UpdateAckLevelAfterGap"
			ow["readerLock"] = "free"
		} else {
			event = "SetReadLevelAfterGap"
		}
		c.reader[o-1] = idleReader()
	case "DBAckCache":
		c.snapDB(a[0].(*taskQueueDB), o)
		return
	case "FinishExpiredTask":
		if c.validationMode {
			return
		}
		task := a[0].(*internalTask)
		if !IsTaskExpired(task.event.AllocatedTaskInfo) {
			panic("validator rejection not proven expiry")
		}
		p := 8
		d := idleDispatch()
		d["pc"] = "finish"
		d["owner"] = o
		d["id"] = task.event.TaskId
		d["work"] = workKey(task.event.Data, enumspb.TASK_QUEUE_TYPE_WORKFLOW)
		d["reply"] = "expired"
		ow["queued"] = removeID(ow["queued"].([]int64), task.event.TaskId)
		c.dispatch[p-1] = d
		c.pollByTask[task] = p
		args["r"] = task.event.TaskId
		args["p"] = p
	case "ValidationMatch":
		if !c.validationMode {
			return
		}
		task := a[0].(*internalTask)
		p := 8
		c.pollByTask[task] = p
		d := idleDispatch()
		d["pc"], d["owner"], d["id"], d["work"] = "matched", o, task.event.TaskId, workKey(task.event.Data, enumspb.TASK_QUEUE_TYPE_WORKFLOW)
		c.dispatch[p-1] = d
		ow["queued"] = removeID(ow["queued"].([]int64), task.event.TaskId)
		c.validationHolds[o-1] = smap{"poller": p, "id": task.event.TaskId, "cancelled": c.mgrs[o].tqCtx.Err() != nil}
		args = smap{"o": o, "r": task.event.TaskId, "p": p}
	case "ValidationResult":
		if !c.validationMode {
			return
		}
		task := a[0].(*internalTask)
		p := c.pollByTask[task]
		d := c.dispatch[p-1]
		result, reply := "valid", "transient"
		if !a[1].(bool) {
			result, reply = "obsolete", "obsolete"
			if IsTaskExpired(task.event.AllocatedTaskInfo) {
				result, reply = "expired", "expired"
			} else {
				c.history[d["work"].(string)].(smap)["obsolete"] = true
			}
		}
		d["pc"], d["reply"] = "finish", reply
		args = smap{"p": p, "result": result}
	case "ValidationDone":
		if !c.validationMode {
			return
		}
		c.validationHolds[o-1] = smap{"poller": 0, "id": int64(0), "cancelled": false}
		c.validationCycles++
	case "PollTask":
		task := a[0].(*internalTask)
		p, err := strconv.Atoi(a[1].(string))
		if err != nil {
			panic(err)
		}
		c.pollByTask[task] = p
		c.tasks[task] = o
		d := idleDispatch()
		d["pc"] = "matched"
		d["owner"] = o
		d["work"] = workKey(task.event.Data, enumspb.TASK_QUEUE_TYPE_WORKFLOW)
		if task.isSyncMatchTask() {
			id := c.callByInfo[task.event.Data]
			d["call"] = id
			c.calls[id-1]["pc"] = "syncWait"
			event = "TrySyncMatch"
			args = smap{"a": id, "p": p}
		} else {
			d["id"] = task.event.TaskId
			ow["queued"] = removeID(ow["queued"].([]int64), task.event.TaskId)
			args["r"] = task.event.TaskId
			args["p"] = p
		}
		c.dispatch[p-1] = d
	case "FinishSyncTask":
		task := a[0].(*internalTask)
		p := c.pollByTask[task]
		d := c.dispatch[p-1]
		id := d["call"].(int)
		call := c.calls[id-1]
		res := a[1].(taskResponse)
		call["buffer"] = "ok"
		if res.startErr != nil {
			call["buffer"] = "unknown"
			if historyResult(res.startErr) == "busy" {
				call["buffer"] = "busy"
			}
		}
		d["pc"] = "idle"
		if res.startErr == nil {
			d["pc"] = "worker"
		}
		args = smap{"p": p}
	case "SyncTaskReceive":
		task := a[0].(*internalTask)
		id := c.callByInfo[task.event.Data]
		call := c.calls[id-1]
		for call["buffer"] == "none" {
			c.changed.Wait()
		}
		call["pc"] = "reply"
		switch call["buffer"] {
		case "ok":
			call["response"] = "ok"
		case "busy":
			call["pc"] = "spool"
			call["response"] = "error"
		default:
			call["response"] = "error"
		}
		args = smap{"a": id}
	case "RecordTaskStartedPrecheckError":
		task := a[0].(*internalTask)
		p := c.pollByTask[task]
		d := c.dispatch[p-1]
		d["pc"] = "historyReply"
		d["result"] = historyResult(a[1].(error))
		args = smap{"p": p, "result": d["result"]}
	case "RecordTaskStartedBegin":
		task := a[0].(*internalTask)
		req := a[1].(*historyservice.RecordWorkflowTaskStartedRequest)
		p := c.pollByTask[task]
		alias := len(c.startAliases) + 1
		c.startAliases[req.RequestId] = alias
		d := c.dispatch[p-1]
		d["pc"] = "history"
		d["request"] = alias
		args = smap{"p": p, "q": alias}
	case "RecordTaskStartedReply":
		task := a[0].(*internalTask)
		p := c.pollByTask[task]
		d := c.dispatch[p-1]
		d["pc"] = "finish"
		d["reply"] = d["result"]
		args = smap{"p": p}
		if err, _ := a[1].(error); err != nil && d["result"] == "ok" {
			event = "RecordTaskStartedReplyLost"
			d["reply"] = "transient"
		}
	case "RespoolCallbackBegin":
		task := a[1].(*internalTask)
		c.respool[task.event.Data] = task
		return
	case "RespoolTaskReturn":
		info := a[1].(*persistencespb.TaskInfo)
		task := c.respool[info]
		p := c.pollByTask[task]
		d := c.dispatch[p-1]
		if d["pc"] == "replacementFailed" {
			return
		}
		args = smap{"p": p}
		d["pc"] = "finish"
		d["reply"] = "replaced"
		if a[2] != nil {
			d["pc"] = "replacementFailed"
			d["reply"] = "respool"
			ow["life"] = "unload"
		}
	case "PollTaskErrorReturn":
		p := c.pollByTask[a[0].(*internalTask)]
		if p == 0 || c.dispatch[p-1]["pc"] != "replacementFailed" {
			return
		}
		c.dispatch[p-1]["pc"] = "idle"
		args = smap{"p": p}
	case "CompleteTaskTransient":
		task := a[1].(*internalTask)
		p := c.pollByTask[task]
		d := c.dispatch[p-1]
		d["pc"] = "idle"
		ow["adding"] = addIDs(ow["adding"].([]int64), task.event.TaskId)
		args = smap{"p": p}
	case "CompleteTaskAck":
		c.snapReader(a[0].(*priTaskReader), o)
		id := a[1].(int64)
		p := 0
		for i, d := range c.dispatch {
			if d["owner"] == o && d["id"] == id && d["pc"] == "finish" {
				p = i + 1
				break
			}
		}
		if p == 0 {
			panic("missing completion poller")
		}
		ow["readerLock"] = "ackDrain"
		ow["cachePoller"] = p
		c.dispatch[p-1]["pc"] = "ackCache"
		args = smap{"p": p}
	case "AckTaskLockedDrained":
		c.snapReader(a[0].(*priTaskReader), o)
		ow["readerLock"] = "ackGC"
	case "GCLaunch":
		c.gcLaunch[o] = true
		c.gcReady[o] = false
		ow["gcBound"] = a[1].(int64)
		return
	case "MaybeGCLocked":
		tr := a[0].(*priTaskReader)
		launch := c.gcLaunch[o]
		c.gcLaunch[o] = false
		ow["readerLock"] = "ackCache"
		if launch {
			ow["gcPC"] = "store"
		}
		if tr.loadedTasks == tr.backlogMgr.config.GetTasksReloadAt() {
			ow["notify"] = true
		}
		args["launch"] = launch
		c.gcReady[o] = true
		c.changed.Broadcast()
	case "UpdateAckLevelAndBacklogStats":
		c.snapReader(a[0].(*priTaskReader), o)
		ow["readerLock"] = "free"
		p := ow["cachePoller"].(int)
		d := c.dispatch[p-1]
		d["pc"] = "idle"
		if d["reply"] == "ok" {
			d["pc"] = "worker"
		}
	case "GCCount":
		ow["gcCount"] = a[1].(int)
		return
	case "DoGCReturn":
		c.snapReader(a[0].(*priTaskReader), o)
		ow["gcPC"] = "idle"
		if a[1] != nil {
			event = "DoGCError"
		}
	case "GCDone":
		c.gcFinished[o]++
		c.changed.Broadcast()
		return
	case "SyncStateBegin":
		db := a[0].(*taskQueueDB)
		m = idleMetadata()
		m["pc"] = "store"
		m["kind"] = "verify"
		if a[1].(bool) {
			m["kind"] = "sync"
		}
		m["expect"] = db.rangeID
		m["newRange"] = db.rangeID
		m["ack"] = db.subqueues[0].AckLevel
		c.metadata[o-1] = m
		if ow["stopStep"] == "sync" {
			event = "StopSyncState"
			ow["stopStep"] = "wait"
		} else {
			args["kind"] = m["kind"]
		}
	case "VerifyOwnership":
		resp := a[1].(*persistence.GetTaskQueueResponse)
		m["pc"] = "result"
		m["outcome"] = "ok"
		if resp.RangeID != m["expect"].(int64) {
			m["outcome"] = "condition"
		}
		args["actualRange"] = resp.RangeID
	case "SyncStateReturn":
		db := a[0].(*taskQueueDB)
		c.snapDB(db, o)
		if m["outcome"] == "condition" && ow["stopStep"] != "wait" {
			ow["life"] = "unload"
		}
		if ow["stopStep"] == "wait" {
			ow["stopStep"] = "cancel"
		}
		c.metadata[o-1] = idleMetadata()
		event = "UpdateTaskQueueReturn"
	case "SignalIfFatal":
		ow["skipFinal"] = a[0].(*priBacklogManagerImpl).skipFinalUpdate.Load()
		if ow["life"] == "ready" {
			ow["life"] = "unload"
		}
	case "StopBegin":
		mgr := a[0].(*physicalTaskQueueManagerImpl)
		b := mgr.backlogMgr.(*priBacklogManagerImpl)
		ow["skipFinal"] = b.skipFinalUpdate.Load()
		if b.skipFinalUpdate.Load() {
			event = "UnloadAfterError"
			ow["stopStep"] = "cancel"
		} else {
			ow["stopStep"] = "cache"
		}
		ow["life"] = "stopping"
	case "StopRefreshAck":
		ow["stopStep"] = "sync"
	case "StopCancel":
		ow["life"] = "stopped"
	default:
		panic("unhandled matching point: " + point)
	}
	c.emit(event, o, args, q)
}
func (c *speculaObserver) qIfKnown(o int) smap {
	if b := c.mgrs[o]; b != nil {
		return queueKey(b.queueKey())
	}
	for db, id := range c.dbs {
		if id == o {
			return queueKey(db.queue)
		}
	}
	panic("unknown owner")
}
func (c *speculaObserver) rowsReadback() ([]smap, error) {
	rows, err := c.sqlDB.Query("SELECT task_id,data,data_encoding FROM tasks ORDER BY task_id")
	if err != nil {
		return nil, err
	}
	defer func() {
		if err := rows.Close(); err != nil {
			panic(err)
		}
	}()
	out := []smap{}
	for rows.Next() {
		var id int64
		var data []byte
		var encoding string
		if err := rows.Scan(&id, &data, &encoding); err != nil {
			return nil, err
		}
		task, err := c.serializer.TaskInfoFromBlob(persistence.NewDataBlob(data, encoding))
		if err != nil {
			return nil, err
		}
		out = append(out, smap{"id": id, "work": workKey(task.Data, enumspb.TASK_QUEUE_TYPE_WORKFLOW)})
	}
	return out, rows.Err()
}
func (c *speculaObserver) readDurable() {
	rows, err := c.rowsReadback()
	if err != nil {
		panic(err)
	}
	retained := emptyInts()
	for _, row := range rows {
		retained = append(retained, row["id"].(int64))
	}
	var data []byte
	var enc string
	var rangeID int64
	if err := c.sqlDB.QueryRow("SELECT range_id,data,data_encoding FROM task_queues").Scan(&rangeID, &data, &enc); err != nil {
		panic(err)
	}
	info, err := c.serializer.TaskQueueInfoFromBlob(persistence.NewDataBlob(data, enc))
	if err != nil {
		panic(err)
	}
	ack := info.AckLevel
	if len(info.Subqueues) > 0 {
		ack = info.Subqueues[0].AckLevel
	}
	c.durable = smap{"range": rangeID, "ack": ack, "rows": retained}
}
func (c *speculaObserver) sqlProbe(ctx context.Context, point string, a ...any) {
	o, _ := ctx.Value(sqlstore.SpeculaOwnerKey{}).(int)
	if o == 0 {
		return
	}
	if point == "GetTasksResponseGate" {
		c.waitGate("GetTasksSnapshot", o)
		return
	}
	if point == "CreateTasksStoreGate" || point == "UpdateTaskQueueStoreGate" {
		c.waitGate(point, o)
		return
	}
	c.mu.Lock()
	if c.ended {
		c.mu.Unlock()
		return
	}
	defer c.mu.Unlock()
	q := c.qIfKnown(o)
	w, m, ow, r := c.writer[o-1], c.metadata[o-1], c.owner[o-1], c.reader[o-1]
	args := smap{"o": o}
	event := point
	switch point {
	case "MetadataRejected":
		event = "UpdateTaskQueueError"
		m["pc"] = "result"
		m["outcome"] = "error"
	case "MetadataLost":
		event = "UpdateTaskQueueReplyLost"
		m["outcome"] = "error"
	case "CreateTasksReject":
		w["pc"] = "storeResult"
		w["outcome"] = "limit"
		args["result"] = "limit"
	case "SQLRangeCondition":
		if a[3].(sqlplugin.MatchingTaskVersion) != sqlplugin.MatchingTaskVersion1 {
			return
		}
		c.condition[o] = [2]int64{a[0].(int64), a[1].(int64)}
		return
	case "CreateTasksTransaction":
		req := a[0].(*persistence.InternalCreateTasksRequest)
		rows := a[1].([]sqlplugin.TasksRow)
		err, _ := a[2].(error)
		q = smap{"namespace": req.NamespaceID, "physicalName": req.TaskQueue, "partition": 0, "subqueue": req.Tasks[0].Subqueue, "taskType": taskTypeName(req.TaskType)}
		pair := c.condition[o]
		w["pc"] = "storeResult"
		if err == nil {
			c.readDurable()
			w["outcome"] = "commit"
			event = "CreateTasksCommit"
			ts := []smap{}
			for _, row := range rows {
				var data []byte
				var enc string
				if e := c.sqlDB.QueryRow("SELECT data,data_encoding FROM specula_task_audit WHERE op='insert' AND task_id=? ORDER BY n DESC LIMIT 1", row.TaskID).Scan(&data, &enc); e != nil {
					panic(e)
				}
				task, e := c.serializer.TaskInfoFromBlob(persistence.NewDataBlob(data, enc))
				if e != nil {
					panic(e)
				}
				ts = append(ts, smap{"id": row.TaskID, "work": workKey(task.Data, enumspb.TASK_QUEUE_TYPE_WORKFLOW)})
			}
			args["tasks"] = ts
			args["expectedRange"] = pair[0]
			args["actualRange"] = pair[1]
		} else if _, ok := err.(*persistence.ConditionFailedError); ok {
			w["outcome"] = "condition"
			event = "CreateTasksConditionFailed"
			args["expectedRange"] = pair[0]
			args["actualRange"] = pair[1]
		} else {
			panic(fmt.Sprintf("unclassified SQL failure: %v", err))
		}
	case "GetTasksSnapshot":
		req := a[0].(*persistence.GetTasksRequest)
		rows := a[1].([]sqlplugin.TasksRow)
		ts := []smap{}
		rs := emptyInts()
		for _, row := range rows {
			task, err := c.serializer.TaskInfoFromBlob(persistence.NewDataBlob(row.Data, row.DataEncoding))
			if err != nil {
				panic(err)
			}
			ts = append(ts, smap{"id": row.TaskID, "work": workKey(task.Data, enumspb.TASK_QUEUE_TYPE_WORKFLOW)})
			rs = append(rs, row.TaskID)
		}
		q = smap{"namespace": req.NamespaceID, "physicalName": req.TaskQueue, "partition": 0, "subqueue": req.Subqueue, "taskType": taskTypeName(req.TaskType)}
		r["rows"] = rs
		r["pc"] = "return"
		args["tasks"] = ts
		args["min"] = req.InclusiveMinTaskID
		args["max"] = req.ExclusiveMaxTaskID
		args["limit"] = req.PageSize
		c.snapshots++
	case "UpdateTaskQueueTransaction":
		if a[2].(sqlplugin.MatchingTaskVersion) != sqlplugin.MatchingTaskVersion1 {
			return
		}
		if !c.enabled {
			return
		}
		req := a[0].(*persistence.InternalUpdateTaskQueueRequest)
		err, _ := a[1].(error)
		pair := c.condition[o]
		q = smap{"namespace": req.NamespaceID, "physicalName": req.TaskQueue, "partition": 0, "subqueue": 0, "taskType": taskTypeName(req.TaskType)}
		m["pc"] = "result"
		m["outcome"] = "ok"
		event = "UpdateTaskQueueCommit"
		args["actualRange"] = pair[1]
		args["expectedRange"] = req.PrevRangeID
		if err == nil {
			c.readDurable()
		} else if _, ok := err.(*persistence.ConditionFailedError); ok {
			event = "UpdateTaskQueueConditionFailed"
			m["outcome"] = "condition"
		} else {
			event = "UpdateTaskQueueError"
			m["outcome"] = "error"
			args = smap{"o": o}
		}
	case "CompleteTasksLessThan":
		req := a[0].(*persistence.CompleteTasksLessThanRequest)
		count := a[1].(int)
		deleted := []smap{}
		rows, err := c.sqlDB.Query("SELECT task_id,data,data_encoding FROM specula_task_audit WHERE op='delete' AND reported=0 ORDER BY n")
		if err != nil {
			panic(err)
		}
		for rows.Next() {
			var id int64
			var data []byte
			var enc string
			if err := rows.Scan(&id, &data, &enc); err != nil {
				panic(err)
			}
			task, err := c.serializer.TaskInfoFromBlob(persistence.NewDataBlob(data, enc))
			if err != nil {
				panic(err)
			}
			deleted = append(deleted, smap{"id": id, "work": workKey(task.Data, enumspb.TASK_QUEUE_TYPE_WORKFLOW)})
		}
		if err := rows.Close(); err != nil {
			panic(err)
		}
		if len(deleted) != count {
			panic("delete audit count disagrees")
		}
		if _, err := c.sqlDB.Exec("UPDATE specula_task_audit SET reported=1 WHERE op='delete'"); err != nil {
			panic(err)
		}
		q = smap{"namespace": req.NamespaceID, "physicalName": req.TaskQueueName, "partition": 0, "subqueue": req.Subqueue, "taskType": taskTypeName(req.TaskType)}
		c.readDurable()
		ow["gcPC"] = "result"
		ow["gcCount"] = count
		args["deleted"] = deleted
		args["max"] = req.ExclusiveMaxTaskID
		args["limit"] = req.Limit
	default:
		panic(point)
	}
	c.emit(event, o, args, q)
	// Release the leaf lock before a response-delivery gate.
	if point != "GetTasksSnapshot" {
		c.mu.Unlock()
		c.waitGate(point, o)
		c.mu.Lock()
	}
}
func (c *speculaObserver) bootstrap() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.readDurable()
	cfg := c.mgrs[1].config
	c.config["rangeSize"] = cfg.RangeSize
	c.config["batchSize"] = cfg.GetTasksBatchSize()
	c.config["reloadAt"] = cfg.GetTasksReloadAt()
	c.config["deleteBatchSize"] = cfg.MaxTaskDeleteBatchSize()
	c.config["writeBatchSize"] = cfg.MaxTaskBatchSize()
	c.config["priority"] = int(cfg.DefaultPriorityKey)
	c.config["useNewMatcher"] = cfg.NewMatcher
	c.config["enableFairness"] = cfg.EnableFairness
	details := smap{"maxTaskQueueIdleTime": cfg.MaxTaskQueueIdleTime().String(), "sqlFile": c.sqlPath, "sqlPragmas": smap{"journal_mode": "wal", "synchronous": "full", "busy_timeout": 10000},
		"updateAckInterval": cfg.UpdateAckInterval().String(), "taskDeleteInterval": cfg.TaskDeleteInterval().String(),
		"outstandingTaskAppendsThreshold": cfg.OutstandingTaskAppendsThreshold(), "metadataUpdateOnAppendInterval": cfg.MetadataUpdateOnAppendInterval().String(),
		"priorityLevels": int(cfg.PriorityLevels), "defaultPriority": int(cfg.DefaultPriorityKey),
		"historyInterface": "controlled fixture; History internal persistence not exercised"}
	raw, err := json.MarshalIndent(details, "", "  ")
	if err != nil {
		panic(err)
	}
	if err := os.WriteFile(c.file.Name()+".queue-config.json", raw, 0644); err != nil {
		panic(err)
	}
	c.queue = c.q(1)
	c.enabled = true
	c.write(smap{"tag": "temporal-matching", "seq": 0, "event": "bootstrap", "source": "implementation", "revision": "0c010ce5fe8c0180aa7573c72fe8fc87c6df7025", "queue": c.queue, "config": c.config, "post": c.all()})
}
func (c *speculaObserver) seal() {
	c.auditQuiescent()
	c.mu.Lock()
	defer c.mu.Unlock()
	c.readDurable()
	c.emit("TraceEnd", 0, smap{}, c.queue)
	c.ended = true
	c.changed.Broadcast()
	if err := c.file.Sync(); err != nil {
		panic(err)
	}
	if err := c.file.Close(); err != nil {
		panic(err)
	}
	b, err := json.MarshalIndent(smap{"startAliases": c.startAliases, "config": c.config, "durable": c.durable}, "", "  ")
	require.NoError(c.t, err)
	require.NoError(c.t, os.WriteFile(c.file.Name()+".evidence.json", b, 0644))
	require.NoError(c.t, c.raw.Close())
}
func (c *speculaObserver) callerReply(info *persistencespb.TaskInfo, err error, lost bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	id := c.callByInfo[info]
	s := c.calls[id-1]
	s["pc"] = "done"
	receipt := "ok"
	if err != nil {
		receipt = "error"
	}
	event := "AddTaskReply"
	if lost {
		receipt = "lost"
		event = "AddTaskReplyLost"
	}
	s["receipt"] = receipt
	o := s["owner"].(int)
	c.emit(event, o, smap{"a": id}, c.q(o))
}
func (c *speculaObserver) workerReply(p int, lost bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	d := c.dispatch[p-1]
	o := d["owner"].(int)
	d["pc"] = "idle"
	event := "PollTaskQueueResponse"
	if lost {
		event = "PollTaskQueueResponseLost"
	} else {
		c.history[d["work"].(string)].(smap)["worker"] = true
	}
	c.emit(event, o, smap{"p": p}, c.q(o))
}
func (c *speculaObserver) historyObserved(req *historyservice.RecordWorkflowTaskStartedRequest, err error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	alias := c.startAliases[req.RequestId]
	p := 0
	for i, d := range c.dispatch {
		if d["request"] == alias && d["pc"] == "history" {
			p = i + 1
			break
		}
	}
	if p == 0 {
		panic("unmapped History request")
	}
	d := c.dispatch[p-1]
	o := d["owner"].(int)
	result := "ok"
	event := "RecordTaskStarted"
	args := smap{"p": p, "work": historyKey(req), "request": alias}
	if _, ok := err.(*serviceerrors.TaskAlreadyStarted); ok {
		result = "already"
	} else if err != nil {
		result = historyResult(err)
		event = "RecordTaskStartedError"
		args = smap{"p": p, "result": result}
	} else {
		c.history[historyKey(req)].(smap)["start"] = alias
	}
	d["pc"] = "historyReply"
	d["result"] = result
	c.emit(event, o, args, c.q(o))
}

func (c *speculaObserver) expireWork(i int) {
	c.t.Helper()
	c.mu.Lock()
	key := c.config["work"].([]string)[i]
	var info *persistencespb.TaskInfo
	for p := range c.callByInfo {
		if workKey(p, enumspb.TASK_QUEUE_TYPE_WORKFLOW) == key {
			info = p
			break
		}
	}
	c.mu.Unlock()
	require.NotNil(c.t, info)
	require.NotNil(c.t, info.ExpiryTime)
	await.RequireTrue(c.t, func() bool { return IsTaskExpired(&persistencespb.AllocatedTaskInfo{Data: info}) }, 5*time.Second, time.Millisecond)
	c.mu.Lock()
	defer c.mu.Unlock()
	c.history[key].(smap)["expired"] = true
	c.emit("ExpireTask", 0, smap{"w": key}, c.queue)
}
func (c *speculaObserver) allowValidator() {
	c.mu.Lock()
	defer c.mu.Unlock()
	for tm, ch := range c.validators {
		close(ch)
		delete(c.validators, tm)
	}
}

func historyResult(err error) string {
	if re, ok := err.(*serviceerror.ResourceExhausted); ok && re.Cause == enumspb.RESOURCE_EXHAUSTED_CAUSE_BUSY_WORKFLOW && re.Scope == enumspb.RESOURCE_EXHAUSTED_SCOPE_NAMESPACE {
		return "busy"
	}
	if common.IsServiceClientTransientError(err) || common.IsContextDeadlineExceededErr(err) || common.IsContextCanceledErr(err) {
		return "transient"
	}
	return "respool"
}
func (c *speculaObserver) retryObserved(req *historyservice.RecordWorkflowTaskStartedRequest) {
	c.mu.Lock()
	defer c.mu.Unlock()
	q := c.startAliases[req.RequestId]
	for i, d := range c.dispatch {
		if d["request"] == q && d["pc"] == "historyReply" {
			d["pc"] = "history"
			d["result"] = "none"
			o := d["owner"].(int)
			c.emit("RecordTaskStartedRetryRPC", o, smap{"p": i + 1}, c.q(o))
			return
		}
	}
}

func (c *speculaObserver) auditQuiescent() {
	await.RequireTrue(c.t, func() bool {
		c.mu.Lock()
		defer c.mu.Unlock()
		for o := range c.owner {
			if c.owner[o]["life"] == "stopped" && !c.readerExited[o+1] {
				return false
			}
			if c.writer[o]["pc"] != "idle" || c.reader[o]["pc"] != "idle" || c.metadata[o]["pc"] != "idle" || c.owner[o]["gcPC"] != "idle" || len(c.owner[o]["adding"].([]int64)) != 0 || len(c.owner[o]["appendQueue"].([]smap)) != 0 {
				return false
			}
		}
		for _, d := range c.dispatch {
			if d["pc"] != "idle" {
				return false
			}
		}
		return true
	}, 10*time.Second, time.Millisecond)
	c.mu.Lock()
	expectedBytes, err := json.Marshal(c.owner)
	mgrs := map[int]*priBacklogManagerImpl{}
	for o, b := range c.mgrs {
		mgrs[o] = b
	}
	c.mu.Unlock()
	require.NoError(c.t, err)
	var expected []smap
	require.NoError(c.t, json.Unmarshal(expectedBytes, &expected))
	actual := map[int]smap{}
	for o, b := range mgrs {
		a := smap{}
		b.db.Lock()
		a["range"] = b.db.rangeID
		a["cachedAck"] = b.db.subqueues[0].AckLevel
		a["maxRead"] = b.db.subqueues[0].maxReadLevel
		a["dirty"] = b.db.lastChange.After(b.db.lastWrite)
		b.db.Unlock()
		tr := b.subqueues[0]
		tr.lock.Lock()
		a["read"] = tr.readLevel
		a["ack"] = tr.ackLevel
		a["loaded"] = tr.loadedTasks
		a["gcLast"] = tr.gcAckLevel
		a["notify"] = len(tr.notifyC) > 0
		outstanding, done := emptyInts(), emptyInts()
		it := tr.outstandingTasks.Iterator()
		for it.Next() {
			id := it.Key().(int64)
			outstanding = append(outstanding, id)
			if it.Value().(bool) {
				done = append(done, id)
			}
		}
		a["outstanding"] = outstanding
		a["done"] = done
		tr.lock.Unlock()
		matcher := b.pqMgr.(*physicalTaskQueueManagerImpl).priMatcher
		matcher.data.lock.Lock()
		queued := emptyInts()
		matcher.data.tasks.tree.Scan(func(task *internalTask) bool {
			if task.event != nil && !task.isSyncMatchTask() {
				queued = append(queued, task.event.TaskId)
			}
			return true
		})
		matcher.data.lock.Unlock()
		slices.Sort(queued)
		a["queued"] = queued
		a["skipFinal"] = b.skipFinalUpdate.Load()
		await.RequireTrue(c.t, func() bool {
			return b.taskWriter.getCurrentTaskIDBlock().start == int64(expected[o-1]["nextId"].(float64))
		}, 5*time.Second, time.Millisecond)
		block := b.taskWriter.getCurrentTaskIDBlock()
		a["nextId"] = block.start
		a["endId"] = block.end
		require.Empty(c.t, b.taskWriter.appendCh)
		raw, err := json.Marshal(a)
		require.NoError(c.t, err)
		var decoded smap
		require.NoError(c.t, json.Unmarshal(raw, &decoded))
		for k, v := range decoded {
			require.Equal(c.t, expected[o-1][k], v, "independent readback owner %d field %s", o, k)
		}
		actual[o] = a
	}
	raw, err := json.MarshalIndent(actual, "", "  ")
	require.NoError(c.t, err)
	require.NoError(c.t, os.WriteFile(c.file.Name()+".owner-readback.json", raw, 0644))
}
