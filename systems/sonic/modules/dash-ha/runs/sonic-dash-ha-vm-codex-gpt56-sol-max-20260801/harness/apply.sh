#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ARTIFACT_DIR=${1:-${DASH_HA_SOURCE:-/users/Pial/targets/sonic-dash-ha}}
PATCH_FILE="$HARNESS_DIR/patches/instrumentation.patch"

if [[ ! -f "$ARTIFACT_DIR/Cargo.toml" ]]; then
    echo "dash-ha source not found at: $ARTIFACT_DIR" >&2
    echo "Pass the source directory as argument 1 or set DASH_HA_SOURCE." >&2
    exit 2
fi

if [[ ! -f "$PATCH_FILE" ]]; then
    echo "Instrumentation patch is missing: $PATCH_FILE" >&2
    exit 2
fi

# The protobuf crate is a pinned source submodule required by the real build.
timeout 120s git -C "$ARTIFACT_DIR" submodule update --init --depth 1 \
    crates/sonic-dash-api-proto/sonic-dash-api

if git -C "$ARTIFACT_DIR" apply --check "$PATCH_FILE" 2>/dev/null; then
    git -C "$ARTIFACT_DIR" apply "$PATCH_FILE"
    echo "Applied dash-ha trace instrumentation patch."
elif git -C "$ARTIFACT_DIR" apply --reverse --check "$PATCH_FILE" 2>/dev/null; then
    echo "Trace instrumentation patch is already applied."
else
    echo "Cannot apply instrumentation patch cleanly." >&2
    echo "The source may differ from the expected dash-ha revision or contain overlapping edits." >&2
    exit 1
fi

# Keep the trace runtime and scenarios outside the source checkout as the
# canonical harness sources, copying them into normal Rust module locations.
install -D -m 0644 "$HARNESS_DIR/src/tla_trace.rs" \
    "$ARTIFACT_DIR/crates/swbus-actor/src/tla_trace.rs"
install -D -m 0644 "$HARNESS_DIR/src/trace_scenarios.rs" \
    "$ARTIFACT_DIR/crates/hamgrd/src/actors/ha_scope/trace_scenarios.rs"
install -D -m 0644 "$HARNESS_DIR/src/ha_set_trace_scenarios.rs" \
    "$ARTIFACT_DIR/crates/hamgrd/src/actors/ha_set_trace_scenarios.rs"

rg -q 'pub mod tla_trace;' "$ARTIFACT_DIR/crates/swbus-actor/src/lib.rs"
rg -q 'NpuHandleVoteRequestRetry' "$ARTIFACT_DIR/crates/hamgrd/src/actors/ha_scope/npu.rs"
echo "Instrumentation ready in $ARTIFACT_DIR"
