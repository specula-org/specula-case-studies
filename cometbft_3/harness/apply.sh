#!/bin/bash
# Apply trace instrumentation to the cometbft artifact.
#
# Idempotent: re-running first reverts the artifact to its pristine state
# (git checkout) and then re-applies the patch.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
# Default path: harness lives under .specula-output/, artifact under case-studies/<case>/artifact/<sub>/
ARTIFACT_DIR="${ARTIFACT_DIR:-$HARNESS_DIR/../../artifact/cometbft}"
PATCH="$HARNESS_DIR/patches/instrumentation.patch"

if [ ! -d "$ARTIFACT_DIR" ]; then
    echo "ERROR: artifact dir not found: $ARTIFACT_DIR" >&2
    exit 1
fi
if [ ! -f "$PATCH" ]; then
    echo "ERROR: patch not found: $PATCH" >&2
    exit 1
fi

echo "==> Reverting artifact to clean state"
(cd "$ARTIFACT_DIR" && git checkout -- . && git clean -fd \
    blocksync/tracehooks.go blocksync/tlatrace_init_test.go blocksync/trace_scenario_test.go \
    consensus/tracehooks.go consensus/tlatrace_init_test.go \
    statesync/tracehooks.go statesync/tlatrace_init_test.go \
    node/tracehooks.go \
    types/tracehooks.go types/tlatrace_init_test.go \
    libs/tla_trace/ 2>/dev/null || true)

echo "==> Applying instrumentation patch"
(cd "$ARTIFACT_DIR" && git apply --whitespace=nowarn "$PATCH")

echo "==> Verifying build"
GO=${GO:-/usr/local/go/bin/go}
(cd "$ARTIFACT_DIR" && GOFLAGS=-mod=readonly "$GO" build ./blocksync/... ./consensus/... ./statesync/... ./node/... ./types/... ./libs/tla_trace/...)

echo "==> Instrumentation applied."
