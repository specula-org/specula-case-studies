#!/usr/bin/env bash
# apply.sh — Install harness files into the artifact.
# Usage: bash harness/apply.sh
# Run from the run directory: .../libspdm-secured-message/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$(dirname "$SCRIPT_DIR")"
ARTIFACT="$RUN_DIR/artifact/libspdm"

echo "[apply] Copying trace module header ..."
cp "$SCRIPT_DIR/src/spdm_tla_trace.h" \
   "$ARTIFACT/include/internal/spdm_tla_trace.h"

echo "[apply] Copying trace module implementation ..."
cp "$SCRIPT_DIR/src/spdm_tla_trace.c" \
   "$ARTIFACT/unit_test/test_spdm_secured_message/spdm_tla_trace.c"

echo "[apply] Copying test scenarios ..."
cp "$SCRIPT_DIR/src/test_tla_scenarios.c" \
   "$ARTIFACT/unit_test/test_spdm_secured_message/test_tla_scenarios.c"

echo "[apply] Done. Source files in artifact are pre-instrumented."
echo "[apply] See harness/INSTRUMENTATION.md for details of what was changed."
