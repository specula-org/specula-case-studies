#!/usr/bin/env bash
set -euo pipefail
HARNESS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OUTPUT_DIR=$(dirname -- "$HARNESS_DIR")
SOURCE_DIR=${VSR_SOURCE_DIR:-"$(dirname -- "$OUTPUT_DIR")/source"}
export VSR_TRACE_DIR="$OUTPUT_DIR/traces"
export VSR_TRACE_RUNTIME="$HARNESS_DIR/runtime"
mkdir -p "$VSR_TRACE_DIR" "$VSR_TRACE_RUNTIME" "$HARNESS_DIR/validation"
bash "$HARNESS_DIR/apply.sh"
cd -- "$SOURCE_DIR"
run_bounded() {
    local seconds=$1 logfile=$2 result
    shift 2
    if timeout "$seconds" "$@" > "$logfile" 2>&1; then
        return 0
    else
        result=$?
        cat "$logfile"
        if [[ $result == 124 ]]; then
            echo "Build/test timeout: potential hang; stopped without retry." >&2
        fi
        return "$result"
    fi
}
run_bounded 300 "$HARNESS_DIR/validation/build.log" cargo test --features tla-trace --test specula_trace --no-run
run_bounded 180 "$HARNESS_DIR/validation/scenarios.log" cargo test --features tla-trace --test specula_trace -- --test-threads=1 --nocapture
cat "$HARNESS_DIR/validation/scenarios.log"
wc -l "$VSR_TRACE_DIR"/*.ndjson
python3 "$HARNESS_DIR/validate.py"
python3 "$HARNESS_DIR/provenance.py" "$SOURCE_DIR"
