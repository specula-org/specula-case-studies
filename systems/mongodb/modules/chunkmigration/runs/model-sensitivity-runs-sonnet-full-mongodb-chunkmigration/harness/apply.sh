#!/usr/bin/env bash
# apply.sh — Copy tla_trace.h into the artifact source tree.
# Does NOT apply the full instrumentation.patch (which requires a real MongoDB build).
# Use this as the first step in a full build-based run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT="${SCRIPT_DIR}/../artifact/mongo-src"
SRC="${ARTIFACT}/src/mongo/db/s"

echo "Copying tla_trace.h into source tree …"
cp "${SCRIPT_DIR}/src/tla_trace.h" "${SRC}/tla_trace.h"

echo "Applying instrumentation patch …"
cd "${ARTIFACT}"
git apply "${SCRIPT_DIR}/patches/instrumentation.patch" --allow-empty || {
    echo "Patch apply failed — this is expected when running outside a full MongoDB build."
    echo "The patch is provided for reference; traces are collected via the Docker harness."
}
echo "apply.sh done."
