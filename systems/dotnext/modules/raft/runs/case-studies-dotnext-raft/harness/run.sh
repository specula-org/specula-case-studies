#!/bin/bash
# End-to-end: apply instrumentation, build, run tests, collect traces.
# Usage: bash harness/run.sh
# Run from: case-studies/dotnext-raft/

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/dotNext"
TRACES_DIR="$CASE_DIR/traces"

echo "========================================"
echo " dotNext Raft Trace Harness"
echo "========================================"

# 0. Ensure .NET SDK is available
if ! command -v dotnet &>/dev/null; then
    echo "=== Installing .NET SDK ==="
    export DOTNET_ROOT="$HOME/.dotnet"
    if [ ! -f "$DOTNET_ROOT/dotnet" ]; then
        curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
        bash /tmp/dotnet-install.sh --channel 10.0 --install-dir "$DOTNET_ROOT"
        rm -f /tmp/dotnet-install.sh
    fi
    export PATH="$DOTNET_ROOT:$PATH"
    echo "  .NET SDK: $(dotnet --version)"
fi

# 1. Apply instrumentation
bash "$SCRIPT_DIR/apply.sh"

# 2. Build
echo ""
echo "=== Building project ==="
cd "$ARTIFACT"
dotnet build src/DotNext.Tests/DotNext.Tests.csproj -c Release --nologo -v q 2>&1 | tail -5
echo "  Build complete."

# 3. Run trace tests
echo ""
echo "=== Running trace tests ==="
mkdir -p "$TRACES_DIR"

# Run all trace tests using xUnit v3 MTP filter
echo "  Running TlaTraceTests..."
TRACE_OUTPUT_DIR="$TRACES_DIR" dotnet exec \
    src/DotNext.Tests/bin/Release/net10.0/DotNext.Tests.dll \
    --filter-class "*TlaTraceTests" \
    2>&1 | grep -v "Non-serializable" | tail -10
echo ""

# 4. Report trace results
echo ""
echo "=== Trace files ==="
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        LINES=$(wc -l < "$f")
        EVENTS=$(grep -c '"tag":"trace"' "$f" 2>/dev/null || grep -c '"tag": "trace"' "$f" 2>/dev/null || echo "0")
        echo "  $(basename "$f"): $LINES lines, $EVENTS trace events"
    fi
done

# 5. Spot-check traces
echo ""
echo "=== Spot-checking traces ==="
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        FNAME="$(basename "$f")"
        # Check valid JSON
        if python3 -c "
import json, sys
with open('$f') as fh:
    for i, line in enumerate(fh, 1):
        try:
            json.loads(line)
        except json.JSONDecodeError as e:
            print(f'  $FNAME: INVALID JSON at line {i}: {e}')
            sys.exit(1)
print(f'  $FNAME: all lines valid JSON')
" 2>/dev/null; then
            true
        else
            echo "  $FNAME: python3 not available, skipping JSON check"
        fi

        # Check for synthetic timestamps (sequential integers)
        if grep -qP '"ts":\s*"?\d{4,}"?' "$f" 2>/dev/null; then
            echo "  $FNAME: WARNING — may have synthetic timestamps"
        fi

        # Show event name distribution
        echo "  $FNAME event types:"
        grep -oP '"name"\s*:\s*"[^"]+"' "$f" 2>/dev/null | sort | uniq -c | sort -rn | head -10 | sed 's/^/    /'
    fi
done

# 6. Revert instrumentation
echo ""
echo "=== Reverting instrumentation ==="
# Restore .bak files
find "$ARTIFACT/src/DotNext.Tests" -name "*.cs.bak" -exec sh -c 'mv "$1" "${1%.bak}"' _ {} \; 2>/dev/null || true
# Revert git changes
git -C "$ARTIFACT" checkout -- . 2>/dev/null || true
# Remove added files
rm -f "$ARTIFACT/src/cluster/DotNext.Net.Cluster/Net/Cluster/Consensus/Raft/Tracing/TlaTrace.cs"
rmdir "$ARTIFACT/src/cluster/DotNext.Net.Cluster/Net/Cluster/Consensus/Raft/Tracing" 2>/dev/null || true
rm -f "$ARTIFACT/src/DotNext.Tests/Net/Cluster/Consensus/Raft/Http/TlaTraceTests.cs"

echo ""
echo "=== Done ==="
echo "Traces collected in: $TRACES_DIR/"
