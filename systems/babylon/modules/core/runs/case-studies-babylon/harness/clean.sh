#!/usr/bin/env bash
# Revert Specula instrumentation by checking out clean source.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_ROOT="$(cd "$HARNESS_DIR/../../artifact/babylon" && pwd)"

cd "$ARTIFACT_ROOT"
git checkout -- x/ 2>/dev/null || true
# Remove copied harness packages.
rm -rf x/tlatrace x/tlatrace_scenarios
