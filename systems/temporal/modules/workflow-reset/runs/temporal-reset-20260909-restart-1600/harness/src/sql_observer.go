package sql

import (
	"context"
	"database/sql"
	"errors"
	"math"
	"time"

	"go.temporal.io/server/chasm"
	"go.temporal.io/server/common/config"
	"go.temporal.io/server/common/metrics"
	p "go.temporal.io/server/common/persistence"
	"go.temporal.io/server/common/persistence/sql/sqlplugin"
	"go.temporal.io/server/common/primitives"
	"go.temporal.io/server/common/resettrace"
	"go.temporal.io/server/common/resolver"
)

func (m *sqlExecutionStore) traceBind(workflow, namespace string, shard int32) {
	if resettrace.Lookup(workflow) == nil {
		return
	}
	resettrace.Bind(workflow, func() (any, error) { return m.traceSnapshot(workflow, namespace, shard) })
}
func (m *sqlExecutionStore) traceRuns(ctx context.Context, workflow, namespace string, shard int32, ids []string, tokens map[string][]byte) (map[string]any, error) {
	runs := map[string]any{}
	for _, id := range ids {
		row, err := m.DB.SelectFromExecutions(ctx, sqlplugin.ExecutionsFilter{ShardID: shard, NamespaceID: primitives.MustParseUUID(namespace), WorkflowID: workflow, RunID: primitives.MustParseUUID(id)})
		if err == sql.ErrNoRows {
			runs[id] = nil
			continue
		}
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
		runs[id] = resettrace.Fields{"info": info, "state": state, "next": row.NextEventID, "ver": row.DBRecordVersion}
		vh := info.GetVersionHistories()
		if len(vh.GetHistories()) > 0 {
			token := vh.Histories[vh.CurrentVersionHistoryIndex].BranchToken
			tokens[id] = token
			resettrace.Token(workflow, id, token)
		}
	}
	return runs, nil
}
func (m *sqlExecutionStore) traceNodes(ctx context.Context, shard int32, tree, branch string) ([]any, error) {
	rows, err := m.DB.RangeSelectFromHistoryNode(ctx, sqlplugin.HistoryNodeSelectFilter{ShardID: shard, TreeID: primitives.MustParseUUID(tree), BranchID: primitives.MustParseUUID(branch), MinNodeID: 1, MaxNodeID: math.MaxInt64, MinTxnID: MinTxnID, MaxTxnID: MaxTxnID, PageSize: 10000})
	if err != nil && err != sql.ErrNoRows {
		return nil, err
	}
	if len(rows) == 10000 {
		return nil, errors.New("reset observer requires history pagination")
	}
	batches := []any{}
	for _, row := range rows {
		events, err := m.serializer.DeserializeEvents(p.NewDataBlob(row.Data, row.DataEncoding))
		if err != nil {
			return nil, err
		}
		batches = append(batches, resettrace.Fields{"node": row.NodeID, "txn": row.TxnID, "prevTxn": row.PrevTxnID, "events": events})
	}
	return batches, nil
}
func (m *sqlExecutionStore) traceBranches(ctx context.Context, shard int32, trees map[string]bool) (map[string]any, error) {
	branches := map[string]any{}
	for tree := range trees {
		rows, err := m.DB.SelectFromHistoryTree(ctx, sqlplugin.HistoryTreeSelectFilter{ShardID: shard, TreeID: primitives.MustParseUUID(tree)})
		if err != nil && err != sql.ErrNoRows {
			return nil, err
		}
		for _, row := range rows {
			b, err := m.serializer.HistoryTreeInfoFromBlob(p.NewDataBlob(row.Data, row.DataEncoding))
			if err != nil {
				return nil, err
			}
			branches[row.BranchID.String()] = b
		}
	}
	return branches, nil
}
func (m *sqlExecutionStore) traceSnapshot(workflow, namespace string, shard int32) (snapshot any, retErr error) {
	if m.GetName() != "sqlite" {
		return m.traceSnapshotRead(workflow, namespace, shard)
	}
	// The writer's pool has one connection. A private, read-only WAL connection
	// observes committed state even while that writer is about to send COMMIT.
	reader, err := NewSQLDB(sqlplugin.DbKindMain, &config.SQL{
		PluginName: "sqlite", DatabaseName: m.GetDbName(),
		ConnectAttributes: map[string]string{"mode": "ro", "cache": "private", "busy_timeout": "1000"},
		MaxConns:          1,
	}, resolver.NewNoopResolver(), m.logger, metrics.NoopMetricsHandler)
	if err != nil {
		return nil, err
	}
	defer func() { retErr = errors.Join(retErr, reader.Close()) }()
	observer := *m
	observer.DB = reader
	return observer.traceSnapshotRead(workflow, namespace, shard)
}

func (m *sqlExecutionStore) traceSnapshotRead(workflow, namespace string, shard int32) (any, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	ids, tokens := resettrace.Runs(workflow)
	runs, err := m.traceRuns(ctx, workflow, namespace, shard, ids, tokens)
	if err != nil {
		return nil, err
	}
	trees := map[string]bool{}
	tokenInfo := map[string]any{}
	physical := map[string]string{}
	for id, token := range tokens {
		if len(token) == 0 {
			continue
		}
		b, err := m.serializer.HistoryBranchFromBlob(token)
		if err != nil {
			return nil, err
		}
		trees[b.TreeId] = true
		tokenInfo[id] = b
		physical[b.BranchId] = b.TreeId
		for _, a := range b.Ancestors {
			physical[a.BranchId] = b.TreeId
		}
	}
	branches, err := m.traceBranches(ctx, shard, trees)
	if err != nil {
		return nil, err
	}
	nodes := map[string]any{}
	for branch, tree := range physical {
		batches, err := m.traceNodes(ctx, shard, tree, branch)
		if err != nil {
			return nil, err
		}
		nodes[branch] = batches
	}
	current := ""
	c, err := m.DB.SelectFromCurrentExecutions(ctx, sqlplugin.CurrentExecutionsFilter{ShardID: shard, NamespaceID: primitives.MustParseUUID(namespace), WorkflowID: workflow, ArchetypeID: chasm.WorkflowArchetypeID})
	if err == nil {
		current = c.RunID.String()
	} else if err != sql.ErrNoRows {
		return nil, err
	}
	epoch, err := m.DB.SelectFromShards(ctx, sqlplugin.ShardsFilter{ShardID: shard})
	if err != nil {
		return nil, err
	}
	return resettrace.Fields{"runs": runs, "current": current, "range": epoch.RangeID, "branches": branches, "nodes": nodes, "tokens": tokenInfo, "plugin": m.GetName(), "database": m.GetDbName(), "shard": shard}, nil
}
