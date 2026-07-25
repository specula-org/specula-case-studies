#!/bin/bash
# Apply trace instrumentation to willemt/raft artifact.
# Run from case-study root: bash harness/apply.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$SCRIPT_DIR/../artifact/raft"

echo "=== Applying instrumentation ==="

# 1. Reset artifact to clean state
echo "  Resetting artifact..."
cd "$ARTIFACT_DIR"
git checkout -- .

# 2. Download CLinkedListQueue dependency if missing
if [ ! -f "$ARTIFACT_DIR/CLinkedListQueue/linked_list_queue.c" ]; then
    echo "  Downloading CLinkedListQueue..."
    mkdir -p "$ARTIFACT_DIR/CLinkedListQueue"
    cd "$ARTIFACT_DIR/CLinkedListQueue"
    if [ ! -d .git ]; then
        git init -q
    fi
    git pull -q https://github.com/willemt/CLinkedListQueue 2>/dev/null || true
    cd "$ARTIFACT_DIR"
fi

# 3. Copy trace module into artifact
echo "  Copying trace module..."
cp "$SCRIPT_DIR/src/tla_trace.h" "$ARTIFACT_DIR/include/"
cp "$SCRIPT_DIR/src/tla_trace.c" "$ARTIFACT_DIR/src/"
cp "$SCRIPT_DIR/src/test_trace.c" "$ARTIFACT_DIR/tests/"

# 4. Apply instrumentation patch to raft_server.c
echo "  Applying patch..."
cd "$ARTIFACT_DIR"
patch -p0 < "$SCRIPT_DIR/patches/instrumentation.patch"

echo "=== Instrumentation applied ==="
