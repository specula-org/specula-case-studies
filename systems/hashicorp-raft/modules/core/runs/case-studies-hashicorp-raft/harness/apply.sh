#!/usr/bin/env bash
# apply.sh — Prepare the artifact for trace-instrumented builds.
#
# hashicorp/raft's trace instrumentation is already baked into the artifact
# source code (trace_logger.go, traceEvent() calls in raft.go and
# replication.go). No patches are needed.
#
# This script just verifies the instrumentation is present and the
# artifact is in a clean state.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/raft"

echo "=== Checking artifact instrumentation ==="

# Verify key instrumentation files exist.
if [ ! -f "$ARTIFACT/trace_logger.go" ]; then
    echo "ERROR: trace_logger.go not found in artifact" >&2
    exit 1
fi

# Verify trace emit calls are present.
count=$(grep -r 'r\.traceEvent(' "$ARTIFACT/raft.go" "$ARTIFACT/replication.go" 2>/dev/null | wc -l)
if [ "$count" -lt 10 ]; then
    echo "ERROR: Expected 10+ traceEvent calls, found $count" >&2
    exit 1
fi

echo "Artifact instrumentation verified ($count traceEvent calls found)"
echo "No patches needed — instrumentation is built into the artifact."
