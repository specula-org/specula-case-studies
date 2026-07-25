#!/usr/bin/env bash
# run.sh — Apply instrumentation, generate traces from real MongoDB 8.0 via Docker.
#
# Usage (from the project root):
#   bash harness/run.sh
#
# Requirements:
#   - docker (mongo:8 image already pulled)
#   - python3 with pymongo (pip install pymongo)
#
# Output:
#   traces/*.ndjson   — NDJSON trace files (one per scenario)
#
# To use the C++ source instrumentation instead (requires a full MongoDB build):
#   bash harness/apply.sh
#   cd artifact/mongo-src
#   bazel build //src/mongo/db/s:migration_test
#   # run migration tests with TLA_TRACE_FILE=<path> set

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
TRACES_DIR="${ROOT_DIR}/traces"
VENV="${ROOT_DIR}/../../../../../../.venv"

mkdir -p "${TRACES_DIR}"

echo "========================================"
echo "MongoDB chunk migration trace generator"
echo "========================================"

# Check prerequisites
if ! command -v docker &>/dev/null; then
    echo "ERROR: docker not found" >&2; exit 1
fi
if ! docker image inspect mongo:8 &>/dev/null; then
    echo "Pulling mongo:8 Docker image …"
    docker pull mongo:8
fi

# Use Specula venv if available, else system python3
if [[ -x "${VENV}/bin/python3" ]]; then
    PYTHON="${VENV}/bin/python3"
else
    PYTHON="python3"
fi

if ! "${PYTHON}" -c "import pymongo" 2>/dev/null; then
    echo "Installing pymongo …"
    "${PYTHON}" -m pip install pymongo --quiet
fi

echo ""
echo "Running trace generator (real MongoDB 8.0 via Docker) …"
echo "Timeout: 30 minutes"
echo ""

timeout 1800 "${PYTHON}" "${SCRIPT_DIR}/src/generate_traces.py" 2>&1

echo ""
echo "Trace files:"
ls -lh "${TRACES_DIR}"/*.ndjson 2>/dev/null || echo "  (no traces generated)"

echo ""
echo "Event counts per file:"
for f in "${TRACES_DIR}"/*.ndjson; do
    [[ -f "$f" ]] || continue
    count=$(wc -l < "$f")
    echo "  $(basename "$f"): ${count} events"
done

echo ""
echo "run.sh complete."
