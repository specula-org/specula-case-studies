#!/usr/bin/env bash
# Revert trace instrumentation in the CCC artifact.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="$HARNESS_DIR/../../../ccc/artifact/claudes-c-compiler"

if [[ ! -d "$ARTIFACT_DIR" ]]; then
  echo "error: artifact not found at $ARTIFACT_DIR" >&2
  exit 1
fi

echo "[clean] artifact: $ARTIFACT_DIR"
( cd "$ARTIFACT_DIR" && git checkout -- src/ir/analysis.rs src/ir/mem2reg/ )
( cd "$ARTIFACT_DIR" && rm -f src/ir/mem2reg/tla_trace.rs src/ir/mem2reg/trace_helpers.rs src/ir/mem2reg/trace_scenarios.rs )
echo "[clean] reverted"
