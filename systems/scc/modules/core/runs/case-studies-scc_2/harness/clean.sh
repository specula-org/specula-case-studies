#!/usr/bin/env bash
# Revert scc trace instrumentation from the artifact.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
ARTIFACT="$CASE_DIR/../artifact/scc"

if [ ! -d "$ARTIFACT" ]; then
    echo "error: artifact not found at $ARTIFACT" >&2
    exit 1
fi

git -C "$ARTIFACT" reset --hard HEAD >/dev/null
rm -f "$ARTIFACT/src/tla_trace.rs"
echo "  artifact reverted to HEAD."
