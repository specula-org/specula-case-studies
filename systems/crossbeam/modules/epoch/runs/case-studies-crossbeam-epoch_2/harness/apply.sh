#!/usr/bin/env bash
# Apply trace instrumentation to the crossbeam-epoch artifact.
#
# Idempotent: discards any existing local edits to the tracked source files,
# then re-applies the instrumentation patch and (re)installs the trace module
# and example binary.
#
# Usage:
#     bash apply.sh           # apply instrumentation
#     bash apply.sh --revert  # revert to upstream

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_ROOT="$HARNESS_DIR/../../artifact/crossbeam"
EPOCH_DIR="$ARTIFACT_ROOT/crossbeam-epoch"
PATCH="$HARNESS_DIR/patches/instrumentation.patch"

if [[ ! -d "$EPOCH_DIR" ]]; then
    echo "error: cannot find $EPOCH_DIR" >&2
    exit 1
fi

revert() {
    echo "[apply.sh] reverting tracked source files"
    git -C "$ARTIFACT_ROOT" checkout -- \
        crossbeam-epoch/src/epoch.rs \
        crossbeam-epoch/src/internal.rs \
        crossbeam-epoch/src/lib.rs 2>/dev/null || true
    rm -f "$EPOCH_DIR/src/tla_trace.rs" "$EPOCH_DIR/examples/tla_harness.rs"
    echo "[apply.sh] reverted."
}

if [[ "${1:-}" == "--revert" ]]; then
    revert
    exit 0
fi

# Reset tracked files to a clean upstream state before re-applying. The patch
# was generated with `git diff` against the upstream HEAD, so a clean tree is
# required for a deterministic re-application.
git -C "$ARTIFACT_ROOT" checkout -- \
    crossbeam-epoch/src/epoch.rs \
    crossbeam-epoch/src/internal.rs \
    crossbeam-epoch/src/lib.rs 2>/dev/null || true

echo "[apply.sh] copying tla_trace.rs into $EPOCH_DIR/src/"
cp "$HARNESS_DIR/src/tla_trace.rs" "$EPOCH_DIR/src/tla_trace.rs"

echo "[apply.sh] copying tla_harness.rs into $EPOCH_DIR/examples/"
mkdir -p "$EPOCH_DIR/examples"
cp "$HARNESS_DIR/src/tla_harness.rs" "$EPOCH_DIR/examples/tla_harness.rs"

echo "[apply.sh] applying instrumentation patch"
( cd "$ARTIFACT_ROOT" && git apply --whitespace=nowarn "$PATCH" )

echo "[apply.sh] instrumentation applied."
