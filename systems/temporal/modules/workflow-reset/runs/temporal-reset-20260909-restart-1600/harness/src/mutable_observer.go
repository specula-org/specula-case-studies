package workflow

func (ms *MutableStateImpl) ResetTraceSnapshot() any {
	return map[string]any{"info": ms.executionInfo, "state": ms.executionState, "next": ms.GetNextEventID(), "ver": ms.dbRecordVersion, "events": ms.hBuilder.ResetTraceEvents(), "buffered": ms.hBuilder.ResetTraceBuffered()}
}
