#!/usr/bin/env bash
# Apply the solana_3 Tower BFT trace harness to the agave artifact.
#
# Steps:
#   1. Reset the artifact to a clean state.
#   2. Copy the trace module + scenario file into core/src/.
#   3. Add the `serde_json` dep to core/Cargo.toml.
#   4. Wire the new modules into core/src/lib.rs.
#
# Idempotent — rerun any time to refresh a dirty working tree.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-$HARNESS_DIR/../../artifact/agave}"

if [[ ! -d "$ARTIFACT_DIR/core/src" ]]; then
    echo "ARTIFACT_DIR=$ARTIFACT_DIR does not look like an agave checkout" >&2
    exit 1
fi

echo "[apply.sh] Resetting artifact tree at $ARTIFACT_DIR"
git -C "$ARTIFACT_DIR" reset --hard HEAD >/dev/null
git -C "$ARTIFACT_DIR" clean -fd \
    core/src/tla_trace.rs core/src/tla_trace_scenarios.rs >/dev/null 2>&1 || true

echo "[apply.sh] Copying trace modules into core/src/"
cp "$HARNESS_DIR/src/tla_trace.rs" "$ARTIFACT_DIR/core/src/tla_trace.rs"
cp "$HARNESS_DIR/src/tla_trace_scenarios.rs" \
   "$ARTIFACT_DIR/core/src/tla_trace_scenarios.rs"

# --- Patch core/Cargo.toml — add serde_json dependency ----------------------
# The patch is idempotent: we only insert when the line is missing.
CARGO_FILE="$ARTIFACT_DIR/core/Cargo.toml"
if ! grep -q '^serde_json = { workspace = true }' "$CARGO_FILE"; then
    echo "[apply.sh] Adding serde_json dep to core/Cargo.toml"
    # Insert after the existing serde_bytes line.
    awk '
        /^serde_bytes = / && !inserted {
            print
            print "serde_json = { workspace = true }"
            inserted = 1
            next
        }
        { print }
    ' "$CARGO_FILE" > "$CARGO_FILE.tmp" && mv "$CARGO_FILE.tmp" "$CARGO_FILE"
fi

# --- Patch core/src/lib.rs — register modules ---------------------------------
LIB_FILE="$ARTIFACT_DIR/core/src/lib.rs"
if ! grep -q '^pub mod tla_trace;' "$LIB_FILE"; then
    echo "[apply.sh] Wiring tla_trace modules into core/src/lib.rs"
    awk '
        /^pub mod system_monitor_service;/ && !inserted {
            print
            print "pub mod tla_trace;"
            print "#[cfg(all(test, feature = \"dev-context-only-utils\"))]"
            print "mod tla_trace_scenarios;"
            inserted = 1
            next
        }
        { print }
    ' "$LIB_FILE" > "$LIB_FILE.tmp" && mv "$LIB_FILE.tmp" "$LIB_FILE"
fi

echo "[apply.sh] Done"
