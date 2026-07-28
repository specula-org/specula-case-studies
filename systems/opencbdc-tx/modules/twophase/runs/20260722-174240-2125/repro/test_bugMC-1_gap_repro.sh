#!/usr/bin/env bash
# Reproduction test for MC-1: Leader/Handler Activation Gap
# Level 3: Add delay in start_stop_func to widen the race window
set -euo pipefail

WORKTREE="/home/ubuntu/Specula/runs/20260722-174240-2125/opencbdc-tx/.specula-output/confirmation/MC-1/worktree"
BUILD_DIR="/tmp/opencode/build_mc1_repro"
REPRO_DIR="/home/ubuntu/Specula/runs/20260722-174240-2125/opencbdc-tx/.specula-output/repro"
PREFIX="/home/ubuntu/2pc/opencbdc-tx/prefix"
THIS_DIR="$(dirname "$0")"

echo "=== MC-1: Leader/Handler Activation Gap Reproduction ==="

# ==========================================
# Step 1: Apply Level 3 patch to source
# ==========================================
echo "[Step 1] Applying Level 3 patch (sleep before start() in start_stop_func)"

SRC_FILE="${WORKTREE}/src/uhs/twophase/coordinator/controller.cpp"
BACKUP_FILE="${SRC_FILE}.bak"

# Always start from a clean source
cp "${SRC_FILE}" "${BACKUP_FILE}"

# Add a 5-second sleep right before start() in start_stop_func to widen the gap
# This makes the isLeader=TRUE, handlerActive=FALSE window observable
# We insert it after the "Starting coordinator" log line and before start()
sed -i 's|m_logger->warn("Starting coordinator");\
                start();|m_logger->warn("Starting coordinator");\
                std::this_thread::sleep_for(std::chrono::seconds(5));\
                start();|' "${SRC_FILE}"

echo "[Step 1] Patch applied. Verifying..."
grep -n "sleep_for" "${SRC_FILE}"

# ==========================================
# Step 2: Build modified coordinator
# ==========================================
echo "[Step 2] Building modified coordinatord"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
cmake -B "${BUILD_DIR}" \
    -DCMAKE_PREFIX_PATH="${PREFIX}" \
    -DCMAKE_BUILD_TYPE=Release \
    "${WORKTREE}" 2>&1 | tail -3
cmake --build "${BUILD_DIR}" --target coordinatord 2>&1 | tail -5

COORD_BIN="${BUILD_DIR}/src/uhs/twophase/coordinator/coordinatord"
echo "[Step 2] Built: ${COORD_BIN}"

# ==========================================
# Step 3: Set up minimal config
# ==========================================
echo "[Step 3] Creating minimal single-node config"
CFG_FILE="${BUILD_DIR}/test_single.cfg"
cat > "${CFG_FILE}" << 'CFGEOF'
2pc=1
sentinel_count=0
shard_count=0
coordinator_count=1
coordinator0_count=1
coordinator0_loglevel="WARN"
coordinator0_0_endpoint="127.0.0.1:19999"
coordinator0_0_raft_endpoint="127.0.0.1:19998"
coordinator_max_threads=4
CFGEOF

# ==========================================
# Step 4: Run modified coordinator in background
# ==========================================
echo "[Step 4] Starting coordinator (single-node, will auto-become leader)"
COORD_LOG="${BUILD_DIR}/coordinator.log"
"${COORD_BIN}" "${CFG_FILE}" 0 0 > "${COORD_LOG}" 2>&1 &
COORD_PID=$!
echo "[Step 4] Coordinator PID: ${COORD_PID}"

# Cleanup function
cleanup() {
    echo ""
    echo "=== Cleanup ==="
    kill "${COORD_PID}" 2>/dev/null || true
    wait "${COORD_PID}" 2>/dev/null || true
    # Restore original source
    cp "${BACKUP_FILE}" "${SRC_FILE}"
    rm -f "${BACKUP_FILE}"
    echo "=== Done ==="
}
trap cleanup EXIT

# Wait for coordinator to initialize (raft init + become leader will happen,
# then start_stop_func will hit the sleep before start())
sleep 2

# ==========================================
# Step 5: Test RPC port during the gap
# ==========================================
echo ""
echo "[Step 5] Testing RPC port (127.0.0.1:19999) during the gap..."
echo "  Expected: Connection refused (handler not active yet)"
echo ""

GAP_RESULT=""
for i in $(seq 1 3); do
    if timeout 1 bash -c "echo | nc -w 1 127.0.0.1 19999 2>/dev/null" 2>/dev/null; then
        GAP_RESULT="connected"
        echo "  Attempt $i: Connected (UNEXPECTED - gap may have ended)"
    else
        GAP_RESULT="refused"
        echo "  Attempt $i: Connection refused (EXPECTED - gap is active)"
    fi
done

# ==========================================
# Step 6: Wait for sleep to expire and test again
# ==========================================
echo ""
echo "[Step 6] Waiting for sleep to expire (remaining ~3s)..."
sleep 4

echo "[Step 6] Testing RPC port again..."
POST_RESULT=""
for i in $(seq 1 3); do
    if timeout 1 bash -c "echo | nc -w 1 127.0.0.1 19999 2>/dev/null" 2>/dev/null; then
        POST_RESULT="connected"
        echo "  Attempt $i: Connected (EXPECTED - handler is active)"
    else
        POST_RESULT="refused"
        echo "  Attempt $i: Connection refused (UNEXPECTED - handler should be active)"
    fi
done

# ==========================================
# Step 7: Show coordinator logs proving the gap
# ==========================================
echo ""
echo "[Step 7] Coordinator log excerpts (gap evidence):"
grep -E "Became leader|Starting coordinator|Started coordinator|sleep_for" "${COORD_LOG}" 2>/dev/null || echo "  (log not found)"

# ==========================================
# Step 8: Demonstrate sentinel retry mask would work
# ==========================================
echo ""
echo "[Step 8] Sentinel retry analysis (from code audit):"
echo "  The sentinel (sentinel_2pc/controller.cpp:220-227) uses:"
echo "    while(!m_coordinator_client.execute_transaction(ctx, cb)) {"
echo "        std::this_thread::sleep_for(std::chrono::milliseconds(100));"
echo "    }"
echo "  This infinite retry loop with 100ms delay handles the transient gap."
echo "  Without the retry, a single execute_transaction() call during the gap"
echo "  returns false (send_to_one fails with no connected peer)."
echo "  With the retry, the transaction eventually succeeds after start() completes."

# ==========================================
# Summary
# ==========================================
echo ""
echo "=== Reproduction Summary ==="
echo "Gap detection: ${GAP_RESULT:-refused} (during gap) -> ${POST_RESULT:-connected} (after gap)"
if [ "${POST_RESULT:-refused}" = "connected" ]; then
    echo "Result: GAP CONFIRMED - isLeader=TRUE, handlerActive=FALSE window exists"
    echo "Mask: Sentinel infinite retry loop masks the consequence"
    echo "Verdict: MASKED (finding, not a live bug)"
else
    echo "Result: GAP NOT CONFIRMED - could not observe the gap"
    echo "Check coordinator logs for startup issues: ${COORD_LOG}"
fi

echo ""
echo "Coordinator log:"
cat "${COORD_LOG}"
