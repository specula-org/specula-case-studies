#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${SREGYM_SOURCE_DIR:-/users/Pial/targets/sregym-codex-gpt56-sol-max-20260727}"
PATCH_FILE="$SCRIPT_DIR/patches/instrumentation.patch"

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
    echo "error: SREGYM source is not a git worktree: $SOURCE_DIR" >&2
    exit 1
fi

if git -C "$SOURCE_DIR" apply --check "$PATCH_FILE" >/dev/null 2>&1; then
    git -C "$SOURCE_DIR" apply "$PATCH_FILE"
    echo "Applied SREGym instrumentation patch."
elif git -C "$SOURCE_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
    echo "SREGym instrumentation patch is already applied."
else
    echo "error: instrumentation patch neither applies nor matches the current source." >&2
    echo "Inspect local source changes before retrying; apply.sh never resets the worktree." >&2
    exit 1
fi

mkdir -p "$SOURCE_DIR/tests/specula"
install -m 0644 "$SCRIPT_DIR/src/tla_trace.py" "$SOURCE_DIR/sregym/tla_trace.py"
install -m 0644 "$SCRIPT_DIR/src/test_trace_scenarios.py" "$SOURCE_DIR/tests/specula/test_trace_scenarios.py"

echo "Installed trace module and scenarios into: $SOURCE_DIR"
