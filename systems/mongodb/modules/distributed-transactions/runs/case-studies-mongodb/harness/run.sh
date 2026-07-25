#!/usr/bin/env bash
# One-command: start cluster, run tests, collect logs, produce traces.
# Usage: cd case-studies/mongodb && bash harness/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACE_DIR="$CASE_DIR/traces"
LOG_DIR="$SCRIPT_DIR/logs"

echo "===== MongoDB v3 Trace Harness ====="
echo "Case study dir: $CASE_DIR"
echo "Trace output:   $TRACE_DIR"

# Prerequisites
python3 -c "import pymongo" 2>/dev/null || { echo "Installing pymongo..."; pip3 install pymongo; }

# Clean old traces
rm -f "$TRACE_DIR"/*.ndjson "$TRACE_DIR"/*.json
mkdir -p "$TRACE_DIR" "$LOG_DIR"

# Step 1: Apply instrumentation (start cluster)
echo ""
echo "--- Step 1: Starting instrumented cluster ---"
bash "$SCRIPT_DIR/apply.sh"

# Step 2: Run test scenarios
echo ""
echo "--- Step 2: Running test scenarios ---"
export MONGOS_URI="mongodb://localhost:27017"
export TRACE_DIR="$TRACE_DIR"
export HARNESS_DIR="$SCRIPT_DIR"

# Give the cluster a moment to settle
sleep 3

python3 "$SCRIPT_DIR/src/test_scenarios.py"

# Step 3: Collect logs from containers
echo ""
echo "--- Step 3: Collecting server logs ---"

# Small delay to let logs flush
sleep 3

# Copy logs from Docker volumes
docker cp mongo-shard1:/var/log/mongodb/mongod.log "$LOG_DIR/shard1.log" 2>/dev/null || \
    docker logs mongo-shard1 > "$LOG_DIR/shard1.log" 2>&1
docker cp mongo-shard2:/var/log/mongodb/mongod.log "$LOG_DIR/shard2.log" 2>/dev/null || \
    docker logs mongo-shard2 > "$LOG_DIR/shard2.log" 2>&1
docker cp mongo-configsvr:/var/log/mongodb/mongod.log "$LOG_DIR/configsvr.log" 2>/dev/null || \
    docker logs mongo-configsvr > "$LOG_DIR/configsvr.log" 2>&1
docker cp mongo-mongos:/var/log/mongodb/mongos.log "$LOG_DIR/mongos.log" 2>/dev/null || \
    docker logs mongo-mongos > "$LOG_DIR/mongos.log" 2>&1

echo "  shard1.log:    $(wc -l < "$LOG_DIR/shard1.log") lines"
echo "  shard2.log:    $(wc -l < "$LOG_DIR/shard2.log") lines"
echo "  configsvr.log: $(wc -l < "$LOG_DIR/configsvr.log") lines"
echo "  mongos.log:    $(wc -l < "$LOG_DIR/mongos.log") lines"

# Step 4: Parse logs and merge with client traces
echo ""
echo "--- Step 4: Parsing logs and producing traces ---"
python3 "$SCRIPT_DIR/src/parse_logs.py"

# Step 5: Report
echo ""
echo "--- Step 5: Trace summary ---"
for f in "$TRACE_DIR"/*.ndjson; do
    if [ -f "$f" ] && [[ "$f" != *"_client.ndjson" ]]; then
        lines=$(wc -l < "$f")
        name=$(basename "$f")
        echo "  $name: $lines lines"
    fi
done

# Step 6: Spot-check trace quality
echo ""
echo "--- Step 6: Trace quality check ---"
python3 -c "
import json, sys, os

trace_dir = '$TRACE_DIR'
ok = True
for fname in sorted(os.listdir(trace_dir)):
    if not fname.endswith('.ndjson') or '_client' in fname:
        continue
    path = os.path.join(trace_dir, fname)
    with open(path) as f:
        lines = [l.strip() for l in f if l.strip()]
    if not lines:
        print(f'  WARN: {fname} is empty')
        ok = False
        continue
    trace_lines = []
    for i, line in enumerate(lines, 1):
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            print(f'  FAIL: {fname}:{i} invalid JSON')
            ok = False
            continue
        if obj.get('tag') == 'trace':
            trace_lines.append(obj)
            if 'event' not in obj:
                print(f'  FAIL: {fname}:{i} missing event field')
                ok = False
    # Check timestamps are real
    ts_list = [int(t['ts']) for t in trace_lines if 'ts' in t]
    if ts_list:
        diffs = [ts_list[i+1]-ts_list[i] for i in range(len(ts_list)-1)]
        if diffs and all(d == 1 for d in diffs):
            print(f'  WARN: {fname} has sequential timestamps (may be synthetic)')
    events = [t['event'] for t in trace_lines]
    print(f'  {fname}: {len(trace_lines)} trace events')
    print(f'    events: {list(dict.fromkeys(events))}')

if ok:
    print('  All traces pass quality check.')
else:
    print('  Some traces have issues (see above).')
"

# Cleanup: stop cluster
echo ""
echo "--- Cleanup ---"
cd "$SCRIPT_DIR"
docker compose down -v 2>/dev/null || true
echo "Cluster stopped."

echo ""
echo "===== Done. Traces in $TRACE_DIR ====="
