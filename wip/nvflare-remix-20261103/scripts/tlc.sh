#!/usr/bin/env bash
# Run TLC or SANY with all temporary state inside the workspace (/ and /tmp are full).
# Usage: scripts/tlc.sh sany <file.tla>
#        scripts/tlc.sh tlc <dir> <Module> <cfg> [extra TLC args...]
set -euo pipefail
W="$(cd "$(dirname "$0")/.." && pwd)"
export TMPDIR="$W/.tmp"; mkdir -p "$TMPDIR"
JAR="$W/lib/tla2tools.jar"
JOPTS=(-Djava.io.tmpdir="$TMPDIR" -XX:-UsePerfData -XX:+UseParallelGC -DTLA-Library="${MIX_BUILD:+$MIX_BUILD:}${MIX_SPEC:-$W/spec}")
mode="$1"; shift
case "$mode" in
  sany)
    f="$1"; cd "$(dirname "$f")"
    # SANY of the mix root: prefer the per-agent build copy if MIX_BUILD is set
    if [ "$(basename "$f")" = "Mix.tla" ] && [ -n "${MIX_BUILD:-}" ]; then cd "$MIX_BUILD"; fi
    java "${JOPTS[@]}" -cp "$JAR" tla2sany.SANY "$(basename "$f")" ;;
  tlc)
    dir="$1"; mod="$2"; cfg="$3"; shift 3
    cd "$dir"
    meta="$W/.tlc/$(date +%s%N)"; mkdir -p "$meta"
    trap 'rm -rf "$meta"' EXIT
    trap 'kill -TERM "$jpid" 2>/dev/null; rm -rf "$meta"; exit 143' TERM INT
    java "${JOPTS[@]}" -Xmx${TLC_HEAP:-8g} -cp "$JAR" tlc2.TLC -metadir "$meta" -cleanup \
         -workers "${TLC_WORKERS:-8}" -config "$cfg" "$@" "$mod.tla" &
    jpid=$!
    set +e; wait "$jpid"; rc=$?; set -e
    exit $rc ;;
  *) echo "unknown mode $mode" >&2; exit 2 ;;
esac
