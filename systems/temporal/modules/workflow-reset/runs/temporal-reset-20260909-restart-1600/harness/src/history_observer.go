package historybuilder

import historypb "go.temporal.io/api/history/v1"

func (b *EventStore) ResetTraceEvents() []*historypb.HistoryEvent {
	events := []*historypb.HistoryEvent{}
	for _, batch := range b.memEventsBatches {
		events = append(events, batch...)
	}
	return append(events, b.memLatestBatch...)
}

func (b *EventStore) ResetTraceBuffered() []*historypb.HistoryEvent {
	return append([]*historypb.HistoryEvent(nil), b.memBufferBatch...)
}
