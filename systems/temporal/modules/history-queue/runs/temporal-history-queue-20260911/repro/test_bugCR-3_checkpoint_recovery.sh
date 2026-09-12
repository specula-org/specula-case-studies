#!/usr/bin/env bash
set -euo pipefail

REPO="${SOURCE_REPO:-/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/confirmation/CR-3/worktree}"
TEST_FILE="$REPO/service/history/queues/cr3_confirmation_recovery_test.go"

cleanup() {
  rm -f "$TEST_FILE"
}
trap cleanup EXIT

cat > "$TEST_FILE" <<'GOEOF'
package queues

import (
	"context"
	stdsql "database/sql"
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
	"go.temporal.io/server/common/persistence/faultinjection"
	"go.temporal.io/server/common/persistence/serialization"
	persistencesql "go.temporal.io/server/common/persistence/sql"
	"go.temporal.io/server/common/persistence/sql/sqlplugin/sqlite"
	"go.temporal.io/server/common/resolver"
	"go.temporal.io/server/service/history/shard"
	"go.temporal.io/server/service/history/tasks"
	"go.uber.org/mock/gomock"
	"google.golang.org/protobuf/proto"
)

func (s *queueBaseSuite) TestBugCR3CheckpointRecoveryEvidence() {
	for _, schedule := range []string{"healthy", "delete_execute_and_timeout", "batched_state_lags", "update_shard_error_after_delete"} {
		s.Run(schedule, func() {
			ctx := context.Background()
			cfg := config.SQL{
				PluginName:        sqlite.PluginName,
				DatabaseName:      filepath.Join(s.T().TempDir(), "history.db"),
				ConnectAttributes: map[string]string{"setup": "true", "journal_mode": "wal", "synchronous": "full"},
			}
			serializer := serialization.NewSerializer()
			openStore := func() (*persistencesql.Factory, persistence.ExecutionManager, persistence.ShardManager) {
				factory := persistencesql.NewFactory(cfg, resolver.NewNoopResolver(), "active", s.logger, metrics.NoopMetricsHandler, serializer)
				executionStore, err := factory.NewExecutionStore()
				s.Require().NoError(err)
				shardStore, err := factory.NewShardStore()
				s.Require().NoError(err)
				return factory,
					persistence.NewExecutionManager(executionStore, serializer, nil, s.logger, dynamicconfig.GetIntPropertyFn(math.MaxInt), dynamicconfig.GetBoolPropertyFn(false)),
					persistence.NewShardManager(shardStore, serializer)
			}

			factory, executionManager, shardManager := openStore()
			state := ToPersistenceQueueState(&queueState{
				readerScopes:                 map[int64][]Scope{},
				exclusiveReaderHighWatermark: tasks.NewImmediateKey(1),
			})
			initial := &persistencespb.ShardInfo{
				ShardId: 10,
				RangeId: 1,
				QueueStates: map[int32]*persistencespb.QueueState{
					int32(tasks.CategoryTransfer.ID()): state,
				},
			}
			_, err := shardManager.GetOrCreateShard(ctx, &persistence.GetOrCreateShardRequest{
				ShardID:          10,
				InitialShardInfo: initial,
			})
			s.Require().NoError(err)

			namespaceID, runID := uuid.NewString(), uuid.NewString()
			s.Require().NoError(executionManager.AddHistoryTasks(ctx, &persistence.AddHistoryTasksRequest{
				ShardID:     10,
				RangeID:     1,
				NamespaceID: namespaceID,
				WorkflowID:  "cr3-checkpoint-recovery",
				ArchetypeID: chasm.WorkflowArchetypeID,
				Tasks: map[tasks.Category][]tasks.Task{tasks.CategoryTransfer: {
					&tasks.WorkflowTask{NamespaceID: namespaceID, WorkflowID: "cr3-checkpoint-recovery", RunID: runID, TaskID: 1, ScheduledEventID: 5},
					&tasks.ActivityTask{NamespaceID: namespaceID, WorkflowID: "cr3-checkpoint-recovery", RunID: runID, TaskID: 2, ScheduledEventID: 8},
				}},
			}))

			localConfig := *s.config
			localConfig.ShardUpdateMinInterval = dynamicconfig.GetDurationPropertyFn(time.Hour)
			localConfig.ShardUpdateMinTasksCompleted = dynamicconfig.GetIntPropertyFn(0)
			owner := shard.NewTestContext(s.controller, proto.Clone(initial).(*persistencespb.ShardInfo), &localConfig)
			owner.Resource.ClusterMetadata.EXPECT().GetAllClusterInfo().Return(map[string]cluster.ClusterInformation{}).AnyTimes()
			updateCalls, updateErrors := 0, 0
			owner.Resource.ShardMgr.EXPECT().UpdateShard(gomock.Any(), gomock.Any()).DoAndReturn(
				func(ctx context.Context, request *persistence.UpdateShardRequest) error {
					updateCalls++
					if schedule == "update_shard_error_after_delete" {
						updateErrors++
						return &persistence.TimeoutError{Msg: "injected UpdateShard timeout after committed range delete"}
					}
					return shardManager.UpdateShard(ctx, request)
				}).AnyTimes()

			if schedule == "batched_state_lags" {
				// Prime lastUpdated so the checkpoint SetQueueState call takes the too-early batching branch:
				// it mutates the owner-local shardInfo but intentionally does not persist the new queue state.
				s.Require().NoError(owner.SetQueueState(tasks.CategoryTransfer, 0, proto.Clone(state).(*persistencespb.QueueState)))
				s.Equal(1, updateCalls)
			}

			deleteManager := executionManager
			if schedule == "delete_execute_and_timeout" {
				faultFactory := faultinjection.NewFaultInjectionDatastoreFactory(
					(&config.FaultInjection{}).WithError(config.ExecutionStoreName, "RangeCompleteHistoryTasks", "ExecuteAndTimeout", 1),
					factory,
				)
				faultStore, faultErr := faultFactory.NewExecutionStore()
				s.Require().NoError(faultErr)
				deleteManager = persistence.NewExecutionManager(faultStore, serializer, nil, s.logger, dynamicconfig.GetIntPropertyFn(math.MaxInt), dynamicconfig.GetBoolPropertyFn(false))
			}

			deleteCalls, deleteErrors := 0, 0
			owner.Resource.ExecutionMgr.EXPECT().RangeCompleteHistoryTasks(gomock.Any(), gomock.Any()).DoAndReturn(
				func(ctx context.Context, request *persistence.RangeCompleteHistoryTasksRequest) error {
					deleteCalls++
					deleteErr := deleteManager.RangeCompleteHistoryTasks(ctx, request)
					if deleteErr != nil {
						deleteErrors++
					}
					return deleteErr
				}).AnyTimes()

			base := s.newQueueBase(owner, tasks.CategoryTransfer, nil)
			base.checkpointTimer = time.NewTimer(time.Hour)
			defer base.checkpointTimer.Stop()
			base.nonReadableScope.Range.InclusiveMin = tasks.NewImmediateKey(2)
			base.checkpoint()

			checkpointUpdateCalls := updateCalls
			checkpointUpdateErrors := updateErrors
			s.Equal(1, deleteCalls)
			if schedule == "delete_execute_and_timeout" {
				s.Equal(1, deleteErrors)
				s.Equal(int64(1), base.exclusiveDeletionHighWatermark.TaskID)
				s.Zero(checkpointUpdateCalls)
				s.Zero(checkpointUpdateErrors)
			} else if schedule == "update_shard_error_after_delete" {
				s.Zero(deleteErrors)
				s.Equal(int64(2), base.exclusiveDeletionHighWatermark.TaskID)
				s.Equal(1, checkpointUpdateCalls)
				s.Equal(1, checkpointUpdateErrors)
			} else {
				s.Zero(deleteErrors)
				s.Equal(int64(2), base.exclusiveDeletionHighWatermark.TaskID)
				s.Equal(1, checkpointUpdateCalls)
				s.Zero(checkpointUpdateErrors)
			}

			if schedule == "delete_execute_and_timeout" {
				executionManager.Close()
			}
			deleteManager.Close()
			shardManager.Close()
			factory.Close()

			independentDB, readErr := stdsql.Open("sqlite", cfg.DatabaseName)
			s.Require().NoError(readErr)
			var independentTaskID int64
			var independentCount int
			s.Require().NoError(independentDB.QueryRowContext(ctx, "SELECT COUNT(*), MIN(task_id) FROM transfer_tasks WHERE shard_id = 10").Scan(&independentCount, &independentTaskID))
			s.Equal(1, independentCount)
			s.Equal(int64(2), independentTaskID)
			s.Require().NoError(independentDB.Close())

			factory, executionManager, shardManager = openStore()
			defer factory.Close()
			defer executionManager.Close()
			defer shardManager.Close()

			reloaded, readErr := shardManager.GetOrCreateShard(ctx, &persistence.GetOrCreateShardRequest{ShardID: 10})
			s.Require().NoError(readErr)
			expectedDurableHigh := int64(1)
			if schedule == "healthy" {
				expectedDurableHigh = 2
			}
			durableHigh := reloaded.ShardInfo.QueueStates[int32(tasks.CategoryTransfer.ID())].ExclusiveReaderHighWatermark.TaskId
			s.Equal(expectedDurableHigh, durableHigh)

			recoveredOwner := shard.NewTestContext(s.controller, reloaded.ShardInfo, &localConfig)
			recovered := s.newQueueBase(recoveredOwner, tasks.CategoryTransfer, nil)
			s.Equal(expectedDurableHigh, recovered.nonReadableScope.Range.InclusiveMin.TaskID)

			readRequest := &persistence.GetHistoryTasksRequest{
				ShardID:             10,
				TaskCategory:        tasks.CategoryTransfer,
				InclusiveMinTaskKey: recovered.nonReadableScope.Range.InclusiveMin,
				ExclusiveMaxTaskKey: tasks.NewImmediateKey(3),
				BatchSize:           10,
			}
			rows, readErr := executionManager.GetHistoryTasks(ctx, readRequest)
			s.Require().NoError(readErr)
			s.Require().Len(rows.Tasks, 1)
			s.Equal(int64(2), rows.Tasks[0].GetTaskID())

			s.Require().NoError(executionManager.RangeCompleteHistoryTasks(ctx, &persistence.RangeCompleteHistoryTasksRequest{
				ShardID:             10,
				TaskCategory:        tasks.CategoryTransfer,
				InclusiveMinTaskKey: tasks.NewImmediateKey(1),
				ExclusiveMaxTaskKey: tasks.NewImmediateKey(2),
			}))
			rows, readErr = executionManager.GetHistoryTasks(ctx, readRequest)
			s.Require().NoError(readErr)
			s.Require().Len(rows.Tasks, 1)
			s.Equal(int64(2), rows.Tasks[0].GetTaskID())

			s.T().Logf("CR3 schedule=%s delete_calls=%d delete_errors=%d checkpoint_shard_updates=%d checkpoint_shard_update_errors=%d total_shard_updates=%d total_shard_update_errors=%d memory_delete=%d durable_reload_high=%d independent_remaining_rows=%d independent_min_task=%d recovered_read_task=%d retry_delete_preserved_unfinished=true",
				schedule, deleteCalls, deleteErrors, checkpointUpdateCalls, checkpointUpdateErrors, updateCalls, updateErrors, base.exclusiveDeletionHighWatermark.TaskID, durableHigh, independentCount, independentTaskID, rows.Tasks[0].GetTaskID())
		})
	}
}
GOEOF

chmod 600 "$TEST_FILE"
echo "source_sha=$(git -C "$REPO" rev-parse HEAD)"
echo "test_file=$TEST_FILE"
cd "$REPO"
timeout "${GO_TEST_TIMEOUT:-10m}" go test -tags=test_dep ./service/history/queues -run 'TestQueueBaseSuite/TestBugCR3CheckpointRecoveryEvidence' -count=1 -v
