#!/bin/bash
# run.sh — One-command harness: start cluster, run tests, extract logs, preprocess traces.
#
# Usage: cd case-studies/mongodb-chunkmigration && bash harness/run.sh
#
# Prerequisites: docker, docker compose, python3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACES_DIR="$CASE_DIR/traces"
HARNESS_SRC="$SCRIPT_DIR/src"
LOGS_DIR="$SCRIPT_DIR/logs"

mkdir -p "$TRACES_DIR" "$LOGS_DIR"

echo "============================================"
echo "  MongoDB Chunk Migration Trace Harness"
echo "============================================"

# Step 1: Start cluster
echo ""
echo ">>> Step 1: Starting sharded cluster"
bash "$SCRIPT_DIR/apply.sh"

# Step 2: Enable verbose logging on shards (belt and suspenders — docker-compose already sets it)
echo ""
echo ">>> Step 2: Verifying verbose logging"
for container in cm-shard0 cm-shard1; do
    docker exec "$container" mongosh --port 27018 --eval '
    db.adminCommand({
        setParameter: 1,
        logComponentVerbosity: {
            sharding: {verbosity: 3}
        }
    });
    ' --quiet 2>/dev/null || true
    echo "  Verbose logging verified on $container"
done

# Step 3: Copy test scripts into mongos container
echo ""
echo ">>> Step 3: Preparing test scripts"
docker exec cm-mongos mkdir -p /scripts 2>/dev/null || true
for f in test_basic_commit.js test_back_to_back.js; do
    docker cp "$HARNESS_SRC/$f" cm-mongos:/scripts/
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
    docker exec cm-mongos mongosh --port 27017 --file "/scripts/$test_file" --quiet 2>&1 || {
        echo "  WARNING: $test_name may have had issues"
    }
    sleep 3  # wait for async cleanup to complete
    MARK_AFTER[$test_name]=$(date -u +"%Y-%m-%dT%H:%M:%S.000+00:00")
    echo "  Time window: ${MARK_BEFORE[$test_name]} -> ${MARK_AFTER[$test_name]}"
    echo "--- $test_name done ---"
}

run_test "basic_commit" "test_basic_commit.js"
run_test "back_to_back" "test_back_to_back.js"

# Step 5: Extract logs from shard containers
echo ""
echo ">>> Step 5: Extracting logs"
docker logs cm-shard0 2>&1 > "$LOGS_DIR/shard0.log"
echo "  shard0.log: $(wc -l < "$LOGS_DIR/shard0.log") lines"
docker logs cm-shard1 2>&1 > "$LOGS_DIR/shard1.log"
echo "  shard1.log: $(wc -l < "$LOGS_DIR/shard1.log") lines"

# Step 6: Preprocess traces
echo ""
echo ">>> Step 6: Preprocessing traces"

# basic_commit: donor shard depends on initial placement — try both
for shard_log in shard1 shard0; do
    python3 "$HARNESS_SRC/preprocess_trace.py" \
        "$LOGS_DIR/${shard_log}.log" \
        "$TRACES_DIR/basic_commit.ndjson" \
        --after "${MARK_BEFORE[basic_commit]}" \
        --before "${MARK_AFTER[basic_commit]}" 2>&1
    count=$(wc -l < "$TRACES_DIR/basic_commit.ndjson" 2>/dev/null || echo 0)
    if [ "$count" -gt 0 ]; then
        echo "  basic_commit: ${count} events from ${shard_log}"
        break
    fi
done

# back_to_back: both migrations likely on the same donor shard
for shard_log in shard1 shard0; do
    python3 "$HARNESS_SRC/preprocess_trace.py" \
        "$LOGS_DIR/${shard_log}.log" \
        "$TRACES_DIR/back_to_back.ndjson" \
        --after "${MARK_BEFORE[back_to_back]}" \
        --before "${MARK_AFTER[back_to_back]}" 2>&1
    count=$(wc -l < "$TRACES_DIR/back_to_back.ndjson" 2>/dev/null || echo 0)
    if [ "$count" -gt 0 ]; then
        echo "  back_to_back: ${count} events from ${shard_log}"
        break
    fi
done

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
            echo "    First: $(head -1 "$f" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("event",{}).get("name","?"))' 2>/dev/null || echo "?")"
            echo "    Last:  $(tail -1 "$f" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("event",{}).get("name","?"))' 2>/dev/null || echo "?")"
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
    events = set()
    with open(path) as fh:
        for i, line in enumerate(fh, 1):
            try:
                d = json.loads(line)
                if 'tag' not in d or d['tag'] != 'trace':
                    print(f'  {fname} line {i}: missing or wrong tag')
                    errors += 1
                if 'event' not in d:
                    print(f'  {fname} line {i}: missing event')
                    errors += 1
                else:
                    ev = d['event']
                    for field in ['name', 'mid', 'state']:
                        if field not in ev:
                            print(f'  {fname} line {i}: missing event.{field}')
                            errors += 1
                    events.add(ev.get('name', '?'))
                # Check timestamp is real ISO, not sequential integer
                ts = d.get('ts', '')
                if ts and ts.isdigit():
                    print(f'  {fname} line {i}: timestamp looks synthetic: {ts}')
                    errors += 1
            except json.JSONDecodeError as e:
                print(f'  {fname} line {i}: invalid JSON: {e}')
                errors += 1
    if errors == 0:
        print(f'  {fname}: OK ({len(events)} event types: {sorted(events)})')
    else:
        print(f'  {fname}: {errors} issues')
"

echo ""
echo "============================================"
echo "  Harness run complete"
echo "============================================"
echo ""
echo "To clean up: cd harness/src && docker compose down -v"
echo "To re-preprocess: python3 harness/src/preprocess_trace.py harness/logs/shard0.log traces/basic_commit.ndjson --after <ts>"
