//go:build test_dep

package queues

import (
	"time"

	"go.temporal.io/server/common/clock"
	"go.temporal.io/server/common/dynamicconfig"
	"go.temporal.io/server/common/hqtrace"
	"go.temporal.io/server/common/metrics"
	"go.temporal.io/server/common/telemetry"
	historyi "go.temporal.io/server/service/history/interfaces"
	"go.temporal.io/server/service/history/tasks"
)

type HQDriver struct {
	base        *queueBase
	immediate   *immediateQueue
	Scheduler   *HQScheduler
	Rescheduler *reschedulerImpl
	Executables []Executable
}
type HQScheduler struct {
	Pending []Executable
	Reject  bool
}

func (s *HQScheduler) Start()              {}
func (s *HQScheduler) Stop()               {}
func (s *HQScheduler) Submit(e Executable) { s.Pending = append(s.Pending, e) }
func (s *HQScheduler) TrySubmit(e Executable) bool {
	if s.Reject {
		return false
	}
	s.Submit(e)
	return true
}
func (s *HQScheduler) TaskChannelKeyFn() TaskChannelKeyFn {
	return func(e Executable) TaskChannelKey {
		return TaskChannelKey{NamespaceID: e.GetNamespaceID(), Priority: e.GetPriority()}
	}
}
func HQNew(sh historyi.ShardContext, executor Executor, options Options, provider PaginationFnProvider) *HQDriver {
	d := &HQDriver{Scheduler: &HQScheduler{}}
	d.Rescheduler = NewRescheduler(d.Scheduler, sh.GetTimeSource(), sh.GetLogger(), metrics.NoopMetricsHandler)
	factory := ExecutableFactoryFn(func(readerID int64, task tasks.Task) Executable {
		e := NewExecutable(readerID, task, executor, d.Scheduler, d.Rescheduler, NewNoopPriorityAssigner(), sh.GetTimeSource(), sh.GetNamespaceRegistry(), sh.GetClusterMetadata(), sh.ChasmRegistry(), GetTaskTypeTagValue, sh.GetLogger(), metrics.NoopMetricsHandler, telemetry.NoopTracer, func(p *ExecutableParams) { p.MaxUnexpectedErrorAttempts = func() int { return 2 } })
		d.Executables = append(d.Executables, e)
		return e
	})
	d.base = newQueueBase(sh, tasks.CategoryTransfer, provider, d.Scheduler, d.Rescheduler, factory, &options, NewReaderPriorityRateLimiter(func() float64 { return 100000 }, 2), NoopReaderCompletionFn, GrouperNamespaceID{}, sh.GetLogger(), metrics.NoopMetricsHandler)
	d.immediate = &immediateQueue{queueBase: d.base, notifyCh: make(chan struct{}, 1)}
	d.base.checkpointTimer = time.NewTimer(time.Hour)
	d.ensureReaders()
	return d
}
func HQOptions() Options {
	return Options{ReaderOptions: ReaderOptions{BatchSize: dynamicconfig.GetIntPropertyFn(1), MaxPendingTasksCount: dynamicconfig.GetIntPropertyFn(100), PollBackoffInterval: dynamicconfig.GetDurationPropertyFn(time.Second), MaxPredicateSize: dynamicconfig.GetIntPropertyFn(0)},
		MonitorOptions: MonitorOptions{PendingTasksCriticalCount: dynamicconfig.GetIntPropertyFn(1000), ReaderStuckCriticalAttempts: dynamicconfig.GetIntPropertyFn(100), ReaderStuckShadowMode: dynamicconfig.GetBoolPropertyFn(false), SliceCountCriticalThreshold: dynamicconfig.GetIntPropertyFn(100)},
		MaxPollRPS:     dynamicconfig.GetIntPropertyFn(100000), MaxPollInterval: dynamicconfig.GetDurationPropertyFn(time.Hour), MaxPollIntervalJitterCoefficient: dynamicconfig.GetFloatPropertyFn(0), CheckpointInterval: dynamicconfig.GetDurationPropertyFn(time.Hour), CheckpointIntervalJitterCoefficient: dynamicconfig.GetFloatPropertyFn(0), MaxReaderCount: dynamicconfig.GetIntPropertyFn(2), MoveGroupTaskCountBase: dynamicconfig.GetIntPropertyFn(2), MoveGroupTaskCountMultiplier: dynamicconfig.GetFloatPropertyFn(3), ShrinkPredicateMaxPendingKeys: dynamicconfig.GetIntPropertyFn(2)}
}
func (d *HQDriver) ensureReaders() {
	for _, id := range []int64{0, 1} {
		d.base.readerGroup.GetOrCreateReader(id)
	}
}
func (d *HQDriver) Process() {
	select {
	case <-d.immediate.notifyCh:
	default:
	}
	d.base.processNewRange()
}
func (d *HQDriver) Hint(t tasks.Task) { d.immediate.NotifyNewTasks([]tasks.Task{t}) }
func (d *HQDriver) Checkpoint()       { d.ensureReaders(); d.base.checkpoint() }
func (d *HQDriver) Load(id int64) {
	d.base.readerGroup.GetOrCreateReader(id).(*ReaderImpl).loadAndSubmitTasks()
}
func (d *HQDriver) Notify(id int64) { d.base.readerGroup.GetOrCreateReader(id).Notify() }
func (d *HQDriver) Close() {
	d.base.checkpointTimer.Stop()
	d.Rescheduler.timerGate.Close()
	for _, r := range d.base.readerGroup.readerMap {
		r.(*ReaderImpl).rateLimitContextCancel()
	}
}
func (d *HQDriver) Run(e Executable) error {
	hqtrace.Exec = hqtrace.Ptr(e)
	defer func() { hqtrace.Exec = "" }()
	err := e.Execute()
	err = e.HandleErr(err)
	if err == nil {
		e.Ack()
	} else {
		d.Scheduler.Reject = true
		e.Nack(err)
		d.Scheduler.Reject = false
	}
	return err
}
func (d *HQDriver) Retry() {
	if c, ok := d.base.timeSource.(*clock.EventTimeSource); ok {
		c.Advance(time.Minute)
	}
	d.Rescheduler.reschedule()
}
func (d *HQDriver) Split(readerID int64, cut int64) {
	r := d.base.readerGroup.GetOrCreateReader(readerID)
	detail := hqtrace.M{"r": readerID, "cut": cut}
	hqtrace.Extra["range_split"] = detail
	defer delete(hqtrace.Extra, "range_split")
	r.SplitSlices(func(z Slice) ([]Slice, bool) {
		if !z.CanSplitByRange(tasks.NewImmediateKey(cut)) {
			return nil, false
		}
		detail["old"] = hqtrace.Ptr(z)
		a, b := z.SplitByRange(tasks.NewImmediateKey(cut))
		detail["left"] = hqtrace.Ptr(a)
		detail["right"] = hqtrace.Ptr(b)
		return []Slice{a, b}, true
	})
}

//nolint:revive // Test-only driver constructs the concrete readers, slices, and executables sampled here.
func (d *HQDriver) Observe() any {
	p := d.base
	readers := []any{}
	execs := []any{}
	for _, rid := range []int64{0, 1} {
		r, ok := p.readerGroup.readerMap[rid]
		rr := hqtrace.M{"id": rid, "lists": []any{}, "cursor": "", "detached": nil}
		if ok {
			impl := r.(*ReaderImpl)
			ls := []any{}
			attached := map[Slice]bool{}
			for el := impl.slices.Front(); el != nil; el = el.Next() {
				z := el.Value.(Slice)
				attached[z] = true
				ls = append(ls, hqSlice(z))
			}
			rr["lists"] = ls
			if el := impl.nextReadSlice; el != nil {
				z := el.Value.(Slice)
				rr["cursor"] = hqtrace.Ptr(z)
				rr["cursor_element"] = hqtrace.Ptr(el)
				if !attached[z] {
					rr["detached"] = hqSlice(z)
				}
			}
			rr["notify_length"] = len(impl.notifyCh)
		}
		readers = append(readers, rr)
	}
	for _, v := range d.Executables {
		e := v.(*executableImpl)
		execs = append(execs, hqtrace.M{"address": hqtrace.Ptr(e), "key": e.GetTaskID(), "state": int(e.state), "terminal": e.terminalFailureCause != nil, "unexpected": e.unexpectedErrorAttempts, "attempt": e.attempt.Load()})
	}
	return hqtrace.M{"notice": len(d.immediate.notifyCh) > 0, "high": p.nonReadableScope.Range.InclusiveMin.TaskID, "deleteMin": p.exclusiveDeletionHighWatermark.TaskID, "lastRange": p.lastRangeID, "readers": readers, "executables": execs}
}
func hqScope(s Scope) any {
	return hqtrace.M{"lo": s.Range.InclusiveMin.TaskID, "hi": s.Range.ExclusiveMax.TaskID, "predicate": ToPersistencePredicate(s.Predicate)}
}

func (d *HQDriver) Stop() { d.base.Stop() }

//nolint:revive // Test-only driver constructs concrete ReaderImpl objects.
func (d *HQDriver) Compact(readerID int64) {
	r := d.base.readerGroup.GetOrCreateReader(readerID).(*ReaderImpl)
	hqtrace.Extra["compact_old"] = hqtrace.Ptr(r.slices.Front().Value.(Slice))
	defer delete(hqtrace.Extra, "compact_old")
	r.CompactSlices(func(Slice) bool { return true })
}
func (d *HQDriver) Clear(readerID int64) {
	hqtrace.Extra["clear_reader"] = readerID
	d.base.readerGroup.GetOrCreateReader(readerID).ClearSlices(func(Slice) bool { return true })
}

func (d *HQDriver) DropHint() {
	select {
	case <-d.immediate.notifyCh:
		hqtrace.Current("DropNotification", nil)
	default:
		panic("no notification to drop") //nolint:forbidigo // A missing injected fault must fail the test.
	}
}
func (d *HQDriver) Poll() {
	t := time.NewTimer(time.Hour)
	defer t.Stop()
	d.immediate.processPollTimer(t)
}
