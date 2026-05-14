#!/usr/bin/env bash
# Apply TLA+ trace instrumentation to the CCC artifact.
#
# Operation:
#   1. Restore instrumented source files to pristine state (git restore).
#   2. Copy tla_trace.rs + tla_trace_scenarios.rs into src/backend/.
#   3. Apply patches/instrumentation.patch to the three touched files
#      (liveness.rs, regalloc.rs, slot_assignment.rs) and backend/mod.rs.
#
# Idempotent: running twice restores first, so repeated invocations converge.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-$HARNESS_DIR/../../../ccc/artifact/claudes-c-compiler}"

if [ ! -d "$ARTIFACT_DIR" ]; then
    echo "ERROR: artifact not found at $ARTIFACT_DIR" >&2
    exit 1
fi

cd "$ARTIFACT_DIR"

# Step 1: restore any previously patched files to their committed state so
# that re-apply is a no-op on a cold checkout.
echo "==> Restoring artifact sources"
git restore -- \
    src/backend/mod.rs \
    src/backend/liveness.rs \
    src/backend/regalloc.rs \
    src/backend/stack_layout/slot_assignment.rs
rm -f src/backend/tla_trace.rs src/backend/tla_trace_scenarios.rs

# Step 2: drop in the trace module and scenarios.
echo "==> Copying trace module + scenarios into src/backend/"
cp "$HARNESS_DIR/src/tla_trace.rs"           src/backend/tla_trace.rs
cp "$HARNESS_DIR/src/tla_trace_scenarios.rs" src/backend/tla_trace_scenarios.rs

# Step 3: apply the instrumentation patch.
echo "==> Applying patches/instrumentation.patch"
git apply --whitespace=nowarn "$HARNESS_DIR/patches/instrumentation.patch"

echo "==> Instrumentation applied successfully"
