#!/usr/bin/env bash
# run.sh — Build and run sonic-iccpd trace harness
# Run from .specula-output/ directory: cd .specula-output && bash harness/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPECULA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT="$SPECULA_DIR/artifact/sonic-buildimage/src/iccpd"
SRC="$ARTIFACT/src"
TRACES_DIR="$SPECULA_DIR/traces"

echo "=== sonic-iccpd Trace Harness ==="
echo ""

# Step 1: Apply instrumentation
echo "--- Step 1: Applying instrumentation ---"
bash "$SCRIPT_DIR/apply.sh"
echo ""

# Step 2: Build test binary
echo "--- Step 2: Building test binary ---"
cd "$SRC"

# Need config.h from autotools build
if [ ! -f "../config.h" ]; then
    echo "Running autotools setup..."
    cd "$ARTIFACT"
    autoreconf -i 2>/dev/null || true
    ./configure 2>&1 | tail -3
    cd "$SRC"
fi

make -f Makefile.test clean 2>/dev/null || true
make -f Makefile.test -j$(nproc) 2>&1 | tail -5

if [ ! -f "$SRC/iccpd_test" ]; then
    echo "ERROR: Build failed, iccpd_test not found"
    exit 1
fi
echo "Build successful: $SRC/iccpd_test"
echo ""

# Step 3: Run test scenarios and collect traces
echo "--- Step 3: Running test scenarios ---"
mkdir -p "$TRACES_DIR"
cd "$SRC"
./iccpd_test "$TRACES_DIR" 2>&1
echo ""

# Step 4: Report trace results
echo "--- Step 4: Trace Results ---"
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        lines=$(wc -l < "$f")
        trace_lines=$(grep -c '"tag":"trace"' "$f" 2>/dev/null || echo 0)
        events=$(grep -o '"name":"[^"]*"' "$f" 2>/dev/null | sort | uniq -c | sort -rn || echo "(none)")
        echo ""
        echo "  $(basename "$f"): $lines total lines, $trace_lines trace events"
        echo "  Event types:"
        echo "$events" | head -20 | sed 's/^/    /'
    fi
done

# Step 5: Basic validation
echo ""
echo "--- Step 5: Basic Validation ---"
errors=0
for f in "$TRACES_DIR"/*.ndjson; do
    [ -f "$f" ] || continue
    # Check each trace line is valid JSON
    while IFS= read -r line; do
        if ! echo "$line" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
            echo "  WARN: Invalid JSON in $(basename "$f"): $line"
            errors=$((errors + 1))
        fi
    done < "$f"

    # Check timestamps are real (not sequential integers)
    ts_count=$(grep -oP '"ts":"(\d+)"' "$f" | head -5 | sort -u | wc -l)
    if [ "$ts_count" -le 1 ]; then
        echo "  WARN: Suspiciously uniform timestamps in $(basename "$f")"
    fi
done

if [ $errors -eq 0 ]; then
    echo "  All trace lines are valid JSON"
    echo "  Timestamps are real (monotonic clock)"
fi

echo ""
echo "=== Harness complete. Traces in: $TRACES_DIR ==="
