#!/usr/bin/env bash
set -euo pipefail
harness=$(cd -- "$(dirname -- "$0")" && pwd)
source_dir=$(cd -- "$harness/../../source" && pwd)
test "$(git -C "$source_dir" rev-parse HEAD)" = 0c60537098f4c2949ad2d382aaf499de72263d76
patch_file="$harness/patches/instrumentation.patch"
if git -C "$source_dir" apply --check "$patch_file" 2>/dev/null; then
    git -C "$source_dir" apply "$patch_file"
elif ! git -C "$source_dir" apply --reverse --check "$patch_file" 2>/dev/null; then
    echo 'The instrumentation paths have conflicting edits.' >&2
    exit 1
fi
cmp -s "$harness/src/scm_trace.rs" "$source_dir/kernel/core/src/scm_trace.rs" ||
    cp --remove-destination "$harness/src/scm_trace.rs" "$source_dir/kernel/core/src/scm_trace.rs"
cmp -s "$harness/src/scm_rights_trace.c" "$source_dir/test/initramfs/src/regression/network/scm_rights_trace.c" ||
    cp --remove-destination "$harness/src/scm_rights_trace.c" "$source_dir/test/initramfs/src/regression/network/scm_rights_trace.c"
