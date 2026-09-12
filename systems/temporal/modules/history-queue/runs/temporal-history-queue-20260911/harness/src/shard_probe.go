//go:build test_dep

package shard

import (
	"slices"

	persistencespb "go.temporal.io/server/api/persistence/v1"
	"go.temporal.io/server/common/future"
	"go.temporal.io/server/common/hqtrace"
	"go.temporal.io/server/common/persistence"
	historyi "go.temporal.io/server/service/history/interfaces"
	"go.temporal.io/server/service/history/tasks"
)

// HQObserve samples the serialized harness; hooks may already hold the shard lock.
func (s *ContextTest) HQObserve() any {
	keys := []int64{}
	for key := range s.taskKeyManager.tracker.pendingTaskKeys[tasks.CategoryTransfer] {
		keys = append(keys, key.TaskID)
	}
	slices.Sort(keys)
	return hqtrace.M{"epoch": s.shardInfo.RangeId, "next": s.taskKeyManager.generator.peekTaskKey(tasks.CategoryTransfer).TaskID,
		"pending_keys": keys, "inflight": s.taskKeyManager.tracker.inflightRequestCount, "context_state": int(s.state),
		"memory": s.shardInfo.QueueStates[int32(tasks.CategoryTransfer.ID())], "address": hqtrace.Ptr(s.ContextImpl)}
}
func (s *ContextTest) HQConfigure(manager persistence.ExecutionManager, sm persistence.ShardManager, rangeBits uint) {
	s.executionManager = manager
	s.persistenceShardManager = sm
	s.config.RangeSizeBits = rangeBits
	s.taskKeyManager.generator.rangeSizeBits = rangeBits
}
func (s *ContextTest) HQBootstrap(info *persistencespb.ShardInfo) {
	s.shardInfo = info
	s.owner = info.Owner
	s.taskKeyManager.setRangeID(info.RangeId)
}

func (s *ContextTest) HQInstallMetadata(info *persistencespb.ShardInfo) { s.shardInfo = info }

type HQEngineFactory func(historyi.ShardContext) historyi.Engine

func (f HQEngineFactory) CreateEngine(s historyi.ShardContext) historyi.Engine { return f(s) }
func (s *ContextTest) HQAcquireFresh(factory HQEngineFactory) {
	s.state = contextStateAcquiring
	s.shardInfo = nil
	s.owner = "s2"
	s.taskKeyManager.generator.nextTaskID = -1
	s.taskKeyManager.generator.exclusiveMaxTaskID = 0
	s.engineFuture = future.NewFuture[historyi.Engine]()
	s.engineFactory = factory
	s.queueMetricEmitter.Do(func() {})
	s.acquireShard()
}
