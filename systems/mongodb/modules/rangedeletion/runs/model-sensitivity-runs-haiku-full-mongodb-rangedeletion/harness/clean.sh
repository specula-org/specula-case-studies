#!/bin/bash
# Revert instrumentation changes
set -e

ARTIFACT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../artifact" && pwd)"

echo "Reverting instrumentation changes..."
cd "${ARTIFACT_DIR}"

# Reset all changes
git checkout -- . || true

echo "✓ Reverted all changes"
