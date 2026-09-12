package testcore

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"go.temporal.io/server/common/config"
	"go.temporal.io/server/common/speculatrace"
)

func (tc *TestCluster) SpeculaPersistenceConfig() config.Persistence {
	return tc.testBase.DefaultTestCluster.Config()
}

func (tc *TestCluster) SpeculaBackupDatabase(ctx context.Context, target string) (retErr error) {
	cfg := tc.SpeculaPersistenceConfig()
	source := cfg.DataStores[cfg.DefaultStore].SQL
	db, err := sql.Open("sqlite", "file:"+source.DatabaseName+"?mode=ro&_pragma=synchronous=normal")
	if err != nil {
		return err
	}
	defer func() { retErr = errors.Join(retErr, db.Close()) }()
	var mode string
	var sync int
	if err = db.QueryRowContext(ctx, "PRAGMA journal_mode").Scan(&mode); err != nil {
		return err
	}
	if err = db.QueryRowContext(ctx, "PRAGMA synchronous").Scan(&sync); err != nil {
		return err
	}
	if mode != "wal" || sync != 1 {
		return fmt.Errorf("unexpected pragmas: %s %d", mode, sync)
	}
	_, err = db.ExecContext(ctx, "VACUUM INTO ?", target)
	if err == nil {
		speculatrace.Emit("", "ReadWorkflowExecution", speculatrace.Fields{"boundary": "sqlite-consistent-backup", "source": source.DatabaseName, "backup": target, "journalMode": mode, "synchronous": sync})
	}
	return err
}
