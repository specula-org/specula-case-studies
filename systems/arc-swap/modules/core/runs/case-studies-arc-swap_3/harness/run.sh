#!/usr/bin/env bash
# run.sh — one-command end-to-end: apply instrumentation, build, run the
# trace test scenarios, collect NDJSON traces under .specula-output/traces/.
#
# Usage:  bash harness/run.sh
# Run from the case-study directory (so that traces/ paths resolve).

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECULA_OUT="$(cd "$HARNESS_DIR/.." && pwd)"
TRACES_DIR="$SPECULA_OUT/traces"
ARTIFACT_DIR="$HARNESS_DIR/../../artifact/arc-swap"

mkdir -p "$TRACES_DIR"

echo "==> Applying instrumentation"
bash "$HARNESS_DIR/apply.sh"

echo "==> Running trace scenarios"
# --test-threads=1 is required because LIST_HEAD is process-global; running
# tests serially keeps the per-test trace clean.
rm -f "$TRACES_DIR"/*.ndjson
( cd "$ARTIFACT_DIR" && \
  ARC_SWAP_TRACE_OUT="$TRACES_DIR" \
  cargo test --test tla_trace_scenarios -- --test-threads=1 --nocapture )

echo
echo "==> Trace files:"
for f in "$TRACES_DIR"/*.ndjson; do
    n=$(wc -l < "$f")
    echo "  $(basename "$f"): $n lines"
done

echo
echo "==> Done.  Traces are under $TRACES_DIR/"
