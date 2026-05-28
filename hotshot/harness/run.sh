#!/usr/bin/env bash
# End-to-end: apply instrumentation, build, run tests, collect traces.
#
# Usage:
#   cd .specula-output && bash harness/run.sh
#
# Set FAST_BUILD=1 to skip cargo test compilation if you only want to verify
# the patches apply cleanly. Set BUILD_TIMEOUT to override the cargo timeout
# (default 1800s / 30min).

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
SPECULA_OUT="$(cd "${HARNESS_DIR}/.." && pwd)"
ARTIFACT_DIR="$(cd "${HARNESS_DIR}/../../artifact/espresso-network" && pwd)"
TRACES_DIR="${SPECULA_OUT}/traces"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-1800}"
TEST_TIMEOUT="${TEST_TIMEOUT:-600}"

echo "=== HotShot trace harness ==="
echo "HARNESS_DIR  = ${HARNESS_DIR}"
echo "SPECULA_OUT  = ${SPECULA_OUT}"
echo "ARTIFACT_DIR = ${ARTIFACT_DIR}"
echo "TRACES_DIR   = ${TRACES_DIR}"

mkdir -p "${TRACES_DIR}"

# Step 1: Apply patches
echo ""
echo "--- Step 1: apply instrumentation ---"
bash "${HARNESS_DIR}/apply.sh"

# Step 2: Build the task-impls crate
echo ""
echo "--- Step 2: cargo build -p hotshot-task-impls ---"
cd "${ARTIFACT_DIR}"
if ! timeout "${BUILD_TIMEOUT}" cargo build -p hotshot-task-impls 2>&1 | tail -40; then
    echo "ERROR: hotshot-task-impls failed to build (or timed out)."
    echo "Try: cd ${ARTIFACT_DIR} && cargo build -p hotshot-task-impls 2>&1 | head -200"
    exit 1
fi

if [[ "${FAST_BUILD:-0}" == "1" ]]; then
    echo "FAST_BUILD=1, skipping tests."
    exit 0
fi

# Step 3: Build & run the trace tests
echo ""
echo "--- Step 3: cargo test -p hotshot-testing trace_harness ---"
# Truncate any existing trace files
rm -f "${TRACES_DIR}"/*.ndjson

# Run all three tla_trace tests. Each test writes to its own NDJSON file
# under TLA_TRACE_DIR.
TLA_TRACE_DIR="${TRACES_DIR}"
export TLA_TRACE_DIR
echo "TLA_TRACE_DIR=${TLA_TRACE_DIR}"

if ! timeout "${TEST_TIMEOUT}" cargo test \
        -p hotshot-testing \
        --test tests_1 \
        -- \
        --nocapture \
        --test-threads=1 \
        tla_trace 2>&1 | tail -60; then
    echo "WARNING: cargo test exited non-zero. Traces may still have been produced."
fi

# Step 4: Summarize traces
echo ""
echo "--- Step 4: trace summary ---"
shopt -s nullglob
trace_files=("${TRACES_DIR}"/*.ndjson)
if [[ ${#trace_files[@]} -eq 0 ]]; then
    echo "ERROR: No trace files produced in ${TRACES_DIR}."
    echo "Verify the test bin actually ran. Check TLA_TRACE_FILE/TLA_TRACE_DIR."
    exit 2
fi
for f in "${trace_files[@]}"; do
    n=$(wc -l < "$f" | tr -d ' ')
    echo "  $(basename "$f"): ${n} lines"
done

# Step 5: Format check
echo ""
echo "--- Step 5: format check ---"
for f in "${trace_files[@]}"; do
    if [[ -s "$f" ]]; then
        if head -n 1 "$f" | python3 -c "import sys, json; json.loads(sys.stdin.read())" 2>/dev/null; then
            echo "  OK: $(basename "$f") first line is valid JSON"
        else
            echo "  WARN: $(basename "$f") first line is not valid JSON"
        fi
    fi
done

echo ""
echo "Done. Traces in ${TRACES_DIR}"
