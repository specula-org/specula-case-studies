#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPECULA_OUTPUT_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
FRR_SRC="${FRR_SRC:-/home/ubuntu/network-control-plane/workspaces/frr/frr-v030-codex-gpt55-xhigh-full-docker-mp4-ee765f7-20260727-150850}"
IMAGE="${IMAGE:-ncp/frr-replay:ubuntu22-topotest}"
PERSIST_DIR="${PERSIST_DIR:-$SPECULA_OUTPUT_DIR/persist}"
TRACES_DIR="$SPECULA_OUTPUT_DIR/traces"

mkdir -p "$TRACES_DIR" "$PERSIST_DIR"
chmod 0777 "$TRACES_DIR"

bash "$HARNESS_DIR/apply.sh"

(cd "$FRR_SRC" && git ls-files -z --cached --others --exclude-standard) \
	> "$SPECULA_OUTPUT_DIR/git-ls-files"

rm -f "$TRACES_DIR"/*.ndjson "$TRACES_DIR"/*.notify "$TRACES_DIR"/*.wrapper

docker run --rm --privileged --network=none \
	-v "$SPECULA_OUTPUT_DIR:/tmp" \
	-v "$FRR_SRC:/root/host-frr:ro" \
	-v "$PERSIST_DIR:/root/persist" \
	-e TOPOTEST_CLEAN="${TOPOTEST_CLEAN:-1}" \
	-e TOPOTEST_VERBOSE="${TOPOTEST_VERBOSE:-0}" \
	-e TOPOTEST_DOC=0 \
	-e TOPOTEST_SANITIZER="${TOPOTEST_SANITIZER:-0}" \
	"$IMAGE" \
	/bin/bash /tmp/harness/src/run_specula_topotests.sh

if ! compgen -G "$TRACES_DIR/*.ndjson" >/dev/null; then
	echo "no NDJSON traces were generated in $TRACES_DIR" >&2
	exit 1
fi

python3 - "$TRACES_DIR" <<'PY'
import collections
import json
import pathlib
import sys

trace_dir = pathlib.Path(sys.argv[1])
for path in sorted(trace_dir.glob("*.ndjson")):
    counts = collections.Counter()
    lines = 0
    for line in path.read_text().splitlines():
        obj = json.loads(line)
        if obj.get("tag") == "frr_route_realization":
            counts[obj["event"]["name"]] += 1
            lines += 1
    if lines == 0:
        raise SystemExit(f"{path} contained no trace events")
    print(f"{path.name}: {lines} trace events")
    for name, count in sorted(counts.items()):
        print(f"  {name}: {count}")
PY
