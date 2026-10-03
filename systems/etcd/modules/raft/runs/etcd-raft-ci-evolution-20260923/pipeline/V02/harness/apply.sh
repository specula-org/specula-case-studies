#!/usr/bin/env bash
set -euo pipefail
harness_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_dir="$(cd -- "$harness_dir/../../source" && pwd)"
patch_file="$harness_dir/patches/instrumentation.patch"
if git -C "$source_dir" apply --check "$patch_file" 2>/dev/null; then
    git -C "$source_dir" apply "$patch_file"
elif ! git -C "$source_dir" apply --reverse --check "$patch_file" 2>/dev/null; then
    printf 'Instrumentation patch conflicts with source changes; nothing was reset.\n' >&2
    exit 1
fi
cp -- "$harness_dir"/src/*.go "$source_dir/"
cp -- "$harness_dir"/src/tracker/*.go "$source_dir/tracker/"
printf 'Observational instrumentation applied to %s\n' "$source_dir"
