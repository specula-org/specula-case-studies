#!/bin/bash
# Apply GRANDPA trace instrumentation patches to a fresh Substrate artifact.
#
# This script applies all modifications needed to emit NDJSON traces
# from the sc-consensus-grandpa crate's existing integration tests.
#
# Prerequisites:
#   - Fresh substrate artifact at artifact/substrate/
#   - Rust toolchain (stable 1.93+)
#   - wasm32-unknown-unknown target installed
#
# Usage:
#   cd case-studies/substrate && bash harness/apply.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(dirname "$SCRIPT_DIR")"
ARTIFACT_DIR="$CASE_DIR/artifact/substrate"

if [ ! -d "$ARTIFACT_DIR" ]; then
    echo "ERROR: Artifact directory not found at $ARTIFACT_DIR"
    exit 1
fi

cd "$ARTIFACT_DIR"

echo "=== Applying GRANDPA trace instrumentation ==="

# -------------------------------------------------------
# 1. Fix rustc 1.93 compatibility: remove #[no_mangle] on panic handler
# -------------------------------------------------------
echo "  [1/7] Fixing sp-io panic handler (#[no_mangle] removal)..."
sed -i '/^#\[no_mangle\]$/{
    N
    /pub fn panic/s/^#\[no_mangle\]\n//
}' primitives/io/src/lib.rs

# -------------------------------------------------------
# 2. Fix wasm-builder: don't exit on runtime_version parse failure
# -------------------------------------------------------
echo "  [2/7] Patching wasm-builder runtime_version check..."
sed -i 's/process::exit(1);$/return;/' utils/wasm-builder/src/wasm_project.rs

# -------------------------------------------------------
# 3. Vendor parity-wasm with saturating float-to-int opcodes
# -------------------------------------------------------
echo "  [3/7] Vendoring patched parity-wasm and wasm-instrument..."
if [ ! -d vendor/parity-wasm-0.45.0 ]; then
    echo "    ERROR: vendor/parity-wasm-0.45.0 not found."
    echo "    Copy the pre-patched vendor/ directory from the harness."
    exit 1
fi
if [ ! -d vendor/wasm-instrument-0.3.0 ]; then
    echo "    ERROR: vendor/wasm-instrument-0.3.0 not found."
    echo "    Copy the pre-patched vendor/ directory from the harness."
    exit 1
fi

# -------------------------------------------------------
# 4. Add [patch.crates-io] to root Cargo.toml
# -------------------------------------------------------
echo "  [4/7] Patching root Cargo.toml..."
if ! grep -q '\[patch.crates-io\]' Cargo.toml; then
    cat >> Cargo.toml <<'TOML'

[patch.crates-io]
parity-wasm = { path = "vendor/parity-wasm-0.45.0" }
wasm-instrument = { path = "vendor/wasm-instrument-0.3.0" }
TOML
fi

# -------------------------------------------------------
# 5. Enable bulk memory in executor
# -------------------------------------------------------
echo "  [5/7] Enabling WASM bulk memory in executor..."
sed -i 's/wasm_bulk_memory: false/wasm_bulk_memory: true/' \
    client/executor/src/wasm_runtime.rs
sed -i 's/wasm-instrument = { version = "0.3" }/wasm-instrument = { version = "0.3", features = ["bulk", "sign_ext"] }/' \
    client/executor/common/Cargo.toml

# -------------------------------------------------------
# 6. Add trace module to sc-consensus-grandpa
# -------------------------------------------------------
echo "  [6/7] Installing tla_trace module..."

# Add once_cell dependency
if ! grep -q 'once_cell' client/consensus/grandpa/Cargo.toml; then
    sed -i '/^log = /a once_cell = "1"' client/consensus/grandpa/Cargo.toml
fi

# Add module declaration
if ! grep -q 'tla_trace' client/consensus/grandpa/src/lib.rs; then
    sed -i '/^mod environment;/a pub(crate) mod tla_trace;' \
        client/consensus/grandpa/src/lib.rs
fi

# Copy trace module
if [ ! -f client/consensus/grandpa/src/tla_trace.rs ]; then
    echo "    ERROR: tla_trace.rs not found. Copy it from the harness."
    exit 1
fi

# -------------------------------------------------------
# 7. Apply environment.rs instrumentation
# -------------------------------------------------------
echo "  [7/7] Checking environment.rs instrumentation..."
if grep -q 'tla_trace::is_enabled' client/consensus/grandpa/src/environment.rs; then
    echo "    Already instrumented."
else
    echo "    ERROR: environment.rs instrumentation not applied."
    echo "    Apply the environment.rs patch manually (see INSTRUMENTATION.md)."
    exit 1
fi

echo ""
echo "=== Instrumentation applied successfully ==="
echo "Run 'bash harness/run.sh' to collect traces."
