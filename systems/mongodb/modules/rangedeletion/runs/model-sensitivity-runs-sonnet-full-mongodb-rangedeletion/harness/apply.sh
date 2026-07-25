#!/usr/bin/env bash
# apply.sh — Instrument MongoDB range deletion source files for TLA+ trace collection.
#
# Usage:
#   bash harness/apply.sh [artifact_root]
#
# Copies tla_trace.h into the source tree and inserts emit() calls at the
# code locations specified in instrumentation-spec.md.
#
# To revert: git -C <artifact_root> checkout -- .

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT="${1:-"$SCRIPT_DIR/../artifact/mongo-src"}"
SRC="$ARTIFACT/src/mongo/db/s"

if [[ ! -d "$SRC" ]]; then
    echo "ERROR: source dir not found: $SRC" >&2
    exit 1
fi

echo "=== Applying TLA+ trace instrumentation to $ARTIFACT ==="

# --- Copy trace header ---
cp "$SCRIPT_DIR/src/tla_trace.h" "$SRC/tla_trace.h"
echo "  + copied tla_trace.h"

# --- Use Python to patch each source file ---
python3 "$SCRIPT_DIR/patch_sources.py" "$SRC"

echo "=== Instrumentation applied ==="
echo "Build with:  cd $ARTIFACT && bazel build //src/mongo/db/s:migration_coordinator ..."
echo "Set TLA_TRACE_FILE=/path/to/traces/scenario.ndjson before running tests."
