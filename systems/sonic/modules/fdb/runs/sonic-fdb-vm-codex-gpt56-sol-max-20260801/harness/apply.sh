#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE_DIR=${1:-${FDB_SOURCE_DIR:-/users/Pial/targets/sonic-swss-fdb}}
EXPECTED_REVISION=4f3dda156e52ed7647b1dbf900d54d87efaea455
PATCH_FILE="$HARNESS_DIR/patches/instrumentation.patch"

if ! git -C "$SOURCE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: not a git checkout: $SOURCE_DIR" >&2
    exit 1
fi

actual_revision=$(git -C "$SOURCE_DIR" rev-parse HEAD)
if [[ "$actual_revision" != "$EXPECTED_REVISION" ]]; then
    echo "error: expected sonic-swss revision $EXPECTED_REVISION, found $actual_revision" >&2
    exit 1
fi

copy_instrumentation_file() {
    local source_file=$1
    local target_file=$2
    if [[ -e "$target_file" ]]; then
        if ! cmp -s "$source_file" "$target_file"; then
            echo "error: refusing to overwrite differing file: $target_file" >&2
            exit 1
        fi
        return
    fi
    cp "$source_file" "$target_file"
}

copy_instrumentation_file "$HARNESS_DIR/src/fdb_trace.h" "$SOURCE_DIR/orchagent/fdb_trace.h"
copy_instrumentation_file "$HARNESS_DIR/src/fdb_trace.cpp" "$SOURCE_DIR/orchagent/fdb_trace.cpp"
copy_instrumentation_file "$HARNESS_DIR/src/swss_file_redirect.cpp" "$SOURCE_DIR/tests/mock_tests/fdb_swss_file_redirect.cpp"

if git -C "$SOURCE_DIR" apply --check "$PATCH_FILE" 2>/dev/null; then
    git -C "$SOURCE_DIR" apply "$PATCH_FILE"
elif git -C "$SOURCE_DIR" apply --reverse --check "$PATCH_FILE" 2>/dev/null; then
    : # The instrumentation patch is already present.
else
    echo "error: instrumentation patch neither applies nor matches the checkout" >&2
    exit 1
fi

echo "instrumentation ready in $SOURCE_DIR"
