#!/usr/bin/env bash
# Continues the bounded reachability search for traces whose wrapper replay
# stopped on TLC's periodic TraceMatched check.
# Usage: run_trace_reachability.sh OUT_DIR CASE...   (CASE is a two-digit number)
#
# TraceMatched is universal: a dead interleaving falsifies it even when another
# interleaving consumes every stream. TLC checks it periodically by default and
# stops there. "-lncheck final" defers it to the end of the search, so the
# TraceIncomplete sentinel can still be reached. Spec and Trace.cfg are unchanged.
# The wrapper does not accept -lncheck, so this calls java with the same budget
# the wrapper used (2 GiB heap, 512 MiB off-heap, 2 workers). It runs alone in
# this lane, inside the 4 GiB / 2-worker limit.
set -euo pipefail

SPEC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRACE_DIR="$SPEC_DIR/../traces"
LIB="${SPECULA_ROOT:?}/lib"
MEM_GATE=/home/chin39/Documents/play/specula-profile-local-artifacts/parallel-scopes-2026-10-04/effective-mem-gib.sh
OUT_DIR="$1"
shift
mkdir -p "$OUT_DIR"

for case_id in "$@"; do
    trace="$TRACE_DIR/case-$case_id.ndjson"
    log="$OUT_DIR/trace-case-$case_id.out"
    free_gib="$(sh "$MEM_GATE")"
    if ! awk -v f="$free_gib" 'BEGIN { exit !(f >= 6) }'; then
        echo "case $case_id: memory gate not met ($free_gib GiB < 6 GiB); stopping" >&2
        exit 3
    fi
    metadir="$(mktemp -d "${TMPDIR:-/tmp}/tlc-states-XXXXXX")"
    echo "case $case_id: start $(date -Is) effective_mem_gib=$free_gib"
    (
        cd "$SPEC_DIR"
        JSON="$trace" timeout 15m java -XX:+UseParallelGC \
            -Dtlc2.tool.fp.FPSet.impl=tlc2.tool.fp.OffHeapDiskFPSet \
            -XX:MaxDirectMemorySize=512M -Xmx2G -Xms2G \
            -cp "$LIB/CommunityModules-deps.jar:$LIB/tla2tools.jar" tlc2.TLC \
            -config Trace.cfg Trace.tla -workers 2 -deadlock -lncheck final \
            -metadir "$metadir" > "$log" 2>&1
    ) || echo "case $case_id: tlc exit $?"
    rm -rf "$metadir"
    echo "case $case_id: end $(date -Is)"
done
