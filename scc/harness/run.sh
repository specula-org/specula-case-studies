#!/bin/bash
# Run trace validation for all scc traces
# Usage: bash harness/run.sh

set -e
SPEC_DIR="$(cd "$(dirname "$0")/../spec" && pwd)"
TRACES_DIR="$(cd "$(dirname "$0")/../traces" && pwd)"
TLA2TOOLS="/home/ubuntu/Specula/lib/tla2tools.jar"
COMMUNITY="/home/ubuntu/Specula/lib/CommunityModules-deps.jar"

echo "=== scc Trace Validation ==="

for trace in "$TRACES_DIR"/*.ndjson; do
    name=$(basename "$trace")
    echo ""
    echo "--- Validating: $name ---"
    java -cp "$TLA2TOOLS:$COMMUNITY" \
        -DJSON="$trace" \
        tlc2.TLC \
        -config Trace.cfg \
        -workers 1 \
        -cleanup \
        "$SPEC_DIR/Trace.tla" 2>&1 | tail -20
done

echo ""
echo "=== Done ==="
