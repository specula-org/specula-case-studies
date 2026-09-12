#!/usr/bin/env bash
set -euo pipefail
HARNESS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${TEMPORAL_SOURCE:-/home/ubuntu/temporal-investigation-20260909/parallel-20260911/source-history-queue}"
EXPECTED_REV=0c010ce5fe8c0180aa7573c72fe8fc87c6df7025
[[ "$(git -C "$SOURCE_DIR" rev-parse HEAD)" == "$EXPECTED_REV" ]] || { echo 'Source revision does not match the pinned target.' >&2; exit 1; }
if git -C "$SOURCE_DIR" apply --check "$HARNESS_DIR/patches/instrumentation.patch" 2>/dev/null; then
 git -C "$SOURCE_DIR" apply "$HARNESS_DIR/patches/instrumentation.patch"
elif ! git -C "$SOURCE_DIR" apply --reverse --check "$HARNESS_DIR/patches/instrumentation.patch" 2>/dev/null; then
 echo 'Instrumentation conflicts with source changes; checkout preserved.' >&2; exit 1
fi
mkdir -p "$SOURCE_DIR/common/hqtrace"
while IFS='|' read -r from to; do
 cp "$HARNESS_DIR/src/$from" "$SOURCE_DIR/$to"
done < "$HARNESS_DIR/files.txt"
python3 "$HARNESS_DIR/install_manifest.py" "$SOURCE_DIR"
echo "Instrumentation applied to $SOURCE_DIR"
