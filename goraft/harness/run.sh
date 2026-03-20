#!/bin/bash
# End-to-end script: apply instrumentation, build, run tests, collect traces.
# Run from: case-studies/goraft/
set -euo pipefail

export PATH=/usr/local/go/bin:$PATH

ARTIFACT="artifact/raft"
TRACES="traces"

echo "========================================"
echo "  goraft Trace Harness"
echo "========================================"

# 1. Apply instrumentation
echo ""
echo "--- Step 1: Apply instrumentation ---"
bash harness/apply.sh

# 2. Build check
echo ""
echo "--- Step 2: Build check ---"
(cd "$ARTIFACT" && go build ./...)
echo "Build: OK"

# 3. Run trace test scenarios
echo ""
echo "--- Step 3: Running trace tests ---"
mkdir -p "$TRACES"

# Set TRACE_DIR so tests know where to write
export TRACE_DIR="$PWD/$TRACES"

# Use -vet=off because the old goraft code has vet issues with newer Go
(cd "$ARTIFACT" && go test -v -vet=off -run "TestTLATrace" -timeout 120s ./... 2>&1) | tee /tmp/goraft-test-output.txt
echo ""

# 4. Report trace files
echo "--- Step 4: Trace collection report ---"
if ls "$TRACES"/*.ndjson 1>/dev/null 2>&1; then
    for f in "$TRACES"/*.ndjson; do
        lines=$(wc -l < "$f")
        events=$(grep -c '"tag":"trace"' "$f" 2>/dev/null || echo "0")
        echo "  $(basename "$f"): $lines lines, $events trace events"
    done
else
    echo "ERROR: No trace files generated!"
    exit 1
fi

# 5. Quick validation: check JSON and event names
echo ""
echo "--- Step 5: Quick trace validation ---"
errors=0
for f in "$TRACES"/*.ndjson; do
    # Check each line is valid JSON
    while IFS= read -r line; do
        if ! echo "$line" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
            echo "  WARN: Invalid JSON in $(basename "$f")"
            errors=$((errors + 1))
            break
        fi
    done < "$f"

    # Check timestamps are real (not sequential integers)
    ts_values=$(python3 -c "
import json, sys
tss = []
for line in open('$f'):
    obj = json.loads(line)
    if 'ts' in obj:
        tss.append(obj['ts'])
if len(tss) >= 2:
    diffs = [tss[i+1] - tss[i] for i in range(len(tss)-1)]
    if all(d == diffs[0] for d in diffs) and diffs[0] == 1:
        print('SYNTHETIC')
    else:
        print('REAL')
else:
    print('TOO_FEW')
" 2>/dev/null || echo "ERROR")

    if [ "$ts_values" = "SYNTHETIC" ]; then
        echo "  WARN: $(basename "$f") has sequential timestamps (likely hand-written)"
        errors=$((errors + 1))
    elif [ "$ts_values" = "REAL" ]; then
        echo "  $(basename "$f"): timestamps OK (real)"
    fi

    # List unique event names
    events=$(python3 -c "
import json
events = set()
for line in open('$f'):
    obj = json.loads(line)
    if 'event' in obj:
        events.add(obj['event'])
print(', '.join(sorted(events)))
" 2>/dev/null || echo "ERROR")
    echo "  $(basename "$f") events: $events"
done

if [ $errors -gt 0 ]; then
    echo ""
    echo "WARNING: $errors validation issues found"
fi

# 6. Revert artifact
echo ""
echo "--- Step 6: Cleaning up artifact ---"
git -C "$ARTIFACT" checkout -- .
rm -f "$ARTIFACT/tla_trace.go" "$ARTIFACT/tla_trace_test.go" "$ARTIFACT/go.mod" "$ARTIFACT/go.sum"

echo ""
echo "========================================"
echo "  Done! Traces in: $TRACES/"
echo "========================================"
