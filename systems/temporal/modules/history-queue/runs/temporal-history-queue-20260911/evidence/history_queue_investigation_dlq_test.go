package queues_test

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"go.temporal.io/api/serviceerror"
	persistencespb "go.temporal.io/server/api/persistence/v1"
	"go.temporal.io/server/common/cluster"
	"go.temporal.io/server/common/config"
	"go.temporal.io/server/common/definition"
	"go.temporal.io/server/common/log"
	"go.temporal.io/server/common/metrics"
	"go.temporal.io/server/common/persistence"
	"go.temporal.io/server/common/persistence/serialization"
	persistencesql "go.temporal.io/server/common/persistence/sql"
	_ "go.temporal.io/server/common/persistence/sql/sqlplugin/sqlite"
	"go.temporal.io/server/common/resolver"
	ctasks "go.temporal.io/server/common/tasks"
	"go.temporal.io/server/common/telemetry"
	"go.temporal.io/server/service/history/queues"
	"go.temporal.io/server/service/history/tasks"
	"go.temporal.io/server/service/history/tests"
	"go.uber.org/mock/gomock"
)

type investigationDLQWriter struct {
	persistence.HistoryTaskQueueManager
	fault     string
	injected  int
	committed int
}

func (w *investigationDLQWriter) EnqueueTask(ctx context.Context, req *persistence.EnqueueTaskRequest) (*persistence.EnqueueTaskResponse, error) {
	fault := w.fault
	w.fault = ""
	if fault == "before" {
		w.injected++
		return nil, &persistence.TimeoutError{Msg: "investigation: definite pre-write failure"}
	}
	resp, err := w.HistoryTaskQueueManager.EnqueueTask(ctx, req)
	if err != nil {
		return resp, err
	}
	w.committed++
	if fault == "after" {
		w.injected++
		return nil, &persistence.TimeoutError{Msg: "investigation: committed DLQ enqueue reply lost"}
	}
	return resp, nil
}

func TestHistoryQueueInvestigationDLQDurableAcceptance(t *testing.T) {
	for _, fault := range []string{"healthy", "before", "after"} {
		t.Run(fault, func(t *testing.T) {
			s := &executableSuite{}
			s.SetT(t)
			s.SetupTest()
			cfg := config.SQL{
				PluginName:        "sqlite",
				DatabaseName:      filepath.Join(t.TempDir(), "history-dlq.sqlite"),
				ConnectAttributes: map[string]string{"setup": "true", "journal_mode": "wal"},
				MaxConns:          1,
			}
			open := func() (*persistencesql.Factory, persistence.HistoryTaskQueueManager) {
				f := persistencesql.NewFactory(cfg, resolver.NewNoopResolver(), cluster.TestCurrentClusterName,
					log.NewTestLogger(), metrics.NoopMetricsHandler, serialization.NewSerializer())
				q, err := f.NewQueueV2()
				require.NoError(t, err)
				return f, persistence.NewHistoryTaskQueueManager(q, serialization.NewSerializer())
			}
			f, manager := open()
			defer func() { f.Close() }()
			wrapped := &investigationDLQWriter{HistoryTaskQueueManager: manager, fault: fault}
			writer := queues.NewDLQWriter(wrapped, metrics.NoopMetricsHandler, log.NewTestLogger(), s.mockNamespaceRegistry, s.chasmRegistry)
			task := &tasks.WorkflowTask{
				WorkflowKey: definition.NewWorkflowKey(tests.NamespaceID.String(), "dlq-obligation", tests.RunID),
				TaskID:      42, ScheduledEventID: 2, TaskQueue: "normal-queue", VisibilityTimestamp: time.Now(),
			}
			e := queues.NewExecutable(queues.DefaultReaderId, task, s.mockExecutor, s.mockScheduler, s.mockRescheduler,
				queues.NewNoopPriorityAssigner(), s.timeSource, s.mockNamespaceRegistry, s.mockClusterMetadata,
				s.chasmRegistry, queues.GetTaskTypeTagValue, log.NewTestLogger(), metrics.NoopMetricsHandler, telemetry.NoopTracer,
				func(p *queues.ExecutableParams) {
					p.DLQEnabled = func() bool { return true }
					p.DLQWriter = writer
					p.MaxUnexpectedErrorAttempts = func() int { return 1 }
				})
			s.mockExecutor.EXPECT().Execute(gomock.Any(), e).Return(queues.ExecuteResponse{
				ExecutedAsActive: true, ExecutionErr: serviceerror.NewUnavailable("investigation: downstream unavailable"),
			})
			require.ErrorIs(t, e.HandleErr(e.Execute()), queues.ErrTerminalTaskFailure)
			require.Equal(t, ctasks.TaskStatePending, e.State())
			key := persistence.QueueKey{QueueType: persistence.QueueTypeHistoryDLQ, Category: tasks.CategoryTransfer,
				SourceCluster: cluster.TestCurrentClusterName, TargetCluster: cluster.TestCurrentClusterName}
			read := func(want int) {
				r, err := manager.ReadTasks(t.Context(), &persistence.ReadTasksRequest{QueueKey: key, PageSize: 10})
				require.NoError(t, err)
				require.Len(t, r.Tasks, want)
				for i, row := range r.Tasks {
					require.Equal(t, int64(42), row.Task.GetTaskID())
					require.Equal(t, int64(i), row.MessageMetadata.ID)
				}
				t.Logf("durable readback: fault=%s rows=%d committed=%d injected=%d executable_state=%v", fault, want, wrapped.committed, wrapped.injected, e.State())
			}
			err := e.Execute()
			if fault != "healthy" {
				require.Error(t, err)
				require.Error(t, e.HandleErr(err))
				require.Equal(t, 1, wrapped.injected)
				require.Equal(t, ctasks.TaskStatePending, e.State())
				if fault == "before" {
					read(0)
				} else {
					read(1)
				}
				err = e.Execute()
			}
			require.NoError(t, err)
			e.Ack()
			require.Equal(t, ctasks.TaskStateAcked, e.State())
			want := 1
			if fault == "after" {
				want = 2
			}
			read(want)
			f.Close()
			f, manager = open()
			t.Log("manager reconstruction: Temporal SQLite connPool retains its underlying database pool")
			read(want)
			independentDB, err := sql.Open("sqlite", cfg.DatabaseName)
			require.NoError(t, err)
			defer func() { require.NoError(t, independentDB.Close()) }()
			rows, err := independentDB.QueryContext(t.Context(),
				"SELECT message_id, message_payload FROM queue_messages WHERE queue_type = ? AND queue_name = ? AND queue_partition = ? ORDER BY message_id",
				key.QueueType, key.GetQueueName(), 0)
			require.NoError(t, err)
			defer func() { require.NoError(t, rows.Close()) }()
			var messageIDs []int64
			for rows.Next() {
				var messageID int64
				var payload []byte
				require.NoError(t, rows.Scan(&messageID, &payload))
				var storedTask persistencespb.HistoryTask
				require.NoError(t, storedTask.Unmarshal(payload))
				require.Equal(t, int32(1), storedTask.ShardId)
				decodedTask, err := serialization.NewSerializer().DeserializeTask(tasks.CategoryTransfer, storedTask.Blob)
				require.NoError(t, err)
				require.Equal(t, int64(42), decodedTask.GetTaskID())
				require.Equal(t, task.WorkflowKey, definition.NewWorkflowKey(decodedTask.GetNamespaceID(), decodedTask.GetWorkflowID(), decodedTask.GetRunID()))
				messageIDs = append(messageIDs, messageID)
			}
			require.NoError(t, rows.Err())
			require.Len(t, messageIDs, want)
			for i, messageID := range messageIDs {
				require.Equal(t, int64(i), messageID)
			}
			t.Logf("independent database/sql connection: fault=%s physical_rows=%d message_ids=%v original_task=42 source_shard=1; no process restart", fault, len(messageIDs), messageIDs)
		})
	}
}
