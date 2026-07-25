#!/bin/bash
# End-to-end harness: applies instrumentation, builds, runs scenarios, and
# collects NDJSON traces.
#
# Usage:  cd .specula-output && bash harness/run.sh
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
# .specula-output/ holds harness/, traces/, spec/; artifact/ is one level up.
SPECULA_OUTPUT_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
ROOT_DIR="$(cd "$SPECULA_OUTPUT_DIR/.." && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT_DIR/artifact/cometbft}"
TRACE_DIR="${TRACE_DIR:-$SPECULA_OUTPUT_DIR/traces}"

mkdir -p "$TRACE_DIR"

export GO=${GO:-/usr/local/go/bin/go}
export PATH=/usr/local/go/bin:$HOME/go/bin:/usr/bin:$PATH

# ---- step 1: apply instrumentation -----------------------------------------
bash "$HARNESS_DIR/apply.sh"

# ---- step 2: run scenarios -------------------------------------------------
cd "$ARTIFACT_DIR"

# We invoke `go test` once per scenario so each gets its own trace file. Each
# binary opens the file in O_TRUNC mode at package init time, so concurrent
# invocations on the same file would clobber each other.

run_scenario() {
    local trace_file=$1
    local package=$2
    local run_pattern=$3
    local nid=${4:-s1}
    local timeout_s=${5:-120}
    echo "==> Scenario: $package :: $run_pattern -> $(basename "$trace_file")"
    rm -f "$trace_file"
    TLA_TRACE_FILE="$trace_file" \
    TLA_TRACE_LOCAL_NID="$nid" \
    timeout "${timeout_s}s" "$GO" test \
        -count=1 -timeout "$((timeout_s - 10))s" \
        -run "$run_pattern" "$package" >/dev/null 2>&1 \
        && echo "    PASS  ($(wc -l <"$trace_file") events)" \
        || echo "    FAIL  ($(wc -l <"$trace_file" 2>/dev/null || echo 0) events captured)"
}

run_scenario "$TRACE_DIR/blocksync_basic.ndjson"      ./blocksync/ "TestScenarioBlockPoolBasic$"
run_scenario "$TRACE_DIR/blocksync_ban.ndjson"        ./blocksync/ "TestScenarioBlockPoolBan$"
run_scenario "$TRACE_DIR/consensus_full_round.ndjson" ./consensus/ "TestStateFullRound1$"
run_scenario "$TRACE_DIR/consensus_lock_relock.ndjson" ./consensus/ "TestStateLockPOLRelock$" s1 180
run_scenario "$TRACE_DIR/types_verify_commit.ndjson"  ./types/      "TestValidatorSet_VerifyCommit(_All|LightTrusting)$"
run_scenario "$TRACE_DIR/types_verify_trusting.ndjson" ./types/     "TestValidatorSet_VerifyCommitLightTrusting$"

# ---- step 3: post-process to remap hex IDs / hashes ------------------------
echo ""
echo "==> Post-processing traces (preprocess_trace.py)"
for raw in "$TRACE_DIR"/*.ndjson; do
    case "$raw" in
        *.mapped.ndjson) continue ;;
    esac
    mapped="${raw%.ndjson}.mapped.ndjson"
    if [ -s "$raw" ]; then
        python3 "$HARNESS_DIR/preprocess_trace.py" "$raw" "$mapped" 2>&1 | sed 's/^/    /'
    fi
done

# ---- summary ---------------------------------------------------------------
echo ""
echo "==> Trace files in $TRACE_DIR"
ls -la "$TRACE_DIR"/*.ndjson 2>/dev/null || echo "    (none)"
