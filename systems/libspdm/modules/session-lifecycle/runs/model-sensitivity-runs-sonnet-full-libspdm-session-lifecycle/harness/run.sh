#!/usr/bin/env bash
# run.sh — end-to-end: apply harness, configure, build, collect traces.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBSPDM="${SCRIPT_DIR}/../artifact/libspdm"
BUILD_DIR="${LIBSPDM}/build_tla"
TRACES_DIR="${SCRIPT_DIR}/../traces"

ARCH="${ARCH:-x64}"
TOOLCHAIN="${TOOLCHAIN:-GCC}"
CRYPTO="${CRYPTO:-openssl}"
DEVICE="${DEVICE:-sample}"
JOBS="${JOBS:-$(nproc)}"
LIBCRYPTO="${LIBCRYPTO:-/usr/lib/x86_64-linux-gnu/libcrypto.a}"
LIBSSL="${LIBSSL:-/usr/lib/x86_64-linux-gnu/libssl.a}"

echo "=== apply harness ==="
bash "$SCRIPT_DIR/apply.sh"

echo "=== cmake configure ==="
mkdir -p "$BUILD_DIR"
cmake -S "$LIBSPDM" -B "$BUILD_DIR" \
    -DARCH="$ARCH" \
    -DTOOLCHAIN="$TOOLCHAIN" \
    -DCRYPTO="$CRYPTO" \
    -DDEVICE="$DEVICE" \
    -DTARGET=Debug \
    -DENABLE_BINARY_BUILD=1 \
    -DCOMPILED_LIBCRYPTO_PATH="$LIBCRYPTO" \
    -DCOMPILED_LIBSSL_PATH="$LIBSSL"

echo "=== build test_spdm_tla_trace ==="
cmake --build "$BUILD_DIR" --target test_spdm_tla_trace -j "$JOBS"

echo "=== run scenarios ==="
mkdir -p "$TRACES_DIR"
"$BUILD_DIR/bin/test_spdm_tla_trace" "$TRACES_DIR"

echo "=== trace summary ==="
for f in "$TRACES_DIR"/*.ndjson; do
    count=$(wc -l < "$f")
    echo "  $f : $count events"
    if [ "$count" -lt 20 ]; then
        echo "  WARNING: fewer than 20 events in $f"
    fi
done

echo "=== done ==="
