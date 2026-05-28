#!/usr/bin/env bash
# Apply the harness instrumentation onto the agave artifact in-place.
# Idempotent: re-running first restores the artifact via `git checkout`.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT="$(cd "$HARNESS_DIR/../../artifact/agave" && pwd)"

echo "[apply] Restoring artifact to clean state..."
git -C "$ARTIFACT" checkout -- votor-messages/Cargo.toml votor-messages/src/lib.rs votor-messages/src/migration.rs || true

echo "[apply] Copying instrumented files..."
cp "$HARNESS_DIR/src/migration.rs"             "$ARTIFACT/votor-messages/src/migration.rs"
cp "$HARNESS_DIR/src/tla_trace.rs"             "$ARTIFACT/votor-messages/src/tla_trace.rs"
cp "$HARNESS_DIR/src/votor_messages_lib.rs"    "$ARTIFACT/votor-messages/src/lib.rs"
cp "$HARNESS_DIR/src/votor_messages_Cargo.toml" "$ARTIFACT/votor-messages/Cargo.toml"

echo "[apply] Done."
