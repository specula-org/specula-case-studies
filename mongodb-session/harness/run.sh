#!/bin/bash
# End-to-end harness: start cluster, run tests, collect traces, validate.
# Usage: cd case-studies/mongodb-session && bash harness/run.sh
set -euo pipefail

CASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS_DIR="$CASE_DIR/harness"
TRACES_DIR="$CASE_DIR/traces"

echo "============================================"
echo " MongoDB Session Lifecycle - Trace Harness"
echo "============================================"

# --- Step 1: Start cluster ---
echo ""
echo "=== Step 1: Starting cluster ==="
bash "$HARNESS_DIR/apply.sh"

# --- Step 2: Prepare traces directory ---
mkdir -p "$TRACES_DIR"
rm -f "$TRACES_DIR"/*.ndjson

# --- Step 3: Run test scenarios ---
echo ""
echo "=== Step 3: Running test scenarios ==="

run_test() {
    local test_name=$1
    local script=$2
    local out="$TRACES_DIR/$test_name.ndjson"
    echo "--- Running $test_name ---"
    # Run mongosh on the primary, capture stdout as NDJSON trace.
    # Stderr goes to a log file for debugging.
    if docker exec session-mongo1 mongosh --quiet --norc \
        "mongodb://mongo1:27017/?replicaSet=rs0" \
        --file "/scripts/$script" \
        > "$out" 2>"$TRACES_DIR/${test_name}.log"; then
        local count
        count=$(wc -l < "$out")
        echo "  OK: $count lines captured"
    else
        echo "  FAILED (exit code $?). Check $TRACES_DIR/${test_name}.log"
        # Keep any partial output
        cat "$TRACES_DIR/${test_name}.log" | tail -10
    fi
}

run_test "basic_lifecycle" "test_basic_lifecycle.js"
run_test "prepare_commit" "test_prepare_commit.js"
run_test "kill_session" "test_kill_session.js"
run_test "reaper_prepared" "test_reaper_prepared.js"

# --- Step 4: Validate trace format ---
echo ""
echo "=== Step 4: Trace format validation ==="
ALL_VALID=true
for f in "$TRACES_DIR"/*.ndjson; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    lines=$(wc -l < "$f")
    if [ "$lines" -eq 0 ]; then
        echo "  $name: EMPTY (0 lines)"
        ALL_VALID=false
        continue
    fi
    # Check each line is valid JSON with an "event" field
    if python3 -c "
import json, sys
errors = 0
with open('$f') as fh:
    for i, line in enumerate(fh, 1):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            if 'event' not in obj:
                print(f'  Line {i}: missing event field', file=sys.stderr)
                errors += 1
            if 'ts' not in obj:
                print(f'  Line {i}: missing ts field', file=sys.stderr)
                errors += 1
        except json.JSONDecodeError as e:
            print(f'  Line {i}: invalid JSON: {e}', file=sys.stderr)
            errors += 1
sys.exit(1 if errors > 0 else 0)
" 2>&1; then
        echo "  $name: valid ($lines events)"
    else
        echo "  $name: INVALID"
        ALL_VALID=false
    fi
done

# --- Step 5: Event coverage report ---
echo ""
echo "=== Step 5: Event coverage ==="
python3 -c "
import json, os, sys

traces_dir = '$TRACES_DIR'
all_events = set()
per_trace = {}

for fname in sorted(os.listdir(traces_dir)):
    if not fname.endswith('.ndjson'):
        continue
    path = os.path.join(traces_dir, fname)
    events = set()
    count = 0
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                if 'event' in obj:
                    events.add(obj['event'])
                    count += 1
            except:
                pass
    all_events |= events
    per_trace[fname] = (count, sorted(events))

for fname, (count, events) in per_trace.items():
    print(f'  {fname}: {count} events')
    for e in events:
        print(f'    - {e}')

print()
print(f'Total unique event types: {len(all_events)}')
print(f'Events covered: {sorted(all_events)}')

# Check against expected event types
expected = {
    'CheckOutSession', 'CheckInSession',
    'BeginTransaction', 'PrepareTransaction',
    'CommitPreparedTransaction', 'AbortTransaction',
    'ResetTransactionState',
    'KillSessionMark', 'KillSessionCheckout', 'KillSessionFinish',
    'ReaperScanMemory', 'ReaperDeleteImages', 'ReaperDeleteTxnRecords',
    'EndSession',
}
missing = expected - all_events
if missing:
    print(f'MISSING event types: {sorted(missing)}')
else:
    print('All expected event types covered!')
" 2>&1

# --- Step 6: Summary ---
echo ""
echo "=== Summary ==="
echo "Traces directory: $TRACES_DIR/"
for f in "$TRACES_DIR"/*.ndjson; do
    [ -f "$f" ] || continue
    echo "  $(basename "$f"): $(wc -l < "$f") events"
done

if [ "$ALL_VALID" = true ]; then
    echo ""
    echo "All traces are valid NDJSON. Ready for Phase 3 validation."
else
    echo ""
    echo "WARNING: Some traces have format issues. Check logs above."
fi
