#!/usr/bin/env bash
set -euo pipefail
harness_dir=$(cd -- "$(dirname -- "$0")" && pwd)
source_dir=${1:-"$harness_dir/../../source"}
git -C "$source_dir" apply --reverse --check "$harness_dir/patches/instrumentation.patch"
git -C "$source_dir" apply --reverse "$harness_dir/patches/instrumentation.patch"
