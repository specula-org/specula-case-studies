#!/usr/bin/env bash
# run.sh — Apply instrumentation, (attempt to) build and run tests, collect traces.
#
# Usage (run from the project root, i.e., the mongodb-raftreconfig directory):
#   bash harness/run.sh
#
# This script has two paths:
#   1. FAST PATH: Generate traces from the Python state-machine simulator
#      (no build required; always available).
#   2. BUILD PATH: Apply C++ patches, attempt a Bazel build, run unit tests.
#      Enabled when TLA_BUILD=1 is set in the environment.
#      Requires the full MongoDB toolchain (python3, bazel, clang, etc.)
#
# Traces are written to traces/*.ndjson.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACT="${PROJ_DIR}/artifact/mongo-src"
TRACES_DIR="${PROJ_DIR}/traces"
SIMULATOR="${SCRIPT_DIR}/src/trace_simulator.py"

mkdir -p "${TRACES_DIR}"

echo "=== MongoDB Raft Reconfig Trace Harness ==="

# ─────────────────────────────────────────────
# Path 1: Python simulator (always runs first)
# ─────────────────────────────────────────────
echo ""
echo "--- Generating simulator traces ---"
python3 "${SIMULATOR}"

echo ""
echo "--- Trace summary ---"
for f in "${TRACES_DIR}"/*.ndjson; do
    count=$(wc -l < "$f")
    echo "  $(basename "$f"): ${count} events"
done

# ─────────────────────────────────────────────
# Path 2: C++ build (only if TLA_BUILD=1)
# ─────────────────────────────────────────────
if [[ "${TLA_BUILD:-0}" != "1" ]]; then
    echo ""
    echo "--- Skipping C++ build (set TLA_BUILD=1 to enable) ---"
    echo "    Simulator traces are in: ${TRACES_DIR}/"
    exit 0
fi

echo ""
echo "--- Applying C++ instrumentation ---"
bash "${SCRIPT_DIR}/apply.sh"

echo ""
echo "--- Building MongoDB repl tests (this may take a long time) ---"
cd "${ARTIFACT}"

# Bazel build for just the replication coordinator unit tests
# Timeout: 30 minutes
timeout 1800 bazel build \
    //src/mongo/db/repl:replication_coordinator_impl_test \
    //src/mongo/db/repl:replication_coordinator_impl_elect_v1_test \
    --config=opt \
    --//src/mongo/db/repl:tla_trace_output="${TRACES_DIR}/cpp_trace.ndjson" \
    2>&1 | tail -20 || {
        echo "[warn] Bazel build failed or timed out; using simulator traces only."
        exit 0
    }

echo ""
echo "--- Running replication coordinator tests ---"
TLA_TRACE_FILE="${TRACES_DIR}/election_cpp.ndjson" \
timeout 300 bazel test \
    //src/mongo/db/repl:replication_coordinator_impl_elect_v1_test \
    --config=opt \
    --test_env=TLA_TRACE_FILE="${TRACES_DIR}/election_cpp.ndjson" \
    2>&1 | tail -20 || {
        echo "[warn] Test run failed or timed out."
    }

echo ""
echo "--- Final trace summary ---"
for f in "${TRACES_DIR}"/*.ndjson; do
    count=$(wc -l < "$f")
    echo "  $(basename "$f"): ${count} events"
done
