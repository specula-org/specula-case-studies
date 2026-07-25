#!/usr/bin/env bash
# run.sh — apply harness, build libspdm with trace instrumentation, run test,
#           collect NDJSON traces into traces/.
# Usage: ./harness/run.sh [build_dir]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
LIBSPDM="$ROOT/artifact/libspdm"
TRACES_DIR="$ROOT/traces"
BUILD_DIR="${1:-$ROOT/build/tla_trace}"

echo "=== Step 1: apply harness files ==="
bash "$SCRIPT_DIR/apply.sh"

echo ""
echo "=== Step 2: configure cmake ==="
mkdir -p "$BUILD_DIR"
cmake -S "$LIBSPDM" -B "$BUILD_DIR" \
    -DARCH=x64 \
    -DTOOLCHAIN=GCC \
    -DTARGET=Debug \
    -DCRYPTO=mbedtls \
    -DTLA_TRACE_ENABLED=ON \
    -DDISABLE_TESTS=0 \
    -DCMAKE_C_FLAGS="-DTLA_TRACE_ENABLED=1" \
    -GNinja

echo ""
echo "=== Step 3: build test_vca_trace ==="
cmake --build "$BUILD_DIR" --target test_vca_trace -j"$(nproc)"

echo ""
echo "=== Step 4: run traces ==="
mkdir -p "$TRACES_DIR"
"$BUILD_DIR/bin/test_vca_trace" "$TRACES_DIR"

echo ""
echo "=== Step 5: verify traces ==="
ok=0; fail=0
for f in "$TRACES_DIR"/*.ndjson; do
    name="$(basename "$f")"
    lines=$(wc -l < "$f")
    # Each line must be valid JSON
    bad=$(grep -c '^' "$f" | true)
    err=0
    while IFS= read -r line; do
        echo "$line" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null || { err=1; break; }
    done < "$f"
    if [ $err -eq 0 ]; then
        echo "  OK  $name ($lines lines)"
        ok=$((ok+1))
    else
        echo "  ERR $name (invalid JSON line)"
        fail=$((fail+1))
    fi
done
echo ""
echo "Traces: $ok OK, $fail FAILED"
echo "Output: $TRACES_DIR/"
[ $fail -eq 0 ]
