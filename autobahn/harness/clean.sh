#!/bin/bash
# Revert TLA+ trace instrumentation from the artifact.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$(cd "$SCRIPT_DIR/../artifact/autobahn-artifact" && pwd)"

echo "=== Reverting instrumentation ==="
cd "$ARTIFACT_DIR"
git checkout -- .
echo "Done."
