#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ARTIFACT_DIR=${1:-${DASH_HA_SOURCE:-/users/Pial/targets/sonic-dash-ha}}
PATCH_FILE="$HARNESS_DIR/patches/instrumentation.patch"

if [[ ! -f "$ARTIFACT_DIR/Cargo.toml" ]]; then
    echo "dash-ha source not found at: $ARTIFACT_DIR" >&2
    exit 2
fi

if git -C "$ARTIFACT_DIR" apply --reverse --check "$PATCH_FILE" 2>/dev/null; then
    git -C "$ARTIFACT_DIR" apply --reverse "$PATCH_FILE"
    echo "Reversed dash-ha trace instrumentation patch."
elif git -C "$ARTIFACT_DIR" apply --check "$PATCH_FILE" 2>/dev/null; then
    echo "Trace instrumentation patch was not applied."
else
    echo "Cannot reverse instrumentation without overlapping source changes." >&2
    exit 1
fi

remove_copy() {
    local canonical=$1
    local installed=$2
    if [[ ! -e "$installed" ]]; then
        return
    fi
    if ! cmp -s "$canonical" "$installed"; then
        echo "Refusing to remove modified harness copy: $installed" >&2
        exit 1
    fi
    rm -f -- "$installed"
}

remove_copy "$HARNESS_DIR/src/tla_trace.rs" \
    "$ARTIFACT_DIR/crates/swbus-actor/src/tla_trace.rs"
remove_copy "$HARNESS_DIR/src/trace_scenarios.rs" \
    "$ARTIFACT_DIR/crates/hamgrd/src/actors/ha_scope/trace_scenarios.rs"
remove_copy "$HARNESS_DIR/src/ha_set_trace_scenarios.rs" \
    "$ARTIFACT_DIR/crates/hamgrd/src/actors/ha_set_trace_scenarios.rs"

echo "Removed unmodified trace-module and scenario copies."
