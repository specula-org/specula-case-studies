#!/bin/bash
# run.sh — apply instrumentation, build, run scenarios, collect traces.
#
# Run from .specula-output/:
#     bash harness/run.sh
#
# Output:
#     traces/<scenario>.ndjson       per-scenario merged trace (JSON)
#     traces/<scenario>.thread_*.ndjson  raw per-thread NDJSON (kept for debugging)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECULA_OUT="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_ROOT="$(cd "$SPECULA_OUT/../artifact/crossbeam/crossbeam-skiplist" && pwd)"
TRACES_DIR="$SPECULA_OUT/traces"

mkdir -p "$TRACES_DIR"

echo "=== Step 1: apply instrumentation ==="
bash "$SCRIPT_DIR/apply.sh"

echo "=== Step 2: build ==="
( cd "$ARTIFACT_ROOT" && timeout 240 cargo build --features tla-trace --tests 2>&1 | tail -20 )

# Each scenario gets its own trace dir + per-scenario merged JSON.
SCENARIOS=(
    scenario_single_thread_basic
    scenario_insert_replace
    scenario_height_growth
    scenario_two_threads_distinct_keys
    scenario_insert_remove_race
)

echo "=== Step 3: run scenarios ==="
for scen in "${SCENARIOS[@]}"; do
    SCEN_DIR="$TRACES_DIR/.raw_$scen"
    rm -rf "$SCEN_DIR"
    mkdir -p "$SCEN_DIR"

    echo "  -> $scen"
    (
        cd "$ARTIFACT_ROOT"
        CROSSBEAM_SKIPLIST_TRACE_DIR="$SCEN_DIR" \
            timeout 60 cargo test --features tla-trace --test tla_scenarios \
                -- "$scen" --nocapture --test-threads=1 \
            > "$SCEN_DIR/cargo.log" 2>&1
    ) || {
        echo "    FAIL: see $SCEN_DIR/cargo.log"
        continue
    }

    # Save cargo.log alongside the merged trace for reference.
    if ls "$SCEN_DIR"/thread_*.ndjson >/dev/null 2>&1; then
        OUT_JSON="$TRACES_DIR/$scen.ndjson"
        python3 "$SCRIPT_DIR/preprocess_trace.py" "$SCEN_DIR" "$OUT_JSON"
    else
        echo "    WARN: no thread_*.ndjson written for $scen"
    fi
done

echo
echo "=== Step 4: trace summary ==="
for scen in "${SCENARIOS[@]}"; do
    f="$TRACES_DIR/$scen.ndjson"
    if [ -f "$f" ]; then
        # Count events by walking the JSON
        n_events=$(python3 -c "
import json,sys
d=json.load(open('$f'))
total=sum(len(v) for k,v in d.items() if k!='meta')
print(total)
")
        echo "  $scen: $n_events events"
    else
        echo "  $scen: MISSING"
    fi
done

echo
echo "Done. Traces in: $TRACES_DIR"
