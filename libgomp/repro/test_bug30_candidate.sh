#!/usr/bin/env bash
set -euo pipefail

TRIALS="${TRIALS:-3000}"
THREADS="${THREADS:-16}"
SEED="${SEED:-12648430}"
RUN_TIMEOUT="${RUN_TIMEOUT:-120}"
LIBGOMP_DIR="${LIBGOMP_DIR:-}"
PROGRAM="cancel_relaxed_publish_probe"
SRC="${PROGRAM}.c"

if [[ -z "${LIBGOMP_DIR}" ]]; then
  echo "error: set LIBGOMP_DIR to the directory containing libgomp.so (e.g. /tmp/libgomp-build/.libs)" >&2
  exit 2
fi

if [[ ! -f "${LIBGOMP_DIR}/libgomp.so" && ! -f "${LIBGOMP_DIR}/libgomp.so.1" ]]; then
  echo "error: ${LIBGOMP_DIR} does not contain libgomp.so/libgomp.so.1" >&2
  exit 2
fi

echo "[bug30] building repro program..."
gcc -O2 -g -fopenmp -pthread -o "${PROGRAM}" "${SRC}"

LOG="$(mktemp /tmp/bug30-candidate.XXXXXX.log)"
echo "[bug30] program=probe trials=${TRIALS} threads=${THREADS} seed=${SEED}"
echo "[bug30] timeout=${RUN_TIMEOUT}s"
echo "[bug30] log=${LOG}"

set +e
timeout "${RUN_TIMEOUT}"s \
  env OMP_CANCELLATION=true LD_LIBRARY_PATH="${LIBGOMP_DIR}" \
  "./${PROGRAM}" --trials "${TRIALS}" --threads "${THREADS}" --seed "${SEED}" \
  >"${LOG}" 2>&1
rc=$?
set -e

if [[ "${rc}" -eq 124 ]]; then
  echo "[bug30] inconclusive: timed out after ${RUN_TIMEOUT}s"
  exit 124
fi
if [[ "${rc}" -ne 0 ]]; then
  echo "[bug30] repro program exited with rc=${rc}"
  tail -n 120 "${LOG}" || true
  exit "${rc}"
fi

tail -n 20 "${LOG}" || true

if grep -q 'WEAKMEM_PROBE_STALE' "${LOG}"; then
  echo "[bug30] FAIL: weak-memory stale observation detected"
  exit 1
fi

echo "[bug30] no probe hits observed (inconclusive, candidate not reproduced)"
exit 0
