#!/usr/bin/env bash
set -euo pipefail
harness=$(cd -- "$(dirname -- "$0")" && pwd)
source_dir=$(cd -- "$harness/../../source" && pwd)
cmp "$harness/src/scm_trace.rs" "$source_dir/kernel/core/src/scm_trace.rs"
cmp "$harness/src/scm_rights_trace.c" "$source_dir/test/initramfs/src/regression/network/scm_rights_trace.c"
git -C "$source_dir" apply --reverse --check "$harness/patches/instrumentation.patch"
git -C "$source_dir" apply --reverse "$harness/patches/instrumentation.patch"
rm "$source_dir/kernel/core/src/scm_trace.rs" "$source_dir/test/initramfs/src/regression/network/scm_rights_trace.c"
