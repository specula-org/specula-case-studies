#!/usr/bin/env bash
set -euo pipefail
HARNESS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export SOURCE_DIR=${SOURCE_DIR:-"$HARNESS_DIR/../../source"}
export TRACE_DIR=${TRACE_DIR:-"$HARNESS_DIR/../traces"}
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-"$HARNESS_DIR/build"}
mkdir -p "$TRACE_DIR" "$HARNESS_DIR/logs"
bash "$HARNESS_DIR/apply.sh"
cd "$SOURCE_DIR"
# The pinned dependency lock is retained with the harness, including the workspace.
if test -f "$HARNESS_DIR/Cargo.lock"; then
    if test -f Cargo.lock && ! cmp -s Cargo.lock "$HARNESS_DIR/Cargo.lock"; then
        echo 'Existing Cargo.lock differs from harness lock; preserving it' >&2
        exit 1
    fi
    cp "$HARNESS_DIR/Cargo.lock" Cargo.lock
fi
timeout 600 cargo test --locked -p vsr-rs --features trace-harness --lib --no-run 2>&1 | tee "$HARNESS_DIR/logs/build.log"
cp Cargo.lock "$HARNESS_DIR/Cargo.lock"
timeout 180 cargo test --locked -p vsr-rs --features trace-harness --lib tla_trace::scenarios:: -- --test-threads=1 --nocapture 2>&1 | tee "$HARNESS_DIR/logs/scenarios.log"
shopt -s nullglob
traces=("$TRACE_DIR"/*.ndjson)
wc -l "${traces[@]}"
python3 "$HARNESS_DIR/audit_traces.py" --require-all-events "${traces[@]}" > "$HARNESS_DIR/logs/coverage.json"
bash "$HARNESS_DIR/validate.sh" "${traces[@]}"
python3 "$HARNESS_DIR/manifest.py"
