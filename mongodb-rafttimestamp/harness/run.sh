#!/bin/bash
# run.sh — One-command harness: start cluster, run tests, extract logs, parse traces.
#
# Usage: cd case-studies/mongodb-rafttimestamp && bash harness/run.sh
#
# Prerequisites: docker, docker compose

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACES_DIR="$CASE_DIR/traces"
HARNESS_SRC="$SCRIPT_DIR/src"
LOGS_DIR="$SCRIPT_DIR/logs"
CONTAINERS=("rts-mongo1" "rts-mongo2" "rts-mongo3")

mkdir -p "$TRACES_DIR" "$LOGS_DIR"

echo "============================================"
echo "  MongoDB RaftMongoReplTimestamp Trace Harness"
echo "============================================"

# Step 1: Start cluster
echo ""
echo ">>> Step 1: Starting 3-node replica set"
bash "$SCRIPT_DIR/apply.sh"

# Step 2: Copy test scripts into mongo1 container
echo ""
echo ">>> Step 2: Preparing test scripts"
docker exec rts-mongo1 mkdir -p /scripts 2>/dev/null || true
for f in test_basic_consensus.js test_stepdown.js test_crash_recovery.js test_crash_recovery_verify.js; do
    docker cp "$HARNESS_SRC/$f" rts-mongo1:/scripts/
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
    docker exec rts-mongo1 mongosh --port 27017 --file "/scripts/$test_file" --quiet 2>&1 || {
        echo "  WARNING: $test_name may have had issues (expected for stepdown/crash tests)"
    }
    sleep 3
    MARK_AFTER[$test_name]=$(date -u +"%Y-%m-%dT%H:%M:%S.000+00:00")
    echo "  Time window: ${MARK_BEFORE[$test_name]} -> ${MARK_AFTER[$test_name]}"
    echo "--- $test_name done ---"
}

# Test 1: Basic consensus
run_test "basic_consensus" "test_basic_consensus.js"

# Test 2: Stepdown + re-election
run_test "stepdown" "test_stepdown.js"

# Test 3: Crash + recovery
# Phase 3a: Pre-crash writes — find current primary first
echo ""
echo "--- Running crash_recovery (pre-crash) ---"
MARK_BEFORE[crash_recovery]=$(date -u +"%Y-%m-%dT%H:%M:%S.000+00:00")
sleep 1

# Try writing from all containers (mongosh auto-routes to primary for writeConcern)
for c in rts-mongo1 rts-mongo2 rts-mongo3; do
    docker exec "$c" mkdir -p /scripts 2>/dev/null || true
    docker cp "$HARNESS_SRC/test_crash_recovery.js" "$c:/scripts/" 2>/dev/null || true
done
# Try each node — the primary will succeed
for c in rts-mongo1 rts-mongo2 rts-mongo3; do
    result=$(docker exec "$c" mongosh --port 27017 --file "/scripts/test_crash_recovery.js" --quiet 2>&1) || true
    echo "$result"
    if echo "$result" | grep -q "Pre-crash write 0$\|Pre-crash write 0:"; then
        break
    fi
done
sleep 2

# Phase 3b: Kill mongo3 (simulate crash)
echo "  Killing rts-mongo3 (simulating crash)..."
docker kill rts-mongo3 2>/dev/null || true
sleep 3

# Phase 3c: Restart mongo3 (triggers recovery)
echo "  Restarting rts-mongo3 (recovery will happen)..."
docker start rts-mongo3 2>/dev/null || true
sleep 8

# Phase 3d: Post-recovery verification
docker exec rts-mongo1 mongosh --port 27017 --file "/scripts/test_crash_recovery_verify.js" --quiet 2>&1 || true
sleep 3
MARK_AFTER[crash_recovery]=$(date -u +"%Y-%m-%dT%H:%M:%S.000+00:00")
echo "  Time window: ${MARK_BEFORE[crash_recovery]} -> ${MARK_AFTER[crash_recovery]}"
echo "--- crash_recovery done ---"

# Step 4: Extract logs from all containers
echo ""
echo ">>> Step 4: Extracting logs"
for container in "${CONTAINERS[@]}"; do
    name="${container#rts-}"
    docker logs "$container" 2>&1 > "$LOGS_DIR/${name}.log"
    lines=$(wc -l < "$LOGS_DIR/${name}.log")
    echo "  ${name}.log: $lines lines"
done

# Step 5: Parse traces
echo ""
echo ">>> Step 5: Parsing traces"

for test_name in basic_consensus stepdown crash_recovery; do
    echo "  Parsing $test_name..."
    python3 "$HARNESS_SRC/parse_repl_logs.py" \
        "$LOGS_DIR" \
        "$TRACES_DIR/${test_name}.ndjson" \
        --after "${MARK_BEFORE[$test_name]}" \
        --before "${MARK_AFTER[$test_name]}" 2>&1 | sed 's/^/    /'
done

# Also parse full log (all events from initial election through all tests)
echo "  Parsing full trace..."
python3 "$HARNESS_SRC/parse_repl_logs.py" \
    "$LOGS_DIR" \
    "$TRACES_DIR/full_trace.ndjson" 2>&1 | sed 's/^/    /'

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
        echo "  $name: $lines lines"
        if [ "$lines" -gt 1 ]; then
            echo "    First event: $(sed -n '2p' "$f" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("event",{}).get("name","?"))' 2>/dev/null || echo "?")"
            echo "    Last event:  $(tail -1 "$f" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("event",{}).get("name","?"))' 2>/dev/null || echo "?")"
        fi
    fi
done

# Step 7: Spot-check trace quality
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
    trace_events = 0
    event_names = set()
    with open(path) as fh:
        for i, line in enumerate(fh, 1):
            try:
                d = json.loads(line)
                if d.get('tag') == 'trace':
                    trace_events += 1
                    event = d.get('event', {})
                    if 'name' not in event:
                        print(f'  {fname} line {i}: missing event.name')
                        errors += 1
                    else:
                        event_names.add(event['name'])
                    if 'node' not in event:
                        print(f'  {fname} line {i}: missing event.node')
                        errors += 1
                    if 'state' not in event:
                        print(f'  {fname} line {i}: missing event.state')
                        errors += 1
                    ts = d.get('ts', '')
                    if ts and ts.isdigit():
                        print(f'  {fname} line {i}: timestamp looks synthetic')
                        errors += 1
                elif d.get('tag') == 'config':
                    pass
                else:
                    print(f'  {fname} line {i}: missing tag field')
                    errors += 1
            except json.JSONDecodeError as e:
                print(f'  {fname} line {i}: invalid JSON: {e}')
                errors += 1
    if errors == 0:
        print(f'  {fname}: OK ({trace_events} events, types: {sorted(event_names)})')
    else:
        print(f'  {fname}: {errors} issues ({trace_events} events)')
"

echo ""
echo "============================================"
echo "  Harness run complete"
echo "============================================"
echo ""
echo "Traces are in: $TRACES_DIR/"
echo "Logs are in: $LOGS_DIR/"
echo ""
echo "To clean up: cd harness/src && docker compose down -v"
echo "To re-parse: python3 harness/src/parse_repl_logs.py harness/logs/ traces/my_trace.ndjson"
echo "To validate: cd spec && java -jar ../../lib/tla2tools.jar -config Trace.cfg -deadlock Trace"
