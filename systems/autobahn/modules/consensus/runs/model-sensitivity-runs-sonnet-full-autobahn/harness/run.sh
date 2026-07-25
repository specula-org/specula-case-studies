#!/bin/bash
# run.sh — apply instrumentation, build, run trace-collection tests, collect traces.
#
# Usage: bash harness/run.sh   (from the .specula-output/ directory)
#
# Outputs:
#   traces/autobahn_happy_path.ndjson    — normal consensus round
#   traces/autobahn_multi_slot.ndjson    — two consecutive slots (triggers CleanSlotPeriods)
#   traces/autobahn_timeout.ndjson       — timeout → TC → SendPrepare
#   traces/autobahn_leader_prepare.ndjson — leader-side events
#   traces/hotstuff_chain.ndjson         — HotStuff block chain (HSMakeVote + HSProcessBlock)
#   traces/hotstuff_crash_recover.ndjson  — HSCrashRecover scenario

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
ARTIFACT="$ROOT/artifact/autobahn"
TRACES_DIR="$ROOT/traces"

mkdir -p "$TRACES_DIR"

echo "=== Phase 1: Apply instrumentation ==="
bash "$SCRIPT_DIR/apply.sh"

echo ""
echo "=== Phase 2: Build (primary + hotstuff) ==="
cd "$ARTIFACT"
timeout 600 cargo build -p primary -p hotstuff 2>&1 | grep -E "^error|Compiling|Finished" || true

echo ""
echo "=== Phase 3: Run primary (Autobahn) trace scenarios ==="
export TRACE_DIR="$TRACES_DIR"
export RUST_LOG=error

timeout 300 cargo test -p primary \
    -- trace_tests:: --test-threads=1 --nocapture \
    2>&1 | grep -E "trace_|events|PASSED|FAILED|ok\." || true

echo ""
echo "=== Phase 4: Run hotstuff trace scenarios ==="
timeout 300 cargo test -p hotstuff \
    -- hs_trace_tests:: --test-threads=1 --nocapture \
    2>&1 | grep -E "trace_|events|PASSED|FAILED|ok\." || true

echo ""
echo "=== Phase 5: Trace summary ==="
total_events=0
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        count=$(wc -l < "$f" 2>/dev/null || echo 0)
        total_events=$((total_events + count))
        echo "  $(basename "$f"): $count events"
    fi
done
echo "  TOTAL: $total_events events across $(ls "$TRACES_DIR"/*.ndjson 2>/dev/null | wc -l) files"

echo ""
echo "=== Phase 6: Event type coverage ==="
if command -v python3 &>/dev/null; then
    cat "$TRACES_DIR"/*.ndjson 2>/dev/null | python3 -c "
import sys, json
events = {}
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        ev = obj.get('event', '?')
        events[ev] = events.get(ev, 0) + 1
    except: pass
for ev, cnt in sorted(events.items()):
    print(f'  {ev}: {cnt}')
print(f'  --- {len(events)} unique event types ---')
" || true
fi

echo ""
echo "=== run.sh complete ==="
