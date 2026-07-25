#!/bin/bash
# Build, run, and collect traces from async-raft.
# Run from case-studies/async-raft/

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$SCRIPT_DIR/.."
ARTIFACT_DIR="$CASE_DIR/artifact/async-raft"
TRACES_DIR="$CASE_DIR/traces"

echo "=== async-raft trace harness ==="

# Step 1: Apply instrumentation
echo ""
echo "--- Step 1: Applying instrumentation..."
bash "$SCRIPT_DIR/apply.sh"

# Step 2: Build
echo ""
echo "--- Step 2: Building async-raft (test mode)..."
(cd "$ARTIFACT_DIR" && cargo test -p async-raft --test tla_trace_scenario --no-run 2>&1 | tail -3)
echo "Build complete."

# Step 3: Create traces directory
mkdir -p "$TRACES_DIR"

# Step 4: Run test scenarios
echo ""
echo "--- Step 3: Running test scenarios..."

# Scenario 1: basic_consensus
echo ""
echo "  Running: basic_consensus"
(cd "$ARTIFACT_DIR" && \
    TLA_TRACE_FILE="$TRACES_DIR/basic_consensus.ndjson" \
    cargo test -p async-raft --test tla_trace_scenario -- basic_consensus --nocapture --test-threads=1 2>&1 | tail -10)
echo ""

# Step 5: Report results
echo ""
echo "--- Step 4: Trace results ---"
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        lines=$(wc -l < "$f")
        name=$(basename "$f")
        echo "  $name: $lines trace lines"
        # Spot check: first event
        echo "    First event: $(head -1 "$f" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('event',{}).get('name','?'))" 2>/dev/null || echo "parse error")"
        # Verify JSON validity
        if python3 -c "
import sys, json
with open('$f') as fp:
    for i, line in enumerate(fp, 1):
        try:
            obj = json.loads(line)
            if 'tag' not in obj:
                print(f'  Line {i}: missing tag field')
                sys.exit(1)
        except json.JSONDecodeError as e:
            print(f'  Line {i}: invalid JSON: {e}')
            sys.exit(1)
print('    JSON valid: all lines pass')
" 2>/dev/null; then
            true
        else
            echo "    JSON validation: FAILED"
        fi
    fi
done

# Step 6: Revert artifact
echo ""
echo "--- Step 5: Reverting artifact..."
(cd "$ARTIFACT_DIR" && git checkout -- .)

echo ""
echo "=== Done ==="
