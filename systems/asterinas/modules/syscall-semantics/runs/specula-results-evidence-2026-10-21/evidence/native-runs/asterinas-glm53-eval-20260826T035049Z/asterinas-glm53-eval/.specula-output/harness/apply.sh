#!/usr/bin/env bash

# SPDX-License-Identifier: MPL-2.0

set -euo pipefail

harness_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
output_dir=$(cd "$harness_dir/.." && pwd)
source_dir=${SPECULA_SOURCE_ROOT:-"$output_dir/../source"}
patch_file="$harness_dir/patches/instrumentation.patch"

if [[ ! -f "$source_dir/Cargo.toml" ]]; then
    echo "Asterinas source not found at $source_dir" >&2
    exit 1
fi

if git -C "$source_dir" apply -p1 --reverse --check "$patch_file" 2>/dev/null; then
    echo "Instrumentation already applied to $source_dir"
elif git -C "$source_dir" apply -p1 --check "$patch_file"; then
    git -C "$source_dir" apply -p1 "$patch_file"
    echo "Applied instrumentation to $source_dir"
else
    echo "Source does not match the pinned artifact or the applied instrumentation" >&2
    exit 1
fi

cmp "$harness_dir/src/tla_trace.rs" "$source_dir/kernel/core/src/tla_trace.rs"
cmp "$harness_dir/src/specula_trace.c" \
    "$source_dir/test/initramfs/src/regression/io/file_io/specula_trace.c"
cmp "$harness_dir/src/specula_trace.sh" \
    "$source_dir/test/initramfs/src/regression/io/file_io/specula_trace.sh"
