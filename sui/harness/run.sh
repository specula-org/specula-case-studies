#!/usr/bin/env bash
# Build the instrumented consensus-core crate and run trace-emitting scenarios.
#
# Each scenario test is invoked separately so the `TLA_TRACE_FILE` env var
# points to a distinct file. NDJSON traces land in
# <ROOT>/.specula-output/traces/<scenario>.ndjson.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HARNESS_DIR/../.." && pwd)"
ARTIFACT_DIR="$ROOT_DIR/artifact/sui"
TRACES_DIR="$ROOT_DIR/.specula-output/traces"

mkdir -p "$TRACES_DIR"

echo "[run] Applying instrumentation"
bash "$HARNESS_DIR/apply.sh"

echo "[run] Compiling consensus-core tests (this builds the crate once)"
# Build & cache the test binary up-front so per-scenario invocations only run.
# Outer timeout: build is expected under 5 min on a warm cache, < 30 min cold.
(cd "$ARTIFACT_DIR" && timeout 1800 cargo test \
    -p consensus-core \
    --no-run \
    tla_trace_scenario_ \
    2>&1 | tail -40)

SCENARIOS=(
    "normal"
    "equivocation"
    "crash_recover"
    "force_propose"
)

for s in "${SCENARIOS[@]}"; do
    out="$TRACES_DIR/${s}.ndjson"
    echo "[run] Scenario: $s -> $out"
    # Run each scenario in a fresh process: ensures static state (writer, signed_history) starts clean.
    (cd "$ARTIFACT_DIR" && TLA_TRACE_FILE="$out" timeout 300 cargo test \
        -p consensus-core \
        --lib \
        -- \
        --exact \
        --nocapture \
        "tla_trace_scenarios::tla_trace_scenario_${s}" \
        2>&1 | tail -20) || {
            echo "[run] WARNING: scenario $s exited non-zero (see above)" >&2
        }
    if [[ -s "$out" ]]; then
        lines=$(wc -l <"$out")
        echo "[run]   $s: $lines trace lines"
        # Compress digests + timestamps to small spec integers.
        python3 "$HARNESS_DIR/preprocess_trace.py" \
            "$out" "$TRACES_DIR/${s}.preprocessed.ndjson"
    else
        echo "[run]   $s: NO TRACE OUTPUT" >&2
    fi
done

echo
echo "[run] All trace files:"
ls -la "$TRACES_DIR" || true

echo "[run] Sample lines (first scenario):"
head -3 "$TRACES_DIR/normal.ndjson" 2>/dev/null || true

echo "[run] Done."
