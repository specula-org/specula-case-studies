#!/usr/bin/env bash
set -euo pipefail
HARNESS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SOURCE_DIR=${SOURCE_DIR:-"$HARNESS_DIR/../../source"}
PIN=3ac0104a567092139534c9022205d02281a2da41
test "$(git -C "$SOURCE_DIR" rev-parse HEAD)" = "$PIN" || { echo 'Source revision differs from harness pin' >&2; exit 1; }
PATCH="$HARNESS_DIR/patches/instrumentation.patch"
if git -C "$SOURCE_DIR" apply --reverse --check "$PATCH" 2>/dev/null; then
    echo 'Instrumentation patch already present'
elif git -C "$SOURCE_DIR" diff --quiet HEAD -- Cargo.toml lib.rs && git -C "$SOURCE_DIR" apply --check "$PATCH"; then
    git -C "$SOURCE_DIR" apply "$PATCH"
else
    echo 'Refusing to replace local changes in Cargo.toml or lib.rs' >&2
    exit 1
fi
mkdir -p "$SOURCE_DIR/tla_trace"
for name in tla_trace.rs owner.rs scenarios.rs; do
    cp -- "$HARNESS_DIR/src/$name" "$SOURCE_DIR/tla_trace/$name"
done
echo "Applied trace instrumentation to $SOURCE_DIR"
