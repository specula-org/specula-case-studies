#!/usr/bin/env bash
# Freeze a consistent copy of spec/ (only if static checks + SANY pass) for
# coordinator campaigns while component agents keep editing spec/.
# Usage: eval "$(scripts/snapshot.sh)"   -> exports MIX_SPEC and MIX_BUILD
set -euo pipefail
W="$(cd "$(dirname "$0")/.." && pwd)"
ts=$(date +%H%M%S); d="$W/.build/snap-$ts"; mkdir -p "$d/spec"
cp "$W"/spec/*.tla "$W"/spec/registry.json "$d/spec/"; cp -r "$W/spec/registry.d" "$d/spec/"
MIX_SPEC="$d/spec" MIX_BUILD="$d/spec" python3 "$W/scripts/gen_mix.py" >&2
( cd "$d/spec" && java -Djava.io.tmpdir="$W/.tmp" -cp "$W/lib/tla2tools.jar" tla2sany.SANY Mix.tla 2>&1 | grep -q -i "error" ) && { echo "SANY failed in snapshot $d" >&2; exit 1; }
echo "export MIX_SPEC=$d/spec MIX_BUILD=$d/spec"
