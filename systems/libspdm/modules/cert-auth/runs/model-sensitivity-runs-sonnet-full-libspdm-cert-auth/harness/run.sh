#!/bin/bash
# run.sh — Apply instrumentation, build, run tests, collect traces.
#
# Usage (from experiment root OR from any directory):
#   bash harness/run.sh
#
# Output: traces/happy_path.ndjson  traces/no_cert_challenge.ndjson
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ARTIFACT_DIR="$ROOT_DIR/artifact/libspdm"
BUILD_DIR="$ROOT_DIR/build/libspdm"
TRACES_DIR="$ROOT_DIR/traces"
SAMPLE_KEY_DIR="$ARTIFACT_DIR/unit_test/sample_key"

echo "=== Phase 2.5 run.sh ==="
echo "  root:   $ROOT_DIR"
echo "  build:  $BUILD_DIR"
echo "  traces: $TRACES_DIR"
echo ""

# ─── 1. Apply instrumentation ───────────────────────────────────────────────
echo "[1/5] Applying instrumentation..."
bash "$SCRIPT_DIR/apply.sh"

# ─── 2. CMake configure ─────────────────────────────────────────────────────
echo "[2/5] Configuring build..."
mkdir -p "$BUILD_DIR"

CRYPTO="${CRYPTO:-openssl}"
TOOLCHAIN="${TOOLCHAIN:-GCC}"

cmake -S "$ARTIFACT_DIR" \
      -B "$BUILD_DIR" \
      -DARCH=x64 \
      -DTOOLCHAIN="$TOOLCHAIN" \
      -DTARGET=Debug \
      -DCRYPTO="$CRYPTO" \
      -DENABLE_BINARY_BUILD=1 \
      -DLIBSPDM_DIR="$ARTIFACT_DIR" \
      -DDEVICE=sample \
      2>&1 | tail -5

# ─── 3. Build ───────────────────────────────────────────────────────────────
echo "[3/5] Building (target: trace_harness)..."
make -C "$BUILD_DIR" -j"$(nproc)" trace_harness 2>&1

# ─── 4. Run test scenarios ───────────────────────────────────────────────────
echo "[4/5] Running test scenarios..."
mkdir -p "$TRACES_DIR"

# Find the trace_harness binary
BINARY=$(find "$BUILD_DIR" -name "trace_harness" -type f | head -1)
if [ -z "$BINARY" ]; then
    echo "ERROR: trace_harness binary not found under $BUILD_DIR"
    exit 1
fi
echo "  binary: $BINARY"

# Run from sample_key directory so cert reading finds ecp256/
cd "$SAMPLE_KEY_DIR"
timeout 120 "$BINARY" "$TRACES_DIR"
cd -

# ─── 5. Report ───────────────────────────────────────────────────────────────
echo "[5/5] Trace summary:"
for f in "$TRACES_DIR"/*.ndjson; do
    if [ -f "$f" ]; then
        count=$(wc -l < "$f")
        echo "  $(basename "$f"): $count events"
        echo "  First 5 trace events:"
        python3 -c "
import sys, json
count = 0
with open('$f') as fh:
    for line in fh:
        line=line.strip()
        if not line: continue
        try:
            o=json.loads(line)
            if o.get('tag')=='trace' and count < 5:
                extras = ''
                for k in ('slot','verify_result','in_session','cert_fetched','cert_hash_valid','status'):
                    if k in o:
                        extras += ' %s=%s' % (k, o[k])
                print('    event=%-30s node=%-10s state=%s%s' % (o.get('event','?'), o.get('node','?'), o.get('connection_state','?'), extras))
                count += 1
        except: pass
" 2>/dev/null || true
    fi
done

echo ""
echo "=== Done. Traces in $TRACES_DIR/ ==="
