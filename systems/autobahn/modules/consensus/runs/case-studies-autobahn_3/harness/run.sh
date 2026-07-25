#!/usr/bin/env bash
# Apply instrumentation, build, run each TLA+ trace scenario, and collect
# NDJSON traces under .specula-output/traces/.
#
# Run from .specula-output/ as `bash harness/run.sh`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARTIFACT="${ROOT_DIR}/../artifact/autobahn-artifact"
TRACES_DIR="${ROOT_DIR}/traces"

mkdir -p "${TRACES_DIR}"
rm -f "${TRACES_DIR}"/*.ndjson

bash "${SCRIPT_DIR}/apply.sh"

cd "${ARTIFACT}"

echo "[run] Building primary tests (timeout 10m)..."
timeout 600 cargo test -p primary --lib --no-run 2>&1 | tail -5

run_scenario() {
    local test_name="$1"
    local trace_name="$2"
    local trace_path="${TRACES_DIR}/${trace_name}.ndjson"
    echo
    echo "[run] === Scenario: ${test_name} ==="
    rm -f "${trace_path}"
    # 60s wall clock cap per scenario; tests themselves use <10s but we
    # guard against deadlock or stuck async tasks.
    if TLA_TRACE_FILE="${trace_path}" timeout 120 \
            cargo test -p primary --lib "core::trace_test::${test_name}" \
            -- --nocapture --test-threads=1 2>&1 | tail -25; then
        echo "[run] OK  scenario ${test_name}"
    else
        echo "[run] WARN scenario ${test_name} returned non-zero (see log above)"
    fi
    if [[ -f "${trace_path}" ]]; then
        local lines
        lines=$(wc -l < "${trace_path}")
        echo "[run]      trace: ${trace_path} (${lines} events)"
    else
        echo "[run]      NO trace produced at ${trace_path}"
    fi
}

run_scenario "tla_trace_consensus"      "consensus"
run_scenario "tla_trace_multi_slot"     "multi_slot"
run_scenario "tla_trace_fast_path"      "fast_path"
run_scenario "tla_trace_view_change"    "view_change"
run_scenario "tla_trace_leader_prepare" "leader_prepare"
run_scenario "tla_trace_vc_leader"      "vc_leader"
run_scenario "tla_trace_timeout"        "timeout"

echo
echo "[run] === Trace summary ==="
for t in "${TRACES_DIR}"/*.ndjson; do
    [[ -f "${t}" ]] || continue
    n_lines=$(wc -l < "${t}")
    printf "  %-40s %5d events\n" "$(basename "${t}")" "${n_lines}"
done

echo
echo "[run] === Event-type coverage across all traces ==="
cat "${TRACES_DIR}"/*.ndjson 2>/dev/null \
    | grep -oE '"event":"[A-Za-z]+"' \
    | sort | uniq -c | sort -rn || true

echo
echo "[run] === NDJSON format spot-check (one parse per line) ==="
fmt_status=0
for t in "${TRACES_DIR}"/*.ndjson; do
    [[ -f "${t}" ]] || continue
    if ! python3 "${SCRIPT_DIR}/check_format.py" "${t}"; then
        fmt_status=1
    fi
done
if [[ ${fmt_status} -eq 0 ]]; then
    echo "[run] All trace lines parse as JSON with required fields."
else
    echo "[run] FORMAT ERRORS — see above."
fi

echo
echo "[run] Done — traces are in ${TRACES_DIR}"
