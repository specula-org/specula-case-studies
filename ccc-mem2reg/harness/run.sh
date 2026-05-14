#!/usr/bin/env bash
# One-command: apply instrumentation, build, run scenarios, collect traces.
#
# Run from .specula-output/:
#   bash harness/run.sh
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECULA_OUT="$(cd "$HARNESS_DIR/.." && pwd)"
ARTIFACT_DIR="$HARNESS_DIR/../../../ccc/artifact/claudes-c-compiler"
TRACES_DIR="$SPECULA_OUT/traces"

mkdir -p "$TRACES_DIR"

echo "[run] applying instrumentation"
bash "$HARNESS_DIR/apply.sh"

echo "[run] building (this can take a few minutes on first run)"
( cd "$ARTIFACT_DIR" && cargo build --lib --tests --quiet )

echo "[run] executing scenarios"
# Per-scenario test names match `#[test]` functions in trace_scenarios.rs.
SCENARIOS=( "trace_diamond" )
for s in "${SCENARIOS[@]}"; do
  echo "[run]   scenario: $s"
  ( cd "$ARTIFACT_DIR" && \
    CCC_TRACE_DIR="$TRACES_DIR" \
    cargo test --quiet --lib -- --exact --nocapture "ir::mem2reg::trace_scenarios::$s" \
      2>&1 | tail -10 ) || true
done

echo "[run] trace files:"
for f in "$TRACES_DIR"/*.ndjson; do
  if [[ -f "$f" ]]; then
    lines=$(wc -l < "$f" || echo "?")
    echo "  $(basename "$f"): $lines lines"
  fi
done

echo "[run] done"
