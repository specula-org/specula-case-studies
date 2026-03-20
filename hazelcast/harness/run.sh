#!/usr/bin/env bash
# Build and run TLA+ trace generation for Hazelcast Raft CP Subsystem.
# Usage: cd case-studies/hazelcast && bash harness/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="$CASE_DIR/artifact/hazelcast"
TRACE_DIR="$CASE_DIR/traces"
HZ_MODULE="$ARTIFACT_DIR/hazelcast"

echo "=========================================="
echo " Hazelcast Raft TLA+ Trace Harness"
echo "=========================================="

# Step 1: Apply instrumentation
echo ""
echo "[Step 1] Applying instrumentation..."
bash "$SCRIPT_DIR/apply.sh"

# Step 2: Install dependencies and build
echo ""
echo "[Step 2] Installing hazelcast-tpc-engine dependency..."
cd "$ARTIFACT_DIR"
mvn install -pl hazelcast-tpc-engine -am \
    -Dcheckstyle.skip=true -Dspotbugs.skip=true -Denforcer.skip=true \
    -Dmaven.javadoc.skip=true -Dpmd.skip=true -DskipTests=true \
    -q 2>&1 | tail -5

echo "Building hazelcast module (test-compile)..."
mvn -pl hazelcast test-compile \
    -Dcheckstyle.skip=true \
    -Dspotbugs.skip=true \
    -Denforcer.skip=true \
    -Dmaven.javadoc.skip=true \
    -Dpmd.skip=true \
    -DskipTests=true \
    -q 2>&1 | tail -20
echo "Build completed."

# Step 3: Ensure traces directory exists
mkdir -p "$TRACE_DIR"

# Step 4: Run trace generation tests
echo ""
echo "[Step 3] Running trace generation tests..."
cd "$ARTIFACT_DIR"

# Set trace output directory
export TLA_TRACE_DIR="$TRACE_DIR"

# Run TlaTraceTest specifically
mvn -pl hazelcast test \
    -Dtest=com.hazelcast.cp.internal.raft.impl.TlaTraceTest \
    -DfailIfNoTests=false \
    -Dcheckstyle.skip=true \
    -Dspotbugs.skip=true \
    -Denforcer.skip=true \
    -Dmaven.javadoc.skip=true \
    -Dpmd.skip=true \
    -Dhazelcast.phone.home.enabled=false \
    -Dhazelcast.test.use.network=false \
    2>&1 | tail -30

echo ""
echo "[Step 4] Trace collection results:"
echo "=========================================="
if [ -d "$TRACE_DIR" ]; then
    for f in "$TRACE_DIR"/*.ndjson; do
        if [ -f "$f" ]; then
            lines=$(wc -l < "$f")
            echo "  $(basename "$f"): $lines events"
        fi
    done
else
    echo "  ERROR: No trace directory found"
    exit 1
fi

# Step 5: Validate trace format
echo ""
echo "[Step 5] Quick trace format check..."
errors=0
for f in "$TRACE_DIR"/*.ndjson; do
    [ -f "$f" ] || continue
    name=$(basename "$f")
    # Check each line is valid JSON
    if ! python3 -c "
import json, sys
with open('$f') as fh:
    for i, line in enumerate(fh, 1):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError as e:
            print(f'  $name line {i}: invalid JSON: {e}', file=sys.stderr)
            sys.exit(1)
        if 'tag' not in obj:
            print(f'  $name line {i}: missing tag field', file=sys.stderr)
            sys.exit(1)
        if obj['tag'] == 'trace':
            if 'event' not in obj:
                print(f'  $name line {i}: trace line missing event', file=sys.stderr)
                sys.exit(1)
            if 'node' not in obj:
                print(f'  $name line {i}: trace line missing node', file=sys.stderr)
                sys.exit(1)
            if 'state' not in obj:
                print(f'  $name line {i}: trace line missing state', file=sys.stderr)
                sys.exit(1)
            ts = obj.get('ts', 0)
            if isinstance(ts, int) and ts < 10000:
                print(f'  $name line {i}: suspicious timestamp {ts} (too small)', file=sys.stderr)
                sys.exit(1)
print(f'  $name: OK')
" 2>&1; then
        ((errors++)) || true
    fi
done

if [ "$errors" -gt 0 ]; then
    echo "  $errors trace file(s) had format issues"
else
    echo "  All traces passed format check"
fi

echo ""
echo "=========================================="
echo " Traces written to: $TRACE_DIR/"
echo "=========================================="
