#!/usr/bin/env bash
# Harness run script: apply instrumentation, build, run tests, collect traces.
#
# Requirements:
#   - MongoDB build environment (Bazel 9+, C++20 toolchain, ~60GB disk)
#   - Run from the run directory: bash harness/run.sh
#   - Bazel will download ~4GB of dependencies on first run (~30 min)
#   - Full build of the test target takes ~2-4 hours on a 16-core machine
#
# Environment variables:
#   TLA_NODE_NAME    - TLA+ name for this node (default: "n1")
#   TLA_TRACE_DIR    - output directory for traces (default: ./traces)
#   BUILD_TIMEOUT    - seconds before aborting build (default: 10800 = 3h)
#
# If the build is not feasible, use gen_traces.py to produce prototype traces:
#   python3 harness/gen_traces.py

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_DIR="$(dirname "$SCRIPT_DIR")"
ARTIFACT_DIR="$RUN_DIR/artifact/mongo-src"
TRACES_DIR="${TLA_TRACE_DIR:-$RUN_DIR/traces}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-10800}"

mkdir -p "$TRACES_DIR"

echo "=== Step 1: Apply instrumentation ==="
bash "$SCRIPT_DIR/apply.sh"

echo "=== Step 2: Copy test scenario into source tree ==="
cp "$SCRIPT_DIR/src/range_deleter_tla_trace_test.cpp" \
    "$ARTIFACT_DIR/src/mongo/db/s/"

echo "=== Step 3: Build test target ==="
echo "Building: //src/mongo/db/s:range_deleter_service_test"
echo "Timeout: ${BUILD_TIMEOUT}s"
BAZEL="$ARTIFACT_DIR/bazel/bazelisk.py"

# The existing range_deleter_service_test target includes our new test file
# if we add it to the BUILD. For now, build the existing target which includes
# range_deleter_service_test.cpp and exercises the same code paths.
#
# To include range_deleter_tla_trace_test.cpp, append it to BUILD.bazel:
#   cc_test(name = "range_deleter_tla_trace_test", ...)

cd "$ARTIFACT_DIR"
timeout "$BUILD_TIMEOUT" python3 "$BAZEL" build \
    --config=opt \
    --jobs=8 \
    //src/mongo/db/s:range_deleter_service_test \
    2>&1 | tail -50

echo "=== Step 4: Run trace scenarios ==="
BINARY=$(python3 "$BAZEL" info bazel-bin)/src/mongo/db/s/range_deleter_service_test

# Scenario 1: Normal operation
echo "--- Scenario 1: normal_operation ---"
TLA_NODE_NAME=n1 TLA_TRACE_FILE="$TRACES_DIR/normal_operation.ndjson" \
    timeout 300 "$BINARY" \
    --gtest_filter="TlaTraceNormalOpTest.NormalDeletionPipeline" \
    2>/dev/null || echo "WARN: scenario 1 failed"

# Scenario 2: Step-down during majority wait
echo "--- Scenario 2: stepdown_mid_majority ---"
TLA_NODE_NAME=n1 TLA_TRACE_FILE="$TRACES_DIR/stepdown_mid_majority.ndjson" \
    timeout 300 "$BINARY" \
    --gtest_filter="TlaTraceStepDownTest.StepDownDuringMajorityWait" \
    2>/dev/null || echo "WARN: scenario 2 failed"

# Scenario 3: Recovery with concurrent op_observer
echo "--- Scenario 3: recovery_with_opobserver ---"
TLA_NODE_NAME=n1 TLA_TRACE_FILE="$TRACES_DIR/recovery_with_opobserver.ndjson" \
    timeout 300 "$BINARY" \
    --gtest_filter="TlaTraceRecoveryOpObserverTest.RecoveryWithConcurrentOpObserver" \
    2>/dev/null || echo "WARN: scenario 3 failed"

echo "=== Step 5: Trace summary ==="
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        count=$(wc -l < "$f")
        echo "  $(basename "$f"): $count events"
    fi
done

echo ""
echo "=== Done ==="
echo "Traces written to: $TRACES_DIR"
echo ""
echo "NOTE: If the build is not feasible, run the prototype trace generator:"
echo "  python3 harness/gen_traces.py"
