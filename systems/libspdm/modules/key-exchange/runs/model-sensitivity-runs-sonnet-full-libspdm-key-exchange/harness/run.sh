#!/usr/bin/env bash
# run.sh — Build libspdm with trace instrumentation, run tests, collect and validate traces.
#
# Usage:
#   ./harness/run.sh [build_dir]
#
# Default build_dir: artifact/libspdm/build_trace
# Traces are written to: traces/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$SCRIPT_DIR/.."
ARTIFACT="$BASE_DIR/artifact/libspdm"
TRACES_DIR="$BASE_DIR/traces"
BUILD_DIR="${1:-$ARTIFACT/build_trace}"

echo "=== TLA+ Trace Harness ==="
echo "Base:    $BASE_DIR"
echo "Build:   $BUILD_DIR"
echo "Traces:  $TRACES_DIR"
echo ""

# Step 1: Apply instrumentation (idempotent)
echo "[1/5] Applying instrumentation files..."
bash "$SCRIPT_DIR/apply.sh"

# Step 2: Create build directory and configure
echo "[2/5] Configuring cmake..."
mkdir -p "$BUILD_DIR"
cmake \
    -S "$ARTIFACT" \
    -B "$BUILD_DIR" \
    -DARCH=x64 \
    -DTOOLCHAIN=GCC \
    -DTARGET=Debug \
    -DCRYPTO=mbedtls \
    -DDISABLE_TESTS=0 \
    2>&1 | tail -5

# Step 3: Build trace_test and copy sample keys
echo "[3/5] Building trace_test..."
cmake --build "$BUILD_DIR" --target trace_test -- -j"$(nproc)" 2>&1 | tail -10
cmake --build "$BUILD_DIR" --target copy_sample_key 2>&1 | tail -3

# Step 4: Create traces directory and run
echo "[4/5] Running test scenarios..."
mkdir -p "$TRACES_DIR"

TRACE_BIN="$BUILD_DIR/bin/trace_test"
if [ ! -x "$TRACE_BIN" ]; then
    echo "ERROR: $TRACE_BIN not found or not executable"
    exit 1
fi

# trace_test reads cert files relative to CWD; run from bin dir
pushd "$BUILD_DIR/bin" >/dev/null
"$TRACE_BIN" "$TRACES_DIR"
popd >/dev/null

# Step 5: Verify traces (JSON structure)
echo "[5/6] Verifying trace JSON..."
echo ""
all_ok=true
for f in "$TRACES_DIR"/*.ndjson; do
    [ -f "$f" ] || continue
    lines=$(wc -l < "$f")
    valid=$(python3 -c "
import sys, json
ok = 0
with open('$f') as fh:
    for ln in fh:
        ln = ln.strip()
        if not ln: continue
        try:
            o = json.loads(ln)
            if o.get('tag') == 'trace' and 'event' in o and 'ts' in o: ok += 1
        except: pass
print(ok)
" 2>/dev/null || echo 0)
    echo "  $(basename "$f"): $lines lines, $valid valid trace events"
    if [ "$valid" -lt 4 ]; then
        echo "  WARNING: fewer than 4 valid events in $(basename "$f")"
        all_ok=false
    fi
done

# Step 6: TLC trace validation
echo ""
echo "[6/6] Running TLC trace validation..."
SPEC_DIR="$BASE_DIR/spec"
TLC_JAR="/home/ubuntu/Specula/lib/tla2tools.jar"
COMMUNITY_JAR="/home/ubuntu/Specula/lib/CommunityModules-deps.jar"
tlc_ok=true
if [ -f "$TLC_JAR" ] && [ -f "$COMMUNITY_JAR" ]; then
    pushd "$SPEC_DIR" >/dev/null
    for f in "$TRACES_DIR"/*.ndjson; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        result=$(JSON="$f" java -cp "$TLC_JAR:$COMMUNITY_JAR" tlc2.TLC \
            -config Trace.cfg Trace.tla 2>&1 || true)
        if echo "$result" | grep -q "No error has been found"; then
            echo "  PASS: $name"
        else
            echo "  FAIL: $name"
            echo "$result" | grep "Error:" | head -5
            tlc_ok=false
        fi
    done
    popd >/dev/null
else
    echo "  (skipping TLC: JARs not found at $TLC_JAR)"
fi

echo ""
if $all_ok && $tlc_ok; then
    echo "=== SUCCESS ==="
elif $all_ok; then
    echo "=== PARTIAL: traces OK, TLC validation failed ==="
else
    echo "=== WARNINGS (see above) ==="
fi
