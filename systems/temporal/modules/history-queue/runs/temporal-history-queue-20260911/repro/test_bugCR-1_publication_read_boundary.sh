#!/usr/bin/env bash
set -euo pipefail

WORKTREE="${WORKTREE:-/home/ubuntu/temporal-investigation-20260909/overnight-20260909/specula-engine/runs/temporal-history-queue-20260911/temporal-history-queue/.specula-output/confirmation/CR-1/worktree}"
EXPECTED_REV="0c010ce5fe8c0180aa7573c72fe8fc87c6df7025"

cd "$WORKTREE"

echo "CR-1 reproduction attempt: uncertain publication versus read eligibility"
REV="$(git rev-parse HEAD)"
echo "source_revision=$REV"
if [[ "$REV" != "$EXPECTED_REV" ]]; then
  echo "unexpected source revision; expected $EXPECTED_REV" >&2
  exit 2
fi

echo
echo "Level 0: ordinary shard task-key guard tests"
timeout 5m go test -tags test_dep ./service/history/shard \
  -run 'TestTaskKeyManagerSuite/TestSetAndTrackTaskKeys|TestTaskRequestTrackerSuite/TestRequestCompletion' \
  -count=1 -v

echo
echo "Level 1: existing SQLite fault-injection publication evidence, if present"
if [[ -f service/history/shard/publication_persistence_evidence_test.go ]]; then
  timeout 5m go test -tags test_dep ./service/history/shard \
    -run 'TestPublicationPersistenceEvidence' \
    -count=1 -v
else
  echo "publication_persistence_evidence_test.go absent; Level 1 local probe skipped"
fi

echo
echo "Level 2: direct SQLite interleaving for old read transaction versus fresh RangeID"
PROBE_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$PROBE_DIR"
}
trap cleanup EXIT
PROBE="$PROBE_DIR/sqlite_late_writer_probe.go"
cat >"$PROBE" <<'GO'
package main

import (
	"context"
	"database/sql"
	"fmt"
	"net/url"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite"
)

func check(label string, err error) {
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: %v\n", label, err)
		os.Exit(2)
	}
}

func main() {
	ctx := context.Background()
	dir, err := os.MkdirTemp("", "cr1-sqlite-")
	check("tempdir", err)
	defer os.RemoveAll(dir)

	dbFile := filepath.Join(dir, "history.sqlite")
	params := url.Values{}
	params.Set("cache", "private")
	params.Add("_pragma", "journal_mode=wal")
	params.Add("_pragma", "synchronous=full")
	params.Add("_pragma", "busy_timeout=10000")
	dsn := "file:" + dbFile + "?" + params.Encode()

	db, err := sql.Open("sqlite", dsn)
	check("open", err)
	defer db.Close()
	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(4)

	_, err = db.ExecContext(ctx, `
CREATE TABLE shards (shard_id INTEGER PRIMARY KEY, range_id INTEGER NOT NULL, data BLOB, data_encoding TEXT);
CREATE TABLE transfer_tasks (shard_id INTEGER NOT NULL, task_id INTEGER NOT NULL, data BLOB, data_encoding TEXT, PRIMARY KEY (shard_id, task_id));
INSERT INTO shards(shard_id, range_id, data, data_encoding) VALUES (1, 1, X'00', 'proto3');
`)
	check("schema", err)

	oldTx, err := db.BeginTx(ctx, nil)
	check("old begin", err)
	var oldReadRange int64
	check("old read range", oldTx.QueryRowContext(ctx, "SELECT range_id FROM shards WHERE shard_id = 1").Scan(&oldReadRange))
	fmt.Printf("old_tx_read_range=%d\n", oldReadRange)

	newTx, err := db.BeginTx(ctx, nil)
	check("new begin", err)
	var newReadRange int64
	check("new read range", newTx.QueryRowContext(ctx, "SELECT range_id FROM shards WHERE shard_id = 1").Scan(&newReadRange))
	_, err = newTx.ExecContext(ctx, "UPDATE shards SET range_id = 2 WHERE shard_id = 1")
	check("new update range", err)
	check("new commit range", newTx.Commit())
	fmt.Printf("new_owner_committed_range=2 after_reading_range=%d\n", newReadRange)

	_, insertErr := oldTx.ExecContext(ctx, "INSERT INTO transfer_tasks(shard_id, task_id, data, data_encoding) VALUES (1, 8, X'01', 'proto3')")
	if insertErr != nil {
		fmt.Printf("old_tx_late_insert_error=%T: %v\n", insertErr, insertErr)
		check("old rollback", oldTx.Rollback())
	} else {
		commitErr := oldTx.Commit()
		fmt.Printf("old_tx_late_insert_commit_error=%T: %v\n", commitErr, commitErr)
		if commitErr == nil {
			fmt.Println("old_tx_late_insert_committed=true")
		}
	}

	var finalRange int64
	var transferRows int
	var minTask sql.NullInt64
	check("final read", db.QueryRowContext(ctx, "SELECT range_id FROM shards WHERE shard_id = 1").Scan(&finalRange))
	check("row read", db.QueryRowContext(ctx, "SELECT COUNT(*), MIN(task_id) FROM transfer_tasks WHERE shard_id = 1").Scan(&transferRows, &minTask))
	fmt.Printf("final_range=%d transfer_rows=%d min_task_valid=%t min_task=%d\n", finalRange, transferRows, minTask.Valid, minTask.Int64)

	if finalRange == 2 && transferRows > 0 {
		fmt.Println("late_publication_below_renewed_range=true")
		os.Exit(1)
	}
	fmt.Println("late_publication_below_renewed_range=false")
	fmt.Println("sqlite_snapshot_or_range_fence_blocked_old_writer=true")
}
GO
timeout 2m go run "$PROBE"

echo
echo "Level 2b: queue cursor/reload recovery probe, if present"
if [[ -f service/history/queues/queue_base_recovery_sqlite_test.go ]]; then
  timeout 8m go test -tags test_dep ./service/history/queues \
    -run 'TestQueueBaseSuite/TestCheckpointSQLiteReaderCursor/(healthy_read_before_checkpoint|checkpoint_orphans_nondefault_cursor)' \
    -count=1 -v
else
  echo "queue_base_recovery_sqlite_test.go absent; Level 2b local probe skipped"
fi

echo
echo "Level 2c: transfer executor and Matching acceptance/reload probe, if present"
if [[ -f service/history/hq_scenarios_test.go ]]; then
  HQ_EVIDENCE_DIR="${HQ_EVIDENCE_DIR:-$PROBE_DIR/hq-evidence}" \
    timeout 10m go test -tags test_dep ./service/history \
      -run 'TestTransferQueueActiveTaskExecutorSuite/TestHQTrace(CursorHealthy|CursorStall)' \
      -count=1 -v
else
  echo "hq_scenarios_test.go absent; Level 2c local probe skipped"
fi

echo
echo "Level 3: no source patch applied"
echo "A source patch that permits an old transaction to commit after a newer RangeID would alter SQLite/persistence semantics rather than widen a real timing window."

echo
echo "CR-1 result: publication-below-read-boundary trigger not reproduced; safeguards blocked or recovered the tested schedules."
