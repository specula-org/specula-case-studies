#!/bin/bash
# Remove TLA+ trace instrumentation from aptos-core consensus crate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$(cd "$SCRIPT_DIR/../artifact/aptos-core" && pwd)"
CONSENSUS_SRC="$ARTIFACT_DIR/consensus/src"

echo "=== Removing TLA+ trace instrumentation ==="

# 1. Remove tla_trace.rs module
rm -f "$CONSENSUS_SRC/tla_trace.rs"
echo "Removed tla_trace.rs"

# 2. Remove from lib.rs
if [ -f "$CONSENSUS_SRC/lib.rs" ]; then
    sed -i '/#\[cfg(test)\]/{N;/pub mod tla_trace;/d}' "$CONSENSUS_SRC/lib.rs"
    # Also remove standalone line if pattern didn't match
    sed -i '/^pub mod tla_trace;$/d' "$CONSENSUS_SRC/lib.rs"
    echo "Cleaned lib.rs"
fi

# 3. Remove test scenario
rm -f "$CONSENSUS_SRC/round_manager_tests/tla_trace_scenario.rs"
echo "Removed tla_trace_scenario.rs"

# 4. Remove from round_manager_tests/mod.rs
if [ -f "$CONSENSUS_SRC/round_manager_tests/mod.rs" ]; then
    sed -i '/^mod tla_trace_scenario;$/d' "$CONSENSUS_SRC/round_manager_tests/mod.rs"
    echo "Cleaned round_manager_tests/mod.rs"
fi

echo "=== Instrumentation removed ==="
