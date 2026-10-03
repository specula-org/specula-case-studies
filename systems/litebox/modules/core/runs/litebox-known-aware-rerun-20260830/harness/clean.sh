#!/usr/bin/env bash
set -euo pipefail

OUTPUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_ROOT="$OUTPUT_ROOT/harness"
SOURCE_ROOT="${LITEBOX_SOURCE_ROOT:-/home/ubuntu/tmp/litebox-specula-source.xc2YsN/litebox}"
PATCH="$HARNESS_ROOT/patches/instrumentation.patch"

if git -C "$SOURCE_ROOT" apply --reverse --check "$PATCH"; then
    git -C "$SOURCE_ROOT" apply --reverse "$PATCH"
else
    echo "Refusing cleanup: source changes no longer exactly match the harness patch" >&2
    exit 1
fi

for file in \
    "$SOURCE_ROOT/litebox/src/sync/tla_futex_scenario.rs" \
    "$SOURCE_ROOT/litebox_shim_linux/src/syscalls/tla_scenarios.rs" \
    "$SOURCE_ROOT/litebox_tla_trace/src/lib.rs" \
    "$SOURCE_ROOT/litebox_tla_trace/Cargo.toml"
do
    test ! -e "$file" || unlink "$file"
done
rmdir "$SOURCE_ROOT/litebox_tla_trace/src" "$SOURCE_ROOT/litebox_tla_trace"
echo "LiteBox trace harness removed from $SOURCE_ROOT"
