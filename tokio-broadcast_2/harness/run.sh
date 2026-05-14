#!/usr/bin/env bash
# One-command pipeline:
#   1. apply instrumentation to artifact
#   2. build + run all five trace scenarios
#   3. preprocess each raw NDJSON into the { threads, events } schema for TLC
#   4. report line counts
#
# Run from anywhere:
#   bash .specula-output/harness/run.sh
#
# Or from .specula-output/:
#   bash harness/run.sh

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECULA_DIR="$(realpath "${HARNESS_DIR}/..")"
ARTIFACT_DIR="$(realpath "${HARNESS_DIR}/../../artifact/tokio")"
TRACE_DIR="${SPECULA_DIR}/traces"

mkdir -p "${TRACE_DIR}"

echo "[run] applying instrumentation..."
bash "${HARNESS_DIR}/apply.sh"

echo "[run] building harness..."
( cd "${ARTIFACT_DIR}/tokio" && cargo build --features full --test tla_harness )

echo "[run] running scenarios..."
( cd "${ARTIFACT_DIR}/tokio" && \
    TLA_TRACE_DIR="${TRACE_DIR}" \
    cargo test --features full --test tla_harness -- --test-threads=1 --nocapture )

echo "[run] preprocessing raw traces..."
for f in "${TRACE_DIR}"/*.ndjson; do
    base=$(basename "${f}" .ndjson)
    # Skip already-processed outputs.
    case "${base}" in
        *.processed) continue ;;
    esac
    out="${TRACE_DIR}/${base}.processed.ndjson"
    python3 "${HARNESS_DIR}/preprocess.py" "${f}" "${out}"
done

echo "[run] trace summary:"
for f in "${TRACE_DIR}"/*.ndjson; do
    lines=$(wc -l < "${f}")
    printf "  %-50s %5d lines\n" "$(basename "${f}")" "${lines}"
done

echo "[run] done."
