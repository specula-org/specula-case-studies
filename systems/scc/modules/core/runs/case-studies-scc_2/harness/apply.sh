#!/usr/bin/env bash
# Apply scc trace instrumentation to the artifact.
#
# Steps:
#   1. Reset the artifact to a clean state (discards prior instrumentation).
#   2. Copy the trace emission module (`src/tla_trace.rs`) into the artifact.
#   3. Apply the unified diff at `patches/instrumentation.patch` which:
#         - adds `pub mod tla_trace;` to `src/lib.rs`
#         - adds the `tla-trace` feature to `Cargo.toml`
#         - inserts emit calls into `src/hash_index.rs` (insert_sync,
#           remove_if_sync, dealloc_garbage, Iter::next)

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
ARTIFACT="$CASE_DIR/../artifact/scc"

if [ ! -d "$ARTIFACT" ]; then
    echo "error: artifact not found at $ARTIFACT" >&2
    exit 1
fi

echo "=== applying instrumentation ==="
echo "  artifact: $ARTIFACT"

# Step 1: clean artifact state
git -C "$ARTIFACT" reset --hard HEAD >/dev/null
git -C "$ARTIFACT" clean -fd -- 'src/tla_trace.rs' >/dev/null 2>&1 || true

# Step 2: copy the trace module
cp "$HARNESS_DIR/src/tla_trace.rs" "$ARTIFACT/src/tla_trace.rs"

# Step 3: apply the patch
git -C "$ARTIFACT" apply "$HARNESS_DIR/patches/instrumentation.patch"

echo "  done."
