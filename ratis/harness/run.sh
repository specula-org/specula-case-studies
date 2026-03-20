#!/usr/bin/env bash
# Build instrumented ratis, run test scenarios, collect traces.
# Run from case-studies/ratis/ directory.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT="$CASE_DIR/artifact/ratis"
TRACES_DIR="$CASE_DIR/traces"

echo "=== Ratis TLA+ Trace Harness ==="
echo "Case dir: $CASE_DIR"
echo "Artifact: $ARTIFACT"
echo ""

# 1. Apply instrumentation
bash "$SCRIPT_DIR/apply.sh"
echo ""

# 2. Build the project (compile ratis-server and its dependencies)
echo "=== Building ratis ==="
cd "$ARTIFACT"
# Build only what we need: proto, common, server-api, client, server
mvn install -DskipTests -pl ratis-proto,ratis-common,ratis-server-api,ratis-client,ratis-server -am -q 2>&1 | tail -5
echo "Build complete."
echo ""

# 3. Prepare traces directory
mkdir -p "$TRACES_DIR"

# 4. Run test scenarios
echo "=== Running trace scenarios ==="

# Scenario 1: Basic consensus
echo "  Running basic_consensus..."
cd "$ARTIFACT"
RATIS_TLA_TRACE_DIR="$TRACES_DIR" \
mvn test -pl ratis-server \
    -Dtest=TlaTraceTest#testBasicConsensus \
    -DfailIfNoTests=false \
    -Dsurefire.useFile=false \
    -q 2>&1 | tail -20
echo ""

# Scenario 2: Leader re-election
echo "  Running leader_reelection..."
cd "$ARTIFACT"
RATIS_TLA_TRACE_DIR="$TRACES_DIR" \
mvn test -pl ratis-server \
    -Dtest=TlaTraceTest#testLeaderReelection \
    -DfailIfNoTests=false \
    -Dsurefire.useFile=false \
    -q 2>&1 | tail -20
echo ""

# 5. Report trace results
echo "=== Trace Results ==="
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        lines=$(wc -l < "$f")
        echo "  $(basename "$f"): $lines lines"
        # Show event distribution
        echo "    Events: $(python3 -c "
import json, sys, collections
events = collections.Counter()
for line in open('$f'):
    try:
        d = json.loads(line)
        if 'event' in d:
            events[d['event']] += 1
    except: pass
for e, c in events.most_common():
    print(f'{e}={c}', end=' ')
print()
" 2>/dev/null || echo "(install python3 for event summary)")"
    fi
done

echo ""
echo "=== Spot-checking trace format ==="
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        echo "  $(basename "$f"):"
        # Verify all lines are valid JSON
        invalid=$(python3 -c "
import json, sys
count = 0
for i, line in enumerate(open('$f'), 1):
    try:
        json.loads(line)
    except:
        count += 1
        if count <= 3:
            print(f'    INVALID JSON at line {i}', file=sys.stderr)
print(count)
" 2>&1)
        if [ "$invalid" = "0" ]; then
            echo "    All lines valid JSON: OK"
        else
            echo "    WARNING: $invalid invalid JSON lines"
        fi
        # Check timestamps are real (not sequential integers)
        python3 -c "
import json
ts = []
for line in open('$f'):
    try:
        d = json.loads(line)
        if 'ts' in d:
            ts.append(d['ts'])
    except: pass
if len(ts) >= 2:
    diffs = [ts[i+1] - ts[i] for i in range(min(5, len(ts)-1))]
    if all(d == diffs[0] for d in diffs) and diffs[0] < 10:
        print('    WARNING: Timestamps look sequential/synthetic')
    else:
        print('    Timestamps look real: OK')
" 2>/dev/null || true
    fi
done

echo ""
echo "=== Done. Traces in: $TRACES_DIR ==="
