#!/bin/bash
# apply.sh — Apply instrumentation to sonic-linkmgrd artifact
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$SCRIPT_DIR/../artifact/sonic-linkmgrd"
STUBS_DIR="$SCRIPT_DIR/stubs"

echo "[apply] Restoring artifact to clean state..."
git -C "$ARTIFACT_DIR" checkout -- .

echo "[apply] Copying trace module..."
cp "$SCRIPT_DIR/src/tla_trace.h" "$ARTIFACT_DIR/src/"

echo "[apply] Applying instrumentation patch..."
git -C "$ARTIFACT_DIR" apply "$SCRIPT_DIR/patches/instrumentation.patch"

echo "[apply] Adding -DLINKMGRD_TRACE and stub includes to build flags..."
STUBS_INCLUDE="-I\"$STUBS_DIR\""

# Patch all subdir.mk compile rules to add trace flag and stubs include path
for mkfile in "$ARTIFACT_DIR"/src/link_manager/subdir.mk \
              "$ARTIFACT_DIR"/src/link_prober/subdir.mk \
              "$ARTIFACT_DIR"/src/subdir.mk \
              "$ARTIFACT_DIR"/src/mux_state/subdir.mk \
              "$ARTIFACT_DIR"/src/link_state/subdir.mk \
              "$ARTIFACT_DIR"/src/common/subdir.mk \
              "$ARTIFACT_DIR"/test/subdir.mk; do
    if [ -f "$mkfile" ]; then
        sed -i "s|\$(CPP_FLAGS)|\$(CPP_FLAGS) -DLINKMGRD_TRACE|g" "$mkfile"
    fi
done

# Add stubs include path to the INCLUDES in the Makefile
sed -i "s|override INCLUDES +=|override INCLUDES += -I\"$STUBS_DIR\"|" "$ARTIFACT_DIR/Makefile"

echo "[apply] Instrumentation applied successfully."
