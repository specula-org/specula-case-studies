#!/usr/bin/env bash
# End-to-end harness for braft_3:
#   1. Apply instrumentation to artifact/braft
#   2. CMake-configure with WITH_BRAFT_TRACE=ON and BUILD_UNIT_TESTS=ON
#   3. Build the trace-instrumented unit tests
#   4. Run each test scenario, collecting one NDJSON trace file per scenario
#   5. Print event-type counts per trace so the user can spot-check coverage
#
# Usable from .specula-output/ as:  bash harness/run.sh
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${HARNESS_DIR}/.." && pwd)"
ARTIFACT_DIR="${ROOT_DIR}/../artifact/braft"
TRACES_DIR="${ROOT_DIR}/traces"
BUILD_DIR="${ARTIFACT_DIR}/bld"

mkdir -p "${TRACES_DIR}"

echo "============================================================"
echo "  braft_3 trace harness"
echo "  artifact:  ${ARTIFACT_DIR}"
echo "  traces:    ${TRACES_DIR}"
echo "============================================================"

bash "${HARNESS_DIR}/apply.sh"

echo ">> Configuring CMake"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"
cmake -DBUILD_UNIT_TESTS=ON -DWITH_BRAFT_TRACE=ON .. >/dev/null

echo ">> Building test binaries"
timeout 900 make -j4 test_trace_smoke test_bug_repro 2>&1 | tail -n 5

run_scenario() {
    local binary="$1"           # absolute test binary path
    local filter="$2"           # gtest --gtest_filter value
    local out="$3"              # trace file to write
    local label="$4"
    echo ""
    echo ">> Scenario: ${label}"
    rm -f "${out}"
    # Each scenario runs from its own working directory so it doesn't fight
    # the others' 'data/' directories.
    local work
    work="$(mktemp -d)"
    (
        cd "${work}"
        RAFT_TRACE_FILE="${out}" timeout 180 \
            "${binary}" --gtest_filter="${filter}" 2>&1 \
            | tail -n 5
    )
    rm -rf "${work}"
    if [ -s "${out}" ]; then
        local n
        n=$(wc -l < "${out}")
        echo ">> ${label}: ${n} trace lines written to ${out}"
    else
        echo "!! ${label}: NO trace lines written (check ${out})"
    fi
}

run_scenario "${BUILD_DIR}/test/test_trace_smoke" \
             "TraceSmokeTest.ElectAndReplicate" \
             "${TRACES_DIR}/smoke_elect_replicate.ndjson" \
             "smoke / elect+replicate"

run_scenario "${BUILD_DIR}/test/test_trace_smoke" \
             "TraceSmokeTest.LeaderLeaseValid" \
             "${TRACES_DIR}/smoke_leader_lease.ndjson" \
             "smoke / leader lease"

run_scenario "${BUILD_DIR}/test/test_bug_repro" \
             "BugReproTest.ForceCommitViaConfigChange" \
             "${TRACES_DIR}/bug_force_commit.ndjson" \
             "bug-repro / force commit"

echo ""
echo ">> Event-type counts per trace:"
for f in "${TRACES_DIR}"/*.ndjson; do
    [ -f "${f}" ] || continue
    echo "----- $(basename "${f}") -----"
    awk -F'"name":' \
        '{for(i=2;i<=NF;i++){split($i,a,"\""); print a[2]}}' "${f}" \
        | sort | uniq -c
done

echo ""
echo ">> Done.  Use traces/*.ndjson with Trace.tla for validation."
