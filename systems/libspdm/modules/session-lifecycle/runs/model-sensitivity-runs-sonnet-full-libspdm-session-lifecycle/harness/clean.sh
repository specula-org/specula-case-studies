#!/usr/bin/env bash
# clean.sh — remove build artifacts and trace files.
# Does NOT revert library source changes; run apply.sh to re-apply if needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBSPDM="${SCRIPT_DIR}/../artifact/libspdm"
BUILD_DIR="${LIBSPDM}/build_tla"

if [ -d "$BUILD_DIR" ]; then
    rm -rf "$BUILD_DIR"
    echo "clean.sh: removed $BUILD_DIR"
fi

TRACES_DIR="${SCRIPT_DIR}/../traces"
if [ -d "$TRACES_DIR" ]; then
    rm -f "$TRACES_DIR"/*.ndjson
    echo "clean.sh: removed traces"
fi

echo "clean.sh: done"
