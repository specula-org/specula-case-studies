#!/usr/bin/env bash
# Specula trace harness driver for Babylon.
#
# Steps:
#   1. Apply trace instrumentation to the artifact (idempotent).
#   2. Build + run trace scenarios with BABYLON_TLA_TRACE_FILE set to one
#      NDJSON file per scenario.
#   3. Copy generated NDJSON traces into .specula-output/traces/.
#   4. Print summary line counts.
#
# Usage:    bash harness/run.sh
# From:     anywhere; uses absolute paths derived from the script location.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECULA_OUT="$(cd "$HARNESS_DIR/.." && pwd)"
ARTIFACT_ROOT="$(cd "$SPECULA_OUT/../artifact/babylon" && pwd)"
TRACES_DIR="$SPECULA_OUT/traces"
GO_BIN="${GO_BIN:-/usr/local/go/bin/go}"

if [[ ! -x "$GO_BIN" ]]; then
    if command -v go >/dev/null 2>&1; then
        GO_BIN="$(command -v go)"
    else
        echo "ERROR: go not found (tried /usr/local/go/bin/go and PATH)" >&2
        exit 1
    fi
fi

mkdir -p "$TRACES_DIR"

echo "==> [1/4] Applying instrumentation"
bash "$HARNESS_DIR/apply.sh"

cd "$ARTIFACT_ROOT"

echo "==> [2/4] Pre-fetching Go toolchain (downloads babylon's pinned Go)"
export GOTOOLCHAIN=auto
export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"
# Trigger toolchain bootstrap by running 'go env' (cheap).
"$GO_BIN" env GOTOOLCHAIN >/dev/null

# Helper: run one scenario with BABYLON_TLA_TRACE_FILE pointing at a fresh
# NDJSON file.  Each scenario emits its own file.
run_scenario() {
    local test_name="$1" out_file="$2"
    : > "$out_file"
    echo "    --> ${test_name}  →  ${out_file##*/}"
    BABYLON_TLA_TRACE_FILE="$out_file" timeout 600 "$GO_BIN" test \
        -run "^${test_name}\$" -v -count=1 -timeout 5m \
        ./x/tlatrace_scenarios/...
}

echo "==> [3/4] Running scenarios"
run_scenario TestTraceScenarioFinality "$TRACES_DIR/finality.ndjson"
run_scenario TestTraceScenarioCommitPubRandRetroactive "$TRACES_DIR/commitpubrand_retroactive.ndjson"
run_scenario TestTraceScenarioLiveness "$TRACES_DIR/liveness.ndjson"
run_scenario TestTraceScenarioUnjail "$TRACES_DIR/unjail.ndjson"

echo "==> [4/4] Trace summary"
shopt -s nullglob
for f in "$TRACES_DIR"/*.ndjson; do
    n=$(wc -l < "$f" || echo 0)
    echo "    $(basename "$f"): $n line(s)"
done

echo "==> Done.  Traces under $TRACES_DIR"
