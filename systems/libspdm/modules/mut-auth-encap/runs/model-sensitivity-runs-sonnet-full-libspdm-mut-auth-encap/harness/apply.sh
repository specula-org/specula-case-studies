#!/usr/bin/env bash
# apply.sh — copy instrumented sources and tla_trace.h into the artifact tree.
#
# Run once before CMake configure.  Safe to re-run; it overwrites in-place.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT="${SCRIPT_DIR}/../artifact/libspdm"
SRC="${SCRIPT_DIR}/src"
INSTR="${SRC}/instrumented"

if [[ ! -d "${ARTIFACT}" ]]; then
    echo "ERROR: artifact/libspdm not found at ${ARTIFACT}" >&2
    exit 1
fi

echo "[apply] Copying tla_trace.h ..."
cp "${SRC}/tla_trace.h" "${ARTIFACT}/include/tla_trace.h"

echo "[apply] Copying instrumented source files ..."
cp "${INSTR}/libspdm_rsp_encap_response.c" \
   "${ARTIFACT}/library/spdm_responder_lib/libspdm_rsp_encap_response.c"

cp "${INSTR}/libspdm_req_challenge.c" \
   "${ARTIFACT}/library/spdm_requester_lib/libspdm_req_challenge.c"

cp "${INSTR}/libspdm_rsp_encap_challenge.c" \
   "${ARTIFACT}/library/spdm_responder_lib/libspdm_rsp_encap_challenge.c"

echo "[apply] Copying harness CMakeLists and test source ..."
mkdir -p "${ARTIFACT}/unit_test/test_spdm_tla_trace"
cp "${SRC}/CMakeLists.txt"   "${ARTIFACT}/unit_test/test_spdm_tla_trace/CMakeLists.txt"
cp "${SRC}/tla_trace.h"      "${ARTIFACT}/unit_test/test_spdm_tla_trace/tla_trace.h"
cp "${SRC}/tla_encap_test.c" "${ARTIFACT}/unit_test/test_spdm_tla_trace/tla_encap_test.c"

echo "[apply] Done.  Now add the subdirectory to the libspdm CMakeLists if needed:"
echo "  add_subdirectory(unit_test/test_spdm_tla_trace)"
