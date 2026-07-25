#!/usr/bin/env bash
# apply.sh — place harness files into the artifact/libspdm tree.
# Safe to run multiple times; files are simply overwritten.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIBSPDM="${SCRIPT_DIR}/../artifact/libspdm"

# 1. Header and trace implementation
cp "$SCRIPT_DIR/src/tla_trace.h" "$LIBSPDM/include/tla_trace.h"

# 2. Test directory
mkdir -p "$LIBSPDM/unit_test/test_spdm_tla_trace"
cp "$SCRIPT_DIR/src/tla_trace.c"    "$LIBSPDM/unit_test/test_spdm_tla_trace/"
cp "$SCRIPT_DIR/src/trace_test.c"   "$LIBSPDM/unit_test/test_spdm_tla_trace/"
cp "$SCRIPT_DIR/src/CMakeLists.txt" "$LIBSPDM/unit_test/test_spdm_tla_trace/"

# 3. Instrumented library files
cp "$SCRIPT_DIR/instrumented/library/spdm_requester_lib/libspdm_req_key_update.c"  \
   "$LIBSPDM/library/spdm_requester_lib/"
cp "$SCRIPT_DIR/instrumented/library/spdm_requester_lib/libspdm_req_end_session.c" \
   "$LIBSPDM/library/spdm_requester_lib/"
cp "$SCRIPT_DIR/instrumented/library/spdm_requester_lib/libspdm_req_heartbeat.c"   \
   "$LIBSPDM/library/spdm_requester_lib/"
cp "$SCRIPT_DIR/instrumented/library/spdm_responder_lib/libspdm_rsp_key_update_ack.c"  \
   "$LIBSPDM/library/spdm_responder_lib/"
cp "$SCRIPT_DIR/instrumented/library/spdm_responder_lib/libspdm_rsp_end_session_ack.c" \
   "$LIBSPDM/library/spdm_responder_lib/"
cp "$SCRIPT_DIR/instrumented/library/spdm_responder_lib/libspdm_rsp_heartbeat.c"       \
   "$LIBSPDM/library/spdm_responder_lib/"
cp "$SCRIPT_DIR/instrumented/library/spdm_responder_lib/libspdm_rsp_receive_send.c"    \
   "$LIBSPDM/library/spdm_responder_lib/"

# 4. Ensure CMakeLists.txt has the add_subdirectory line
if ! grep -q "test_spdm_tla_trace" "$LIBSPDM/CMakeLists.txt"; then
    sed -i 's|add_subdirectory(unit_test/test_spdm_sample)|add_subdirectory(unit_test/test_spdm_sample)\n            add_subdirectory(unit_test/test_spdm_tla_trace)|' \
        "$LIBSPDM/CMakeLists.txt"
fi

echo "apply.sh: done"
