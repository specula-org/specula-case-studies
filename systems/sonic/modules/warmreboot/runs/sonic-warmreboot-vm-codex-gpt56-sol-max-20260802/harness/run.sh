#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUTPUT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd)
ARTIFACT=${SPECULA_ARTIFACT:-/users/Pial/targets/sonic-buildimage-warmreboot}
SPECULA_ROOT=${SPECULA_ROOT:-/users/Pial/Specula}
TRACE_DIR="${OUTPUT_DIR}/traces"
SPEC_DIR="${OUTPUT_DIR}/spec"
export PYTHONDONTWRITEBYTECODE=1

mkdir -p "${TRACE_DIR}"
chmod +x "${SCRIPT_DIR}/src/warmreboot_trace.py" \
    "${SCRIPT_DIR}/src/test_scenarios.py" \
    "${SCRIPT_DIR}/src/verify_traces.py" \
    "${SCRIPT_DIR}/src/validate_traces.py" \
    "${SCRIPT_DIR}/src/fakebin/"*

echo "Applying instrumentation..."
SPECULA_ARTIFACT="${ARTIFACT}" timeout 30s bash "${SCRIPT_DIR}/apply.sh"

echo "Checking the instrumented source and harness..."
timeout 30s bash -n "${ARTIFACT}/src/sonic-utilities/scripts/fast-reboot"
timeout 30s bash -c 'for script in "$1"/src/fakebin/*; do bash -n "$script"; done' _ "${SCRIPT_DIR}"
PYTHON_CACHE_DIR=$(mktemp -d -t warmreboot-pycache-XXXXXX)
function cleanup_python_cache()
{
    find "${PYTHON_CACHE_DIR}" -depth -delete
}
trap cleanup_python_cache EXIT
PYTHONPYCACHEPREFIX="${PYTHON_CACHE_DIR}" timeout 30s python3 -m py_compile \
    "${SCRIPT_DIR}/src/warmreboot_trace.py" \
    "${SCRIPT_DIR}/src/test_scenarios.py" \
    "${SCRIPT_DIR}/src/verify_traces.py" \
    "${SCRIPT_DIR}/src/validate_traces.py"
cleanup_python_cache
trap - EXIT

echo "Running real fast-reboot scenarios..."
SPECULA_ARTIFACT="${ARTIFACT}" \
SPECULA_TRACE_DIR="${TRACE_DIR}" \
timeout 120s python3 "${SCRIPT_DIR}/src/test_scenarios.py"

echo "Checking NDJSON schema and event coverage..."
timeout 30s python3 "${SCRIPT_DIR}/src/verify_traces.py" "${TRACE_DIR}"

echo "Replaying every trace with TLC..."
timeout 300s python3 "${SCRIPT_DIR}/src/validate_traces.py" \
    --spec-dir "${SPEC_DIR}" \
    --trace-dir "${TRACE_DIR}" \
    --specula-root "${SPECULA_ROOT}"

echo "Trace line counts:"
for trace in \
    normal_admission.ndjson \
    signal_cancellation.ndjson \
    two_owner_rejection.ndjson \
    multi_asic_masked_stops.ndjson; do
    printf '  %s: %s\n' "${trace}" "$(wc -l < "${TRACE_DIR}/${trace}")"
done
