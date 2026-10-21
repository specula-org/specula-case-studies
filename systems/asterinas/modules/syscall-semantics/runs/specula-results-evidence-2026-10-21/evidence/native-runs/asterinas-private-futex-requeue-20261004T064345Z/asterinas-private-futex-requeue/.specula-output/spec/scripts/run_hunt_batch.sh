#!/usr/bin/env bash
# Runs hunting configurations one after another through Specula's budgeted
# TLC wrapper (default 3 GiB heap, 1 GiB off-heap, 2 workers, 30-minute TLC
# budget). TLC_HEAP, TLC_OFFHEAP and TLC_WORKERS override the defaults when a
# second TLC shares the lane's 4 GiB / 2-worker limit.
# Usage: run_hunt_batch.sh OUT_DIR MODE CFG...   (MODE is bfs or sim)
#
# Each counterexample is also dumped as JSON for scripts/cex_summary.py.
set -euo pipefail
TLC_HEAP="${TLC_HEAP:-3G}"
TLC_OFFHEAP="${TLC_OFFHEAP:-1G}"
TLC_WORKERS="${TLC_WORKERS:-2}"

SPEC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="${SPECULA_ROOT:?}/scripts/tlc/run_model_check.sh"
MEM_GATE=/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/effective-mem-gib.sh
OUT_DIR="$(mkdir -p "$1" && cd "$1" && pwd)"
MODE="$2"
shift 2

for cfg in "$@"; do
    name="${cfg%.cfg}"
    log="$OUT_DIR/$name-$MODE.out"
    free_gib="$(sh "$MEM_GATE")"
    if ! awk -v f="$free_gib" 'BEGIN { exit !(f >= 6) }'; then
        echo "$cfg: memory gate not met ($free_gib GiB < 6 GiB); stopping" >&2
        exit 3
    fi
    mode_args=()
    if [ "$MODE" = sim ]; then
        mode_args=(-S -n 999999999 -p 100)
    fi
    echo "$cfg $MODE: start $(date -Is) effective_mem_gib=$free_gib"
    (
        cd "$SPEC_DIR"
        # TLC stops itself at 30 minutes. The outer timeout covers a hung JVM.
        timeout 40m "$WRAPPER" -s MC.tla -c "$cfg" "${mode_args[@]}" \
            -m "$TLC_HEAP" -M "$TLC_OFFHEAP" -w "$TLC_WORKERS" -t 30 -j "$OUT_DIR/$name-$MODE.json" \
            -o "$log" > "$log.launcher" 2>&1
    ) || echo "$cfg $MODE: wrapper exit $?"
    echo "$cfg $MODE: end $(date -Is)"
done
