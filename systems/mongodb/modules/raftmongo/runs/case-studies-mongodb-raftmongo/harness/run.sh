#!/bin/bash
# run.sh — One-command harness: start cluster, run tests, extract logs, parse traces.
#
# Usage: cd case-studies/mongodb-raftmongo && bash harness/run.sh
#
# Prerequisites: docker, docker compose

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACES_DIR="$CASE_DIR/traces"
HARNESS_SRC="$SCRIPT_DIR/src"
LOGS_DIR="$SCRIPT_DIR/logs"
CONTAINERS=("rm-mongo1" "rm-mongo2" "rm-mongo3")

mkdir -p "$TRACES_DIR" "$LOGS_DIR"

echo "============================================"
echo "  MongoDB RaftMongo Trace Harness"
echo "============================================"

# Step 1: Start cluster
echo ""
echo ">>> Step 1: Starting 3-node replica set"
bash "$SCRIPT_DIR/apply.sh"

# Step 2: Copy test scripts into mongo1 container
echo ""
echo ">>> Step 2: Preparing test scripts"
docker exec rm-mongo1 mkdir -p /scripts 2>/dev/null || true
for f in test_basic_consensus.js test_stepdown_election.js test_write_concern.js; do
    docker cp "$HARNESS_SRC/$f" rm-mongo1:/scripts/
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
    docker exec rm-mongo1 mongosh --port 27017 --file "/scripts/$test_file" --quiet 2>&1 || {
        echo "  WARNING: $test_name may have had issues (expected for stepdown test)"
    }
    sleep 3
    MARK_AFTER[$test_name]=$(date -u +"%Y-%m-%dT%H:%M:%S.000+00:00")
    echo "  Time window: ${MARK_BEFORE[$test_name]} -> ${MARK_AFTER[$test_name]}"
    echo "--- $test_name done ---"
}

run_test "basic_consensus" "test_basic_consensus.js"
run_test "stepdown_election" "test_stepdown_election.js"
run_test "write_concern" "test_write_concern.js"

# Step 4: Extract logs from all containers
echo ""
echo ">>> Step 4: Extracting logs"
for container in "${CONTAINERS[@]}"; do
    name="${container#rm-}"
    docker logs "$container" 2>&1 > "$LOGS_DIR/${name}.log"
    lines=$(wc -l < "$LOGS_DIR/${name}.log")
    echo "  ${name}.log: $lines lines"
done

# Step 5: Parse traces
echo ""
echo ">>> Step 5: Parsing traces"

for test_name in basic_consensus stepdown_election write_concern; do
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
            # Show first trace event (skip config line)
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
                    if 'state' not in event:
                        print(f'  {fname} line {i}: missing event.state')
                        errors += 1
                    elif 'server' not in event.get('state', {}):
                        print(f'  {fname} line {i}: missing event.state.server')
                        errors += 1
                    # Check timestamp is real (not sequential integers)
                    ts = d.get('ts', '')
                    if ts and ts.isdigit():
                        print(f'  {fname} line {i}: timestamp looks synthetic')
                        errors += 1
                elif d.get('tag') == 'config':
                    pass  # Config line is fine
                else:
                    print(f'  {fname} line {i}: missing tag field')
                    errors += 1
            except json.JSONDecodeError as e:
                print(f'  {fname} line {i}: invalid JSON: {e}')
                errors += 1
    if errors == 0:
        print(f'  {fname}: OK ({trace_events} trace events)')
    else:
        print(f'  {fname}: {errors} issues ({trace_events} trace events)')
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
echo "To validate: cd spec && java -jar ../../lib/tla2tools.jar -config Trace.cfg Trace.tla -deadlock"
