#!/usr/bin/env bash
# apply.sh — copy harness files into the libspdm source tree.
# Run this before building.  Idempotent.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBSPDM="$SCRIPT_DIR/../artifact/libspdm"
SRC="$SCRIPT_DIR/src"

# 1. Public header — visible to all instrumented translation units
cp -v "$SRC/tla_trace.h" "$LIBSPDM/include/tla_trace.h"

# 2. Implementation — compiled as part of spdm_common_lib
cp -v "$SRC/tla_trace.c" "$LIBSPDM/library/spdm_common_lib/tla_trace.c"

# 3. Test source — compiled as test_vca_trace executable
cp -v "$SRC/test_vca.c" "$LIBSPDM/unit_test/test_vca_trace/test_vca_trace.c"

echo "apply.sh: done."
