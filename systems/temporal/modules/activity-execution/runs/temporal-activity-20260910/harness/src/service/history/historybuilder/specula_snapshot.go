package historybuilder

import "go.temporal.io/server/common/speculatrace"

func (b *EventStore) SpeculaSnapshot() speculatrace.Fields {
	return speculatrace.Fields{"dbBuffer": b.dbBufferBatch, "memBuffer": b.memBufferBatch,
		"batches": b.memEventsBatches, "latestBatch": b.memLatestBatch, "clearBuffer": b.dbClearBuffer, "nextEventId": b.nextEventID}
}
