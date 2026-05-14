#!/usr/bin/env bash
# Apply trace instrumentation to the CCC artifact.
#
# Strategy: copy harness/instrumented/<file>.rs over the originals, plus
# drop trace module sources into src/ir/mem2reg/. Use clean.sh to revert.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="$HARNESS_DIR/../../../ccc/artifact/claudes-c-compiler"
SRC_DIR="$ARTIFACT_DIR/src"

if [[ ! -d "$ARTIFACT_DIR" ]]; then
  echo "error: artifact not found at $ARTIFACT_DIR" >&2
  exit 1
fi

echo "[apply] artifact: $ARTIFACT_DIR"

# Ensure clean baseline first.
( cd "$ARTIFACT_DIR" && git checkout -- src/ir/analysis.rs src/ir/mem2reg/ 2>/dev/null || true )
( cd "$ARTIFACT_DIR" && rm -f src/ir/mem2reg/tla_trace.rs src/ir/mem2reg/trace_helpers.rs src/ir/mem2reg/trace_scenarios.rs )

# Copy instrumented versions over the originals.
cp "$HARNESS_DIR/instrumented/promote.rs"      "$SRC_DIR/ir/mem2reg/promote.rs"
cp "$HARNESS_DIR/instrumented/phi_eliminate.rs" "$SRC_DIR/ir/mem2reg/phi_eliminate.rs"
cp "$HARNESS_DIR/instrumented/analysis.rs"      "$SRC_DIR/ir/analysis.rs"
cp "$HARNESS_DIR/instrumented/mod.rs"           "$SRC_DIR/ir/mem2reg/mod.rs"

# Drop the trace module sources and the test scenarios into the artifact.
cp "$HARNESS_DIR/src/tla_trace.rs"        "$SRC_DIR/ir/mem2reg/tla_trace.rs"
cp "$HARNESS_DIR/src/trace_helpers.rs"    "$SRC_DIR/ir/mem2reg/trace_helpers.rs"
cp "$HARNESS_DIR/src/trace_scenarios.rs"  "$SRC_DIR/ir/mem2reg/trace_scenarios.rs"

echo "[apply] instrumentation applied"
