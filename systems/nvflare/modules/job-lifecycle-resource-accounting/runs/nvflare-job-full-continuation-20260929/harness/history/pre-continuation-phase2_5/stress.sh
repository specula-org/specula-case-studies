#!/bin/bash
# Re-run scenarios N times in parallel (CPU contention varies the interleavings) and TLC-validate every trace.
#   bash harness/stress.sh 3                                   # 3 rounds of the default set
#   SCENARIOS="random_mix_s7 random_mix_s8" bash harness/stress.sh 2
# Traces go to harness/build/stress/round<k>/ (the official traces/ directory is not touched).
# Requires a built instrumented copy (bash harness/apply.sh or harness/run.sh).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROUNDS="${1:-2}"
BUILD="$SCRIPT_DIR/build/nvflare_src"
[ -d "$BUILD/nvflare" ] || { echo "run harness/apply.sh first"; exit 1; }
DEFAULT="$(sed -n '/^DEFAULT_SCENARIOS="/,/"$/p' "$SCRIPT_DIR/run.sh" | tr -d '\\"' | sed 's/DEFAULT_SCENARIOS=//' | tr '\n' ' ')"
SCENARIOS="${SCENARIOS:-$DEFAULT}"
export NVF_INSTRUMENTED_ROOT="$BUILD"
export PYTHONPATH="$BUILD:$SCRIPT_DIR/src"
for r in $(seq 1 "$ROUNDS"); do
    D="$SCRIPT_DIR/build/stress/round$r"
    rm -rf "$D" && mkdir -p "$D"
    for s in $SCENARIOS; do
        ( timeout 180 python3 "$SCRIPT_DIR/src/run_scenario.py" "$s" --out "$D/$s.ndjson" --root "$D/work-$s" \
            --report "$D/$s.json" > "$D/$s.stdout" 2> "$D/$s.stderr" || echo "$s rc=$?" >> "$D/run_failures.txt" ) &
    done
    wait
    [ -f "$D/run_failures.txt" ] && { echo "round $r scenario failures:"; cat "$D/run_failures.txt"; }
    bash "$SCRIPT_DIR/validate.sh" "$D"/*.ndjson > "$D/validate.txt" 2>&1
    echo "round $r: $(grep -c '^PASS' "$D/validate.txt") pass; fail: $(grep '^FAIL' "$D/validate.txt" | awk '{print $2}' | tr '\n' ' ')"
done
