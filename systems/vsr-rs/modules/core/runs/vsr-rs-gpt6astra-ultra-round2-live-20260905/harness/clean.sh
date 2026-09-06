#!/usr/bin/env bash
# Remove only the known instrumentation, preserving unrelated work.
set -euo pipefail
HARNESS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SOURCE_DIR=${SOURCE_DIR:-"$HARNESS_DIR/../../source"}
for name in tla_trace.rs owner.rs scenarios.rs; do
    if test -e "$SOURCE_DIR/tla_trace/$name"; then
        cmp -- "$HARNESS_DIR/src/$name" "$SOURCE_DIR/tla_trace/$name" || { echo "Preserving locally edited $name" >&2; exit 1; }
    fi
done
git -C "$SOURCE_DIR" apply --reverse --check "$HARNESS_DIR/patches/instrumentation.patch"
git -C "$SOURCE_DIR" apply --reverse "$HARNESS_DIR/patches/instrumentation.patch"
for name in tla_trace.rs owner.rs scenarios.rs; do
    rm -f -- "$SOURCE_DIR/tla_trace/$name"
done
rmdir -- "$SOURCE_DIR/tla_trace"
