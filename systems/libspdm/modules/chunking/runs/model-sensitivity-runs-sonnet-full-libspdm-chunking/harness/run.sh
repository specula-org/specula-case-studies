#!/usr/bin/env bash
# run.sh — Apply instrumentation, build, run test scenarios, collect traces.
# Usage: bash harness/run.sh [trace_dir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_DIR="${SCRIPT_DIR}"
BASE_DIR="$(realpath "${HARNESS_DIR}/..")"
TRACE_DIR="${1:-${BASE_DIR}/traces}"
BINARY="${HARNESS_DIR}/spdm_harness"

mkdir -p "${TRACE_DIR}"

echo "=== Step 1: Apply instrumentation ==="
bash "${HARNESS_DIR}/apply.sh"

echo ""
echo "=== Step 2: Build ==="
make -C "${HARNESS_DIR}" -f "${HARNESS_DIR}/Makefile"

echo ""
echo "=== Step 3: Run test scenarios (timeout 120s) ==="
timeout 120 "${BINARY}" "${TRACE_DIR}" || {
    echo "ERROR: harness timed out or crashed (exit $?)" >&2
    exit 1
}

echo ""
echo "=== Step 4: Trace summary ==="
for f in "${TRACE_DIR}"/*.ndjson; do
    count=$(wc -l < "$f")
    printf "  %-45s  %d events\n" "$(basename "$f")" "$count"
done

echo ""
echo "Done. Traces at: ${TRACE_DIR}"
