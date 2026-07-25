#!/bin/bash
set -e

# Apply instrumentation patches to the artifact
echo "Applying trace instrumentation to libspdm..."

# Copy patched files from artifact_patched to artifact
if [ -d "artifact_patched" ]; then
    cp artifact_patched/library/spdm_requester_lib/libspdm_req_psk_exchange.c \
       artifact/libspdm/library/spdm_requester_lib/libspdm_req_psk_exchange.c

    cp artifact_patched/library/spdm_responder_lib/libspdm_rsp_psk_exchange_rsp.c \
       artifact/libspdm/library/spdm_responder_lib/libspdm_rsp_psk_exchange_rsp.c

    echo "Instrumentation applied successfully"
else
    echo "Error: artifact_patched directory not found"
    exit 1
fi
