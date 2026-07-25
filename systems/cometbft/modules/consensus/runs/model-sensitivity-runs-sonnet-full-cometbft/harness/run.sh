#!/bin/bash
# Run CometBFT consensus trace harness.
# Generates NDJSON traces for TLA+ trace validation, then post-processes them
# to map concrete hex addresses/hashes to abstract IDs (s1/s2/s3, v1/v2/...).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMETBFT_DIR="$SCRIPT_DIR/../artifact/cometbft"
TRACE_DIR="$SCRIPT_DIR/../traces"

mkdir -p "$TRACE_DIR"

export TRACE_DIR
export PATH=/usr/local/go/bin:$HOME/go/bin:/usr/bin:$PATH

echo "==> Verifying instrumentation..."
bash "$SCRIPT_DIR/apply.sh"

echo ""
echo "==> Building consensus package..."
cd "$COMETBFT_DIR"
go build ./consensus/ 2>&1

echo ""
echo "==> Running CometBFT trace scenarios..."
FAILED=0
for scenario in BasicConsensus TimeoutPropose LockAndRelock TwoHeights PrevoteWait; do
    echo "--- Scenario: $scenario"
    if timeout 120 go test -v -count=1 -run "TestScenario${scenario}" -timeout 90s ./consensus/ 2>&1; then
        echo "PASS: $scenario"
    else
        echo "FAIL: $scenario (exit $?)"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "==> Post-processing traces (hex -> abstract IDs)..."
for raw in "$TRACE_DIR"/basic_consensus.ndjson \
           "$TRACE_DIR"/timeout_propose.ndjson \
           "$TRACE_DIR"/lock_and_relock.ndjson \
           "$TRACE_DIR"/two_heights.ndjson \
           "$TRACE_DIR"/prevote_wait.ndjson; do
    name="$(basename "${raw%.ndjson}")"
    mapped="$TRACE_DIR/${name}_mapped.ndjson"
    if [[ -f "$raw" ]]; then
        python3 "$SCRIPT_DIR/preprocess_trace.py" "$raw" "$mapped" && \
            echo "  $name: $(wc -l < "$mapped") events (mapped)"
    else
        echo "  MISSING: $raw"
    fi
done

echo ""
echo "==> Trace summary:"
for f in "$TRACE_DIR"/*.ndjson; do
    printf "  %-45s  %d events\n" "$(basename "$f")" "$(wc -l < "$f" 2>/dev/null || echo 0)"
done

if [[ $FAILED -gt 0 ]]; then
    echo ""
    echo "WARNING: $FAILED scenario(s) failed"
    exit 1
fi

echo ""
echo "Done. Traces written to: $TRACE_DIR"
