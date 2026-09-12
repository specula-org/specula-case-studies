package workflow

import (
	"go.temporal.io/server/common/namespace"
	"go.temporal.io/server/common/speculatrace"
	"go.temporal.io/server/service/history/events"
	historyi "go.temporal.io/server/service/history/interfaces"
	"go.temporal.io/server/service/history/workflow/update"
)

func SpeculaSnapshot(ms historyi.MutableState, reg update.Registry) map[string]any {
	if ms == nil {
		return map[string]any{"loaded": false}
	}
	_, rv := ms.GetUpdateCondition()
	r := map[string]any{"loaded": true, "mutableIdentity": speculatrace.ID(ms),
		"next": ms.GetNextEventID(), "rv": rv, "closed": !ms.IsWorkflowExecutionRunning(),
		"sticky": ms.IsStickyTaskQueueSet(), "task": ms.GetPendingWorkflowTask(),
		"info": ms.GetExecutionInfo().GetUpdateInfos(), "executionInfo": ms.GetExecutionInfo(),
		"registry": update.SpeculaRegistry(reg)}
	if actual, ok := ms.(*MutableStateImpl); ok {
		r["range"] = actual.shard.GetRangeID()
		r["timerPointer"] = speculatrace.ID(actual.speculativeWorkflowTaskTimeoutTask)
		r["timer"] = actual.speculativeWorkflowTaskTimeoutTask
		if actual.speculativeWorkflowTaskTimeoutTask != nil {
			r["timerState"] = int(actual.speculativeWorkflowTaskTimeoutTask.State())
		}
	}
	return r
}

func SpeculaEmit(name string, ms historyi.MutableState, reg update.Registry, extra any) {
	if ms == nil || !speculatrace.Enabled(ms.GetWorkflowKey().WorkflowID) {
		return
	}
	speculatrace.Emit(ms.GetWorkflowKey().WorkflowID, name, map[string]any{"mutable": SpeculaSnapshot(ms, reg), "extra": extra})
}

// SpeculaBootstrap runs under the first Update request's lease. Only the chosen
// run's four bootstrap cache keys are removed; no other workflow is affected.
func SpeculaBootstrap(ms historyi.MutableState, reg update.Registry) {
	actual, ok := ms.(*MutableStateImpl)
	if !ok || !speculatrace.Enabled(ms.GetWorkflowKey().WorkflowID) || !speculatrace.FirstBaseline() {
		return
	}
	if ms.GetNextEventID() != 5 || ms.HasPendingWorkflowTask() || reg.Len() != 0 {
		return
	}
	key := ms.GetWorkflowKey()
	for id := int64(1); id < 5; id++ {
		actual.eventsCache.DeleteEvent(events.EventKey{
			NamespaceID: namespace.ID(key.NamespaceID), WorkflowID: key.WorkflowID,
			RunID: key.RunID, EventID: id, Version: actual.GetCurrentVersion(),
		})
	}
	SpeculaEmit("probe.LeasedBaseline", ms, reg, map[string]any{
		"hostCacheEnabled": actual.config.EnableHostLevelEventsCache(),
		"eventVersion":     actual.GetCurrentVersion(), "clearedPrefix": 4,
	})
}
