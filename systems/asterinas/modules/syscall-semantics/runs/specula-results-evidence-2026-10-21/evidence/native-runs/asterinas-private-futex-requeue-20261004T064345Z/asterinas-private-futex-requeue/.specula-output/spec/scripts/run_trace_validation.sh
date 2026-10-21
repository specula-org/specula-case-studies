#!/usr/bin/env bash
# Replays normalized traces through Trace.tla, one TLC process at a time.
# Usage: run_trace_validation.sh OUT_DIR CASE...   (CASE is a two-digit number)
#
# The TLC wrapper reserves heap plus off-heap memory and workers against the
# lane budget in SPECULA_TLC_MEMORY_LIMIT / SPECULA_TLC_WORKER_LIMIT, so it is
# used instead of a bare java command. Trace.tla reads the trace path from
# IOEnv.JSON, which the MCP start_tlc tool cannot set; this script exports it.
set -euo pipefail

SPEC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRACE_DIR="$SPEC_DIR/../traces"
WRAPPER="${SPECULA_ROOT:?}/scripts/tlc/run_model_check.sh"
MEM_GATE=/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/effective-mem-gib.sh
OUT_DIR="$1"
shift
mkdir -p "$OUT_DIR"

for case_id in "$@"; do
    trace="$TRACE_DIR/case-$case_id.ndjson"
    log="$OUT_DIR/trace-case-$case_id.out"
    # The resource policy requires 6 GiB of reclaimable memory before each TLC start.
    free_gib="$(sh "$MEM_GATE")"
    if ! awk -v f="$free_gib" 'BEGIN { exit !(f >= 6) }'; then
        echo "case $case_id: memory gate not met ($free_gib GiB < 6 GiB); stopping" >&2
        exit 3
    fi
    echo "case $case_id: start $(date -Is) effective_mem_gib=$free_gib"
    (
        cd "$SPEC_DIR"
        # TLC's own -t budget is 10 minutes. The outer timeout covers a hung JVM.
        JSON="$trace" timeout 15m "$WRAPPER" -s Trace.tla -c Trace.cfg \
            -m 2G -M 512M -w 2 -t 10 -o "$log" > "$log.launcher" 2>&1
    ) || echo "case $case_id: wrapper exit $?"
    echo "case $case_id: end $(date -Is)"
done
