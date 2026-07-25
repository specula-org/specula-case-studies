#!/usr/bin/env bash
# apply.sh — apply the trace harness to the arc-swap artifact.
#
# Steps:
#   1. Reset the artifact to a clean working tree (only the 6 instrumented
#      source files are reverted; stash everything else just in case).
#   2. Copy harness/src/tla_trace.rs into artifact/arc-swap/src/.
#   3. Copy harness/src/tla_trace_scenarios.rs into artifact/arc-swap/tests/.
#   4. Apply harness/patches/instrumentation.patch which inserts the
#      emit_* hook calls into the 6 instrumented source files.
#
# Idempotent: rerunning resets and re-applies.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="$HARNESS_DIR/../../artifact/arc-swap"

if [ ! -d "$ARTIFACT_DIR" ]; then
    echo "error: artifact not found at $ARTIFACT_DIR"
    exit 1
fi

echo "==> Resetting artifact to pristine state"
git -C "$ARTIFACT_DIR" checkout -- \
    src/debt/fast.rs \
    src/debt/helping.rs \
    src/debt/list.rs \
    src/debt/mod.rs \
    src/lib.rs \
    src/strategy/hybrid.rs
rm -f "$ARTIFACT_DIR/src/tla_trace.rs"
rm -f "$ARTIFACT_DIR/tests/tla_trace_scenarios.rs"

echo "==> Copying harness source files"
cp "$HARNESS_DIR/src/tla_trace.rs" "$ARTIFACT_DIR/src/tla_trace.rs"
cp "$HARNESS_DIR/src/tla_trace_scenarios.rs" "$ARTIFACT_DIR/tests/tla_trace_scenarios.rs"

echo "==> Applying instrumentation patch"
git -C "$ARTIFACT_DIR" apply --whitespace=nowarn "$HARNESS_DIR/patches/instrumentation.patch"

echo "==> Verifying the patched tree builds"
( cd "$ARTIFACT_DIR" && cargo build --quiet ) >/dev/null

echo "==> Done"
