#!/usr/bin/env bash
# One-command: start cluster, run tests, collect logs, produce traces.
# Usage: cd case-studies/mongodb-txnsmoverange && bash harness/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACE_DIR="$CASE_DIR/traces"
LOG_DIR="$SCRIPT_DIR/logs"

echo "===== TxnsMoveRange Trace Harness ====="
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
export MONGOS_URI="mongodb://localhost:27217"
export TRACE_DIR="$TRACE_DIR"
export HARNESS_DIR="$SCRIPT_DIR"

# Give the cluster a moment to settle
sleep 5

python3 "$SCRIPT_DIR/src/test_scenarios.py"

# Step 3: Collect logs from containers
echo ""
echo "--- Step 3: Collecting server logs ---"

# Small delay to let logs flush
sleep 3

# Copy logs from Docker volumes
docker cp txnmr-shard1:/var/log/mongodb/mongod.log "$LOG_DIR/shard1.log" 2>/dev/null || \
    docker logs txnmr-shard1 > "$LOG_DIR/shard1.log" 2>&1
docker cp txnmr-shard2:/var/log/mongodb/mongod.log "$LOG_DIR/shard2.log" 2>/dev/null || \
    docker logs txnmr-shard2 > "$LOG_DIR/shard2.log" 2>&1
docker cp txnmr-configsvr:/var/log/mongodb/mongod.log "$LOG_DIR/configsvr.log" 2>/dev/null || \
    docker logs txnmr-configsvr > "$LOG_DIR/configsvr.log" 2>&1
docker cp txnmr-mongos:/var/log/mongodb/mongos.log "$LOG_DIR/mongos.log" 2>/dev/null || \
    docker logs txnmr-mongos > "$LOG_DIR/mongos.log" 2>&1

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
all_events = set()
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
        if 'event' in obj:
            trace_lines.append(obj)
            all_events.add(obj['event'])

    events = [t['event'] for t in trace_lines]
    print(f'  {fname}: {len(trace_lines)} trace events')
    print(f'    events: {list(dict.fromkeys(events))}')

print(f'  All event types across traces: {sorted(all_events)}')
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
