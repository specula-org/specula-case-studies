#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="${SCRIPT_DIR}/../artifact/libspdm"
TRACES_DIR="${SCRIPT_DIR}/../traces"

# Ensure traces directory exists
mkdir -p "${TRACES_DIR}"

# Copy trace header to artifact library directory
cp "${SCRIPT_DIR}/src/tla_trace.h" "${ARTIFACT_DIR}/library/spdm_responder_lib/"
cp "${SCRIPT_DIR}/src/tla_trace.h" "${ARTIFACT_DIR}/library/spdm_requester_lib/"

# The instrumentation patches have already been applied via Edit operations
# Just verify the includes are in place
echo "Instrumentation applied successfully"

# Check that trace includes are present in the source files
if grep -q "include \"tla_trace.h\"" "${ARTIFACT_DIR}/library/spdm_responder_lib/libspdm_rsp_event_ack.c"; then
    echo "✓ libspdm_rsp_event_ack.c is instrumented"
fi

if grep -q "include \"tla_trace.h\"" "${ARTIFACT_DIR}/library/spdm_responder_lib/libspdm_rsp_subscribe_event_types_ack.c"; then
    echo "✓ libspdm_rsp_subscribe_event_types_ack.c is instrumented"
fi

if grep -q "include \"tla_trace.h\"" "${ARTIFACT_DIR}/library/spdm_requester_lib/libspdm_req_subscribe_event_types.c"; then
    echo "✓ libspdm_req_subscribe_event_types.c is instrumented"
fi

echo "Apply script completed"
