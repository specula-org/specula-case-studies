package workflow

import (
	"go.temporal.io/server/common/speculatrace"
	historyi "go.temporal.io/server/service/history/interfaces"
)

func SpeculaSnapshot(ms historyi.MutableState) speculatrace.Fields {
	if ms == nil {
		return speculatrace.Fields{"valid": false}
	}
	m, ok := ms.(*MutableStateImpl)
	if !ok {
		return speculatrace.Fields{"unsupportedMutableState": true}
	}
	return speculatrace.Fields{"valid": true, "mutableState": speculatrace.Proto(m.CloneToProto()),
		"historyBuilder":  speculatrace.Freeze(m.hBuilder.SpeculaSnapshot()),
		"watermark":       speculatrace.Freeze(m.pendingActivityTimerHeartbeats),
		"dbRecordVersion": m.dbRecordVersion, "tasks": speculatrace.Freeze(m.InsertTasks),
		"running": m.IsWorkflowExecutionRunning(), "pendingWFT": m.HasPendingWorkflowTask(), "startedWFT": m.HasStartedWorkflowTask()}
}
func SpeculaObserve(ms historyi.MutableState, event string, fields speculatrace.Fields) {
	if ms == nil || !speculatrace.Active(ms.GetExecutionInfo().WorkflowId) {
		return
	}
	fields["cache"] = SpeculaSnapshot(ms)
	speculatrace.Emit(ms.GetExecutionInfo().WorkflowId, event, fields)
}
