#!/usr/bin/env bash
# run.sh — Apply instrumentation, build libspdm, run MEL trace tests, collect traces.
# Run from the experiment root directory: bash harness/run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIBSPDM="$ROOT/artifact/libspdm"
BUILD="$LIBSPDM/build"
TRACES="$ROOT/traces"

echo "=== [1/4] Applying instrumentation ==="
bash "$ROOT/harness/apply.sh"

echo "=== [2/4] Configuring build ==="
cmake -B "$BUILD" -S "$LIBSPDM" \
    -DARCH=x64 \
    -DTOOLCHAIN=GCC \
    -DCRYPTO=openssl \
    -DTARGET=Debug \
    -DENABLE_BINARY_BUILD=1 \
    -DCOMPILED_LIBCRYPTO_PATH=/usr/lib/x86_64-linux-gnu/libcrypto.a \
    -DCOMPILED_LIBSSL_PATH=/usr/lib/x86_64-linux-gnu/libssl.a \
    2>&1 | tail -5

echo "=== [3/4] Building test_mel_trace ==="
timeout 300 cmake --build "$BUILD" --target test_mel_trace -- -j"$(nproc)" 2>&1 | tail -20

echo "=== [4/4] Running trace scenarios ==="
mkdir -p "$TRACES"
timeout 60 "$BUILD/bin/test_mel_trace" "$TRACES"

echo ""
echo "=== Trace summary ==="
for f in "$TRACES"/trace_*.ndjson; do
    [ -f "$f" ] || continue
    count=$(wc -l < "$f")
    echo "  $(basename "$f"): $count events"
done

echo ""
echo "=== All done. Traces in: $TRACES/ ==="
