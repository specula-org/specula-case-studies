#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ICCPD_DIR="${ICCPD_SOURCE_DIR:-/users/Pial/targets/sonic-buildimage-iccpd/src/iccpd}"
PATCH_FILE="$HARNESS_DIR/patches/instrumentation.patch"
EXPECTED_REV="9df8ccbf72c31948741b5554d09c38ac6c1ec6e9"

if ! git -C "$ICCPD_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: iccpd source is not a Git worktree: $ICCPD_DIR" >&2
    exit 1
fi

actual_rev="$(git -C "$ICCPD_DIR" rev-parse HEAD)"
if [[ "$actual_rev" != "$EXPECTED_REV" ]]; then
    echo "error: expected iccpd revision $EXPECTED_REV, found $actual_rev" >&2
    exit 1
fi

install -m 0644 "$HARNESS_DIR/src/tla_trace.h" \
    "$ICCPD_DIR/include/tla_trace.h"
install -m 0644 "$HARNESS_DIR/src/tla_trace.c" \
    "$ICCPD_DIR/src/tla_trace.c"

if git -C "$ICCPD_DIR" apply --check "$PATCH_FILE" 2>/dev/null; then
    git -C "$ICCPD_DIR" apply "$PATCH_FILE"
    echo "Applied iccpd trace instrumentation."
elif git -C "$ICCPD_DIR" apply --reverse --check "$PATCH_FILE" 2>/dev/null; then
    echo "iccpd trace instrumentation is already applied."
else
    echo "error: instrumentation patch neither applies nor is already applied" >&2
    echo "Inspect overlapping source changes in $ICCPD_DIR." >&2
    exit 1
fi
