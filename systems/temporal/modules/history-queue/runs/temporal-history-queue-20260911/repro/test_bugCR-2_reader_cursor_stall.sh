#!/usr/bin/env bash
set -euo pipefail

REPO="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/confirmation/CR-2/worktree"
TEST_FILE="$REPO/service/history/queues/bugcr2_cursor_stall_repro_test.go"

cleanup() {
  rm -f "$TEST_FILE"
}
trap cleanup EXIT

cat >"$TEST_FILE" <<'GO'
package queues

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"go.temporal.io/server/common/collection"
	"go.temporal.io/server/common/definition"
	"go.temporal.io/server/common/dynamicconfig"
	"go.temporal.io/server/common/predicates"
	"go.temporal.io/server/service/history/tasks"
	"go.temporal.io/server/service/history/tests"
	"go.uber.org/mock/gomock"
)

func TestBugCR2ReaderCursorStall(t *testing.T) {
	for _, shrinkBeforeNextRead := range []bool{false, true} {
		name := "healthy_read_before_checkpoint_shrink"
		if shrinkBeforeNextRead {
			name = "checkpoint_shrink_orphans_live_reader_cursor"
		}
		t.Run(name, func(t *testing.T) {
			s := new(readerSuite)
			s.SetT(t)
			s.SetupTest()
			defer s.TearDownTest()

			rows := []tasks.Task{
				&tasks.WorkflowTask{
					WorkflowKey:         definition.NewWorkflowKey(tests.LocalNamespaceEntry.ID().String(), "bug-cr2-workflow", "run-1"),
					TaskID:              1,
					VisibilityTimestamp: time.Now(),
				},
				&tasks.ActivityTask{
					WorkflowKey:         definition.NewWorkflowKey(tests.LocalNamespaceEntry.ID().String(), "bug-cr2-workflow", "run-1"),
					TaskID:              3,
					VisibilityTimestamp: time.Now(),
				},
			}
			reads := 0
			provider := func(r Range) collection.PaginationFn[tasks.Task] {
				return func([]byte) ([]tasks.Task, []byte, error) {
					reads++
					selected := make([]tasks.Task, 0, len(rows))
					for _, task := range rows {
						if r.ContainsKey(task.GetKey()) {
							selected = append(selected, task)
						}
					}
					return selected, nil, nil
				}
			}

			scopes := []Scope{
				NewScope(NewRange(tasks.NewImmediateKey(1), tasks.NewImmediateKey(2)), predicates.Universal[tasks.Task]()),
				NewScope(NewRange(tasks.NewImmediateKey(3), tasks.NewImmediateKey(4)), predicates.Universal[tasks.Task]()),
			}
			reader := s.newTestReader(scopes, provider, NoopReaderCompletionFn)
			reader.options.BatchSize = dynamicconfig.GetIntPropertyFn(1)

			var submitted []int64
			s.mockScheduler.EXPECT().TrySubmit(gomock.Any()).DoAndReturn(func(e Executable) bool {
				submitted = append(submitted, e.GetTaskID())
				e.Ack()
				return true
			}).AnyTimes()

			reader.loadAndSubmitTasks()
			require.Equal(t, []int64{1}, submitted)
			require.True(t, reader.nextReadSlice.Value.(Slice).MoreTasks())

			if shrinkBeforeNextRead {
				require.Equal(t, 1, reader.ShrinkSlices())
				require.Len(t, reader.Scopes(), 1)
				require.NotSame(t, reader.slices.Front(), reader.nextReadSlice)
			}

			for range 3 {
				reader.loadAndSubmitTasks()
			}

			if !shrinkBeforeNextRead {
				require.Equal(t, []int64{1, 3}, submitted)
				t.Logf("healthy_control submitted=%v persistence_reads=%d", submitted, reads)
				return
			}

			require.Equal(t, []int64{1}, submitted)
			require.Nil(t, reader.nextReadSlice)
			require.True(t, reader.slices.Front().Value.(Slice).MoreTasks())

			reader.Notify()
			reader.loadAndSubmitTasks()
			require.Equal(t, []int64{1}, submitted)
			t.Logf("bug_triggered submitted=%v persistence_reads=%d remaining_scopes=%v cursor_nil=%v notify_repaired=false", submitted, reads, reader.Scopes(), reader.nextReadSlice == nil)

			reloaded := s.newTestReader(reader.Scopes(), provider, NoopReaderCompletionFn)
			reloaded.loadAndSubmitTasks()
			require.Equal(t, []int64{1, 3}, submitted)
			t.Logf("reconstruction_repaired submitted=%v persistence_reads=%d", submitted, reads)
		})
	}
}
GO

cd "$REPO"
echo "source_head=$(git rev-parse HEAD)"
echo "preflight=plain go test currently requires -tags test_dep because existing local instrumentation references hqScope from a test_dep file"
timeout 10m go test -tags test_dep ./service/history/queues -run TestBugCR2ReaderCursorStall -count=1 -v
