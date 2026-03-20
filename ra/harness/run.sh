#!/bin/bash
# Build instrumented Ra, run test scenarios, and collect traces.
# Run from case-studies/ra/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_STUDY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="$CASE_STUDY_DIR/artifact/ra"
TRACES_DIR="$CASE_STUDY_DIR/traces"

# OTP 25+ is sufficient (patch fixes OTP 26 map comprehension in ra_kv.erl)
if [ -d /opt/erlang26/bin ]; then
    export PATH="/opt/erlang26/bin:$PATH"
fi

echo "=== Ra Trace Harness ==="
echo "Using: $(erl -eval 'io:format("OTP ~s~n", [erlang:system_info(otp_release)]), halt().' -noshell 2>/dev/null || echo 'unknown')"
echo ""

# 1. Apply instrumentation
echo "--- Step 1: Apply instrumentation ---"
bash "$SCRIPT_DIR/apply.sh"
echo ""

# 2. Build
echo "--- Step 2: Build ---"
cd "$ARTIFACT_DIR"

# Use system rebar3 first (local ./rebar3 may require newer OTP)
if command -v rebar3 &>/dev/null; then
    REBAR3="rebar3"
elif [ -x ./rebar3 ]; then
    REBAR3="./rebar3"
else
    echo "ERROR: rebar3 not found. Please install or place in artifact dir."
    exit 1
fi

echo "Compiling..."
$REBAR3 compile 2>&1 | tail -10
echo ""

# 3. Create traces directory
mkdir -p "$TRACES_DIR"

# 4. Run test scenarios
echo "--- Step 3: Run test scenarios ---"
export TLA_TRACE_DIR="$TRACES_DIR"
$REBAR3 ct --suite tla_trace_SUITE --readable true 2>&1 | tail -30
CT_EXIT=${PIPESTATUS[0]}
echo ""

# 5. Report traces
echo "--- Step 4: Trace report ---"
TOTAL=0
if [ -d "$TRACES_DIR" ]; then
    for f in "$TRACES_DIR"/*.ndjson; do
        if [ -f "$f" ]; then
            LINES=$(wc -l < "$f")
            TOTAL=$((TOTAL + LINES))
            echo "  $(basename "$f"): $LINES lines"
            # Quick JSON validation
            head -1 "$f" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null \
                && echo "    First line: valid JSON" \
                || echo "    First line: INVALID JSON"
        fi
    done
fi
echo ""
echo "Total trace lines: $TOTAL"

if [ $CT_EXIT -eq 0 ] && [ $TOTAL -gt 0 ]; then
    echo "=== SUCCESS: Traces collected in $TRACES_DIR ==="
elif [ $CT_EXIT -ne 0 ]; then
    echo "=== FAILURE: CT tests exited with code $CT_EXIT ==="
    echo "Check logs at $ARTIFACT_DIR/_build/test/logs/"
    exit $CT_EXIT
else
    echo "=== WARNING: No trace lines generated ==="
    exit 1
fi
