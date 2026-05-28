#!/usr/bin/env bash
# End-to-end driver: apply instrumentation, build, run trace test scenarios,
# emit NDJSON trace files into .specula-output/traces/.

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$(cd "${HARNESS_DIR}/.." && pwd)"
ARTIFACT_DIR="${OUTPUT_DIR}/../artifact/AlephBFT"
TRACES_DIR="${OUTPUT_DIR}/traces"

mkdir -p "${TRACES_DIR}"

echo "[run] applying instrumentation"
bash "${HARNESS_DIR}/apply.sh"

echo "[run] building (cargo build, dev profile)"
(cd "${ARTIFACT_DIR}" && timeout 600 cargo build -p aleph-bft --tests 2>&1 | tail -20)

# Scenario 1: 4 honest, all alive.
SCENARIO="four_honest_all_alive"
TRACE_FILE="${TRACES_DIR}/${SCENARIO}.ndjson"
echo "[run] scenario: ${SCENARIO} -> ${TRACE_FILE}"
rm -f "${TRACE_FILE}"
(cd "${ARTIFACT_DIR}" && \
  TLA_TRACE_FILE="${TRACE_FILE}" \
  timeout 120 cargo test -p aleph-bft --tests trace_four_honest_all_alive \
  -- --test-threads=1 --nocapture 2>&1 | tail -5)

# Scenario 2: 4 honest, one node crash (only 3 alive).
SCENARIO="four_honest_one_crash"
TRACE_FILE="${TRACES_DIR}/${SCENARIO}.ndjson"
echo "[run] scenario: ${SCENARIO} -> ${TRACE_FILE}"
rm -f "${TRACE_FILE}"
(cd "${ARTIFACT_DIR}" && \
  TLA_TRACE_FILE="${TRACE_FILE}" \
  timeout 120 cargo test -p aleph-bft --tests trace_four_honest_one_crash \
  -- --test-threads=1 --nocapture 2>&1 | tail -5)

# Maintain a "default" trace file that the Trace.cfg JSON-loader can pick up.
cp "${TRACES_DIR}/four_honest_all_alive.ndjson" "${TRACES_DIR}/trace.ndjson"

echo
echo "[run] trace line counts:"
for f in "${TRACES_DIR}"/*.ndjson; do
  printf "  %-60s %s lines\n" "$f" "$(wc -l < "$f")"
done

echo
echo "[run] event type distribution (four_honest_all_alive.ndjson):"
awk -F'"name":"' '{split($2, a, "\""); print a[1]}' \
  "${TRACES_DIR}/four_honest_all_alive.ndjson" | sort | uniq -c

echo
echo "[run] done"
