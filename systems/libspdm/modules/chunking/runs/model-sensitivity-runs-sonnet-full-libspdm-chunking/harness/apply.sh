#!/usr/bin/env bash
# apply.sh — Copy spdm_trace.h into the artifact include path.
# The source files are already instrumented in-place.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBSPDM_DIR="$(realpath "${SCRIPT_DIR}/../artifact/libspdm")"
TRACE_HEADER="${SCRIPT_DIR}/src/spdm_trace.h"

echo "[apply.sh] Copying spdm_trace.h to ${LIBSPDM_DIR}/include/"
cp "${TRACE_HEADER}" "${LIBSPDM_DIR}/include/spdm_trace.h"

echo "[apply.sh] Instrumentation applied."
