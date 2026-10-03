#!/usr/bin/env bash
set -euo pipefail
harness_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source_dir="$(cd -- "$harness_dir/../../source" && pwd)"
git -C "$source_dir" apply --reverse --check "$harness_dir/patches/instrumentation.patch"
# Refuse to discard any harness-file edits made by the validation agent.
for path in "$harness_dir"/src/*.go "$harness_dir"/src/tracker/*.go; do
    rel="${path#"$harness_dir/src/"}"
    cmp -- "$path" "$source_dir/$rel"
done
git -C "$source_dir" apply --reverse "$harness_dir/patches/instrumentation.patch"
for path in "$harness_dir"/src/*.go "$harness_dir"/src/tracker/*.go; do
    rel="${path#"$harness_dir/src/"}"
    rm -- "$source_dir/$rel"
done
