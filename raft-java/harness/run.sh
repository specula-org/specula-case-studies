#!/usr/bin/env bash
# One-command: apply instrumentation, build, run tests, collect traces.
# Run from: case-studies/raft-java/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/raft-java"
TRACES_DIR="$CASE_DIR/traces"

echo "============================================"
echo "  raft-java Trace Harness"
echo "============================================"

# 1. Apply instrumentation
bash "$SCRIPT_DIR/apply.sh"

# 2. Build
echo ""
echo "=== Building raft-java ==="
cd "$ARTIFACT"
mvn clean install -DskipTests -q
echo "Build successful."

# 3. Create traces directory
mkdir -p "$TRACES_DIR"

# 4. Run test scenarios
echo ""
echo "=== Running test scenarios ==="

# Scenario 1: basic_consensus
echo ""
echo "--- Scenario: basic_consensus ---"
TRACE_FILE="$TRACES_DIR/basic_consensus.ndjson"
mvn -pl raft-java-core test \
    -Dtest=com.github.wenweihu86.raft.RaftTraceTest#testBasicConsensus \
    -Draft.trace.file="$TRACE_FILE" \
    -Dsurefire.useFile=false \
    2>&1 | grep -E "(Tests run|Leader elected|ClientRequest|commitIndex|Node s|BUILD)" || true

if [ -f "$TRACE_FILE" ]; then
    LINES=$(wc -l < "$TRACE_FILE")
    echo "  -> Trace: $TRACE_FILE ($LINES lines)"
else
    echo "  -> WARNING: No trace file generated"
fi

# Scenario 2: multiple_requests
echo ""
echo "--- Scenario: multiple_requests ---"
TRACE_FILE="$TRACES_DIR/multiple_requests.ndjson"
mvn -pl raft-java-core test \
    -Dtest=com.github.wenweihu86.raft.RaftTraceTest#testMultipleRequests \
    -Draft.trace.file="$TRACE_FILE" \
    -Dsurefire.useFile=false \
    2>&1 | grep -E "(Tests run|Leader|Round|Request|commitIndex|Node s|BUILD)" || true

if [ -f "$TRACE_FILE" ]; then
    LINES=$(wc -l < "$TRACE_FILE")
    echo "  -> Trace: $TRACE_FILE ($LINES lines)"
else
    echo "  -> WARNING: No trace file generated"
fi

# 5. Summary
echo ""
echo "============================================"
echo "  Trace Summary"
echo "============================================"
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        LINES=$(wc -l < "$f")
        EVENTS=$(grep -c '"tag":"trace"' "$f" || true)
        UNIQUE=$(grep -o '"name":"[^"]*"' "$f" | sort -u | tr '\n' ', ' | sed 's/,$//')
        echo "  $(basename "$f"): $LINES lines, $EVENTS events"
        echo "    Event types: $UNIQUE"
    fi
done
echo ""

# 6. Spot check: verify JSON validity
echo "=== Spot-checking trace format ==="
ERRORS=0
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        # Check each line is valid JSON using python
        python3 -c "
import json, sys
errors = 0
with open('$f') as fh:
    for i, line in enumerate(fh, 1):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            if 'tag' not in obj:
                print(f'  Line {i}: missing tag field')
                errors += 1
        except json.JSONDecodeError as e:
            print(f'  Line {i}: invalid JSON: {e}')
            errors += 1
if errors > 0:
    print(f'  {errors} errors in $(basename $f)')
    sys.exit(1)
else:
    print(f'  $(basename $f): all lines valid JSON')
" || ERRORS=$((ERRORS + 1))
    fi
done

if [ "$ERRORS" -gt 0 ]; then
    echo "WARNING: $ERRORS trace files have format issues"
else
    echo "All traces pass format check."
fi

echo ""
echo "Done. Traces are in: $TRACES_DIR/"
