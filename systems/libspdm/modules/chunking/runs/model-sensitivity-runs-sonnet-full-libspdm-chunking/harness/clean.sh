#!/usr/bin/env bash
# clean.sh — Remove spdm_trace.h from the artifact include path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIBSPDM_DIR="$(realpath "${SCRIPT_DIR}/../artifact/libspdm")"

rm -f "${LIBSPDM_DIR}/include/spdm_trace.h"
echo "[clean.sh] Instrumentation cleaned."
