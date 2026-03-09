#!/bin/bash
# Apply TLA+ trace instrumentation to Autobahn primary crate.
# This script:
# 1. Fixes rocksdb build issue (upgrades version)
# 2. Adds serde_json dependency
# 3. Copies tla_trace.rs module into primary/src/
# 4. Adds `pub mod tla_trace;` to primary/src/lib.rs
# 5. Applies instrumentation patch to core.rs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$(cd "$SCRIPT_DIR/../artifact/autobahn-artifact" && pwd)"
PRIMARY_SRC="$ARTIFACT_DIR/primary/src"

echo "=== Applying TLA+ trace instrumentation ==="
echo "Primary src: $PRIMARY_SRC"

# 1. Fix rocksdb build (upgrade to version compatible with newer bindgen)
echo "[1/5] Fixing rocksdb dependency..."
sed -i 's/rocksdb = "0.16.0"/rocksdb = "0.22"/' "$ARTIFACT_DIR/store/Cargo.toml"

# 2. Add serde_json dependency to primary
echo "[2/5] Adding serde_json dependency..."
if ! grep -q 'serde_json' "$ARTIFACT_DIR/primary/Cargo.toml"; then
    sed -i '/^bincode = "1.3.1"$/a serde_json = "1.0"' "$ARTIFACT_DIR/primary/Cargo.toml"
    echo "  Added serde_json"
else
    echo "  serde_json already present"
fi

# 3. Copy tla_trace.rs module
echo "[3/5] Copying tla_trace.rs..."
cp "$SCRIPT_DIR/src/tla_trace.rs" "$PRIMARY_SRC/tla_trace.rs"

# 4. Add module declaration to lib.rs
echo "[4/5] Patching lib.rs..."
if ! grep -q 'tla_trace' "$PRIMARY_SRC/lib.rs"; then
    echo '' >> "$PRIMARY_SRC/lib.rs"
    echo 'pub mod tla_trace;' >> "$PRIMARY_SRC/lib.rs"
    echo "  Added tla_trace module to lib.rs"
else
    echo "  tla_trace module already in lib.rs"
fi

# 5. Apply core.rs instrumentation patch
echo "[5/5] Applying core.rs instrumentation..."
if [ -f "$SCRIPT_DIR/patches/core_instrumentation.patch" ]; then
    cd "$ARTIFACT_DIR"
    git apply --check "$SCRIPT_DIR/patches/core_instrumentation.patch" 2>/dev/null && \
        git apply "$SCRIPT_DIR/patches/core_instrumentation.patch" && \
        echo "  Applied core.rs patch" || \
        echo "  Patch already applied or conflicts"
else
    echo "  WARNING: No core.rs patch found. Run the instrumentation manually."
    echo "  See harness/INSTRUMENTATION.md for details."
fi

echo ""
echo "=== Instrumentation applied ==="
echo ""
echo "To build: cd $ARTIFACT_DIR && cargo build -p primary"
echo "To run with tracing: TLA_TRACE_FILE=trace.ndjson <node_binary> ..."
