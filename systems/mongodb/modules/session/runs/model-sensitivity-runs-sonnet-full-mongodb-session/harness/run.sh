#!/usr/bin/env bash
# End-to-end harness for mongodb-session:
#   1. Build the standalone scenario generator (C++17, g++)
#   2. Run all 4 scenarios, writing one NDJSON trace file per scenario to traces/
#   3. Validate trace format (JSON lines, event names, timestamps)
#   4. Report event-type counts
#
# Usable from the run root:  bash harness/run.sh
#
# For instrumentation of the real MongoDB source (requires Bazel + full toolchain):
#   bash harness/apply.sh   # patches artifact/mongo-src
#   # then build MongoDB with -DMONGODB_TLA_TRACE and run session catalog tests
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${HARNESS_DIR}/.." && pwd)"
BUILD_DIR="${HARNESS_DIR}/build"
TRACES_DIR="${ROOT_DIR}/traces"
SRC_DIR="${HARNESS_DIR}/src"

mkdir -p "${BUILD_DIR}" "${TRACES_DIR}"

echo "============================================================"
echo "  mongodb-session trace harness"
echo "  harness: ${HARNESS_DIR}"
echo "  traces:  ${TRACES_DIR}"
echo "============================================================"
echo ""

# ---------------------------------------------------------------------------
# Step 1: Build the scenario generator
# ---------------------------------------------------------------------------
echo ">> Building scenario generator"
cd "${BUILD_DIR}"
cmake "${SRC_DIR}" -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_CXX_FLAGS="-O2" > /dev/null 2>&1

timeout 120 make -j"$(nproc)" session_scenarios 2>&1 | tail -5
echo "   Build complete: ${BUILD_DIR}/session_scenarios"
echo ""

# ---------------------------------------------------------------------------
# Step 2: Run scenarios and collect traces
# ---------------------------------------------------------------------------
echo ">> Running scenarios"
rm -f "${TRACES_DIR}"/*.ndjson

timeout 30 "${BUILD_DIR}/session_scenarios" "${TRACES_DIR}/"
echo ""

# ---------------------------------------------------------------------------
# Step 3: Validate traces
# ---------------------------------------------------------------------------
echo ">> Validating traces"

EXPECTED_EVENTS=(
    wait_for_checkout checkout_session checkin_session
    request_kill register_kill_change_succeed
    kill_release_clear_checkout kill_release_notify kill_release_decrement
    start_refresh refresh_succeed refresh_fail end_refresh
    start_reap memory_reap disk_reap_image disk_reap_txn end_reap
)

ALL_OK=true

for trace_file in "${TRACES_DIR}"/*.ndjson; do
    fname="$(basename "${trace_file}")"
    line_count="$(wc -l < "${trace_file}")"

    # Check JSON validity
    json_ok=true
    while IFS= read -r line; do
        if ! python3 -c "import json; json.loads('$line')" 2>/dev/null; then
            # Fallback: use python3 -c with heredoc to handle quotes
            if ! echo "${line}" | python3 -c "import sys,json; json.loads(sys.stdin.read())" 2>/dev/null; then
                json_ok=false
                echo "  FAIL  ${fname}: invalid JSON on a line"
                ALL_OK=false
                break
            fi
        fi
    done < "${trace_file}"

    if [ "${json_ok}" = "true" ]; then
        echo "  OK    ${fname}: ${line_count} events (valid JSON)"
        if [ "${line_count}" -lt 20 ]; then
            echo "  WARN  ${fname}: only ${line_count} events (expected >= 20)"
        fi
    fi
done

# Check real timestamps (not sequential integers)
echo ""
echo ">> Checking timestamps"
python3 - "${TRACES_DIR}" <<'PYEOF'
import json, os, sys

traces_dir = sys.argv[1]
for fname in sorted(os.listdir(traces_dir)):
    if not fname.endswith('.ndjson'):
        continue
    path = os.path.join(traces_dir, fname)
    ts_list = []
    events = []
    with open(path) as f:
        for line in f:
            obj = json.loads(line)
            ts_list.append(obj.get('ts', 0))
            events.append(obj.get('event', '?'))
    # Timestamps should be > 1e15 (nanoseconds since epoch, ~2001+)
    real_ts = all(t > 1_000_000_000_000_000 for t in ts_list)
    monotonic = all(ts_list[i] <= ts_list[i+1] for i in range(len(ts_list)-1))
    print(f"  {fname}: real_timestamps={real_ts}, monotonic={monotonic}")
PYEOF

# Check event type coverage
echo ""
echo ">> Checking event type coverage"
python3 - "${TRACES_DIR}" <<'PYEOF'
import json, os, sys

traces_dir = sys.argv[1]
all_events = set()
for fname in os.listdir(traces_dir):
    if not fname.endswith('.ndjson'):
        continue
    with open(os.path.join(traces_dir, fname)) as f:
        for line in f:
            obj = json.loads(line)
            all_events.add(obj.get('event', '?'))

expected = {
    'wait_for_checkout', 'checkout_session', 'checkin_session',
    'request_kill', 'register_kill_change_succeed',
    'kill_release_clear_checkout', 'kill_release_notify', 'kill_release_decrement',
    'start_refresh', 'refresh_succeed', 'refresh_fail', 'end_refresh',
    'start_reap', 'memory_reap', 'disk_reap_image', 'disk_reap_txn', 'end_reap'
}
missing = expected - all_events
if missing:
    print(f"  WARN: missing event types: {sorted(missing)}")
else:
    print(f"  OK: all {len(expected)} expected event types present")
    print(f"  Events: {sorted(all_events)}")
PYEOF

echo ""
echo ">> Trace line counts"
for trace_file in "${TRACES_DIR}"/*.ndjson; do
    printf "  %-40s %d lines\n" "$(basename "${trace_file}")" "$(wc -l < "${trace_file}")"
done

echo ""
echo "============================================================"
echo "  Traces written to: ${TRACES_DIR}"
echo "  Next: run Phase 3 validation with /validation-workflow skill"
echo "============================================================"
