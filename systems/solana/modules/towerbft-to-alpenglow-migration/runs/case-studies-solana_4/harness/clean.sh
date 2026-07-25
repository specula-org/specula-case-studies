#!/usr/bin/env bash
# Revert the harness instrumentation from the agave artifact.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT="$(cd "$HARNESS_DIR/../../artifact/agave" && pwd)"

echo "[clean] Restoring votor-messages files via git..."
git -C "$ARTIFACT" checkout -- votor-messages/Cargo.toml votor-messages/src/lib.rs votor-messages/src/migration.rs || true
# Remove the new file (not tracked by git).
rm -f "$ARTIFACT/votor-messages/src/tla_trace.rs"
echo "[clean] Done."
