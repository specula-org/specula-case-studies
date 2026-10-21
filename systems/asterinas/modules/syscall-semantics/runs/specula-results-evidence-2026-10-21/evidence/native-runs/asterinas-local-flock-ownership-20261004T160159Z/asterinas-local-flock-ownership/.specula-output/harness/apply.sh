#!/usr/bin/env bash
set -euo pipefail
harness_dir=$(cd -- "$(dirname -- "$0")" && pwd)
source_dir=${1:-"$harness_dir/../../source"}
expected=0c60537098f4c2949ad2d382aaf499de72263d76
[[ $(git -C "$source_dir" rev-parse HEAD) == "$expected" ]] || { echo 'source pin mismatch' >&2; exit 2; }
patch_file="$harness_dir/patches/instrumentation.patch"
if git -C "$source_dir" apply --reverse --check "$patch_file" 2>/dev/null; then
    echo 'instrumentation already applied'
elif git -C "$source_dir" apply --check "$patch_file"; then
    git -C "$source_dir" apply "$patch_file"
else
    echo 'source differs from both baseline and exact instrumentation' >&2
    exit 2
fi
cmp "$harness_dir/src/flock_trace.rs" "$source_dir/ostd/src/flock_trace.rs"
