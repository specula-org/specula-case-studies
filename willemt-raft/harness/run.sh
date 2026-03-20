#!/bin/bash
# Build instrumented willemt/raft and run trace-generating tests.
# Run from case-study root: bash harness/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$SCRIPT_DIR/.."
ARTIFACT_DIR="$CASE_DIR/artifact/raft"
TRACES_DIR="$CASE_DIR/traces"

# 1. Apply instrumentation
bash "$SCRIPT_DIR/apply.sh"

# 2. Build test binary
echo ""
echo "=== Building instrumented test ==="
cd "$ARTIFACT_DIR"

gcc -Iinclude -I"$ARTIFACT_DIR/CLinkedListQueue" \
    -DRAFT_ENABLE_TRACE \
    -Wno-pointer-sign -Wno-unused-variable \
    -g -O0 \
    src/raft_server.c \
    src/raft_server_properties.c \
    src/raft_node.c \
    src/raft_log.c \
    src/tla_trace.c \
    tests/test_trace.c \
    -o test_trace

echo "  Build OK"

# 3. Create traces directory
mkdir -p "$TRACES_DIR"

# 4. Run tests (traces are written to $TRACES_DIR via env var)
echo ""
echo "=== Running trace tests ==="
cd "$ARTIFACT_DIR"
TRACE_DIR="$TRACES_DIR" ./test_trace

# 5. Report results
echo ""
echo "=== Trace files ==="
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        lines=$(wc -l < "$f")
        echo "  $(basename "$f"): $lines lines"
        # Quick JSON validity check on first line
        head -1 "$f" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null \
            && echo "    (valid JSON)" \
            || echo "    (WARNING: invalid JSON on first line)"
    fi
done

echo ""
echo "=== Done ==="
