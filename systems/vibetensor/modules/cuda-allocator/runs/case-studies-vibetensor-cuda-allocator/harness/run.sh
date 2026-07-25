#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# run.sh — one-command reproduction of the VibeTensor CUDA allocator trace.
#
#   * Applies the instrumentation patch (via apply.sh).
#   * Compiles the real allocator source against the CUDA runtime stubs in
#     stubs/ and the trace module in src/ — no NVIDIA toolkit or GPU is
#     required; the stub cudaMalloc uses host malloc and events are no-ops.
#   * Links three test scenarios, runs each, and collects per-thread NDJSON
#     traces into ../traces/<scenario>-thread-*.ndjson.
#   * Runs the preprocessor to merge per-thread files into a single JSON per
#     scenario, which is what Trace.tla consumes.
#   * Prints per-scenario event counts.
#
# The script is idempotent: re-running overwrites previous traces.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$(cd "${HARNESS_DIR}/.." && pwd)"
TRACES_DIR="${OUTPUT_DIR}/traces"
ARTIFACT="${HARNESS_DIR}/../../../vibetensor/artifact/vibetensor"

mkdir -p "${TRACES_DIR}"
mkdir -p "${HARNESS_DIR}/build"

# --- Step 1: apply instrumentation ------------------------------------------
bash "${HARNESS_DIR}/apply.sh"

# --- Step 2: compile allocator + deps against stubs -------------------------
BUILD="${HARNESS_DIR}/build"
STUBS="${HARNESS_DIR}/stubs"
SRC="${HARNESS_DIR}/src"

CXX="${CXX:-g++}"
CXXFLAGS="-std=c++17 -O0 -g -pthread \
    -DVBT_WITH_CUDA=1 -DVBT_TRACE=1 \
    -include algorithm \
    -I${STUBS} -I${SRC} -I${ARTIFACT}/include"

echo "[run.sh] building object files..."

# Real allocator source (patched in place by apply.sh).
${CXX} ${CXXFLAGS} -c "${ARTIFACT}/src/vbt/cuda/allocator.cc"        -o "${BUILD}/allocator.o"
${CXX} ${CXXFLAGS} -c "${ARTIFACT}/src/vbt/cuda/stream.cc"           -o "${BUILD}/stream.o"
${CXX} ${CXXFLAGS} -c "${ARTIFACT}/src/vbt/cuda/event.cc"            -o "${BUILD}/event.o"
${CXX} ${CXXFLAGS} -c "${ARTIFACT}/src/vbt/cuda/event_pool.cc"       -o "${BUILD}/event_pool.o"
${CXX} ${CXXFLAGS} -c "${ARTIFACT}/src/vbt/cuda/guard.cc"            -o "${BUILD}/guard.o"
${CXX} ${CXXFLAGS} -c "${ARTIFACT}/src/vbt/cuda/device_count.cc"     -o "${BUILD}/device_count.o"

# Stubs.
${CXX} ${CXXFLAGS} -c "${STUBS}/cuda_stub.cc"              -o "${BUILD}/cuda_stub.o"
${CXX} ${CXXFLAGS} -c "${STUBS}/graphs_stub.cc"            -o "${BUILD}/graphs_stub.o"
${CXX} ${CXXFLAGS} -c "${STUBS}/allocator_async_stub.cc"   -o "${BUILD}/allocator_async_stub.o"

# Trace module.
${CXX} ${CXXFLAGS} -c "${SRC}/vbt_trace.cc"                -o "${BUILD}/vbt_trace.o"

LIBOBJS=(
    "${BUILD}/allocator.o"
    "${BUILD}/stream.o"
    "${BUILD}/event.o"
    "${BUILD}/event_pool.o"
    "${BUILD}/guard.o"
    "${BUILD}/device_count.o"
    "${BUILD}/cuda_stub.o"
    "${BUILD}/graphs_stub.o"
    "${BUILD}/allocator_async_stub.o"
    "${BUILD}/vbt_trace.o"
)

SCENARIOS=(
    "basic_alloc_free"
    "concurrent_alloc"
    "deferred_capture"
)

for sc in "${SCENARIOS[@]}"; do
    echo "[run.sh] building scenario: ${sc}"
    ${CXX} ${CXXFLAGS} "${SRC}/scenario_${sc}.cc" "${LIBOBJS[@]}" -o "${BUILD}/scenario_${sc}"
done

# --- Step 3: run each scenario, collect per-thread traces -------------------
for sc in "${SCENARIOS[@]}"; do
    echo "[run.sh] running scenario: ${sc}"
    # Remove any stale files for this scenario.
    rm -f "${TRACES_DIR}/${sc}-thread-"*.ndjson "${TRACES_DIR}/${sc}.json"
    "${BUILD}/scenario_${sc}" "${TRACES_DIR}/${sc}"
done

# --- Step 4: preprocess per-thread traces into merged JSON ------------------
echo "[run.sh] preprocessing traces..."
python3 "${HARNESS_DIR}/preprocess_trace.py" "${TRACES_DIR}"

# --- Step 5: report coverage ------------------------------------------------
echo "[run.sh] trace summary:"
for sc in "${SCENARIOS[@]}"; do
    thread_files=$(ls "${TRACES_DIR}/${sc}-thread-"*.ndjson 2>/dev/null | wc -l | tr -d ' ')
    total_lines=0
    for f in "${TRACES_DIR}/${sc}-thread-"*.ndjson; do
        [[ -f "$f" ]] || continue
        lines=$(wc -l < "$f")
        total_lines=$((total_lines + lines))
    done
    echo "    ${sc}: ${thread_files} thread files, ${total_lines} total events"
done

echo "[run.sh] done.  Traces are in ${TRACES_DIR}/"
