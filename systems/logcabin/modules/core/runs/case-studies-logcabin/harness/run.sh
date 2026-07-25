#!/bin/bash
# One-command: apply instrumentation, build, run tests, collect traces.
#
# Usage: cd case-studies/logcabin && bash harness/run.sh
set -euo pipefail

CASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/logcabin"
TRACES="$CASE_DIR/traces"

echo "============================================"
echo "  LogCabin TLA+ Trace Harness"
echo "============================================"
echo ""

# ---- Step 1: Apply instrumentation ----
echo ">>> Step 1: Applying instrumentation..."
bash "$CASE_DIR/harness/apply.sh"
echo ""

# ---- Step 2: Build ----
echo ">>> Step 2: Building LogCabin with trace instrumentation..."
cd "$ARTIFACT"

# Build with trace flag enabled.
# -fno-access-control is already set for test compilation in test/SConscript.
# We add LOGCABIN_TLA_TRACE define via CXXFLAGS.
scons -j"$(nproc)" CXXFLAGS="-DLOGCABIN_TLA_TRACE -Wno-deprecated-declarations -Wno-register" 2>&1 | tail -20
echo ""

# ---- Step 3: Run test scenarios ----
echo ">>> Step 3: Running trace test scenarios..."
mkdir -p "$TRACES"

# Scenario 1: basic_consensus
echo "  [1] basic_consensus..."
LOGCABIN_TRACE_FILE="$TRACES/basic_consensus.ndjson" \
    "$ARTIFACT/build/test/test" --gtest_filter='RaftTraceTest.basic_consensus' \
    2>/dev/null || {
    echo "    FAILED (test returned non-zero)"
    # Still continue to check what traces were generated
}

# Scenario 2: leader_stepdown
echo "  [2] leader_stepdown..."
LOGCABIN_TRACE_FILE="$TRACES/leader_stepdown.ndjson" \
    "$ARTIFACT/build/test/test" --gtest_filter='RaftTraceTest.leader_stepdown' \
    2>/dev/null || {
    echo "    FAILED (test returned non-zero)"
}

echo ""

# ---- Step 4: Report trace stats ----
echo ">>> Step 4: Trace statistics"
echo "-------------------------------------------"
for f in "$TRACES"/*.ndjson; do
    if [ -f "$f" ]; then
        lines=$(wc -l < "$f")
        name=$(basename "$f")
        echo "  $name: $lines events"
        # Spot check: show first and last event names
        if [ "$lines" -gt 0 ]; then
            first=$(head -1 "$f" | python3 -c "import sys,json; print(json.load(sys.stdin).get('event','?'))" 2>/dev/null || echo "?")
            last=$(tail -1 "$f" | python3 -c "import sys,json; print(json.load(sys.stdin).get('event','?'))" 2>/dev/null || echo "?")
            echo "    first: $first, last: $last"
        fi
    fi
done
echo "-------------------------------------------"

# ---- Step 5: Validate JSON format ----
echo ""
echo ">>> Step 5: Validating trace format..."
errors=0
for f in "$TRACES"/*.ndjson; do
    if [ -f "$f" ]; then
        name=$(basename "$f")
        # Check each line is valid JSON
        if python3 -c "
import json, sys
with open('$f') as fh:
    for i, line in enumerate(fh, 1):
        try:
            obj = json.loads(line)
            if 'tag' not in obj:
                print(f'  $name line {i}: missing tag field')
                sys.exit(1)
            if obj['tag'] == 'trace' and 'event' not in obj:
                print(f'  $name line {i}: trace event missing event field')
                sys.exit(1)
            if obj['tag'] == 'trace' and 'node' not in obj:
                print(f'  $name line {i}: trace event missing node field')
                sys.exit(1)
        except json.JSONDecodeError as e:
            print(f'  $name line {i}: invalid JSON: {e}')
            sys.exit(1)
print(f'  $name: OK')
" 2>&1; then
            :
        else
            errors=$((errors + 1))
        fi
    fi
done

if [ "$errors" -gt 0 ]; then
    echo "  $errors trace file(s) have format issues!"
    exit 1
fi

echo ""
echo "============================================"
echo "  Traces collected in: $TRACES/"
echo "============================================"
