#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="${SCRIPT_DIR}/../artifact/libspdm"

echo "Reverting instrumentation patches..."

# Reset the artifact directory to the clean baseline
cd "${ARTIFACT_DIR}"
git checkout -- library/spdm_responder_lib/libspdm_rsp_event_ack.c
git checkout -- library/spdm_responder_lib/libspdm_rsp_subscribe_event_types_ack.c
git checkout -- library/spdm_requester_lib/libspdm_req_subscribe_event_types.c

echo "Instrumentation reverted successfully"
