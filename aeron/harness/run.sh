#!/bin/bash
# Build instrumented Aeron and run trace-generating tests.
# Run from case-studies/aeron/ directory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="$CASE_DIR/artifact/aeron"
TRACES_DIR="$CASE_DIR/traces"

echo "=== Aeron TLA+ Trace Generation ==="
echo "Case dir:     $CASE_DIR"
echo "Artifact dir: $ARTIFACT_DIR"
echo "Traces dir:   $TRACES_DIR"

# 1. Apply instrumentation
echo ""
echo "--- Step 1: Apply instrumentation ---"
bash "$SCRIPT_DIR/apply.sh"

# 2. Build aeron-cluster (compile only, skip non-cluster tests)
echo ""
echo "--- Step 2: Build aeron-cluster ---"
cd "$ARTIFACT_DIR"
./gradlew :aeron-cluster:compileJava :aeron-cluster:compileTestJava --no-daemon -q 2>&1 || {
    echo "ERROR: Build failed"
    exit 1
}
echo "Build successful"

# 3. Create traces directory
mkdir -p "$TRACES_DIR"

# 4. Run trace-generating tests
echo ""
echo "--- Step 3: Run trace tests ---"

# Clean test cache to ensure re-runs pick up env vars
./gradlew :aeron-cluster:cleanTest --no-daemon -q 2>&1

# Test 1: basic_election
echo "  Running basicElection..."
TLA_TRACE_FILE="$TRACES_DIR/basic_election.ndjson" \
    ./gradlew :aeron-cluster:test --tests "io.aeron.cluster.TlaTraceElectionTest.basicElection" \
    --no-daemon -q 2>&1 || {
    echo "  WARN: basicElection test may have had issues (checking trace anyway)"
}

# Clean again between tests since TLA_TRACE_FILE changes
./gradlew :aeron-cluster:cleanTest --no-daemon -q 2>&1

# Test 2: electionCommitPosition
echo "  Running electionCommitPosition..."
TLA_TRACE_FILE="$TRACES_DIR/election_commit_position.ndjson" \
    ./gradlew :aeron-cluster:test --tests "io.aeron.cluster.TlaTraceElectionTest.electionCommitPosition" \
    --no-daemon -q 2>&1 || {
    echo "  WARN: electionCommitPosition test may have had issues (checking trace anyway)"
}

# 5. Report results
echo ""
echo "--- Step 4: Trace summary ---"
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        lines=$(wc -l < "$f")
        echo "  $(basename "$f"): $lines lines"
        # Show first 3 lines for sanity
        echo "    First events:"
        head -3 "$f" | while read -r line; do
            action=$(echo "$line" | grep -o '"action":"[^"]*"' | head -1)
            echo "      $action"
        done
    fi
done

# 6. Validate JSON format
echo ""
echo "--- Step 5: JSON validation ---"
all_valid=true
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        # Check each line is valid JSON using python
        if python3 -c "
import json, sys
with open('$f') as fh:
    for i, line in enumerate(fh, 1):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            if 'action' not in obj:
                print(f'  WARN: line {i} missing \"action\" field')
        except json.JSONDecodeError as e:
            print(f'  ERROR: line {i} invalid JSON: {e}')
            sys.exit(1)
print(f'  $(basename "$f"): all lines valid JSON')
" 2>&1; then
            :
        else
            all_valid=false
        fi
    fi
done

if [ "$all_valid" = true ]; then
    echo "All traces are valid NDJSON"
else
    echo "WARNING: Some traces have JSON issues"
fi

echo ""
echo "=== Trace generation complete ==="
echo "Traces are in: $TRACES_DIR/"
