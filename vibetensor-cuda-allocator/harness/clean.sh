#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Restore the artifact allocator.cc from the backup taken by apply.sh.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_SRC="${HARNESS_DIR}/../../../vibetensor/artifact/vibetensor/src/vbt/cuda"

if [[ -f "${ARTIFACT_SRC}/allocator.cc.orig" ]]; then
    mv "${ARTIFACT_SRC}/allocator.cc.orig" "${ARTIFACT_SRC}/allocator.cc"
    echo "clean.sh: restored original allocator.cc"
else
    echo "clean.sh: no backup found at ${ARTIFACT_SRC}/allocator.cc.orig" >&2
fi

# Remove harness build outputs.
rm -rf "${HARNESS_DIR}/build"
echo "clean.sh: harness build dir removed"
