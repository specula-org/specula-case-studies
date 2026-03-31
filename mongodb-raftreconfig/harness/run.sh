#!/usr/bin/env bash
# One-command: start RS cluster, run test scenarios, collect logs, produce traces.
# Usage: cd case-studies/mongodb-raftreconfig && bash harness/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACE_DIR="$CASE_DIR/traces"
LOG_DIR="$SCRIPT_DIR/logs"

echo "===== MongoRaftReconfig Trace Harness ====="
echo "Case study dir: $CASE_DIR"
echo "Trace output:   $TRACE_DIR"

# Clean old traces and logs
rm -f "$TRACE_DIR"/*.ndjson "$TRACE_DIR"/*.json
rm -f "$LOG_DIR"/*.log
mkdir -p "$TRACE_DIR" "$LOG_DIR"

# Step 1: Apply instrumentation (start cluster)
echo ""
echo "--- Step 1: Starting instrumented replica set ---"
bash "$SCRIPT_DIR/apply.sh"

# Step 2: Run test scenarios
echo ""
echo "--- Step 2: Running test scenarios ---"
export TRACE_DIR="$TRACE_DIR"
export HARNESS_DIR="$SCRIPT_DIR"

# Give the cluster time to stabilize after initial election
sleep 5

bash "$SCRIPT_DIR/src/test_scenarios.sh"

# Step 3: Collect logs from containers
echo ""
echo "--- Step 3: Collecting server logs ---"

# Let logs flush
sleep 3

# Copy logs from Docker volumes
for i in 1 2 3 4 5; do
    container="mongo-rs0-$i"
    logfile="$LOG_DIR/mongo${i}.log"
    docker cp "$container:/var/log/mongodb/mongod.log" "$logfile" 2>/dev/null || \
        docker logs "$container" > "$logfile" 2>&1 || \
        echo "" > "$logfile"
    lines=$(wc -l < "$logfile" 2>/dev/null || echo 0)
    echo "  mongo${i}.log: $lines lines"
done

# Step 4: Parse logs and produce traces
echo ""
echo "--- Step 4: Parsing logs and producing traces ---"
python3 "$SCRIPT_DIR/src/parse_repl_logs.py"

# Step 5: Report
echo ""
echo "--- Step 5: Trace summary ---"
for f in "$TRACE_DIR"/*.ndjson; do
    if [ -f "$f" ] && [[ "$f" != *"_client.ndjson" ]]; then
        lines=$(wc -l < "$f")
        name=$(basename "$f")
        echo "  $name: $lines trace lines"
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
            ev = obj.get('event', {})
            if not isinstance(ev, dict) or 'name' not in ev:
                print(f'  FAIL: {fname}:{i} missing event.name')
                ok = False
    # Check timestamps are real (not sequential integers)
    ts_list = []
    for t in trace_lines:
        try:
            ts_list.append(int(t['ts']))
        except (KeyError, ValueError):
            pass
    if ts_list:
        diffs = [ts_list[i+1]-ts_list[i] for i in range(len(ts_list)-1)]
        if diffs and all(d == 1 for d in diffs):
            print(f'  WARN: {fname} has sequential timestamps (may be synthetic)')
    events = [t.get('event', {}).get('name', '?') for t in trace_lines]
    event_set = list(dict.fromkeys(events))
    print(f'  {fname}: {len(trace_lines)} trace events, actions: {event_set}')

if ok:
    print('  All traces pass quality check.')
else:
    print('  Some traces have issues (see above).')
    sys.exit(1)
"

# Cleanup: stop cluster
echo ""
echo "--- Cleanup ---"
cd "$SCRIPT_DIR"
docker compose down -v 2>/dev/null || true
echo "Cluster stopped."

echo ""
echo "===== Done. Traces in $TRACE_DIR ====="
