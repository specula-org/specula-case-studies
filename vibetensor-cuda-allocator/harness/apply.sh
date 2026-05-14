#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# apply.sh — copy the instrumented allocator.cc into the artifact tree.
#
# Rationale: the upstream allocator.cc is left untouched; `allocator_patched.cc`
# (which lives next to this script) is a byte-for-byte copy of allocator.cc
# with VBT_TRACE-gated emit calls inserted at the trace sites listed in
# INSTRUMENTATION.md.  When VBT_TRACE is NOT defined the macros expand to
# no-ops, so the patched file is a drop-in replacement.
#
# The harness never rebuilds the artifact's CMake project.  Instead, run.sh
# compiles the patched allocator.cc + a handful of its dependencies + the
# trace module against the CUDA runtime stubs in `stubs/`, producing a
# self-contained executable that exercises the real allocator code paths.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_SRC="${HARNESS_DIR}/../../../vibetensor/artifact/vibetensor/src/vbt/cuda"

if [[ ! -f "${ARTIFACT_SRC}/allocator.cc" ]]; then
    echo "error: artifact allocator.cc not found at ${ARTIFACT_SRC}" >&2
    exit 1
fi

# Back up the original on first apply.
if [[ ! -f "${ARTIFACT_SRC}/allocator.cc.orig" ]]; then
    cp "${ARTIFACT_SRC}/allocator.cc" "${ARTIFACT_SRC}/allocator.cc.orig"
fi

# Overwrite the artifact's allocator.cc with the instrumented copy.
cp "${HARNESS_DIR}/src/allocator_patched.cc" "${ARTIFACT_SRC}/allocator.cc"

echo "apply.sh: instrumentation applied to ${ARTIFACT_SRC}/allocator.cc"
echo "apply.sh: original preserved at ${ARTIFACT_SRC}/allocator.cc.orig"
