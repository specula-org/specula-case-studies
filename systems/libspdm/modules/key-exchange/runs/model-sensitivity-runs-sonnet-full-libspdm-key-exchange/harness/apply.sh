#!/usr/bin/env bash
# apply.sh — ensure trace support files are in place inside the artifact.
# The source instrumentations are already applied in-tree; this script
# only ensures the header and globals reach the correct locations.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT="$SCRIPT_DIR/../artifact/libspdm"
SRC="$SCRIPT_DIR/src"

echo "[apply.sh] Installing tla_trace.h into artifact include/"
cp -f "$SRC/tla_trace.h" "$ARTIFACT/include/tla_trace.h"

echo "[apply.sh] Installing tla_trace_globals.c and trace_test.c into test_tla_trace/"
mkdir -p "$ARTIFACT/unit_test/test_tla_trace"
cp -f "$SRC/tla_trace_globals.c" "$ARTIFACT/unit_test/test_tla_trace/tla_trace_globals.c"
cp -f "$SRC/trace_test.c"        "$ARTIFACT/unit_test/test_tla_trace/trace_test.c"

echo "[apply.sh] Done."
