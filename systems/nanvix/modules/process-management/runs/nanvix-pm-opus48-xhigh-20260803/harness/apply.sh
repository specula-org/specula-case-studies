#!/usr/bin/env bash
# Copyright(c) The Maintainers of Nanvix.
# Licensed under the MIT License.
#
# Applies the Specula PM trace instrumentation to the Nanvix source artifact.
#
# The instrumentation has two parts:
#   1. New harness modules (copied verbatim into the kernel tree):
#        - src/kernel/src/pm/tla_trace.rs                     (NDJSON emitter)
#        - src/kernel/src/pm/process/state/tla_world.rs       (real-transition scenarios)
#   2. Small edits to three existing kernel files (patches/instrumentation.patch):
#        - pm/mod.rs                 : declare pm::tla_trace (test builds only)
#        - pm/process/state/mod.rs   : declare pm::process::state::tla_world (test builds only)
#        - pm/test.rs                : invoke the scenario runner from pm::test()
#
# All additions are guarded by `#[cfg(feature = "test")]`, so a normal (non-test) build is
# unaffected.
#
# Usage:  ARTIFACT=/path/to/nanvix/source bash apply.sh
#         (ARTIFACT defaults to ../../source relative to this script.)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT="${ARTIFACT:-$SCRIPT_DIR/../../source}"
ARTIFACT="$(cd "$ARTIFACT" && pwd)"

TRACKED=(
    src/kernel/src/pm/mod.rs
    src/kernel/src/pm/process/state/mod.rs
    src/kernel/src/pm/test.rs
)

echo "[apply] artifact = $ARTIFACT"

# 1. Reset any previously-applied instrumentation on the tracked files so the patch applies cleanly.
if git -C "$ARTIFACT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$ARTIFACT" checkout -- "${TRACKED[@]}" 2>/dev/null || true
fi

# 2. Apply the tracked-file instrumentation patch.
git -C "$ARTIFACT" apply "$SCRIPT_DIR/patches/instrumentation.patch"
echo "[apply] patched: ${TRACKED[*]}"

# 3. Copy the new harness modules into the kernel tree.
cp "$SCRIPT_DIR/src/tla_trace.rs" "$ARTIFACT/src/kernel/src/pm/tla_trace.rs"
cp "$SCRIPT_DIR/src/tla_world.rs" "$ARTIFACT/src/kernel/src/pm/process/state/tla_world.rs"
echo "[apply] copied: pm/tla_trace.rs, pm/process/state/tla_world.rs"

echo "[apply] done."
