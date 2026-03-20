#!/bin/bash
# Build and run nuraft trace tests, collect traces.
# Usage: cd case-studies/nuraft && bash harness/run.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$SCRIPT_DIR/.."
ARTIFACT_DIR="$CASE_DIR/artifact/nuraft"
TRACE_DIR="$CASE_DIR/traces"
BUILD_DIR="$ARTIFACT_DIR/build"

echo "=== nuraft Trace Harness ==="

# 1. Apply instrumentation
echo "[1/5] Applying instrumentation..."
bash "$SCRIPT_DIR/apply.sh"

# 2. Build with trace enabled
echo "[2/5] Building with NURAFT_TLA_TRACE=ON..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
cmake .. \
    -DNURAFT_TLA_TRACE=ON \
    -DDISABLE_SSL=1 \
    -DCMAKE_BUILD_TYPE=Debug \
    -DBUILD_EXAMPLES=OFF \
    2>&1 | tail -5
make -j"$(nproc)" trace_test 2>&1 | tail -5
echo "Build complete."

# 3. Run test scenarios
echo "[3/5] Running test scenarios..."
mkdir -p "$TRACE_DIR"

NURAFT_TRACE_FILE="$TRACE_DIR/basic_consensus.ndjson" \
    "$BUILD_DIR/tests/trace_test" --abort-on-failure 2>&1 | tail -5
echo "Test complete."

# 4. Report trace statistics
echo "[4/5] Trace statistics:"
for f in "$TRACE_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        lines=$(wc -l < "$f")
        name=$(basename "$f")
        echo "  $name: $lines events"
        # Validate JSON
        python3 -c "
import json, sys
ok = True
with open('$f') as fh:
    for i, line in enumerate(fh, 1):
        try:
            obj = json.loads(line)
            assert 'tag' in obj and obj['tag'] == 'trace', f'Line {i}: missing tag'
            assert 'event' in obj, f'Line {i}: missing event'
            assert 'nid' in obj, f'Line {i}: missing nid'
        except Exception as e:
            print(f'  ERROR: {e}', file=sys.stderr)
            ok = False
if ok:
    print(f'  JSON validation: OK')
else:
    print(f'  JSON validation: FAILED')
    sys.exit(1)
"
    fi
done

# 5. Event type summary
echo "[5/5] Event types:"
python3 -c "
import json
for fname in ['$TRACE_DIR/basic_consensus.ndjson']:
    events = {}
    with open(fname) as f:
        for line in f:
            obj = json.loads(line)
            ev = obj['event']
            events[ev] = events.get(ev, 0) + 1
    for k, v in sorted(events.items()):
        print(f'  {k}: {v}')
    print(f'  Total: {sum(events.values())} events, {len(events)} types')
"

echo ""
echo "=== Done. Traces in: $TRACE_DIR ==="
echo "To validate with TLC:"
echo "  cd spec && java -jar ../../lib/tla2tools.jar -config Trace.cfg -deadlock -DJSON=../traces/basic_consensus.ndjson Trace"
