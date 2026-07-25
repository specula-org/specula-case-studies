#!/bin/bash
# Apply TLA+ trace instrumentation to aptos-core consensus crate.
# This script:
# 1. Copies tla_trace.rs module into consensus/src/
# 2. Adds `mod tla_trace;` to consensus/src/lib.rs
# 3. Copies the test scenario into round_manager_tests/
# 4. Adds `mod tla_trace_scenario;` to round_manager_tests/mod.rs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$(cd "$SCRIPT_DIR/../artifact/aptos-core" && pwd)"
CONSENSUS_SRC="$ARTIFACT_DIR/consensus/src"

echo "=== Applying TLA+ trace instrumentation ==="
echo "Consensus src: $CONSENSUS_SRC"

# 1. Copy tla_trace.rs module
echo "[1/4] Copying tla_trace.rs..."
cp "$SCRIPT_DIR/src/tla_trace.rs" "$CONSENSUS_SRC/tla_trace.rs"

# 2. Add module declaration to lib.rs (if not already present)
echo "[2/4] Patching lib.rs..."
if ! grep -q 'mod tla_trace;' "$CONSENSUS_SRC/lib.rs"; then
    # Add after the last `pub mod` line, guarded by cfg(test)
    # Find the line number of the last `pub mod` or `mod` declaration
    echo '' >> "$CONSENSUS_SRC/lib.rs"
    echo '#[cfg(test)]' >> "$CONSENSUS_SRC/lib.rs"
    echo 'pub mod tla_trace;' >> "$CONSENSUS_SRC/lib.rs"
    echo "  Added tla_trace module to lib.rs"
else
    echo "  tla_trace module already in lib.rs"
fi

# 3. Copy test scenario
echo "[3/4] Copying tla_trace_scenario.rs..."
cp "$SCRIPT_DIR/src/tla_trace_scenario.rs" "$CONSENSUS_SRC/round_manager_tests/tla_trace_scenario.rs"

# 4. Add test module declaration (if not already present)
echo "[4/4] Patching round_manager_tests/mod.rs..."
if ! grep -q 'mod tla_trace_scenario;' "$CONSENSUS_SRC/round_manager_tests/mod.rs"; then
    echo '' >> "$CONSENSUS_SRC/round_manager_tests/mod.rs"
    echo 'mod tla_trace_scenario;' >> "$CONSENSUS_SRC/round_manager_tests/mod.rs"
    echo "  Added tla_trace_scenario module"
else
    echo "  tla_trace_scenario module already present"
fi

echo "=== Instrumentation applied successfully ==="
echo ""
echo "To build and run:"
echo "  cd $ARTIFACT_DIR && cargo test -p aptos-consensus --test '' -- tla_trace_basic_consensus --nocapture"
