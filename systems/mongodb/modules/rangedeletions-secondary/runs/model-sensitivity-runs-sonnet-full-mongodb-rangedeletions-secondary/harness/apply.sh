#!/usr/bin/env bash
# Apply TLA+ instrumentation patches to the MongoDB source tree.
# Must be run from the run directory (i.e., parent of harness/ and artifact/).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_DIR="$(dirname "$SCRIPT_DIR")"
ARTIFACT_DIR="$RUN_DIR/artifact/mongo-src"
SRC_DIR="$ARTIFACT_DIR/src/mongo/db/s"

echo "[apply.sh] Copying tla_trace.h into source tree..."
cp "$SCRIPT_DIR/src/tla_trace.h" "$SRC_DIR/"

echo "[apply.sh] Reverting any prior instrumentation in artifact..."
(cd "$ARTIFACT_DIR" && git checkout -- \
    src/mongo/db/s/range_deleter_service_op_observer.cpp \
    src/mongo/db/s/range_deleter_service.cpp \
    src/mongo/db/s/ready_range_deletions_processor.cpp 2>/dev/null || true)

echo "[apply.sh] Applying instrumentation patch..."
(cd "$ARTIFACT_DIR" && git apply "$SCRIPT_DIR/patches/instrumentation.patch")

echo "[apply.sh] Done. Source files instrumented."
