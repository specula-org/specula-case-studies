#!/usr/bin/env bash
# Revert instrumentation patches — restore original MongoDB source files.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_DIR="$(dirname "$SCRIPT_DIR")"
ARTIFACT_DIR="$RUN_DIR/artifact/mongo-src"
SRC_DIR="$ARTIFACT_DIR/src/mongo/db/s"

echo "[clean.sh] Reverting instrumented source files..."
(cd "$ARTIFACT_DIR" && git checkout -- \
    src/mongo/db/s/range_deleter_service_op_observer.cpp \
    src/mongo/db/s/range_deleter_service.cpp \
    src/mongo/db/s/ready_range_deletions_processor.cpp)

echo "[clean.sh] Removing tla_trace.h from source tree..."
rm -f "$SRC_DIR/tla_trace.h"

echo "[clean.sh] Done."
