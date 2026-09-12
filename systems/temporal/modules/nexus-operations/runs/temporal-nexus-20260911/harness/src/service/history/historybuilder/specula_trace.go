package historybuilder

import (
 "go.temporal.io/server/common/speculatrace"
 historypb "go.temporal.io/api/history/v1"
)

func (b *EventStore) SpeculaSnapshot() any {
 encode := func(events []*historypb.HistoryEvent) []any {
  result := make([]any, 0, len(events))
  for _, e := range events { result = append(result, speculatrace.Proto(e)) }
  return result
 }
 batches := make([]any, 0, len(b.memEventsBatches))
 for _, events := range b.memEventsBatches { batches = append(batches, encode(events)) }
 return map[string]any{
  "db_buffer": encode(b.dbBufferBatch), "clear_db_buffer": b.dbClearBuffer,
  "memory_batches": batches, "latest_batch": encode(b.memLatestBatch),
  "memory_buffer": encode(b.memBufferBatch), "next_event_id": b.nextEventID,
 }
}
