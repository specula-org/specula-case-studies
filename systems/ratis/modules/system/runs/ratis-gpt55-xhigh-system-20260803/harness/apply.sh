#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${SPECULA_SOURCE_DIR:-/home/ubuntu/specula-ratis-issue123-20260803/sources/ratis-system}"
PATCH_FILE="$SCRIPT_DIR/patches/instrumentation.patch"

if ! git -C "$SOURCE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Source directory is not a git checkout: $SOURCE_DIR" >&2
  exit 2
fi

if [[ ! -f "$PATCH_FILE" ]]; then
  echo "Missing instrumentation patch: $PATCH_FILE" >&2
  exit 2
fi

cd "$SOURCE_DIR"

if git apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
  echo "Instrumentation patch is already applied in $SOURCE_DIR"
  exit 0
fi

git apply --check "$PATCH_FILE"
git apply "$PATCH_FILE"
echo "Applied instrumentation patch to $SOURCE_DIR"
