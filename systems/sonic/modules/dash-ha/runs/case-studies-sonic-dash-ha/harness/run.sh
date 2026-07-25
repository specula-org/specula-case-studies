#!/bin/bash
# Build the instrumented sonic-dash-ha and run tests to generate TLA+ traces.
#
# Usage:
#   cd case-studies/sonic-dash-ha && bash harness/run.sh
#
# Prerequisites:
#   - Rust toolchain (cargo)
#   - Redis server (used by swss_common_testing for integration tests)
#   - swss-common native library (libswsscommon)
#
# Output:
#   traces/ha_scope_lifecycle.ndjson — HA scope config → up → active → down → delete

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="$CASE_DIR/artifact/sonic-dash-ha"
TRACES_DIR="$CASE_DIR/traces"

# Ensure Rust is available
if ! command -v cargo &>/dev/null; then
    if [ -f "$HOME/.cargo/env" ]; then
        . "$HOME/.cargo/env"
    else
        echo "ERROR: cargo not found. Install Rust first."
        exit 1
    fi
fi

# Set up SWSS_COMMON_REPO if not already set
if [ -z "${SWSS_COMMON_REPO:-}" ]; then
    SWSS_CHECKOUT=$(find "$HOME/.cargo/git/checkouts/sonic-swss-common-"* -maxdepth 1 -type d 2>/dev/null | head -1)
    if [ -n "$SWSS_CHECKOUT" ] && [ -f "$SWSS_CHECKOUT/common/.libs/libswsscommon.so" ]; then
        export SWSS_COMMON_REPO="$SWSS_CHECKOUT"
        export LD_LIBRARY_PATH="${SWSS_COMMON_REPO}/common/.libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        echo "Auto-detected SWSS_COMMON_REPO=$SWSS_COMMON_REPO"
    fi
fi

echo "=== TLA+ Trace Generation for sonic-dash-ha ==="
echo "Artifact: $ARTIFACT_DIR"
echo "Traces:   $TRACES_DIR"
echo ""

# Step 1: Apply instrumentation
echo "--- Step 1: Apply instrumentation ---"
bash "$SCRIPT_DIR/apply.sh"
echo ""

# Step 2: Build
echo "--- Step 2: Build hamgrd ---"
cd "$ARTIFACT_DIR"
if ! cargo build -p hamgrd 2>&1 | tail -10; then
    echo ""
    echo "ERROR: Build failed. Common causes:"
    echo "  - Missing libswsscommon (swss-common native library)"
    echo "  - Missing Redis headers"
    echo "  - Try: apt-get install libswsscommon-dev redis-server"
    echo ""
    echo "If building in a SONiC dev container, the dependencies should be available."
    exit 1
fi
echo ""

# Step 3: Run tests with tracing enabled
echo "--- Step 3: Run tests ---"
mkdir -p "$TRACES_DIR"

# Run the ha_scope integration test (exercises the full HA scope lifecycle)
export HA_TRACE_FILE="$TRACES_DIR/ha_scope_lifecycle.ndjson"
export RUST_LOG=info

echo "Running ha_scope_planned_up_then_down test..."
if cargo test -p hamgrd ha_scope_planned_up_then_down -- --nocapture --test-threads=1 2>&1 | tee "$TRACES_DIR/test.log" | tail -20; then
    echo "  Test passed."
else
    echo ""
    echo "WARNING: Test failed. Check $TRACES_DIR/test.log for details."
    echo "Common causes:"
    echo "  - Redis not running: redis-server &"
    echo "  - Missing swss-common native library"
fi

echo ""

# Step 4: Verify traces
echo "--- Step 4: Verify traces ---"
FOUND_TRACES=0
for trace in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$trace" ]; then
        LINES=$(wc -l < "$trace")
        echo "  $trace: $LINES lines"
        FOUND_TRACES=1
        if [ "$LINES" -gt 0 ]; then
            echo "  First 5 lines:"
            head -5 "$trace" | while IFS= read -r line; do
                echo "    $line" | python3 -m json.tool --compact 2>/dev/null || echo "    $line"
            done
            echo ""

            # Check event coverage
            echo "  Event types found:"
            python3 -c "
import json, sys
events = {}
with open('$trace') as f:
    for line in f:
        try:
            obj = json.loads(line)
            if obj.get('tag') == 'ha':
                name = obj.get('event', '?')
                events[name] = events.get(name, 0) + 1
        except: pass
for name, count in sorted(events.items()):
    print(f'    {name}: {count}')
" 2>/dev/null || echo "    (python3 not available for analysis)"
        fi
    fi
done

if [ "$FOUND_TRACES" -eq 0 ]; then
    echo ""
    echo "WARNING: No trace files generated."
    echo "Ensure HA_TRACE_FILE is set and the test exercises HA scope code paths."
fi

echo ""
echo "=== Done ==="
