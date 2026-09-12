#!/usr/bin/env bash
set -euo pipefail

REPO="/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-nexus-20260911/temporal-nexus/.specula-output/confirmation/CR-4/worktree"
PKG_DIR="$REPO/service/history/hsm/nexusoperations/workflow"
TEST_FILE="$PKG_DIR/zz_cr4_repro_test.go"

cleanup() {
  rm -f "$TEST_FILE"
}
trap cleanup EXIT

cat >"$TEST_FILE" <<'GOEOF'
package workflow_test

import (
	"context"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	commandpb "go.temporal.io/api/command/v1"
	enumspb "go.temporal.io/api/enums/v1"
	"go.temporal.io/server/common/dynamicconfig"
	"go.temporal.io/server/service/history/hsm"
	"go.temporal.io/server/service/history/hsm/nexusoperations"
	"google.golang.org/protobuf/types/known/durationpb"
)

func TestBugCR4ScheduleToCloseLimitWithOmittedTimeout(t *testing.T) {
	cfg := *defaultConfig
	cfg.MaxOperationScheduleToCloseTimeout = dynamicconfig.GetDurationPropertyFnFilteredByNamespace(time.Minute)

	t.Run("control explicit long timeout is capped", func(t *testing.T) {
		tcx := newTestContext(t, &cfg)
		err := tcx.scheduleHandler(context.Background(), tcx.ms, commandValidator{maxPayloadSize: 1}, 1, &commandpb.Command{
			Attributes: &commandpb.Command_ScheduleNexusOperationCommandAttributes{
				ScheduleNexusOperationCommandAttributes: &commandpb.ScheduleNexusOperationCommandAttributes{
					Endpoint:               "endpoint",
					Service:                "service",
					Operation:              "op",
					ScheduleToCloseTimeout: durationpb.New(time.Hour),
				},
			},
		})
		require.NoError(t, err)
		require.Len(t, tcx.history.Events, 1)
		got := tcx.history.Events[0].GetNexusOperationScheduledEventAttributes().ScheduleToCloseTimeout.AsDuration()
		require.Equal(t, time.Minute, got)
		t.Logf("CONTROL_OK: explicit 1h schedule-to-close capped to %s", got)
	})

	t.Run("omitted timeout bypasses configured max and emits no timeout task", func(t *testing.T) {
		tcx := newTestContext(t, &cfg)
		require.Nil(t, tcx.execInfo.WorkflowRunTimeout)

		err := tcx.scheduleHandler(context.Background(), tcx.ms, commandValidator{maxPayloadSize: 1}, 1, &commandpb.Command{
			Attributes: &commandpb.Command_ScheduleNexusOperationCommandAttributes{
				ScheduleNexusOperationCommandAttributes: &commandpb.ScheduleNexusOperationCommandAttributes{
					Endpoint:  "endpoint",
					Service:   "service",
					Operation: "op",
				},
			},
		})
		require.NoError(t, err)
		require.Len(t, tcx.history.Events, 1)

		event := tcx.history.Events[0]
		got := event.GetNexusOperationScheduledEventAttributes().ScheduleToCloseTimeout.AsDuration()
		require.Zero(t, got)

		child, err := tcx.ms.HSM().Child([]hsm.Key{{
			Type: nexusoperations.OperationMachineType,
			ID:   strconv.FormatInt(event.EventId, 10),
		}})
		require.NoError(t, err)
		op, err := hsm.MachineData[nexusoperations.Operation](child)
		require.NoError(t, err)
		tasks, err := op.RegenerateTasks(child)
		require.NoError(t, err)
		require.Equal(t, []string{nexusoperations.TaskTypeInvocation}, taskTypesCR4(tasks))

		t.Logf("BUG_TRIGGERED: omitted schedule-to-close persisted as %s despite max %s", got, time.Minute)
		t.Logf("BUG_TRIGGERED: regenerated task types are %v, so no %s timer will enforce the configured max", taskTypesCR4(tasks), nexusoperations.TaskTypeScheduleToCloseTimeout)
	})

	t.Run("run timeout masks omitted operation timeout", func(t *testing.T) {
		tcx := newTestContext(t, &cfg)
		tcx.execInfo.WorkflowRunTimeout = durationpb.New(30 * time.Second)

		err := tcx.scheduleHandler(context.Background(), tcx.ms, commandValidator{maxPayloadSize: 1}, 1, &commandpb.Command{
			Attributes: &commandpb.Command_ScheduleNexusOperationCommandAttributes{
				ScheduleNexusOperationCommandAttributes: &commandpb.ScheduleNexusOperationCommandAttributes{
					Endpoint:  "endpoint",
					Service:   "service",
					Operation: "op",
				},
			},
		})
		require.NoError(t, err)
		require.Len(t, tcx.history.Events, 1)
		got := tcx.history.Events[0].GetNexusOperationScheduledEventAttributes().ScheduleToCloseTimeout.AsDuration()
		require.Equal(t, 30*time.Second, got)
		t.Logf("MASK_CONTROL_OK: workflow run timeout sets omitted operation schedule-to-close to %s", got)
	})

	require.Equal(t, enumspb.EVENT_TYPE_NEXUS_OPERATION_SCHEDULED.String(), enumspb.EVENT_TYPE_NEXUS_OPERATION_SCHEDULED.String())
}

func taskTypesCR4(tasks []hsm.Task) []string {
	types := make([]string, 0, len(tasks))
	for _, task := range tasks {
		types = append(types, task.Type())
	}
	return types
}
GOEOF

cd "$REPO"
timeout 10m go test ./service/history/hsm/nexusoperations/workflow -run TestBugCR4ScheduleToCloseLimitWithOmittedTimeout -count=1 -v
