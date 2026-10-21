#!/usr/bin/env bash
set -euo pipefail
harness_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_dir=$(cd -- "$harness_dir/../../source" && pwd)
module="$source_dir/kernel/core/src/tla_trace.rs"
cmp -- "$module" "$harness_dir/src/tla_trace.rs"
git -C "$source_dir" apply --reverse --check "$harness_dir/patches/instrumentation.patch"
git -C "$source_dir" apply --reverse "$harness_dir/patches/instrumentation.patch"
rm -- "$module"
