#!/usr/bin/env bash
# Apply Specula TLA+ trace harness to the Sui consensus crate.
#
# Idempotent: running apply.sh twice is safe (existing files are overwritten,
# lib.rs is only patched if not already patched).
#
# Layout assumption: this script lives in
#   <ROOT>/.specula-output/harness/apply.sh
# and the artifact lives in
#   <ROOT>/artifact/sui/consensus/core/

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$HARNESS_DIR/../.." && pwd)"
ARTIFACT_SRC="$ROOT_DIR/artifact/sui/consensus/core/src"
TESTS_DIR="$ARTIFACT_SRC/tests"
LIB_RS="$ARTIFACT_SRC/lib.rs"

if [[ ! -f "$LIB_RS" ]]; then
    echo "ERROR: expected lib.rs at $LIB_RS — wrong layout?" >&2
    exit 1
fi

echo "[apply] Copying tla_trace.rs into $ARTIFACT_SRC"
cp "$HARNESS_DIR/src/tla_trace.rs" "$ARTIFACT_SRC/tla_trace.rs"

echo "[apply] Copying tla_trace_scenarios.rs into $TESTS_DIR"
mkdir -p "$TESTS_DIR"
cp "$HARNESS_DIR/src/tla_trace_scenarios.rs" "$TESTS_DIR/tla_trace_scenarios.rs"

# Patch lib.rs to register the new modules. We add a sentinel comment so we
# can detect previous applications and skip re-patching.
SENTINEL='// SPECULA-TLA-TRACE'
if grep -qF "$SENTINEL" "$LIB_RS"; then
    echo "[apply] lib.rs already patched, skipping"
else
    echo "[apply] Patching lib.rs"
    cat >> "$LIB_RS" <<EOF

$SENTINEL: trace emission module and scenarios.
// Only present at test time — production builds don't carry the trace code.
#[cfg(test)]
mod tla_trace;

#[cfg(test)]
#[path = "tests/tla_trace_scenarios.rs"]
mod tla_trace_scenarios;
EOF
fi

echo "[apply] Done."
