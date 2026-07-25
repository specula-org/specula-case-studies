#!/usr/bin/env bash
# One-command harness: apply instrumentation, build, run trace scenarios,
# preprocess per-thread NDJSON into the consolidated JSON consumed by Trace.tla.
#
# Run from .specula-output/ so the relative paths line up:
#     cd .specula-output && bash harness/run.sh

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECULA_OUT="$(cd "${HARNESS_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${SPECULA_OUT}/.." && pwd)"
ARTIFACT="${ROOT_DIR}/artifact/papaya"
TRACES_DIR="${SPECULA_OUT}/traces"
RAW_DIR="${TRACES_DIR}/raw"

mkdir -p "${TRACES_DIR}" "${RAW_DIR}"

echo "[run] applying instrumentation"
bash "${HARNESS_DIR}/apply.sh"

echo "[run] building"
cd "${ARTIFACT}"
cargo build --release --tests 2>&1 | tail -3 || true

# Each scenario writes its per-thread files to TLA_TRACE_DIR.
SCENARIOS=(
    trace_iter_modify_resize
    trace_meta_overwrite_race
    trace_blocking_resize_parkers
    trace_incremental_resize_iter
)

for scenario in "${SCENARIOS[@]}"; do
    echo "[run] scenario: ${scenario}"
    rm -f "${RAW_DIR}/"*-thread-*.ndjson
    TLA_TRACE_DIR="${RAW_DIR}" \
        cargo test --release --test trace_tests "${scenario}" -- --nocapture --test-threads=1 \
        2>&1 | tail -8 || true

    # Preprocess per-thread files for this scenario into a single JSON
    short=$(echo "${scenario}" | sed 's/^trace_//')
    out="${TRACES_DIR}/${short}.ndjson"

    python3 "${HARNESS_DIR}/src/preprocess_trace.py" \
        "${RAW_DIR}" "${short}" "${out}"

    echo "[run]   wrote ${out}"
done

echo "[run] trace summary:"
for f in "${TRACES_DIR}"/*.ndjson; do
    [[ -f "${f}" ]] || continue
    nlines=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(sum(len(v) for v in d.get('threads',{}).values()))" "${f}")
    nthreads=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(len(d.get('threads',{})))" "${f}")
    echo "  ${f}: ${nthreads} threads, ${nlines} events"
done

echo "[run] done"
