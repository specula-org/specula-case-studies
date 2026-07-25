#!/usr/bin/env bash
#
# End-to-end: install the harness into the artifact, build the test binary,
# run each scenario in its own subprocess (so the per-scenario
# SOLANA_TLA_TRACE_FILE env var fixes the destination NDJSON), and report
# trace line counts.
#
# Runtime budget: ~5 min cold cargo build + a couple of seconds per
# scenario.  All `cargo` invocations are wrapped in `timeout` so a deadlocked
# test cannot stall the pipeline forever.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "$HARNESS_DIR/../.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/agave"
TRACES_DIR="$CASE_DIR/.specula-output/traces"
LOG_DIR="$CASE_DIR/.specula-output/harness/logs"

mkdir -p "$TRACES_DIR" "$LOG_DIR"

# libclang.so is required for clang-sys -> rocksdb-sys during the cold build.
# Detect the system library and point LIBCLANG_PATH at a directory containing
# a `libclang.so` symlink.
detect_libclang() {
    if [[ -n "${LIBCLANG_PATH:-}" && -e "$LIBCLANG_PATH/libclang.so" ]]; then
        return 0
    fi
    for cand in /usr/lib/x86_64-linux-gnu/libclang-*.so.* /usr/lib/x86_64-linux-gnu/libclang.so; do
        if [[ -e "$cand" ]]; then
            local target="$LOG_DIR/libclang.so"
            ln -sf "$cand" "$target"
            export LIBCLANG_PATH="$LOG_DIR"
            echo "run.sh: LIBCLANG_PATH=$LIBCLANG_PATH (-> $cand)"
            return 0
        fi
    done
    echo "run.sh: warning: libclang not found; build may fail" >&2
}
detect_libclang

# Stage harness sources into the artifact.
bash "$HARNESS_DIR/apply.sh"

cd "$ARTIFACT"

CARGO_FLAGS=(
    -p solana-core
    --test tla_trace_scenarios
    --features dev-context-only-utils
)

echo "run.sh: building test binary (cold build can take a few minutes)..."
BUILD_LOG="$LOG_DIR/build.log"
if ! timeout 1800 cargo test "${CARGO_FLAGS[@]}" --no-run >"$BUILD_LOG" 2>&1; then
    echo "run.sh: build failed; last 80 lines of $BUILD_LOG:" >&2
    tail -n 80 "$BUILD_LOG" >&2
    exit 1
fi
echo "run.sh: build done"

SCENARIOS=(
    scenario_basic_voting_pipeline
    scenario_crash_before_fsync
    scenario_oc_threshold_slot1
    scenario_two_fork_persistence
)

PASS_COUNT=0
FAIL_COUNT=0

for scenario in "${SCENARIOS[@]}"; do
    trace_file="$TRACES_DIR/$scenario.ndjson"
    rm -f "$trace_file"
    log_file="$LOG_DIR/$scenario.log"
    echo "run.sh: running $scenario -> $trace_file"
    if SOLANA_TLA_TRACE_FILE="$trace_file" \
        timeout 300 cargo test "${CARGO_FLAGS[@]}" -- \
        --exact "$scenario" --nocapture >"$log_file" 2>&1; then
        if [[ -s "$trace_file" ]]; then
            line_count=$(wc -l <"$trace_file")
            echo "  ok ($line_count trace lines)"
            PASS_COUNT=$((PASS_COUNT + 1))
        else
            echo "  ok-but-no-trace ($scenario produced no NDJSON lines)" >&2
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    else
        echo "  FAIL ($scenario exited non-zero; tail of log below)" >&2
        tail -n 20 "$log_file" >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
done

echo "run.sh: ${PASS_COUNT}/${#SCENARIOS[@]} scenarios produced traces ($FAIL_COUNT failures)"
ls -lh "$TRACES_DIR"/*.ndjson 2>/dev/null || true
[[ "$FAIL_COUNT" -eq 0 ]]
