#!/bin/bash
# Apply instrumentation patches to libspdm artifact
#
# This script prepares the artifact for trace collection by:
# 1. Ensuring the trace module is compiled
# 2. Applying any necessary patches to source files
# 3. Setting up the build environment

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="${SCRIPT_DIR}/../artifact/libspdm"
SRC_DIR="${SCRIPT_DIR}/src"

echo "[*] Applying instrumentation patches..."

# For now, we're using a standalone test harness approach.
# In a production scenario, this would patch the actual source files
# to emit trace events at instrumentation points.

# Create symbolic link or copy of trace module for easier access
if [ ! -d "${ARTIFACT_DIR}/harness_src" ]; then
    mkdir -p "${ARTIFACT_DIR}/harness_src"
fi

cp "${SRC_DIR}/libspdm_tla_trace.h" "${ARTIFACT_DIR}/harness_src/"
cp "${SRC_DIR}/libspdm_tla_trace.c" "${ARTIFACT_DIR}/harness_src/"

echo "[*] Trace module copied to artifact"

# Verify that key source files exist (these will be instrumented in Phase 3)
if [ ! -f "${ARTIFACT_DIR}/library/spdm_responder_lib/libspdm_rsp_encap_challenge.c" ]; then
    echo "[!] ERROR: Responder source file not found"
    exit 1
fi

if [ ! -f "${ARTIFACT_DIR}/library/spdm_requester_lib/libspdm_req_encap_challenge_auth.c" ]; then
    echo "[!] ERROR: Requester source file not found"
    exit 1
fi

echo "[*] Instrumentation sources verified"
echo "[+] Apply script completed successfully"
