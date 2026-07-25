#!/usr/bin/env bash
# apply.sh — Install instrumented sources and trace harness into artifact/libspdm.
#
# Run from the libspdm-measurements/ directory:
#   bash harness/apply.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT="$SCRIPT_DIR/../artifact/libspdm"
HARNESS_SRC="$SCRIPT_DIR/src"
PATCHES_SRC="$SCRIPT_DIR/patches/src"

echo "[apply] Copying instrumented source files..."
cp "$PATCHES_SRC/libspdm_rsp_algorithms.c"           "$ARTIFACT/library/spdm_responder_lib/"
cp "$PATCHES_SRC/libspdm_rsp_measurements.c"          "$ARTIFACT/library/spdm_responder_lib/"
cp "$PATCHES_SRC/libspdm_req_get_measurements.c"      "$ARTIFACT/library/spdm_requester_lib/"
cp "$PATCHES_SRC/libspdm_rsp_handle_response_state.c" "$ARTIFACT/library/spdm_responder_lib/"
cp "$PATCHES_SRC/libspdm_com_context_data.c"          "$ARTIFACT/library/spdm_common_lib/"

echo "[apply] Installing tla_trace module to artifact include/..."
cp "$HARNESS_SRC/tla_trace.h" "$ARTIFACT/include/"

echo "[apply] Creating test_tla_trace unit test directory..."
TRACE_DIR="$ARTIFACT/unit_test/test_tla_trace"
mkdir -p "$TRACE_DIR"
cp "$HARNESS_SRC/spdm_trace_test.c" "$TRACE_DIR/"
cp "$HARNESS_SRC/tla_trace.c"       "$TRACE_DIR/"
cp "$HARNESS_SRC/support.c"         "$TRACE_DIR/"

cat > "$TRACE_DIR/CMakeLists.txt" << 'ENDCMAKE'
cmake_minimum_required(VERSION 3.5)

add_executable(spdm_trace_test)

target_include_directories(spdm_trace_test
    PRIVATE
        ${LIBSPDM_DIR}/include
        ${LIBSPDM_DIR}/unit_test/include
        ${LIBSPDM_DIR}/os_stub/spdm_device_secret_lib_${DEVICE}
        ${LIBSPDM_DIR}/unit_test/spdm_unit_test_common
        ${LIBSPDM_DIR}/os_stub
)

target_sources(spdm_trace_test
    PRIVATE
        spdm_trace_test.c
        tla_trace.c
        support.c
)

target_compile_definitions(spdm_trace_test
    PRIVATE
        LIBSPDM_RECORD_TRANSCRIPT_DATA_SUPPORT=1
)

target_link_libraries(spdm_trace_test
    PRIVATE
        memlib
        debuglib
        spdm_responder_lib
        spdm_requester_lib
        spdm_common_lib
        ${CRYPTO_LIB_PATHS}
        rnglib
        cryptlib_${CRYPTO}
        malloclib
        spdm_crypt_lib
        spdm_crypt_ext_lib
        spdm_secured_message_lib
        spdm_device_secret_lib_${DEVICE}
        spdm_transport_test_lib
        platform_lib
        pthread
)
ENDCMAKE

echo "[apply] Wiring test_tla_trace into top-level CMakeLists..."
TOP_CMAKE="$ARTIFACT/CMakeLists.txt"
if ! grep -q "test_tla_trace" "$TOP_CMAKE"; then
    # Append our subdirectory just after test_spdm_sample (inside the LIBFUZZER guard)
    sed -i 's|add_subdirectory(unit_test/test_spdm_sample)|add_subdirectory(unit_test/test_spdm_sample)\n            add_subdirectory(unit_test/test_tla_trace)|' "$TOP_CMAKE"
    echo "[apply] Added add_subdirectory(unit_test/test_tla_trace)"
else
    echo "[apply] test_tla_trace already in CMakeLists"
fi

echo "[apply] Done."
