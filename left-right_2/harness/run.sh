#!/usr/bin/env bash
# End-to-end: apply instrumentation, build, run trace scenarios, collect traces.
#
# Idempotent: safe to run repeatedly.  Writes one merged trace file per scenario
# to ../traces/<scenario>.ndjson (the file is JSON, not NDJSON, but the .ndjson
# extension matches the trace-validation harness convention).

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT_DIR="${HARNESS_DIR}/../../artifact/left-right"
TRACES_DIR="${HARNESS_DIR}/../traces"
RAW_DIR="${TRACES_DIR}/raw"

mkdir -p "${TRACES_DIR}" "${RAW_DIR}"

echo "[run] Applying instrumentation..."
bash "${HARNESS_DIR}/apply.sh"

echo "[run] Building..."
( cd "${ARTIFACT_DIR}" && timeout 300 cargo build --tests --quiet )

# Each scenario writes per-thread NDJSON files into a unique subdirectory of
# RAW_DIR (LEFTRIGHT_TRACE_DIR is set per-test via setup_trace).  We invoke
# tests one at a time so trace dirs don't interleave and so we can timeout
# each one independently.

# trace_tests::setup_trace strips the "trace_" prefix and uses the suffix as
# the per-scenario subdirectory name.  We pass both the test fn name and the
# scenario name explicitly.
run_test() {
  local test_name="$1"     # cargo test fn name, e.g. trace_sequential
  local scenario="$2"      # subdir under RAW_DIR, e.g. sequential
  local scenario_dir="${RAW_DIR}/${scenario}"
  rm -rf "${scenario_dir}"
  mkdir -p "${scenario_dir}"

  echo "[run] Running ${test_name}..."
  ( cd "${ARTIFACT_DIR}" \
      && LEFTRIGHT_TRACE_BASE="${RAW_DIR}" \
         timeout 60 cargo test --test trace_tests --quiet -- --exact \
         "${test_name}" --nocapture )

  local out="${TRACES_DIR}/${scenario}.ndjson"
  python3 "${HARNESS_DIR}/preprocess.py" "${scenario_dir}" "${out}"
}

run_test trace_sequential          sequential
run_test trace_slow_reader_overlap slow_reader_overlap
run_test trace_nested_enters       nested_enters
run_test trace_try_publish         try_publish

echo
echo "[run] Trace summary:"
for f in "${TRACES_DIR}"/*.ndjson; do
  if [[ -f "$f" ]]; then
    # event-count = sum of array lengths inside threads object
    count=$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
threads = d.get('threads', {})
total = sum(len(v) for v in threads.values())
print(f\"{total} events ({', '.join(f'{k}={len(v)}' for k,v in sorted(threads.items()))})\")" "$f")
    echo "  $(basename "$f"): ${count}"
  fi
done

echo "[run] Done."
