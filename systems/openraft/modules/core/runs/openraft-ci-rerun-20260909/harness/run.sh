#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$(dirname "$HARNESS_DIR")"
ARTIFACT_DIR="$(dirname "$OUTPUT_DIR")"
SOURCE_DIR="${SPECULA_SOURCE_DIR:-$ARTIFACT_DIR/source}"
TRACE_DIR="$OUTPUT_DIR/traces"
SPEC_DIR="$OUTPUT_DIR/spec"
SPECULA_ROOT="${SPECULA_ROOT:-/home/ubuntu/specula-ci-gpt55-rerun-20260909-Qgo42gGo/Specula}"
TLA_JAR="$SPECULA_ROOT/lib/tla2tools.jar"
COMMUNITY_JAR="$SPECULA_ROOT/lib/CommunityModules-deps.jar"
VALIDATION_DIR="$HARNESS_DIR/validation"

bash "$HARNESS_DIR/apply.sh"
mkdir -p "$TRACE_DIR" "$VALIDATION_DIR"

echo "building instrumented OpenRaft test library"
(
    cd "$SOURCE_DIR"
    timeout 900 cargo test -p openraft --features specula-trace --lib --no-run
)

run_scenario() {
    local trace_name="$1"
    local test_name="$2"
    local trace_file="$TRACE_DIR/$trace_name.ndjson"

    echo "running $trace_name"
    (
        cd "$SOURCE_DIR"
        timeout 600 env \
            SPECULA_TRACE_FILE="$trace_file" \
            RUST_TEST_THREADS=1 \
            cargo test -p openraft --features specula-trace --lib "$test_name" -- \
                --ignored --exact --nocapture --test-threads=1
    )
}

run_scenario \
    election_remote_grants \
    engine::specula_trace_scenarios::trace_election_and_remote_grants
run_scenario \
    competing_candidates \
    engine::specula_trace_scenarios::trace_competing_candidates_and_ordered_vote
run_scenario \
    snapshot_trigger \
    engine::specula_trace_scenarios::trace_snapshot_trigger_deduplicates_pending_build
run_scenario \
    initialize_then_election \
    engine::specula_trace_scenarios::trace_initialize_then_manual_election

traces=(
    "$TRACE_DIR/election_remote_grants.ndjson"
    "$TRACE_DIR/competing_candidates.ndjson"
    "$TRACE_DIR/snapshot_trigger.ndjson"
    "$TRACE_DIR/initialize_then_election.ndjson"
)

python3 "$HARNESS_DIR/verify_traces.py" "${traces[@]}"

if [[ ! -f "$TLA_JAR" || ! -f "$COMMUNITY_JAR" ]]; then
    echo "error: TLC jars not found under SPECULA_ROOT=$SPECULA_ROOT" >&2
    exit 1
fi

for trace_file in "${traces[@]}"; do
    scenario="$(basename "$trace_file" .ndjson)"
    log_file="$VALIDATION_DIR/$scenario.log"
    tlc_state_dir="$(mktemp -d "/tmp/openraft-$scenario-tlc.XXXXXX")"

    echo "validating $scenario with Trace.tla"
    (
        cd "$SPEC_DIR"
        timeout 600 env JSON="../traces/$scenario.ndjson" \
            java -XX:+UseParallelGC \
            -cp "$TLA_JAR:$COMMUNITY_JAR" \
            tlc2.TLC -config Trace.cfg -workers 1 \
            -metadir "$tlc_state_dir" Trace.tla
    ) 2>&1 | tee "$log_file"
    grep -q "Model checking completed. No error has been found." "$log_file"
    find "$tlc_state_dir" -xdev -depth -delete
done

echo "trace line counts"
wc -l "${traces[@]}"
echo "all OpenRaft trace scenarios and TLC replays passed"
