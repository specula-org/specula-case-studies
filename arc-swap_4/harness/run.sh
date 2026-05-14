#!/usr/bin/env bash
# run.sh — apply instrumentation, build, run scenarios, and collect traces.
#
# Anyone should be able to reproduce traces with:
#   cd .specula-output && bash harness/run.sh
#
# Outputs traces to .specula-output/traces/<scenario>.ndjson.  Each test
# scenario runs in its own cargo-test invocation so the global LIST_HEAD is
# guaranteed to start empty (avoids cross-scenario contamination).

set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECULA_OUT="$(cd "${HARNESS_DIR}/.." && pwd)"
TRACES_DIR="${SPECULA_OUT}/traces"
ARTIFACT="${ARC_SWAP_ARTIFACT:-${HARNESS_DIR}/../../artifact/arc-swap}"
ARTIFACT="$(cd "${ARTIFACT}" && pwd)"

echo "[run] harness:    ${HARNESS_DIR}"
echo "[run] artifact:   ${ARTIFACT}"
echo "[run] traces out: ${TRACES_DIR}"

mkdir -p "${TRACES_DIR}"

# 1) Apply instrumentation.
bash "${HARNESS_DIR}/apply.sh"

# 2) Build (compile only — fail fast if instrumentation has type errors).
#    We restrict to our trace-scenarios test binary; the artifact's other tests
#    (fallback_uaf.rs, random.rs) require feature flags or extra dev-deps that
#    are unrelated to the harness.
#    `--features internal-test-strategies` enables the optional
#    `family_5_fallback_path` scenario which forces the helping/fallback path
#    via FillFastSlots.
echo "[run] building..."
( cd "${ARTIFACT}" && timeout 600 cargo build --test tla_trace_scenarios \
    --features internal-test-strategies --quiet 2>&1 ) | tail -40

# 3) Run each test scenario in its own cargo-test invocation.  Each scenario
#    writes its own .ndjson file under $ARC_SWAP_TRACE_OUT.
SCENARIOS=(
    basic_read_write
    concurrent_readers_writer
    family_2_into_inner
    family_2_send_guard
    family_2_guard_clone
    family_2_cas_arc
    family_2_cas_raw_stale
    family_5_fallback_path
)

for scenario in "${SCENARIOS[@]}"; do
    echo "[run] === scenario: ${scenario} ==="
    # Use a fresh trace dir per scenario, then copy out into the canonical
    # traces/ directory.  --test-threads=1 ensures sequential invocation
    # within the cargo test process; combined with running each scenario as
    # its own `cargo test --exact` invocation, this gives a clean trace.
    SCENARIO_TMP="$(mktemp -d)"
    if ! ARC_SWAP_TRACE_OUT="${SCENARIO_TMP}" \
        timeout 300 cargo test \
            --manifest-path "${ARTIFACT}/Cargo.toml" \
            --test tla_trace_scenarios \
            --features internal-test-strategies \
            --quiet \
            -- --exact "${scenario}" --test-threads=1 \
        > "${SCENARIO_TMP}/.cargo-output.log" 2>&1; then
        echo "[run] scenario ${scenario} failed; cargo output:"
        sed 's/^/[run]   /' "${SCENARIO_TMP}/.cargo-output.log"
        rm -rf "${SCENARIO_TMP}"
        exit 1
    fi
    # Move the produced trace.
    if [ -f "${SCENARIO_TMP}/${scenario}.ndjson" ]; then
        cp "${SCENARIO_TMP}/${scenario}.ndjson" "${TRACES_DIR}/${scenario}.ndjson"
        lines="$(wc -l < "${TRACES_DIR}/${scenario}.ndjson")"
        echo "[run]   trace: ${TRACES_DIR}/${scenario}.ndjson (${lines} lines)"
    else
        echo "[run]   warning: ${scenario}.ndjson not produced"
    fi
    rm -rf "${SCENARIO_TMP}"
done

# 4) Symlink one of the traces as the default trace.ndjson for Trace.cfg.
DEFAULT_TRACE="${TRACES_DIR}/trace.ndjson"
if [ -f "${TRACES_DIR}/basic_read_write.ndjson" ]; then
    ln -sf basic_read_write.ndjson "${DEFAULT_TRACE}"
    echo "[run] default trace symlink: ${DEFAULT_TRACE} -> basic_read_write.ndjson"
fi

echo
echo "[run] === summary ==="
ls -la "${TRACES_DIR}"
echo
echo "[run] DONE.  Validate with:"
echo "  cd ${SPECULA_OUT}/spec && JSON=../traces/basic_read_write.ndjson tlc Trace -config Trace.cfg"
