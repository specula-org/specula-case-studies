#!/usr/bin/env bash
# Build instrumented eliben/raft, run trace tests, collect traces.
# Run from: case-studies/eliben-raft/
set -euo pipefail

# Ensure Go is on PATH
export PATH="/usr/local/go/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/raft"
RAFT_PKG="$ARTIFACT/part3/raft"
TRACES_DIR="$CASE_DIR/traces"

# 1. Apply instrumentation
bash "$SCRIPT_DIR/apply.sh"

# 2. Ensure traces directory exists
mkdir -p "$TRACES_DIR"

# 3. Build and run trace tests
echo ""
echo "=== Running trace tests ==="
export RAFT_TRACE_DIR="$TRACES_DIR"
cd "$RAFT_PKG"

# Run each trace test individually to isolate traces
for test in TestTraceBasicConsensus TestTraceLeaderReelection TestTraceCrashRecovery; do
    echo "  Running $test..."
    go test -v -run "^${test}$" -count=1 -timeout 60s . 2>&1 | tail -3
    echo ""
done

# 4. Report results
echo "=== Trace files ==="
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        lines=$(wc -l < "$f")
        echo "  $(basename "$f"): $lines lines"
    fi
done

# 5. Quick sanity check: verify JSON validity
echo ""
echo "=== Sanity check ==="
ok=true
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        if python3 -c "
import json, sys
with open('$f') as fh:
    for i, line in enumerate(fh, 1):
        json.loads(line)
" 2>/dev/null; then
            echo "  $(basename "$f"): valid JSON"
        else
            echo "  $(basename "$f"): INVALID JSON!"
            ok=false
        fi
    fi
done

if $ok; then
    echo ""
    echo "All traces generated successfully."
else
    echo ""
    echo "WARNING: Some traces have invalid JSON."
    exit 1
fi
