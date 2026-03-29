#!/bin/bash
# Apply instrumentation to the tokio broadcast artifact.
# Run from the case study root: cd case-studies/tokio-broadcast && bash harness/apply.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/tokio"

echo "=== Applying tokio broadcast instrumentation ==="

# 1. Revert artifact to clean state
echo "Reverting artifact to clean state..."
git -C "$ARTIFACT" checkout -- .

# 2. Copy trace module into artifact
echo "Copying trace module..."
cp "$SCRIPT_DIR/src/tla_trace.rs" "$ARTIFACT/tokio/src/sync/tla_trace.rs"

# 3. Copy test scenarios
echo "Copying test scenarios..."
cp "$SCRIPT_DIR/src/trace_tests.rs" "$ARTIFACT/tokio/tests/trace_broadcast.rs"

# 4. Apply instrumentation patch (broadcast.rs + mod.rs)
echo "Applying instrumentation patch..."
git -C "$ARTIFACT" apply "$SCRIPT_DIR/patches/instrumentation.patch"

echo "=== Instrumentation applied successfully ==="
