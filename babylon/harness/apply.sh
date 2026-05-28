#!/usr/bin/env bash
# Apply Specula trace instrumentation to the babylon artifact.
#
# Idempotent: re-running on an already-instrumented tree is a no-op.
# Reverts cleanly via harness/clean.sh.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_ROOT="$(cd "$HARNESS_DIR/../../artifact/babylon" && pwd)"

if [[ ! -d "$ARTIFACT_ROOT" ]]; then
    echo "ERROR: artifact not found at $ARTIFACT_ROOT" >&2
    exit 1
fi

# Apply via the Python script (line-based anchor insertions).
python3 "$HARNESS_DIR/patches/apply.py"
