#!/bin/bash
# run.sh — One-command harness: start cluster, run tests, extract logs, preprocess traces.
#
# Usage: cd case-studies/mongodb-rangedeletion && bash harness/run.sh
#
# Prerequisites: docker, docker compose

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACES_DIR="$CASE_DIR/traces"
HARNESS_SRC="$SCRIPT_DIR/src"
LOGS_DIR="$SCRIPT_DIR/logs"

mkdir -p "$TRACES_DIR" "$LOGS_DIR"

echo "============================================"
echo "  MongoDB Range Deletion Trace Harness"
echo "============================================"

# Step 1: Start cluster
echo ""
echo ">>> Step 1: Starting sharded cluster"
bash "$SCRIPT_DIR/apply.sh"

# Step 2: Enable verbose logging on shards
echo ""
echo ">>> Step 2: Enabling verbose logging"
for container in rd-shard0 rd-shard1; do
    docker exec "$container" mongosh --port 27018 --eval '
    db.adminCommand({
        setParameter: 1,
        logComponentVerbosity: {
            sharding: {
                rangeDeleter: {verbosity: 2},
                migration: {verbosity: 2}
            }
        }
    });
    ' --quiet 2>/dev/null || true
    echo "  Verbose logging enabled on $container"
done

docker exec rd-mongos mongosh --port 27017 --eval '
db.adminCommand({enableSharding: "testdb"});
' --quiet 2>/dev/null || true

# Step 3: Copy test scripts into mongos container
echo ""
echo ">>> Step 3: Preparing test scripts"
docker exec rd-mongos mkdir -p /scripts 2>/dev/null || true
for f in test_basic_migration.js test_concurrent_migrations.js test_stepdown_recovery.js; do
    docker cp "$HARNESS_SRC/$f" rd-mongos:/scripts/
done

# Step 4: Run test scenarios with timestamp bookmarks
echo ""
echo ">>> Step 4: Running test scenarios"

declare -A MARK_BEFORE
declare -A MARK_AFTER

run_test() {
    local test_name=$1
    local test_file=$2
    echo ""
    echo "--- Running $test_name ---"
    MARK_BEFORE[$test_name]=$(date -u +"%Y-%m-%dT%H:%M:%S.000+00:00")
    sleep 1
    docker exec rd-mongos mongosh --port 27017 --file "/scripts/$test_file" --quiet 2>&1 || {
        echo "  WARNING: $test_name may have had issues"
    }
    sleep 2
    MARK_AFTER[$test_name]=$(date -u +"%Y-%m-%dT%H:%M:%S.000+00:00")
    echo "  Time window: ${MARK_BEFORE[$test_name]} -> ${MARK_AFTER[$test_name]}"
    echo "--- $test_name done ---"
}

run_test "basic_migration" "test_basic_migration.js"
run_test "concurrent_migrations" "test_concurrent_migrations.js"

# Step 5: Extract logs from shard containers
echo ""
echo ">>> Step 5: Extracting logs"
docker logs rd-shard0 2>&1 > "$LOGS_DIR/shard0.log"
echo "  shard0.log: $(wc -l < "$LOGS_DIR/shard0.log") lines"
docker logs rd-shard1 2>&1 > "$LOGS_DIR/shard1.log"
echo "  shard1.log: $(wc -l < "$LOGS_DIR/shard1.log") lines"

# Step 6: Preprocess traces
echo ""
echo ">>> Step 6: Preprocessing traces"

python3 "$HARNESS_SRC/preprocess_trace.py" \
    "$LOGS_DIR/shard0.log" \
    "$TRACES_DIR/basic_migration.ndjson" \
    --after "${MARK_BEFORE[basic_migration]}" \
    --before "${MARK_AFTER[basic_migration]}" 2>&1

python3 "$HARNESS_SRC/preprocess_trace.py" \
    "$LOGS_DIR/shard0.log" \
    "$TRACES_DIR/concurrent_migrations.ndjson" \
    --after "${MARK_BEFORE[concurrent_migrations]}" \
    --before "${MARK_AFTER[concurrent_migrations]}" 2>&1

# Step 7: Report results
echo ""
echo "============================================"
echo "  Trace Collection Results"
echo "============================================"
echo ""
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        lines=$(wc -l < "$f")
        name=$(basename "$f")
        echo "  $name: $lines events"
        if [ "$lines" -gt 0 ]; then
            echo "    First: $(head -1 "$f" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("action","?"))' 2>/dev/null || echo "?")"
            echo "    Last:  $(tail -1 "$f" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("action","?"))' 2>/dev/null || echo "?")"
        fi
    fi
done

# Step 8: Spot-check trace quality
echo ""
echo ">>> Spot-checking trace quality"
python3 -c "
import json, sys, os
traces_dir = '$TRACES_DIR'
for fname in sorted(os.listdir(traces_dir)):
    if not fname.endswith('.ndjson'):
        continue
    path = os.path.join(traces_dir, fname)
    errors = 0
    with open(path) as fh:
        for i, line in enumerate(fh, 1):
            try:
                d = json.loads(line)
                for field in ['tag', 'action', 'ts']:
                    if field not in d:
                        print(f'  {fname} line {i}: missing {field}')
                        errors += 1
            except json.JSONDecodeError as e:
                print(f'  {fname} line {i}: invalid JSON: {e}')
                errors += 1
    if errors == 0:
        print(f'  {fname}: OK')
    else:
        print(f'  {fname}: {errors} issues')
"

echo ""
echo "============================================"
echo "  Harness run complete"
echo "============================================"
echo ""
echo "To clean up: cd harness/src && docker compose down -v"
echo "To re-preprocess: python3 harness/src/preprocess_trace.py harness/logs/shard0.log traces/basic_migration.ndjson --after <ts>"
