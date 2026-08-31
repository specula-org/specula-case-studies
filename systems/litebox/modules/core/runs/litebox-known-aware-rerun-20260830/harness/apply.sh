#!/usr/bin/env bash
set -euo pipefail

OUTPUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_ROOT="$OUTPUT_ROOT/harness"
SOURCE_ROOT="${LITEBOX_SOURCE_ROOT:-/home/ubuntu/tmp/litebox-specula-source.xc2YsN/litebox}"

test -f "$SOURCE_ROOT/Cargo.toml"
mkdir -p "$SOURCE_ROOT/litebox_tla_trace/src"
cp "$HARNESS_ROOT/src/litebox_tla_trace/Cargo.toml" "$SOURCE_ROOT/litebox_tla_trace/Cargo.toml"
cp "$HARNESS_ROOT/src/litebox_tla_trace/src/lib.rs" "$SOURCE_ROOT/litebox_tla_trace/src/lib.rs"
cp "$HARNESS_ROOT/src/tla_scenarios.rs" \
    "$SOURCE_ROOT/litebox_shim_linux/src/syscalls/tla_scenarios.rs"
cp "$HARNESS_ROOT/src/tla_futex_scenario.rs" \
    "$SOURCE_ROOT/litebox/src/sync/tla_futex_scenario.rs"

PATCH="$HARNESS_ROOT/patches/instrumentation.patch"
if test -f "$PATCH"; then
    if git -C "$SOURCE_ROOT" apply --reverse --check "$PATCH" >/dev/null 2>&1; then
        echo "LiteBox instrumentation patch already applied"
    else
        git -C "$SOURCE_ROOT" apply --check "$PATCH"
        git -C "$SOURCE_ROOT" apply "$PATCH"
    fi
fi

echo "LiteBox trace harness applied to $SOURCE_ROOT"

