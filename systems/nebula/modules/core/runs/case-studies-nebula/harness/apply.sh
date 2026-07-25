#!/bin/bash
# Apply TLA+ trace instrumentation to the nebula artifact.
# Usage: cd case-studies/nebula && bash harness/apply.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT="$SCRIPT_DIR/../artifact/nebula"
RAFTEX="$ARTIFACT/src/kvstore/raftex"

echo "=== Applying nebula raft trace instrumentation ==="

# 1. Revert any previous instrumentation
echo "--- Reverting previous changes ---"
cd "$ARTIFACT"
git checkout -- . 2>/dev/null || true
cd - >/dev/null

# 2. Copy trace module into source tree
echo "--- Copying trace module ---"
cp "$SCRIPT_DIR/src/trace_logger.h" "$RAFTEX/trace_logger.h"
cp "$SCRIPT_DIR/src/trace_logger.cpp" "$RAFTEX/trace_logger.cpp"

# 3. Copy test scenario
echo "--- Copying test scenario ---"
cp "$SCRIPT_DIR/src/TraceTest.cpp" "$RAFTEX/test/TraceTest.cpp"

# 4. Apply instrumentation via Python script
echo "--- Applying instrumentation patches ---"
python3 "$SCRIPT_DIR/patches/apply_instrumentation.py" "$ARTIFACT"

echo "=== Instrumentation applied successfully ==="
