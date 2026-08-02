#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACE_DIR="$OUTPUT_DIR/traces"
SOURCE_DIR="${SREGYM_SOURCE_DIR:-/users/Pial/targets/sregym-codex-gpt56-sol-max-20260727}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

mkdir -p "$TRACE_DIR"
bash "$SCRIPT_DIR/apply.sh"

echo "Compiling instrumented Python sources..."
timeout 60s "$PYTHON_BIN" -m py_compile \
    "$SOURCE_DIR/sregym/tla_trace.py" \
    "$SOURCE_DIR/sregym/conductor/conductor.py" \
    "$SOURCE_DIR/sregym/conductor/conductor_api.py" \
    "$SOURCE_DIR/sregym/service/cluster_state.py" \
    "$SOURCE_DIR/sregym/generators/noise/manager.py" \
    "$SOURCE_DIR/sregym/conductor/problems/khaos_faults.py" \
    "$SOURCE_DIR/main.py" \
    "$SOURCE_DIR/tests/specula/test_trace_scenarios.py"

scenario_names=(
    normal_diagnosis
    duplicate_transport
    timeout_cleanup
    crash_restart
)
scenario_tests=(
    TraceScenarioTests.test_normal_diagnosis
    TraceScenarioTests.test_duplicate_transport
    TraceScenarioTests.test_timeout_cleanup_and_late_submission
    TraceScenarioTests.test_crash_restart_loads_baseline
)

trace_files=()
for index in "${!scenario_names[@]}"; do
    scenario="${scenario_names[$index]}"
    test_name="${scenario_tests[$index]}"
    trace_file="$TRACE_DIR/$scenario.ndjson"
    rm -f "$trace_file"
    echo "Running trace scenario: $scenario"
    (
        cd "$SOURCE_DIR"
        unset SREGYM_TRACE_FILE SREGYM_TRACE_REQUEST_IDS
        SPECULA_TRACE_FILE="$trace_file" \
        PYTHONHASHSEED=0 \
        timeout 90s "$PYTHON_BIN" tests/specula/test_trace_scenarios.py "$test_name"
    )
    trace_files+=("$trace_file")
done

echo "Checking NDJSON schema, timestamps, and event coverage..."
timeout 60s "$PYTHON_BIN" "$SCRIPT_DIR/src/check_traces.py" "${trace_files[@]}"

echo "Trace line counts:"
wc -l "${trace_files[@]}"
