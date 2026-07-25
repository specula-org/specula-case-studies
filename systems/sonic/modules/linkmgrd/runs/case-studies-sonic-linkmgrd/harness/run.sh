#!/bin/bash
# run.sh — One-command: apply instrumentation, build, run tests, collect traces
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$SCRIPT_DIR/../artifact/sonic-linkmgrd"
TRACES_DIR="$SCRIPT_DIR/../traces"

mkdir -p "$TRACES_DIR"

# Step 1: Apply instrumentation
echo "================================================================"
echo "[Step 1/5] Applying instrumentation..."
echo "================================================================"
bash "$SCRIPT_DIR/apply.sh"

# Step 2: Build instrumented test binary
echo ""
echo "================================================================"
echo "[Step 2/5] Building instrumented test binary..."
echo "================================================================"
cd "$ARTIFACT_DIR"
make clean-targets 2>/dev/null || true
# Build test target (includes all test files and source files)
make -j"$(nproc)" test-targets CPP_FLAGS="-O0 -Wall -c -fmessage-length=0 -fPIC -fprofile-arcs -ftest-coverage -DLINKMGRD_TRACE" 2>&1 | tail -5 || {
    echo "[ERROR] Build failed. Dumping last 30 lines of output:"
    make -j1 test-targets CPP_FLAGS="-O0 -Wall -c -fmessage-length=0 -fPIC -fprofile-arcs -ftest-coverage -DLINKMGRD_TRACE" 2>&1 | tail -30
    exit 1
}

# Step 3: Run test scenarios and collect traces
echo ""
echo "================================================================"
echo "[Step 3/5] Running test scenarios and collecting traces..."
echo "================================================================"

# Scenario 1: Normal Active-Active operation (MuxActive, link events, heartbeats)
echo "  Scenario: normal_active_active..."
LINKMGRD_TRACE_FILE="$TRACES_DIR/normal_active_active.ndjson" \
    ./linkmgrd-test --gtest_filter="LinkManagerStateMachineActiveActiveTest.MuxActive:LinkManagerStateMachineActiveActiveTest.MuxActiveLinkProberUnknown:LinkManagerStateMachineActiveActiveTest.MuxStandby" 2>/dev/null || true
echo "    -> $(wc -l < "$TRACES_DIR/normal_active_active.ndjson" 2>/dev/null || echo 0) lines"

# Scenario 2: Mode changes and mux switching
echo "  Scenario: mode_changes..."
LINKMGRD_TRACE_FILE="$TRACES_DIR/mode_changes.ndjson" \
    ./linkmgrd-test --gtest_filter="LinkManagerStateMachineActiveActiveTest.*Mode*:LinkManagerStateMachineActiveActiveTest.*Config*" 2>/dev/null || true
echo "    -> $(wc -l < "$TRACES_DIR/mode_changes.ndjson" 2>/dev/null || echo 0) lines"

# Scenario 3: Default route changes and link flaps
echo "  Scenario: default_route..."
LINKMGRD_TRACE_FILE="$TRACES_DIR/default_route.ndjson" \
    ./linkmgrd-test --gtest_filter="LinkManagerStateMachineActiveActiveTest.*DefaultRoute*:LinkManagerStateMachineActiveActiveTest.*LinkDown*" 2>/dev/null || true
echo "    -> $(wc -l < "$TRACES_DIR/default_route.ndjson" 2>/dev/null || echo 0) lines"

# Scenario 4: Peer state changes
echo "  Scenario: peer_state..."
LINKMGRD_TRACE_FILE="$TRACES_DIR/peer_state.ndjson" \
    ./linkmgrd-test --gtest_filter="LinkManagerStateMachineActiveActiveTest.*Peer*" 2>/dev/null || true
echo "    -> $(wc -l < "$TRACES_DIR/peer_state.ndjson" 2>/dev/null || echo 0) lines"

# Scenario 5: All active-active tests (comprehensive trace)
echo "  Scenario: all_active_active..."
LINKMGRD_TRACE_FILE="$TRACES_DIR/all_active_active.ndjson" \
    ./linkmgrd-test --gtest_filter="LinkManagerStateMachineActiveActiveTest.*" 2>/dev/null || true
echo "    -> $(wc -l < "$TRACES_DIR/all_active_active.ndjson" 2>/dev/null || echo 0) lines"

# Step 4: Report trace summary
echo ""
echo "================================================================"
echo "[Step 4/5] Trace collection summary"
echo "================================================================"
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        lines=$(wc -l < "$f")
        events=$(python3 -c "
import json, sys, collections
counts = collections.Counter()
with open('$f') as fh:
    for line in fh:
        try:
            obj = json.loads(line)
            if obj.get('tag') == 'linkmgrd':
                counts[obj['event']] += 1
        except: pass
for k,v in sorted(counts.items()):
    print(f'    {k}: {v}')
" 2>/dev/null || echo "    (parse error)")
        echo "  $(basename "$f"): $lines lines"
        echo "$events"
    fi
done

# Step 5: Quick validation check
echo ""
echo "================================================================"
echo "[Step 5/5] Spot-checking trace format..."
echo "================================================================"
python3 -c "
import json, sys
traces = ['$TRACES_DIR/normal_active_active.ndjson', '$TRACES_DIR/all_active_active.ndjson']
ok = True
for path in traces:
    try:
        with open(path) as f:
            lines = f.readlines()
        if not lines:
            print(f'  WARNING: {path} is empty')
            ok = False
            continue
        bad = 0
        for i, line in enumerate(lines):
            try:
                obj = json.loads(line)
                if 'tag' not in obj:
                    print(f'  WARNING: {path}:{i+1} missing tag field')
                    bad += 1
            except json.JSONDecodeError:
                print(f'  ERROR: {path}:{i+1} invalid JSON')
                bad += 1
        if bad == 0:
            print(f'  OK: {path} ({len(lines)} lines, all valid JSON)')
        else:
            print(f'  WARN: {path} ({bad} issues)')
            ok = False
    except FileNotFoundError:
        print(f'  SKIP: {path} not found')
if ok:
    print('  All checks passed.')
else:
    print('  Some issues found — see above.')
"

# Restore artifact
echo ""
echo "[cleanup] Restoring artifact to clean state..."
git -C "$ARTIFACT_DIR" checkout -- .

echo ""
echo "Done. Traces in: $TRACES_DIR/"
