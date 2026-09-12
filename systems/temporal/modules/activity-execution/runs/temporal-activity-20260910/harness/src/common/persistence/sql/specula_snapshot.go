package sql

import (
	"context"
	"database/sql"
	"errors"
	"math"
	"time"

	persistencespb "go.temporal.io/server/api/persistence/v1"
	p "go.temporal.io/server/common/persistence"
	"go.temporal.io/server/common/persistence/sql/sqlplugin"
	"go.temporal.io/server/common/primitives"
	"go.temporal.io/server/common/speculatrace"
)

// Read through the transaction that performed the mutation; this snapshot is
// declared committed only after the delegate's SQL commit succeeds.
func (m *sqlExecutionStore) speculaSnapshot(ctx context.Context, db sqlplugin.TableCRUD, shard int32, ns, wf, run string) (speculatrace.Fields, error) {
	n := primitives.MustParseUUID(ns)
	r := primitives.MustParseUUID(run)
	row, err := db.SelectFromExecutions(ctx, sqlplugin.ExecutionsFilter{ShardID: shard, NamespaceID: n, WorkflowID: wf, RunID: r})
	if err != nil {
		return nil, err
	}
	info, err := m.serializer.WorkflowExecutionInfoFromBlob(p.NewDataBlob(row.Data, row.DataEncoding))
	if err != nil {
		return nil, err
	}
	state, err := m.serializer.WorkflowExecutionStateFromBlob(p.NewDataBlob(row.State, row.StateEncoding))
	if err != nil {
		return nil, err
	}
	ai, err := m.speculaActivities(ctx, db, sqlplugin.ActivityInfoMapsAllFilter{ShardID: shard, NamespaceID: n, WorkflowID: wf, RunID: r})
	if err != nil {
		return nil, err
	}
	events, err := m.speculaBuffer(ctx, db, sqlplugin.BufferedEventsFilter{ShardID: shard, NamespaceID: n, WorkflowID: wf, RunID: r})
	if err != nil {
		return nil, err
	}
	tasks, err := speculaTasks(ctx, db, shard, wf, run)
	if err != nil {
		return nil, err
	}
	shardrow, err := db.SelectFromShards(ctx, sqlplugin.ShardsFilter{ShardID: shard})
	if err != nil {
		return nil, err
	}
	return speculatrace.Fields{"database": m.DB.DbName(), "dbRecordVersion": row.DBRecordVersion, "rangeId": shardrow.RangeID, "nextEventId": row.NextEventID,
		"executionInfo": speculatrace.Proto(info), "executionState": speculatrace.Proto(state), "activityInfos": ai, "bufferedEvents": events, "tasks": tasks}, nil
}
func (m *sqlExecutionStore) speculaActivities(ctx context.Context, db sqlplugin.TableCRUD, filter sqlplugin.ActivityInfoMapsAllFilter) (map[int64]any, error) {
	rows, err := db.SelectAllFromActivityInfoMaps(ctx, filter)
	if err != nil && err != sql.ErrNoRows {
		return nil, err
	}
	ai := map[int64]any{}
	for _, v := range rows {
		a, e := m.serializer.ActivityInfoFromBlob(p.NewDataBlob(v.Data, v.DataEncoding))
		if e != nil {
			return nil, e
		}
		ai[v.ScheduleID] = speculatrace.Proto(a)
	}
	return ai, nil
}
func (m *sqlExecutionStore) speculaBuffer(ctx context.Context, db sqlplugin.TableCRUD, filter sqlplugin.BufferedEventsFilter) ([]any, error) {
	rows, err := db.SelectFromBufferedEvents(ctx, filter)
	if err != nil && err != sql.ErrNoRows {
		return nil, err
	}
	events := []any{}
	for _, v := range rows {
		ev, e := m.serializer.DeserializeEvents(p.NewDataBlob(v.Data, v.DataEncoding))
		if e != nil {
			return nil, e
		}
		for _, x := range ev {
			events = append(events, speculatrace.Proto(x))
		}
	}
	return events, nil
}
func speculaTasks(ctx context.Context, db sqlplugin.TableCRUD, shard int32, wf, run string) ([]any, error) {
	transfers, err := db.RangeSelectFromTransferTasks(ctx, sqlplugin.TransferTasksRangeFilter{ShardID: shard, InclusiveMinTaskID: 0, ExclusiveMaxTaskID: math.MaxInt64, PageSize: 10000})
	if err != nil && err != sql.ErrNoRows {
		return nil, err
	}
	timers, err := db.RangeSelectFromTimerTasks(ctx, sqlplugin.TimerTasksRangeFilter{ShardID: shard, InclusiveMinTaskID: 0, InclusiveMinVisibilityTimestamp: time.Unix(0, 0), ExclusiveMaxVisibilityTimestamp: time.Date(2100, 1, 1, 0, 0, 0, 0, time.UTC), PageSize: 10000})
	if err != nil && err != sql.ErrNoRows {
		return nil, err
	}
	if len(transfers) == 10000 || len(timers) == 10000 {
		return nil, errors.New("trace task read truncated at 10000 rows")
	}
	ts := []any{}
	for _, v := range transfers {
		x := &persistencespb.TransferTaskInfo{}
		if e := x.Unmarshal(v.Data); e != nil {
			return nil, e
		}
		if x.WorkflowId == wf && x.RunId == run {
			ts = append(ts, speculatrace.Fields{"category": "transfer", "taskId": v.TaskID, "task": speculatrace.Proto(x)})
		}
	}
	for _, v := range timers {
		x := &persistencespb.TimerTaskInfo{}
		if e := x.Unmarshal(v.Data); e != nil {
			return nil, e
		}
		if x.WorkflowId == wf && x.RunId == run {
			ts = append(ts, speculatrace.Fields{"category": "timer", "taskId": v.TaskID, "visibility": v.VisibilityTimestamp, "task": speculatrace.Proto(x)})
		}
	}
	return ts, nil
}
