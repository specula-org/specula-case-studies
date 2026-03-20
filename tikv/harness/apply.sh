#!/usr/bin/env bash
# Apply TLA+ trace instrumentation to raft-rs artifact.
#
# Steps:
#   1. Reset artifact to clean state
#   2. Copy tla_trace.rs into raft crate src/
#   3. Add module declaration to src/lib.rs
#   4. Copy test scenario into harness/tests/
#   5. Register test binary in harness/Cargo.toml
#   6. Patch raft.rs with instrumentation calls
#
# Usage: bash harness/apply.sh  (from case-studies/tikv/)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/raft-rs"

echo "=== Applying TLA+ trace instrumentation ==="

# 1. Reset artifact to clean state
echo "[1/6] Resetting artifact..."
git -C "$ARTIFACT" checkout -- .

# 2. Copy trace module into raft crate
echo "[2/6] Copying tla_trace.rs..."
cp "$SCRIPT_DIR/src/tla_trace.rs" "$ARTIFACT/src/tla_trace.rs"

# 3. Add module declaration to src/lib.rs (before 'mod raft;')
echo "[3/6] Adding module declaration to lib.rs..."
if ! grep -q 'pub mod tla_trace;' "$ARTIFACT/src/lib.rs"; then
    sed -i 's/^mod raft;/pub mod tla_trace;\nmod raft;/' "$ARTIFACT/src/lib.rs"
fi

# 4. Copy test scenario
echo "[4/6] Copying test scenario..."
cp "$SCRIPT_DIR/src/tla_trace_test.rs" "$ARTIFACT/harness/tests/tla_trace_test.rs"

# 5. Register test binary in harness/Cargo.toml
echo "[5/6] Registering test binary..."
if ! grep -q 'tla_trace_test' "$ARTIFACT/harness/Cargo.toml"; then
    cat >> "$ARTIFACT/harness/Cargo.toml" << 'EOF'

[[test]]
name = "tla_trace_test"
path = "tests/tla_trace_test.rs"
EOF
fi

# 6. Add macro import to raft.rs and patch with instrumentation calls
echo "[6/7] Adding macro import to raft.rs..."
if ! grep -q 'use crate::tla_trace_event;' "$ARTIFACT/src/raft.rs"; then
    # Add the import after the last 'use crate::' line in the imports section
    sed -i '/^use crate::{confchange/a use crate::tla_trace_event;' "$ARTIFACT/src/raft.rs"
fi

echo "[7/7] Patching raft.rs with trace instrumentation..."
python3 "$SCRIPT_DIR/src/patch_raft.py" "$ARTIFACT/src/raft.rs"

echo "=== Instrumentation applied successfully ==="
