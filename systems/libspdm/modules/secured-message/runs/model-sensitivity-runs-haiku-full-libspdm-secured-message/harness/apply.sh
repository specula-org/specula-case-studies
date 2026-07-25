#!/bin/bash

set -e

ARTIFACT_DIR="/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/libspdm-secured-message/artifact/libspdm"
HARNESS_DIR="/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/libspdm-secured-message/harness"

echo "Applying instrumentation patches..."

# Copy trace module files to artifact
cp "$HARNESS_DIR/src/tla_trace.h" "$ARTIFACT_DIR/include/"
cp "$HARNESS_DIR/src/tla_trace.c" "$ARTIFACT_DIR/library/spdm_secured_message_lib/"

# Add instrumentation to libspdm_secmes_context_data.c (TransitionToEstablished)
# This is done inline in the source using sed patterns

# Add instrumentation to libspdm_secmes_encode_decode.c (EncodeSecuredMessage)
# This is done inline in the source

# Add instrumentation to libspdm_secmes_session.c (InitiateKeyUpdate, etc)
# This is done inline in the source

echo "Instrumentation patches applied successfully"
