#!/usr/bin/env bash
set -euo pipefail
harness_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_dir=$(cd -- "$harness_dir/../../source" && pwd)
expected=0c60537098f4c2949ad2d382aaf499de72263d76
[[ $(git -C "$source_dir" rev-parse HEAD) == "$expected" ]] || {
    echo "Source revision differs from the instrumentation specification." >&2
    exit 1
}
patch_file="$harness_dir/patches/instrumentation.patch"
if git -C "$source_dir" apply --reverse --check "$patch_file" 2>/dev/null; then
    :
else
    git -C "$source_dir" apply --check "$patch_file"
    git -C "$source_dir" apply "$patch_file"
fi
cp -- "$harness_dir/src/tla_trace.rs" "$source_dir/kernel/core/src/tla_trace.rs"
