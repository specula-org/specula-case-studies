#!/bin/bash
# apply.sh — Verify instrumentation is in place (no copy needed; files live in artifact).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMETBFT_DIR="$SCRIPT_DIR/../artifact/cometbft"

echo "==> Verifying instrumentation in $COMETBFT_DIR/consensus/"

for f in trace_emit.go scenario_trace_test.go; do
    if [[ ! -f "$COMETBFT_DIR/consensus/$f" ]]; then
        echo "MISSING: consensus/$f"
        exit 1
    fi
done

grep -q "traceLogger.Emit" "$COMETBFT_DIR/consensus/state.go" || {
    echo "MISSING: trace emit calls in state.go"
    exit 1
}

echo "Instrumentation verified."
