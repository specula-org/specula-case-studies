#!/usr/bin/env bash
# Apply papaya trace instrumentation to the artifact.
# Run from the case study root: cd case-studies/papaya && bash harness/apply.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT="$SCRIPT_DIR/../artifact/papaya"

echo "==> Reverting artifact to clean state..."
git -C "$ARTIFACT" checkout -- .

echo "==> Copying trace module..."
cp "$SCRIPT_DIR/src/tla_trace.rs" "$ARTIFACT/src/tla_trace.rs"

echo "==> Copying test scenarios..."
cp "$SCRIPT_DIR/src/trace_tests.rs" "$ARTIFACT/tests/trace_tests.rs"

echo "==> Applying instrumentation patch..."
git -C "$ARTIFACT" apply "$SCRIPT_DIR/patches/instrumentation.patch"

echo "==> Done. Instrumentation applied."
