#!/usr/bin/env bash
# One-command: start cluster, run tests, collect logs, produce traces.
# Usage: cd case-studies/mongodb-txnscollincarnation && bash harness/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACE_DIR="$CASE_DIR/traces"
LOG_DIR="$SCRIPT_DIR/logs"

echo "===== TxnsCollectionIncarnation Trace Harness ====="
echo "Case study dir: $CASE_DIR"
echo "Trace output:   $TRACE_DIR"

# Prerequisites
python3 -c "import pymongo" 2>/dev/null || { echo "Installing pymongo..."; pip install pymongo; }

# Clean old traces and logs
rm -f "$TRACE_DIR"/*.ndjson "$TRACE_DIR"/*.json
rm -rf "$LOG_DIR"

# Step 1: Start cluster
echo ""
echo "--- Step 1: Starting instrumented cluster ---"
bash "$SCRIPT_DIR/apply.sh"

# Step 2: Run test scenarios
echo ""
echo "--- Step 2: Running test scenarios ---"
export MONGOS_URI="mongodb://localhost:27217"
export TRACE_DIR="$TRACE_DIR"

# Give the cluster a moment to settle
sleep 2

python3 "$SCRIPT_DIR/src/test_scenarios.py"

# Step 3: Collect logs from containers
echo ""
echo "--- Step 3: Collecting server logs ---"
mkdir -p "$LOG_DIR"

# Small delay to let logs flush
sleep 2

# Copy logs from Docker volumes
docker cp tci-configsvr:/var/log/mongodb/mongod.log "$LOG_DIR/configsvr.log" 2>/dev/null || \
    docker logs tci-configsvr > "$LOG_DIR/configsvr.log" 2>&1
docker cp tci-shard0:/var/log/mongodb/mongod.log "$LOG_DIR/shard0.log" 2>/dev/null || \
    docker logs tci-shard0 > "$LOG_DIR/shard0.log" 2>&1
docker cp tci-shard1:/var/log/mongodb/mongod.log "$LOG_DIR/shard1.log" 2>/dev/null || \
    docker logs tci-shard1 > "$LOG_DIR/shard1.log" 2>&1
docker cp tci-mongos:/var/log/mongodb/mongos.log "$LOG_DIR/mongos.log" 2>/dev/null || \
    docker logs tci-mongos > "$LOG_DIR/mongos.log" 2>&1

echo "  configsvr.log: $(wc -l < "$LOG_DIR/configsvr.log") lines"
echo "  shard0.log:    $(wc -l < "$LOG_DIR/shard0.log") lines"
echo "  shard1.log:    $(wc -l < "$LOG_DIR/shard1.log") lines"
echo "  mongos.log:    $(wc -l < "$LOG_DIR/mongos.log") lines"

# Step 4: Parse logs and produce traces
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
        # Count unique event types
        events=$(python3 -c "
import json, sys
with open('$f') as fh:
    names = set()
    for line in fh:
        try:
            obj = json.loads(line)
            if 'event' in obj:
                names.add(obj['event'])
        except: pass
    print(', '.join(sorted(names)))
")
        echo "  $name: $lines events [$events]"
    fi
done

# Step 6: Trace quality check
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
        if 'event' in obj:
            trace_lines.append(obj)
    # Check timestamps
    ts_list = []
    for t in trace_lines:
        ts = t.get('ts', '')
        if isinstance(ts, str) and 'T' in ts:
            ts_list.append(ts)
    if ts_list and len(set(ts_list)) < 2:
        print(f'  WARN: {fname} has identical timestamps (may be synthetic)')
    events = [t['event'] for t in trace_lines]
    print(f'  {fname}: {len(trace_lines)} trace events, {len(set(events))} unique types')

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
