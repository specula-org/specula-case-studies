#!/bin/bash
# Apply TLA+ trace instrumentation to openraft.
#
# This script:
#   1. Resets the artifact to a clean state
#   2. Copies the trace module into openraft/src/
#   3. Applies the instrumentation patch
#   4. Copies the test scenario into tests/tests/
#   5. Adds the tla-trace feature to the test crate

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="$CASE_DIR/artifact/openraft"
OPENRAFT_SRC="$ARTIFACT_DIR/openraft/src"
TESTS_DIR="$ARTIFACT_DIR/tests/tests"

echo "=== Applying TLA+ trace instrumentation ==="
echo "Artifact: $ARTIFACT_DIR"

# 1. Reset to clean state
echo "--- Resetting artifact to clean state"
git -C "$ARTIFACT_DIR" checkout -- .

# 2. Copy trace module
echo "--- Copying tla_trace.rs"
cp "$SCRIPT_DIR/src/tla_trace.rs" "$OPENRAFT_SRC/tla_trace.rs"

# 3. Apply instrumentation patch
echo "--- Applying instrumentation patch"
git -C "$ARTIFACT_DIR" apply "$SCRIPT_DIR/patches/instrumentation.patch"

# 4. Copy test scenario
echo "--- Copying test scenario"
mkdir -p "$TESTS_DIR/tla_trace"
cp "$SCRIPT_DIR/src/tla_trace_test.rs" "$TESTS_DIR/tla_trace/tla_trace_basic_consensus.rs"
cp "$SCRIPT_DIR/src/tla_trace_main.rs" "$TESTS_DIR/tla_trace/main.rs"

# 5. Add tla-trace feature to test crate
echo "--- Adding tla-trace feature to test crate"
if ! grep -q 'tla-trace' "$ARTIFACT_DIR/tests/Cargo.toml"; then
    # Add feature to openraft dependency
    sed -i 's|openraft.*=.*{.*path = "../openraft".*features = \["type-alias"\].*}|openraft = { path = "../openraft", version = "0.10.0-alpha.17", features = ["type-alias", "tla-trace"] }|' "$ARTIFACT_DIR/tests/Cargo.toml"

    # Add [[test]] entry for the tla_trace test binary
    cat >> "$ARTIFACT_DIR/tests/Cargo.toml" <<'EOF'

[[test]]
name = "tla_trace"
path = "tests/tla_trace/main.rs"
EOF
fi

echo "=== Instrumentation applied successfully ==="
