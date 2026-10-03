#!/bin/bash
# One command: build the instrumented nvflare copy, run the trace scenarios, collect traces/<scenario>.ndjson.
#
#   cd .specula-output && bash harness/run.sh                       # default scenario set
#   SCENARIOS="normal_two_jobs start_failures" bash harness/run.sh  # a subset
#   VALIDATE=1 bash harness/run.sh                                  # also TLC trace-validate every trace
#
# Uses the pinned Python environment from paths.sh; PYTHONPATH is pointed at the instrumented copy (never at the arm's
# source) and run_scenario.py refuses to run if nvflare resolves anywhere else.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/paths.sh"
OUT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACES="$OUT_DIR/traces"
BUILD="$SCRIPT_DIR/build/nvflare_src"
REPORTS="$SCRIPT_DIR/build/reports"
WORK="$SCRIPT_DIR/build/work"
PER_SCENARIO_TIMEOUT="${PER_SCENARIO_TIMEOUT:-180}"

DEFAULT_SCENARIOS="normal_two_jobs abort_running_and_queued check_timeout_backoff_expiry lossy_check_cant_schedule \
start_failures client_failure_and_sj_crash client_crash_sweep outcome_deadline_hb_cleanup disable_client_outcome_wait \
delete_held_job_kills_runner delete_during_scan abort_during_deploy failrun_during_start failrun_during_start_dup_abort \
refresh_rmw_revert running_after_terminal start_timeout_late_start concurrent_jobs_contention expiry_before_start \
disable_between_schedule_and_deploy abort_before_checks lost_report_heartbeat double_abort_terminate \
random_mix_s1 random_mix_s2 random_mix_s3 random_mix_s4 random_mix_s5 random_mix_s6 wfc_stale_read_after_pop \
check_deadline_backoff_expiry start_deadline_late_start"
# opt-in only (outside the supported envelope; Trace.cfg has EnableUnsupported = FALSE): unsupported_app_missing
SCENARIOS="${SCENARIOS:-$DEFAULT_SCENARIOS}"

echo "==> [1/4] applying instrumentation"
bash "$SCRIPT_DIR/apply.sh" || { echo "apply.sh failed"; exit 1; }

export NVF_INSTRUMENTED_ROOT="$BUILD"
export PYTHONPATH="$BUILD:$SCRIPT_DIR/src"
echo "==> [2/4] checking the import path"
timeout 30 "$NVF_PYTHON" -c 'import nvflare, os; from pathlib import Path; p=Path(nvflare.__file__).resolve(); assert p.is_relative_to(Path(os.environ["NVF_INSTRUMENTED_ROOT"]).resolve()), p; print("   nvflare ->", p)' \
    || { echo "nvflare does not resolve to the instrumented copy"; exit 1; }

mkdir -p "$TRACES" "$REPORTS" "$WORK"
echo "==> [3/4] running scenarios (timeout ${PER_SCENARIO_TIMEOUT}s each)"
failed=()
for s in $SCENARIOS; do
    rm -rf "$WORK/$s" "$TRACES/$s.ndjson"
    start=$(date +%s)
    timeout "$PER_SCENARIO_TIMEOUT" "$NVF_PYTHON" "$SCRIPT_DIR/src/run_scenario.py" "$s" \
        --out "$TRACES/$s.ndjson" --root "$WORK/$s" --report "$REPORTS/$s.json" \
        > "$REPORTS/$s.stdout" 2> "$REPORTS/$s.stderr"
    rc=$?
    printf '%s\n' "$rc" > "$REPORTS/$s.exitcode"
    dur=$(( $(date +%s) - start ))
    if [ $rc -eq 0 ] && timeout 30 "$NVF_PYTHON" "$SCRIPT_DIR/src/trace_contract.py" "$TRACES/$s.ndjson" \
        --report "$REPORTS/$s.json" > "$REPORTS/$s.integrity.json" 2>&1; then
        printf "   %-40s ok      %4ss\n" "$s" "$dur"
    elif [ $rc -eq 124 ]; then
        printf "   %-40s TIMEOUT %4ss  (investigate timeout/deadlock; see %s)\n" "$s" "$dur" "$REPORTS/$s.stderr"
        failed+=("$s")
    else
        printf "   %-40s FAILED  %4ss  scenario_rc=%s (see report and integrity log in %s)\n" "$s" "$dur" "$rc" "$REPORTS"
        failed+=("$s")
    fi
done

echo "==> [4/4] traces written to $TRACES"
for s in $SCENARIOS; do
    if [ -f "$TRACES/$s.ndjson" ]; then
        printf "   %6d lines  %s\n" "$(wc -l < "$TRACES/$s.ndjson")" "traces/$s.ndjson"
    fi
done

if [ "${VALIDATE:-0}" = "1" ]; then
    echo "==> TLC trace validation (spec/Trace.tla + spec/Trace.cfg)"
    files=()
    for s in $SCENARIOS; do [ -f "$TRACES/$s.ndjson" ] && files+=("$TRACES/$s.ndjson"); done
    bash "$SCRIPT_DIR/validate.sh" "${files[@]}" || failed+=("trace_validation")
fi

if [ ${#failed[@]} -gt 0 ]; then
    echo "scenario failures: ${failed[*]}"
    exit 1
fi
exit 0
