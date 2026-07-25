#!/usr/bin/env bash
# One-command harness: apply instrumentation, build crossbeam-deque, run trace
# scenarios, preprocess per-thread NDJSON into Trace.tla-friendly JSON files.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
ARTIFACT_DIR="$(cd "$HARNESS_DIR/../../artifact/crossbeam" && pwd)"
TRACES_DIR="$OUT_DIR/traces"
SCRATCH_DIR="$OUT_DIR/.trace-scratch"

mkdir -p "$TRACES_DIR" "$SCRATCH_DIR"

# 1. Apply (or re-apply) instrumentation.
bash "$HARNESS_DIR/apply.sh"

# 2. Build only what we need: the crossbeam-deque tests with trace_scenarios.
echo "[run] cargo build -p crossbeam-deque --tests ..."
( cd "$ARTIFACT_DIR" && cargo build -p crossbeam-deque --tests --quiet )

run_scenario() {
    local scenario="$1"; local flavor="$2"
    local scenario_dir="$SCRATCH_DIR/$scenario"
    rm -rf "$scenario_dir"
    mkdir -p "$scenario_dir"

    echo "[run] scenario: $scenario  (flavor=$flavor)"
    (
        cd "$ARTIFACT_DIR"
        CROSSBEAM_DEQUE_TRACE_DIR_BASE="$SCRATCH_DIR" \
        cargo test -p crossbeam-deque --test trace_scenarios -- \
            --exact --nocapture "$scenario" >/dev/null
    )

    if ! ls "$scenario_dir"/trace-*.ndjson >/dev/null 2>&1; then
        echo "[run] WARNING: no trace files emitted for $scenario"
        return 1
    fi

    python3 "$HARNESS_DIR/preprocess_trace.py" \
        "$scenario_dir" \
        "$TRACES_DIR/$scenario.json" \
        --flavor "$flavor"

    # Also emit one of the raw per-thread NDJSON files concatenated for easy
    # inspection. Spec validation reads the merged JSON, but humans want
    # NDJSON.
    cat "$scenario_dir"/trace-*.ndjson > "$TRACES_DIR/$scenario.ndjson"

    local lines
    lines=$(wc -l < "$TRACES_DIR/$scenario.ndjson")
    echo "[run]   $scenario.ndjson: $lines events"
}

# 3. Run each scenario.
run_scenario "fifo_short"           "FIFO"
run_scenario "fifo_two_stealers"    "FIFO"
run_scenario "lifo_three_stealers"  "LIFO"

echo "[run] done. Traces in $TRACES_DIR/"
ls -la "$TRACES_DIR/"
