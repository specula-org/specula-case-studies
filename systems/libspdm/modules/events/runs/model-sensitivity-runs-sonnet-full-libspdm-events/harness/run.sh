#!/usr/bin/env bash
# run.sh — Apply instrumentation, build, run scenarios, collect traces.
#
# Usage: bash harness/run.sh
# (Run from the libspdm-events/ project directory or the harness/ directory.)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."
ARTIFACT="${PROJECT_DIR}/artifact/libspdm"
BUILD_DIR="${PROJECT_DIR}/build"
TRACES_DIR="${PROJECT_DIR}/traces"

echo "=== Phase 2.5: TLA+ Trace Collection ==="

# ---- Step 1: Apply instrumentation ----------------------------------------
bash "${SCRIPT_DIR}/apply.sh"

# ---- Step 2: Build -----------------------------------------------------------
echo "[build] Configuring with cmake (crypto=mbedtls, ARCH=x64)..."
mkdir -p "${BUILD_DIR}"
cmake -S "${ARTIFACT}" -B "${BUILD_DIR}" \
    -DARCH=x64 \
    -DTOOLCHAIN=GCC \
    -DTARGET=Debug \
    -DCRYPTO=mbedtls \
    -DGCOV=OFF \
    -DDEVICE=sample \
    -DCMAKE_BUILD_TYPE=Debug \
    2>&1 | tail -10

echo "[build] Building test_tla_trace..."
timeout 300 cmake --build "${BUILD_DIR}" --target test_tla_trace -j"$(nproc)" 2>&1

# ---- Step 3: Run scenarios ---------------------------------------------------
echo "[run] Creating traces directory..."
mkdir -p "${TRACES_DIR}"

echo "[run] Executing trace scenarios..."
# Must cd to sample_key so cert paths like ecp256/bundle_responder.certchain.der resolve.
SAMPLE_KEY_DIR="${ARTIFACT}/unit_test/sample_key"
(cd "${SAMPLE_KEY_DIR}" && \
 TLA_TRACES_DIR="${TRACES_DIR}" timeout 120 "${BUILD_DIR}/bin/test_tla_trace" 2>&1) || {
    echo "[warn] Test runner exited with non-zero status (cmocka reports failures)."
    echo "       Checking if trace files were created anyway..."
}

# ---- Step 4: Report ----------------------------------------------------------
echo ""
echo "=== Trace Collection Report ==="
for f in "${TRACES_DIR}"/*.ndjson; do
    if [ -f "$f" ]; then
        lines=$(wc -l < "$f")
        echo "  $(basename "$f"): ${lines} events"
        # Spot-check: first event
        echo "    first: $(head -1 "$f" | python3 -c 'import sys,json; e=json.loads(sys.stdin.read()); print(e["event"])' 2>/dev/null || echo '<parse error>')"
    fi
done

echo ""
echo "=== Event type coverage ==="
for f in "${TRACES_DIR}"/*.ndjson; do
    if [ -f "$f" ]; then
        echo "  $(basename "$f"):"
        python3 -c "
import sys, json
events = set()
for line in open('$f'):
    try:
        e = json.loads(line.strip())
        if e.get('tag') == 'trace':
            events.add(e.get('event','?'))
    except:
        pass
for ev in sorted(events):
    print('    ' + ev)
" 2>/dev/null || echo "    <parse error>"
    fi
done

echo ""
echo "=== Done ==="
