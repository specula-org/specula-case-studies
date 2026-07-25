#!/usr/bin/env bash
# One-shot: apply instrumentation, build, run scenarios, collect traces.
#
# Run from .specula-output/:   bash harness/run.sh
# Or from anywhere:            bash /path/to/harness/run.sh
#
# Each scenario writes one trace file in .specula-output/traces/.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-$OUTPUT_DIR/../artifact/agave}"
TRACES_DIR="$OUTPUT_DIR/traces"

mkdir -p "$TRACES_DIR"

echo "[run.sh] HARNESS_DIR=$HARNESS_DIR"
echo "[run.sh] ARTIFACT_DIR=$ARTIFACT_DIR"
echo "[run.sh] TRACES_DIR=$TRACES_DIR"

# clang-sys looks for libclang.so (no version suffix) under LIBCLANG_PATH.
# Ubuntu ships libclang-18.so.1; pre-create a symlinked dir we control.
LIBCLANG_DIR="$HARNESS_DIR/.libclang"
if [[ ! -f "$LIBCLANG_DIR/libclang.so" ]]; then
    mkdir -p "$LIBCLANG_DIR"
    for cand in /usr/lib/x86_64-linux-gnu/libclang-18.so.1 \
                /usr/lib/llvm-18/lib/libclang.so.1; do
        if [[ -e "$cand" ]]; then
            ln -sf "$cand" "$LIBCLANG_DIR/libclang.so"
            break
        fi
    done
fi
export LIBCLANG_PATH="$LIBCLANG_DIR"
echo "[run.sh] LIBCLANG_PATH=$LIBCLANG_PATH"

# Step 1: apply instrumentation
bash "$HARNESS_DIR/apply.sh"

# Step 2: build the test binary once. agave is large; allow up to 30 min for
# the cold build. Subsequent runs reuse incremental cache.
echo "[run.sh] Building solana-core test binary (this is slow on first run)"
(cd "$ARTIFACT_DIR" && \
    timeout 1800 cargo test \
        -p solana-core \
        --features dev-context-only-utils \
        --no-run \
        tla_trace_scenarios:: 2>&1 | tail -30)

# Locate the test binary. cargo places it under target/debug/deps with a
# hash suffix; pick the most recent solana_core-* binary.
TEST_BIN="$(ls -t "$ARTIFACT_DIR/target/debug/deps/" 2>/dev/null \
    | grep -E '^solana_core-[a-f0-9]+$' \
    | head -1)"
if [[ -z "${TEST_BIN:-}" ]]; then
    echo "[run.sh] Could not locate solana_core test binary in target/debug/deps/" >&2
    exit 1
fi
TEST_BIN_PATH="$ARTIFACT_DIR/target/debug/deps/$TEST_BIN"
echo "[run.sh] Test binary: $TEST_BIN_PATH"

# Step 3: run scenarios. Each scenario name maps 1:1 to a #[test] function in
# core/src/tla_trace_scenarios.rs.
SCENARIOS=(
    scenario_normal_vote_cycle
    scenario_crash_restart
    scenario_oc_accumulation
    scenario_gossip_latest_frozen
    scenario_adopt_on_chain_vote_state
    scenario_advance_root
    scenario_byzantine
)

for s in "${SCENARIOS[@]}"; do
    OUT="$TRACES_DIR/$s.ndjson"
    echo "[run.sh] Running $s -> $OUT"
    rm -f "$OUT"
    TLA_TRACE_FILE="$OUT" \
        timeout 300 \
        "$TEST_BIN_PATH" \
        --test-threads=1 \
        --nocapture \
        "tla_trace_scenarios::$s" \
        2>&1 | tail -10
done

# Step 4: report line counts
echo "[run.sh] Trace summary:"
for s in "${SCENARIOS[@]}"; do
    OUT="$TRACES_DIR/$s.ndjson"
    if [[ -f "$OUT" ]]; then
        LINES=$(wc -l < "$OUT")
        echo "  $s.ndjson — $LINES lines"
    else
        echo "  $s.ndjson — MISSING"
    fi
done

echo "[run.sh] Done"
