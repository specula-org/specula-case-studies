#!/usr/bin/env bash
# End-to-end: apply instrumentation, build the example, run scenarios, merge
# per-thread shards into a single trace JSON for Trace.tla.
#
# Usage:
#     bash run.sh                      # all scenarios
#     bash run.sh basic concurrent_defer
#     SCENARIOS="basic" bash run.sh    # alternative
#
# Output:
#     traces/<scenario>/trace-tN.ndjson   per-thread shards
#     traces/<scenario>.ndjson            merged + compressed file (Trace.tla
#                                         input via the `JSON` env var)

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_ROOT="$HARNESS_DIR/../../artifact/crossbeam"
EPOCH_DIR="$ARTIFACT_ROOT/crossbeam-epoch"
TRACES_DIR="$HARNESS_DIR/../traces"

ALL_SCENARIOS=(basic concurrent_defer repin_panic nested_pin)

if [[ $# -gt 0 ]]; then
    SCENARIOS=("$@")
elif [[ -n "${SCENARIOS:-}" ]]; then
    read -ra SCENARIOS <<< "$SCENARIOS"
else
    SCENARIOS=("${ALL_SCENARIOS[@]}")
fi

echo "[run.sh] applying instrumentation"
bash "$HARNESS_DIR/apply.sh"

echo "[run.sh] building tla_harness"
( cd "$EPOCH_DIR" && cargo build --release --example tla_harness >/dev/null 2>&1 )

mkdir -p "$TRACES_DIR"

for scenario in "${SCENARIOS[@]}"; do
    out="$TRACES_DIR/$scenario"
    rm -rf "$out"
    mkdir -p "$out"
    echo "[run.sh] running scenario: $scenario"
    ( cd "$EPOCH_DIR" && \
      cargo run --release --example tla_harness -- "$scenario" "$out" 2>&1 \
        | grep -v 'panicked at' || true )

    merged="$TRACES_DIR/$scenario.ndjson"
    python3 "$HARNESS_DIR/preprocess.py" "$out" "$merged"
done

echo
echo "[run.sh] traces summary:"
for scenario in "${SCENARIOS[@]}"; do
    out="$TRACES_DIR/$scenario"
    if [[ -d "$out" ]]; then
        for shard in "$out"/trace-*.ndjson; do
            [[ -f "$shard" ]] || continue
            n=$(wc -l < "$shard")
            printf "  %-22s %s : %d events\n" "$scenario" "$(basename "$shard")" "$n"
        done
    fi
done
echo "[run.sh] done."
