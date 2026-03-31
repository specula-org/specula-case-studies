#!/bin/bash
# run.sh — One-command harness: start cluster, run tests, extract logs, preprocess traces.
#
# Usage: cd case-studies/mongodb-moverange && bash harness/run.sh
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
echo "  MongoDB MoveRange Trace Harness"
echo "============================================"

# Step 1: Start cluster
echo ""
echo ">>> Step 1: Starting sharded cluster"
bash "$SCRIPT_DIR/apply.sh"

# Step 2: Copy test scripts into mongos container
echo ""
echo ">>> Step 2: Preparing test scripts"
docker exec mr-mongos mkdir -p /scripts 2>/dev/null || true
for f in test_basic_commit.js test_abort_migration.js test_stepdown_recovery.js; do
    if [ -f "$HARNESS_SRC/$f" ]; then
        docker cp "$HARNESS_SRC/$f" mr-mongos:/scripts/
    fi
done

# Step 3: Run test scenarios with timestamp bookmarks
echo ""
echo ">>> Step 3: Running test scenarios"

declare -A MARK_BEFORE
declare -A MARK_AFTER

run_test() {
    local test_name=$1
    local test_file=$2
    echo ""
    echo "--- Running $test_name ---"
    MARK_BEFORE[$test_name]=$(date -u +"%Y-%m-%dT%H:%M:%S.000+00:00")
    sleep 1
    docker exec mr-mongos mongosh --port 27017 --file "/scripts/$test_file" --quiet 2>&1 || {
        echo "  WARNING: $test_name may have had issues"
    }
    sleep 5  # Allow range deletion and async events to complete
    MARK_AFTER[$test_name]=$(date -u +"%Y-%m-%dT%H:%M:%S.000+00:00")
    echo "  Time window: ${MARK_BEFORE[$test_name]} -> ${MARK_AFTER[$test_name]}"
    echo "--- $test_name done ---"
}

run_test "basic_commit" "test_basic_commit.js"
run_test "abort_migration" "test_abort_migration.js"
run_test "stepdown_recovery" "test_stepdown_recovery.js"

# Step 4: Extract logs from shard containers
echo ""
echo ">>> Step 4: Extracting logs"
docker logs mr-shard0 2>&1 > "$LOGS_DIR/shard0.log"
echo "  shard0.log: $(wc -l < "$LOGS_DIR/shard0.log") lines"
docker logs mr-shard1 2>&1 > "$LOGS_DIR/shard1.log"
echo "  shard1.log: $(wc -l < "$LOGS_DIR/shard1.log") lines"

# Step 5: Preprocess traces
echo ""
echo ">>> Step 5: Preprocessing traces"

for test_name in basic_commit abort_migration stepdown_recovery; do
    echo ""
    echo "--- Preprocessing $test_name ---"
    python3 "$HARNESS_SRC/preprocess_trace.py" \
        --donor "$LOGS_DIR/shard0.log" \
        --recipient "$LOGS_DIR/shard1.log" \
        --output "$TRACES_DIR/${test_name}.ndjson" \
        --after "${MARK_BEFORE[$test_name]}" \
        --before "${MARK_AFTER[$test_name]}" \
        2>&1
done

# Step 6: Report results
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
            echo "    First: $(head -1 "$f" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("event","?"))' 2>/dev/null || echo "?")"
            echo "    Last:  $(tail -1 "$f" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("event","?"))' 2>/dev/null || echo "?")"
            echo "    Events: $(cat "$f" | python3 -c '
import json, sys
counts = {}
for line in sys.stdin:
    d = json.loads(line.strip())
    e = d.get("event", "?")
    counts[e] = counts.get(e, 0) + 1
print(", ".join(f"{k}:{v}" for k, v in sorted(counts.items())))
' 2>/dev/null || echo "?")"
        fi
    fi
done

# Step 7: Spot-check trace quality
echo ""
echo ">>> Spot-checking trace quality"
python3 -c "
import json, sys, os
traces_dir = '$TRACES_DIR'
all_ok = True
for fname in sorted(os.listdir(traces_dir)):
    if not fname.endswith('.ndjson'):
        continue
    path = os.path.join(traces_dir, fname)
    errors = 0
    events = 0
    with open(path) as fh:
        for i, line in enumerate(fh, 1):
            try:
                d = json.loads(line)
                events += 1
                if 'event' not in d:
                    print(f'  {fname} line {i}: missing event field')
                    errors += 1
                if 'ts' not in d:
                    print(f'  {fname} line {i}: missing ts field')
                    errors += 1
                # Check for sequential integer timestamps (hand-written trace indicator)
                ts = d.get('ts', '')
                if isinstance(ts, int) or (isinstance(ts, str) and ts.isdigit()):
                    print(f'  {fname} line {i}: WARNING: integer timestamp (may be synthetic)')
            except json.JSONDecodeError as e:
                print(f'  {fname} line {i}: invalid JSON: {e}')
                errors += 1
    if errors == 0 and events > 0:
        print(f'  {fname}: OK ({events} events)')
    elif events == 0:
        print(f'  {fname}: EMPTY (no events)')
        all_ok = False
    else:
        print(f'  {fname}: {errors} issues in {events} events')
        all_ok = False

if all_ok:
    print('All traces pass quality check.')
else:
    print('Some traces have issues — see above.')
"

echo ""
echo "============================================"
echo "  Harness run complete"
echo "============================================"
echo ""
echo "To clean up: cd harness/src && docker compose down -v"
echo "To re-preprocess: python3 harness/src/preprocess_trace.py --donor harness/logs/shard0.log --recipient harness/logs/shard1.log --output traces/basic_commit.ndjson --after <ts>"
