#!/usr/bin/env bash
# apply.sh — copy harness source into artifact and wire up CMake
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT="${SCRIPT_DIR}/../artifact/libspdm"
HARNESS_SRC="${SCRIPT_DIR}/src"

echo "[apply] Copying trace library into artifact unit test tree..."
mkdir -p "${ARTIFACT}/unit_test/test_tla_trace"
cp "${HARNESS_SRC}/CMakeLists.txt"    "${ARTIFACT}/unit_test/test_tla_trace/"
cp "${HARNESS_SRC}/tla_trace.h"       "${ARTIFACT}/unit_test/test_tla_trace/"
cp "${HARNESS_SRC}/tla_trace.c"       "${ARTIFACT}/unit_test/test_tla_trace/"
cp "${HARNESS_SRC}/tla_scenarios.c"   "${ARTIFACT}/unit_test/test_tla_trace/"
cp "${HARNESS_SRC}/tla_trace_main.c"  "${ARTIFACT}/unit_test/test_tla_trace/"
cp "${HARNESS_SRC}/CMakeLists.txt"    "${ARTIFACT}/unit_test/test_tla_trace/"

echo "[apply] Wiring test_tla_trace into unit_test/CMakeLists.txt..."
UNIT_CMAKE="${ARTIFACT}/unit_test/CMakeLists.txt"
if ! grep -q "test_tla_trace" "${UNIT_CMAKE}"; then
    echo 'add_subdirectory(test_tla_trace)' >> "${UNIT_CMAKE}"
fi

echo "[apply] Enabling TLA_TRACE_ENABLED globally in top-level CMakeLists.txt..."
TOP_CMAKE="${ARTIFACT}/CMakeLists.txt"
if ! grep -q "TLA_TRACE_ENABLED" "${TOP_CMAKE}"; then
    # Insert global define before the ENABLE_CODEQL block that adds library subdirs
    sed -i 's/^if(ENABLE_CODEQL STREQUAL "ON")/# TLA+ trace instrumentation: enable globally so library code compiles in trace calls.\nif(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}\/unit_test\/test_tla_trace\/tla_trace.h")\n    add_compile_definitions(TLA_TRACE_ENABLED)\n    include_directories("${CMAKE_CURRENT_SOURCE_DIR}\/unit_test\/test_tla_trace")\nendif()\n\nif(ENABLE_CODEQL STREQUAL "ON")/' "${TOP_CMAKE}"
fi

# Source instrumentation patches are already applied directly to the artifact
# (libspdm_rsp_key_exchange.c, libspdm_rsp_receive_send.c, etc.)
# If you need to re-apply from a clean tree, run:
#   git -C "${ARTIFACT}" checkout -- . && bash apply.sh
# The patches are stored in patches/instrumentation.patch

echo "[apply] Done."
