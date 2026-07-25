#!/bin/bash
set -e

ARTIFACT_DIR="${1:-.}"
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Harness apply.sh: Setting up instrumentation"
echo "Artifact directory: $ARTIFACT_DIR"
echo "Harness directory: $HARNESS_DIR"

if [ -d "$ARTIFACT_DIR/.git" ]; then
    echo "Git repository detected, saving current state..."
    cd "$ARTIFACT_DIR"
    git add -A || true
    git stash || true
fi

if [ -f "$HARNESS_DIR/patches/instrumentation.patch" ]; then
    echo "Applying instrumentation patch..."
    cd "$ARTIFACT_DIR"
    git apply "$HARNESS_DIR/patches/instrumentation.patch" || true
fi

echo "Harness setup complete."
