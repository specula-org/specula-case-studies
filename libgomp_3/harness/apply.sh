#!/bin/bash
# apply.sh — Apply the libgomp_3 instrumentation patch and copy the trace
# header into the source tree.  Idempotent: prior application is reverted
# via git first.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Script lives in .specula-output/harness/, so the case study root is
# two levels up.
CASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/gcc"
LIBGOMP_SRC="$ARTIFACT/libgomp"
PATCH="$SCRIPT_DIR/patches/instrumentation.patch"
TRACE_HDR="$SCRIPT_DIR/src/tla_trace.h"

echo "=== Applying libgomp_3 instrumentation ==="

if [ ! -d "$ARTIFACT/.git" ]; then
    echo "ERROR: $ARTIFACT is not a git checkout — cannot revert in apply.sh"
    exit 1
fi

# Revert any previous patch application so this script is idempotent.
(cd "$ARTIFACT" && git checkout -- libgomp/ 2>/dev/null || true)

# Apply the captured patch.
(cd "$ARTIFACT" && git apply --whitespace=nowarn "$PATCH")
echo "  Applied $(basename "$PATCH")"

# Copy the trace emission header into the libgomp source dir.
cp "$TRACE_HDR" "$LIBGOMP_SRC/tla_trace.h"
echo "  Copied tla_trace.h into $LIBGOMP_SRC/"

echo "  Instrumentation applied."
