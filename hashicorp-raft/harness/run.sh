#!/usr/bin/env bash
# run.sh — Build and run all trace scenarios, collect traces.
#
# Usage: cd case-studies/hashicorp-raft && bash harness/run.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$SCRIPT_DIR/src"
TRACE_DIR="$CASE_DIR/traces"

export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"

echo "=== Step 1: Verify instrumentation ==="
bash "$SCRIPT_DIR/apply.sh"

echo ""
echo "=== Step 2: Build harness ==="
cd "$SRC_DIR"
go mod tidy
go build -o "$SRC_DIR/harness" .
echo "Harness built: $SRC_DIR/harness"

echo ""
echo "=== Step 3: Run scenarios ==="
mkdir -p "$TRACE_DIR"

SCENARIOS="basic_election client_request leader_failure config_change"
for sc in $SCENARIOS; do
    echo ""
    echo "--- Running scenario: $sc ---"
    "$SRC_DIR/harness" -scenario "$sc" -out "$TRACE_DIR/${sc}.ndjson" 2>&1 || {
        echo "WARNING: scenario $sc failed" >&2
        continue
    }
done

echo ""
echo "=== Step 4: Trace summary ==="
for f in "$TRACE_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        lines=$(wc -l < "$f")
        trace_lines=$(grep -c '"tag":"trace"' "$f" 2>/dev/null || echo 0)
        echo "$(basename "$f"): $lines lines ($trace_lines trace events)"
    fi
done

echo ""
echo "=== Step 5: Spot-check traces ==="
for f in "$TRACE_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        echo ""
        echo "--- $(basename "$f") ---"
        # Verify valid JSON
        if ! head -1 "$f" | python3 -m json.tool > /dev/null 2>&1; then
            echo "WARNING: first line is not valid JSON"
        else
            echo "JSON format: OK"
        fi
        # Show first trace event
        grep '"tag":"trace"' "$f" | head -1 | python3 -c "
import sys, json
line = json.loads(sys.stdin.readline())
evt = line.get('event', {})
print(f\"  First event: {evt.get('name', '?')} nid={evt.get('nid', '?')} term={evt.get('state', {}).get('term', '?')}\")
" 2>/dev/null || true
        # Show last trace event
        grep '"tag":"trace"' "$f" | tail -1 | python3 -c "
import sys, json
line = json.loads(sys.stdin.readline())
evt = line.get('event', {})
print(f\"  Last event:  {evt.get('name', '?')} nid={evt.get('nid', '?')} term={evt.get('state', {}).get('term', '?')}\")
" 2>/dev/null || true
        # Check timestamps are real (not sequential integers)
        grep '"tag":"trace"' "$f" | head -3 | python3 -c "
import sys, json
for line in sys.stdin:
    obj = json.loads(line)
    ts = str(obj.get('ts', ''))
    if ts.isdigit() and len(ts) < 6:
        print('  WARNING: timestamp looks synthetic:', ts)
        break
else:
    print('  Timestamps: real')
" 2>/dev/null || true
    fi
done

echo ""
echo "=== Done ==="
echo "Traces in: $TRACE_DIR/"
