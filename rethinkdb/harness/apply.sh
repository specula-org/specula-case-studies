#!/usr/bin/env bash
# Apply trace instrumentation to the rethinkdb artifact.
# Run from the case study root: cd case-studies/rethinkdb && bash harness/apply.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$SCRIPT_DIR/../artifact/rethinkdb"

echo "=== Applying RethinkDB Raft trace instrumentation ==="

# 1. Revert any previous instrumentation
echo "[1/3] Reverting previous changes..."
git -C "$ARTIFACT_DIR" checkout -- . 2>/dev/null || true

# 2. Copy trace header into the source tree
echo "[2/3] Copying trace header..."
cp "$SCRIPT_DIR/src/raft_trace.hpp" \
   "$ARTIFACT_DIR/src/clustering/generic/raft_trace.hpp"

# 3. Apply the instrumentation patch
echo "[3/3] Applying instrumentation patch..."
git -C "$ARTIFACT_DIR" apply "$SCRIPT_DIR/patches/instrumentation.patch"

echo "=== Instrumentation applied successfully ==="
echo "Build with: cd artifact/rethinkdb && CXXFLAGS='-DRETHINKDB_TLA_TRACE' make -j\$(nproc) DEBUG=1 ALLOW_WARNINGS=1"
