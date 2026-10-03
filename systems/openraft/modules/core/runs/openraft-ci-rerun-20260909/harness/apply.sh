#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$(dirname "$HARNESS_DIR")"
ARTIFACT_DIR="$(dirname "$OUTPUT_DIR")"
SOURCE_DIR="${SPECULA_SOURCE_DIR:-$ARTIFACT_DIR/source}"
EXPECTED_HEAD="15f927e1358d41ffc1297516f781029dbf8ca86a"
PATCH_FILE="$HARNESS_DIR/patches/instrumentation.patch"

if [[ ! -d "$SOURCE_DIR/.git" ]]; then
    echo "error: OpenRaft source checkout not found: $SOURCE_DIR" >&2
    exit 1
fi

actual_head="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
if [[ "$actual_head" != "$EXPECTED_HEAD" ]]; then
    echo "error: harness targets $EXPECTED_HEAD, source is $actual_head" >&2
    exit 1
fi

if git -C "$SOURCE_DIR" apply --check "$PATCH_FILE" >/dev/null 2>&1; then
    git -C "$SOURCE_DIR" apply "$PATCH_FILE"
    echo "applied OpenRaft trace hooks"
elif git -C "$SOURCE_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
    echo "OpenRaft trace hooks already applied"
else
    echo "error: trace patch neither applies cleanly nor is already applied" >&2
    exit 1
fi

install -m 0644 "$HARNESS_DIR/src/tla_trace.rs" "$SOURCE_DIR/openraft/src/tla_trace.rs"
install -m 0644 \
    "$HARNESS_DIR/src/specula_trace_scenarios.rs" \
    "$SOURCE_DIR/openraft/src/engine/specula_trace_scenarios.rs"

echo "installed test-only trace module and scenarios"
