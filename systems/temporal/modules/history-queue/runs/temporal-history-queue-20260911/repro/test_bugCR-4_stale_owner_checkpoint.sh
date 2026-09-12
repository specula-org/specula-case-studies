#!/usr/bin/env bash
set -euo pipefail

SOURCE_REPO="${SOURCE_REPO:-/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/confirmation/CR-4/worktree}"
SOURCE_SHA="${SOURCE_SHA:-0c010ce5fe8c0180aa7573c72fe8fc87c6df7025}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cr4-repro.XXXXXX")"
WORKTREE="$TMP_ROOT/temporal-clean"

cleanup() {
  set +e
  if [[ -e "$WORKTREE/.git" || -d "$WORKTREE" ]]; then
    git -C "$SOURCE_REPO" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || rm -rf "$WORKTREE"
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

echo "CR4_REPRO source_repo=$SOURCE_REPO"
echo "CR4_REPRO source_sha=$SOURCE_SHA"
echo "LEVEL0_ATTEMPT public-api-normal-ops result=not-triggered reason=no deterministic public API knob exposes the post-ack/pre-checkpoint stale-owner window"
echo "LEVEL1_ATTEMPT timing-test-hook result=not-triggered reason=available queue hooks do not force durable shard acquisition between old-owner completion and checkpoint without state control"

git -C "$SOURCE_REPO" worktree add --detach "$WORKTREE" "$SOURCE_SHA" >/dev/null
echo "CR4_REPRO clean_worktree=$(git -C "$WORKTREE" rev-parse HEAD)"

cat > "$WORKTREE/service/history/queues/cr4_stale_owner_checkpoint_test.go" <<'GO'
package queues

import (
	"context"
	stdsql "database/sql"
	"errors"
	"fmt"
	"math"
	"path/filepath"
	"time"

	"github.com/google/uuid"
	persistencespb "go.temporal.io/server/api/persistence/v1"
	"go.temporal.io/server/chasm"
	"go.temporal.io/server/common/cluster"
	"go.temporal.io/server/common/config"
	"go.temporal.io/server/common/dynamicconfig"
	"go.temporal.io/server/common/metrics"
	"go.temporal.io/server/common/persistence"
	"go.temporal.io/server/common/persistence/serialization"
	persistencesql "go.temporal.io/server/common/persistence/sql"
	"go.temporal.io/server/common/persistence/sql/sqlplugin/sqlite"
	"go.temporal.io/server/common/resolver"
	"go.temporal.io/server/service/history/shard"
	"go.temporal.io/server/service/history/tasks"
	"go.uber.org/mock/gomock"
	"google.golang.org/protobuf/proto"
)

func (s *queueBaseSuite) TestCR4StaleOwnerCheckpointDeletesBeforeOwnershipFence() {
	ctx := context.Background()
	serializer := serialization.NewSerializer()
	cfg := config.SQL{
		PluginName:        sqlite.PluginName,
		DatabaseName:      filepath.Join(s.T().TempDir(), "cr4.db"),
		ConnectAttributes: map[string]string{"setup": "true", "journal_mode": "wal", "synchronous": "full"},
	}
	openStore := func() (*persistencesql.Factory, persistence.ExecutionManager, persistence.ShardManager) {
		factory := persistencesql.NewFactory(cfg, resolver.NewNoopResolver(), "active", s.logger, metrics.NoopMetricsHandler, serializer)
		executionStore, err := factory.NewExecutionStore()
		s.Require().NoError(err)
		shardStore, err := factory.NewShardStore()
		s.Require().NoError(err)
		return factory,
			persistence.NewExecutionManager(executionStore, serializer, nil, s.logger,
				dynamicconfig.GetIntPropertyFn(math.MaxInt), dynamicconfig.GetBoolPropertyFn(false)),
			persistence.NewShardManager(shardStore, serializer)
	}

	factory, executionManager, shardManager := openStore()
	defer factory.Close()
	defer executionManager.Close()
	defer shardManager.Close()

	shardID := int32(44)
	state := ToPersistenceQueueState(&queueState{
		readerScopes:                 map[int64][]Scope{},
		exclusiveReaderHighWatermark: tasks.NewImmediateKey(1),
	})
	initial := &persistencespb.ShardInfo{
		ShardId: shardID,
		RangeId: 1,
		QueueStates: map[int32]*persistencespb.QueueState{
			int32(tasks.CategoryTransfer.ID()): state,
		},
	}
	_, err := shardManager.GetOrCreateShard(ctx, &persistence.GetOrCreateShardRequest{
		ShardID:          shardID,
		InitialShardInfo: initial,
	})
	s.Require().NoError(err)

	namespaceID := uuid.NewString()
	runID := uuid.NewString()
	err = executionManager.AddHistoryTasks(ctx, &persistence.AddHistoryTasksRequest{
		ShardID:     shardID,
		RangeID:     1,
		NamespaceID: namespaceID,
		WorkflowID:  "cr4-stale-owner",
		ArchetypeID: chasm.WorkflowArchetypeID,
		Tasks: map[tasks.Category][]tasks.Task{
			tasks.CategoryTransfer: {
				&tasks.WorkflowTask{
					NamespaceID:      namespaceID,
					WorkflowID:       "cr4-stale-owner",
					RunID:            runID,
					TaskID:           1,
					ScheduledEventID: 5,
				},
			},
		},
	})
	s.Require().NoError(err)

	before, err := executionManager.GetHistoryTasks(ctx, &persistence.GetHistoryTasksRequest{
		ShardID:             shardID,
		TaskCategory:        tasks.CategoryTransfer,
		InclusiveMinTaskKey: tasks.NewImmediateKey(1),
		ExclusiveMaxTaskKey: tasks.NewImmediateKey(2),
		BatchSize:           10,
	})
	s.Require().NoError(err)
	s.Require().Len(before.Tasks, 1)

	err = shardManager.UpdateShard(ctx, &persistence.UpdateShardRequest{
		ShardInfo: &persistencespb.ShardInfo{
			ShardId: shardID,
			RangeId: 2,
			QueueStates: map[int32]*persistencespb.QueueState{
				int32(tasks.CategoryTransfer.ID()): proto.Clone(state).(*persistencespb.QueueState),
			},
		},
		PreviousRangeID: 1,
	})
	s.Require().NoError(err)
	fmt.Printf("OWNERSHIP_OBSERVATION durable_owner_rangeid=2 previous_owner_rangeid=1 transfer_rows_before=%d\n", len(before.Tasks))

	localConfig := *s.config
	localConfig.ShardUpdateMinInterval = dynamicconfig.GetDurationPropertyFn(0)
	localConfig.ShardUpdateMinTasksCompleted = dynamicconfig.GetIntPropertyFn(0)
	oldOwner := shard.NewTestContext(s.controller, proto.Clone(initial).(*persistencespb.ShardInfo), &localConfig)
	oldOwner.Resource.ClusterMetadata.EXPECT().GetAllClusterInfo().Return(map[string]cluster.ClusterInformation{}).AnyTimes()

	var staleUpdateErr error
	oldOwner.Resource.ShardMgr.EXPECT().UpdateShard(gomock.Any(), gomock.Any()).DoAndReturn(
		func(ctx context.Context, request *persistence.UpdateShardRequest) error {
			staleUpdateErr = shardManager.UpdateShard(ctx, request)
			fmt.Printf("QUEUE_OBSERVATION stale_state_update previousRangeID=%d requestedRangeID=%d error=%T\n",
				request.PreviousRangeID, request.ShardInfo.GetRangeId(), staleUpdateErr)
			return staleUpdateErr
		}).AnyTimes()
	oldOwner.Resource.ExecutionMgr.EXPECT().RangeCompleteHistoryTasks(gomock.Any(), gomock.Any()).DoAndReturn(
		func(ctx context.Context, request *persistence.RangeCompleteHistoryTasksRequest) error {
			fmt.Printf("QUEUE_OBSERVATION range_delete_called shard=%d min=%d max=%d request_has_range_id=false\n",
				request.ShardID, request.InclusiveMinTaskKey.TaskID, request.ExclusiveMaxTaskKey.TaskID)
			return executionManager.RangeCompleteHistoryTasks(ctx, request)
		}).Times(1)

	base := s.newQueueBase(oldOwner, tasks.CategoryTransfer, nil)
	base.checkpointTimer = time.NewTimer(time.Hour)
	defer base.checkpointTimer.Stop()

	base.nonReadableScope.Range.InclusiveMin = tasks.NewImmediateKey(2)
	base.checkpoint()

	var ownershipLost *persistence.ShardOwnershipLostError
	s.Require().True(errors.As(staleUpdateErr, &ownershipLost), "stale state update must be range-fenced")

	after, err := executionManager.GetHistoryTasks(ctx, &persistence.GetHistoryTasksRequest{
		ShardID:             shardID,
		TaskCategory:        tasks.CategoryTransfer,
		InclusiveMinTaskKey: tasks.NewImmediateKey(1),
		ExclusiveMaxTaskKey: tasks.NewImmediateKey(2),
		BatchSize:           10,
	})
	s.Require().NoError(err)
	s.Require().Len(after.Tasks, 0)

	reloaded, err := shardManager.GetOrCreateShard(ctx, &persistence.GetOrCreateShardRequest{ShardID: shardID})
	s.Require().NoError(err)
	durableWatermark := reloaded.ShardInfo.QueueStates[int32(tasks.CategoryTransfer.ID())].ExclusiveReaderHighWatermark.TaskId
	s.Require().Equal(int64(2), reloaded.ShardInfo.GetRangeId())
	s.Require().Equal(int64(1), durableWatermark)

	db, err := stdsql.Open("sqlite", cfg.DatabaseName)
	s.Require().NoError(err)
	defer db.Close()
	var physicalRows int
	s.Require().NoError(db.QueryRowContext(ctx,
		"SELECT COUNT(*) FROM transfer_tasks WHERE shard_id = ? AND task_id >= ? AND task_id < ?",
		shardID, 1, 2).Scan(&physicalRows))
	s.Require().Zero(physicalRows)

	fmt.Printf("SQL_OBSERVATION transfer_rows_after_old_checkpoint=%d physical_rows_after_old_checkpoint=%d durable_rangeid=%d durable_watermark=%d old_owner_memory_delete_watermark=%d\n",
		len(after.Tasks), physicalRows, reloaded.ShardInfo.GetRangeId(), durableWatermark, base.exclusiveDeletionHighWatermark.TaskID)
	fmt.Println("MASK_OBSERVATION old_owner_row_delete_is_unfenced=true stale_queue_state_update_is_fenced=true deletion_precondition=old_owner_advanced_local_ack_boundary")
}
GO

echo "LEVEL2_ATTEMPT state-injection result=running injected_precondition=durable-rangeid-2-with-old-owner-local-rangeid-1-and-local-ack-boundary-advanced-to-task-2"
cd "$WORKTREE"
timeout "${GO_TEST_TIMEOUT:-10m}" go test ./service/history/queues -run 'TestQueueBaseSuite/TestCR4StaleOwnerCheckpointDeletesBeforeOwnershipFence' -count=1 -v
