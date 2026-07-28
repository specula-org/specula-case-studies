#!/usr/bin/env bash

set -euo pipefail

OUTPUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_DIR="$OUTPUT_ROOT/harness"
PATCH_FILE="$HARNESS_DIR/patches/instrumentation.patch"
ARTIFACT_DIR="${ARTIFACT_DIR:-/home/ubuntu/Specula/case-studies/slatedb-dist-compaction/artifact/slatedb}"
CRATE_DIR="$ARTIFACT_DIR/slatedb"

install -d "$CRATE_DIR/src"
install -m 0644 "$HARNESS_DIR/src/tla_trace.rs" "$CRATE_DIR/src/tla_trace.rs"
install -m 0644 "$HARNESS_DIR/src/tla_trace_scenarios.rs" "$CRATE_DIR/src/tla_trace_scenarios.rs"

cd "$ARTIFACT_DIR"

if git apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
    printf '%s\n' "Instrumentation patch already applied."
elif git apply --check "$PATCH_FILE" >/dev/null 2>&1; then
    git apply "$PATCH_FILE"
    printf '%s\n' "Applied instrumentation patch."
else
    printf '%s\n' "Instrumentation patch does not apply cleanly. Inspect $PATCH_FILE against $ARTIFACT_DIR." >&2
    exit 1
fi
