#!/usr/bin/env bash
# apply.sh — Instrument the MongoDB replication coordinator source.
#
# Usage:
#   bash harness/apply.sh             # instrument source
#   bash harness/apply.sh --clean     # revert to original (git checkout)
#
# Run from the specula-output directory:
#   cd .specula-output && bash harness/apply.sh
#
# The script copies tla_trace.{h,cpp} into the source tree, then applies
# the instrumentation edits via the Python patcher.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT="${SCRIPT_DIR}/../artifact/mongo-src"
REPL_DIR="${ARTIFACT}/src/mongo/db/repl"
PATCHER="${SCRIPT_DIR}/apply_patch.py"

if [[ "${1:-}" == "--clean" ]]; then
    echo "[apply.sh] Cleaning instrumentation..."
    # Remove added files
    rm -f "${REPL_DIR}/tla_trace.h" "${REPL_DIR}/tla_trace.cpp"
    # Restore original source files if git is available
    if git -C "${ARTIFACT}" rev-parse --git-dir &>/dev/null 2>&1; then
        git -C "${ARTIFACT}" checkout -- src/mongo/db/repl/replication_coordinator_impl.cpp \
            src/mongo/db/repl/replication_coordinator_impl_elect_v1.cpp \
            src/mongo/db/repl/replication_coordinator_impl_heartbeat.cpp
        echo "[apply.sh] Restored via git checkout."
    else
        echo "[apply.sh] No git repo found; run manually or use saved originals."
    fi
    exit 0
fi

echo "[apply.sh] Copying trace module..."
cp "${SCRIPT_DIR}/src/tla_trace.h"   "${REPL_DIR}/tla_trace.h"
cp "${SCRIPT_DIR}/src/tla_trace.cpp" "${REPL_DIR}/tla_trace.cpp"

echo "[apply.sh] Applying instrumentation patches..."
python3 "${PATCHER}" "${REPL_DIR}"

echo "[apply.sh] Done.  Source files instrumented in ${REPL_DIR}"
