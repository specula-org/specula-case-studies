#!/usr/bin/env bash
#
# One-command: start cluster, run tests, collect traces.
#
# Usage: cd case-studies/mongodb-changestreams && bash harness/run.sh
#
set -euo pipefail

CASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS_DIR="$CASE_DIR/harness"
TRACE_DIR="$CASE_DIR/traces"
SPEC_DIR="$CASE_DIR/spec"
MONGOS_PORT="${MONGOS_PORT:-27117}"

export MONGOS_URI="mongodb://localhost:${MONGOS_PORT}"

echo "================================================================"
echo "  MongoDB Change Streams — Trace Harness"
echo "================================================================"
echo ""

# ------------------------------------------------------------------
# Step 1: Apply instrumentation (start cluster)
# ------------------------------------------------------------------
echo ">>> Step 1: Starting MongoDB cluster..."
bash "$HARNESS_DIR/apply.sh"
echo ""

# ------------------------------------------------------------------
# Step 2: Run test scenarios
# ------------------------------------------------------------------
echo ">>> Step 2: Running test scenarios..."
echo ""

mkdir -p "$TRACE_DIR"

PYTHON="${PYTHON:-python3}"

# Activate venv if present
if [ -f "$CASE_DIR/../../.venv/bin/activate" ]; then
    source "$CASE_DIR/../../.venv/bin/activate"
fi

FAILED=0

for test_script in "$HARNESS_DIR"/src/test_*.py; do
    test_name="$(basename "$test_script" .py)"
    echo "--- Running $test_name ---"
    if $PYTHON "$test_script"; then
        echo "  PASS"
    else
        echo "  FAIL (exit code $?)"
        FAILED=1
    fi
    echo ""
done

# ------------------------------------------------------------------
# Step 3: Report traces
# ------------------------------------------------------------------
echo ">>> Step 3: Trace summary"
echo ""
for trace_file in "$TRACE_DIR"/*.ndjson; do
    if [ -f "$trace_file" ]; then
        lines=$(wc -l < "$trace_file")
        name=$(basename "$trace_file")
        echo "  $name: $lines events"
    fi
done
echo ""

# ------------------------------------------------------------------
# Step 4: Spot-check trace format
# ------------------------------------------------------------------
echo ">>> Step 4: Spot-checking trace format..."
for trace_file in "$TRACE_DIR"/*.ndjson; do
    if [ -f "$trace_file" ]; then
        name=$(basename "$trace_file")
        # Check each line is valid JSON with tag=trace
        bad_lines=$($PYTHON -c "
import json, sys
bad = 0
for i, line in enumerate(open('$trace_file'), 1):
    try:
        obj = json.loads(line)
        if obj.get('tag') != 'trace':
            print(f'  {name}:{i}: missing tag=trace')
            bad += 1
        if 'event' not in obj or 'name' not in obj['event']:
            print(f'  {name}:{i}: missing event.name')
            bad += 1
    except json.JSONDecodeError:
        print(f'  {name}:{i}: invalid JSON')
        bad += 1
print(bad)
" | tail -1)
        if [ "$bad_lines" = "0" ]; then
            echo "  $name: OK (valid NDJSON, all lines have tag=trace)"
        else
            echo "  $name: $bad_lines format issues"
            FAILED=1
        fi
    fi
done
echo ""

# ------------------------------------------------------------------
# Step 5: Quick TLC trace validation (if TLC available)
# ------------------------------------------------------------------
TLA2TOOLS="$CASE_DIR/../../lib/tla2tools.jar"
COMMUNITY_MODULES="$CASE_DIR/../../lib/CommunityModules-deps.jar"

if [ -f "$TLA2TOOLS" ] && [ -f "$COMMUNITY_MODULES" ]; then
    echo ">>> Step 5: TLC trace validation..."
    echo ""

    # Copy harness validate.cfg to spec dir for TLC
    cp "$HARNESS_DIR/validate.cfg" "$SPEC_DIR/validate_harness.cfg"

    for trace_file in "$TRACE_DIR"/*.ndjson; do
        if [ -f "$trace_file" ]; then
            name=$(basename "$trace_file" .ndjson)
            echo "--- Validating $name ---"
            (
                cd "$SPEC_DIR"
                JSON="$trace_file" java \
                    -cp "${TLA2TOOLS}:${COMMUNITY_MODULES}" \
                    -DTLA-Library="${COMMUNITY_MODULES}" \
                    tlc2.TLC Trace \
                    -config validate_harness.cfg \
                    -deadlock \
                    -workers 1 \
                    -cleanup \
                    2>&1 \
                    | tail -30
            ) || echo "  TLC validation failed for $name (may need spec adjustments)"
            echo ""
        fi
    done
else
    echo ">>> Step 5: Skipping TLC validation (tla2tools.jar not found)"
    echo "  To validate: java -cp lib/tla2tools.jar:lib/CommunityModules-deps.jar tlc2.TLC Trace -config validate_harness.cfg"
fi

echo ""

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
if [ $FAILED -eq 0 ]; then
    echo "================================================================"
    echo "  All tests passed. Traces in: traces/"
    echo "================================================================"
else
    echo "================================================================"
    echo "  Some tests FAILED. Check output above."
    echo "================================================================"
    exit 1
fi
