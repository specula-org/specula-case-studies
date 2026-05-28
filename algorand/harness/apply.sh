#!/usr/bin/env bash
# Apply the Specula harness instrumentation to the go-algorand artifact.
#
# Idempotent: re-running first reverts uncommitted changes in the artifact's
# agreement/ tree, then re-applies everything from scratch. This means an
# operator can iterate on the trace module by editing harness/src/agreement/
# and re-running apply.sh.
#
# Usage: bash harness/apply.sh

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
# harness/ lives under .specula-output/, and the artifact is at the case root.
CASE_DIR="$(cd "$HARNESS_DIR/../.." && pwd)"
ARTIFACT_DIR="$CASE_DIR/artifact/go-algorand"

if [ ! -d "$ARTIFACT_DIR/agreement" ]; then
  echo "apply.sh: artifact not found at $ARTIFACT_DIR/agreement" >&2
  exit 1
fi

echo "[apply] reverting any prior modifications under artifact/agreement and agreementtest"
git -C "$ARTIFACT_DIR" checkout -- agreement/ 2>/dev/null || true
rm -f "$ARTIFACT_DIR/agreement/tla_trace.go"
rm -f "$ARTIFACT_DIR/agreement/agreementtest/spec_trace_test.go"

echo "[apply] copying trace module"
cp "$HARNESS_DIR/src/agreement/tla_trace.go" "$ARTIFACT_DIR/agreement/tla_trace.go"

echo "[apply] copying test scenarios"
cp "$HARNESS_DIR/src/agreementtest/spec_trace_test.go" \
   "$ARTIFACT_DIR/agreement/agreementtest/spec_trace_test.go"

echo "[apply] applying source patches"
git -C "$ARTIFACT_DIR" apply --whitespace=nowarn "$HARNESS_DIR/patches/instrumentation.patch"

echo "[apply] done."
