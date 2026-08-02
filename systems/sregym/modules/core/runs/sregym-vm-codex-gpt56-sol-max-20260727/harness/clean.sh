#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${SREGYM_SOURCE_DIR:-/users/Pial/targets/sregym-codex-gpt56-sol-max-20260727}"
PATCH_FILE="$SCRIPT_DIR/patches/instrumentation.patch"

if git -C "$SOURCE_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
    git -C "$SOURCE_DIR" apply --reverse "$PATCH_FILE"
    echo "Reversed SREGym instrumentation patch."
else
    echo "Instrumentation patch was not applied; source edits were left untouched."
fi

rm -f \
    "$SOURCE_DIR/sregym/tla_trace.py" \
    "$SOURCE_DIR/tests/specula/test_trace_scenarios.py"
rmdir "$SOURCE_DIR/tests/specula" 2>/dev/null || true

echo "Removed copied harness files (recoverable from $SCRIPT_DIR/src)."
