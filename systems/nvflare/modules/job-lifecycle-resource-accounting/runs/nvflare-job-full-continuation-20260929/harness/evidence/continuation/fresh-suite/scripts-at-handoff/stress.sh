#!/bin/bash
# Optional additional scheduling variation. Fresh round dirs; up to four scenario processes; serial TLC.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/paths.sh"
ROUNDS="${1:-2}"
BUILD="$SCRIPT_DIR/build/nvflare_src"
[[ "$ROUNDS" =~ ^[1-9][0-9]*$ ]] || exit 2
[ -d "$BUILD/nvflare" ] || { echo "run harness/apply.sh first"; exit 1; }
DEFAULT="$(sed -n '/^DEFAULT_SCENARIOS="/,/"$/p' "$SCRIPT_DIR/run.sh" | tr -d '\\"' | sed 's/DEFAULT_SCENARIOS=//' | tr '\n' ' ')"
SCENARIOS="${SCENARIOS:-$DEFAULT}"
export NVF_INSTRUMENTED_ROOT="$BUILD"
export PYTHONPATH="$BUILD:$SCRIPT_DIR/src"
export NVF_STRESS_SCRIPT_DIR="$SCRIPT_DIR"
for r in $(seq 1 "$ROUNDS"); do
    NVF_STRESS_DIR="$(mktemp -d "$SCRIPT_DIR/build/stress-round${r}-XXXXXX")"
    export NVF_STRESS_DIR
    printf '%s\n' $SCENARIOS | xargs -r -P 4 -I '{}' bash -c '
        s="$1"
        [[ "$s" =~ ^[a-z][a-z0-9_]*$ ]] || exit 2
        timeout 180 "$NVF_PYTHON" "$NVF_STRESS_SCRIPT_DIR/src/run_scenario.py" "$s" \
            --out "$NVF_STRESS_DIR/$s.ndjson" --root "$NVF_STRESS_DIR/work-$s" \
            --report "$NVF_STRESS_DIR/$s.json" > "$NVF_STRESS_DIR/$s.stdout" 2> "$NVF_STRESS_DIR/$s.stderr"
        rc=$?
        printf "%s\n" "$rc" > "$NVF_STRESS_DIR/$s.exitcode"
        [ "$rc" -eq 0 ] || exit "$rc"
        "$NVF_PYTHON" "$NVF_STRESS_SCRIPT_DIR/src/trace_contract.py" "$NVF_STRESS_DIR/$s.ndjson" \
            --report "$NVF_STRESS_DIR/$s.json" > "$NVF_STRESS_DIR/$s.integrity.json"
    ' _ '{}'
    bash "$SCRIPT_DIR/validate.sh" --report-dir "$NVF_STRESS_DIR" "$NVF_STRESS_DIR"/*.ndjson \
        --results "$NVF_STRESS_DIR/replay-results.json" > "$NVF_STRESS_DIR/validate.txt" 2>&1
    echo "round $r complete: $NVF_STRESS_DIR"
done
