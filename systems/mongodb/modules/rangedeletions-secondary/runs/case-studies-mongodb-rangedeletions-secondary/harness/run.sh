#!/bin/bash
# Full pipeline: start cluster, run test, extract traces, cross-check with logs.
# Usage: cd case-studies/mongodb-rangedeletions-secondary && bash harness/run.sh
set -euo pipefail
CASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="$CASE_DIR/harness"
TRACES="$CASE_DIR/traces"
LOGS="$HARNESS/logs"

mkdir -p "$TRACES" "$LOGS"

echo "============================================="
echo "  RangeDeletionsSecondaryNodes Trace Harness"
echo "============================================="

# ---- Step 1: Start cluster ----
echo -e "\n--- Step 1: Start cluster ---"
bash "$HARNESS/apply.sh"

# ---- Step 2: Run test_basic_kill ----
echo -e "\n--- Step 2: Run test_basic_kill ---"
docker cp "$HARNESS/src/test_basic_kill.js" rdsec-mongos:/tmp/test.js

BEFORE_TS=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
TEST_OUTPUT=$(docker exec rdsec-mongos mongosh --quiet --file /tmp/test.js 2>&1) || true
AFTER_TS=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)

echo "$TEST_OUTPUT"

# ---- Step 3: Extract trace from test output ----
echo -e "\n--- Step 3: Extract trace ---"
echo "$TEST_OUTPUT" | grep '^TRACE:' | sed 's/^TRACE://' > "$TRACES/basic_kill.ndjson"
TRACE_LINES=$(wc -l < "$TRACES/basic_kill.ndjson")
echo "Trace: $TRACES/basic_kill.ndjson ($TRACE_LINES lines)"

if [ "$TRACE_LINES" -lt 2 ]; then
    echo "ERROR: Trace has fewer than 2 lines — test likely failed"
    echo "Full test output above. Check for errors."
    exit 1
fi

# ---- Step 4: Collect logs from secondary ----
echo -e "\n--- Step 4: Collect secondary logs ---"
docker logs rdsec-shard0sec > "$LOGS/shard0sec.log" 2>&1
SEC_LOG_LINES=$(wc -l < "$LOGS/shard0sec.log")
echo "Secondary log: $LOGS/shard0sec.log ($SEC_LOG_LINES lines)"

# Also collect primary log for reference
docker logs rdsec-shard0pri > "$LOGS/shard0pri.log" 2>&1
echo "Primary log: $LOGS/shard0pri.log ($(wc -l < "$LOGS/shard0pri.log") lines)"

# ---- Step 5: Spot-check trace ----
echo -e "\n--- Step 5: Spot-check trace ---"

python3 -c "
import json, sys

with open('$TRACES/basic_kill.ndjson') as f:
    lines = f.readlines()

# Check all lines are valid JSON with 'event' field
for i, line in enumerate(lines, 1):
    try:
        obj = json.loads(line.strip())
    except json.JSONDecodeError as e:
        print(f'  Line {i}: INVALID JSON: {e}')
        sys.exit(1)
    if 'event' not in obj:
        print(f'  Line {i}: missing event field')
        sys.exit(1)

# Check first line is init
first = json.loads(lines[0].strip())
if first.get('event') != 'init':
    print(f'  Line 1: expected event=init, got {first.get(\"event\")}')
    sys.exit(1)

# Check required init fields
for field in ['nodeRole', 'trackerShardV', 'rdPreMigShardV', 'queryTracker']:
    if field not in first:
        print(f'  Line 1: missing required init field: {field}')
        sys.exit(1)

# Report events
print('Trace events:')
for i, line in enumerate(lines, 1):
    obj = json.loads(line.strip())
    event = obj.get('event', '?')
    extras = []
    for k in ['rd', 'query', 'queryState', 'lastAppliedSnapshotSize', 'nodeRole']:
        if k in obj:
            extras.append(f'{k}={obj[k]}')
    print(f'  [{i}] {event}  {\" \".join(extras)}')

# Check we have at least init + one event
if len(lines) < 2:
    print('ERROR: need at least init + 1 event')
    sys.exit(1)

print(f'All {len(lines)} lines valid.')
"

# ---- Step 6: Cross-check with MongoDB logs ----
echo -e "\n--- Step 6: Cross-check with logs ---"
python3 "$HARNESS/src/parse_logs.py" "$LOGS/shard0sec.log" "$TRACES/basic_kill.ndjson"

# ---- Step 7: Summary ----
echo -e "\n============================================="
echo "  Trace generation complete"
echo "  Trace:  $TRACES/basic_kill.ndjson ($TRACE_LINES lines)"
echo "  Logs:   $LOGS/shard0sec.log ($SEC_LOG_LINES lines)"
echo "============================================="
echo ""
echo "Next: run trace validation with TLC:"
echo "  cd spec && java -jar ../../lib/tla2tools.jar -config Trace.cfg Trace.tla \\"
echo "    -DJSON=../traces/basic_kill.ndjson"
