#!/usr/bin/env bash
set -euo pipefail
harness_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
run_dir=$(cd -- "$harness_dir/../.." && pwd)
exec 9>"$harness_dir/run.lock"
flock -n 9 || { echo "Another harness run holds run.lock." >&2; exit 1; }
attempt="$harness_dir/attempts/$(date -u +%Y%m%dT%H%M%SZ)"
for path in "$harness_dir/logs" "$harness_dir/raw" "$harness_dir/../traces"; do
    if [[ -d $path ]] && [[ -n $(ls -A -- "$path") ]]; then
        mkdir -p "$attempt"
        mv -- "$path" "$attempt/$(basename -- "$path")"
    fi
done
mkdir -p "$harness_dir/logs" "$harness_dir/raw" "$harness_dir/../traces"
bash "$harness_dir/apply.sh"
container_name="specula-memfd-harness-$$"
cleanup() { docker rm -f "$container_name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker image inspect asterinas/dev:0.18.1-20260926 \
    --format '{{json .RepoDigests}} {{.Id}}' >"$harness_dir/logs/image.txt"
docker run -d --name "$container_name" --device /dev/kvm --network host \
    -v "$run_dir:/work" -w /work/source --entrypoint sleep \
    asterinas/dev:0.18.1-20260926 infinity >/dev/null
docker exec "$container_name" bash /work/.specula-output/harness/src/run-container.sh
docker inspect "$container_name" --format '{{json .HostConfig.Devices}}' \
    >"$harness_dir/logs/devices.json"
python3 "$harness_dir/src/manifest.py" "$harness_dir"
python3 "$harness_dir/src/collect.py" "$harness_dir/logs/guest.log" \
    --output "$harness_dir/../traces" --raw "$harness_dir/raw" \
    --spec "$harness_dir/../spec/Trace.tla"
python3 - "$harness_dir/../traces" <<'PY'
from pathlib import Path
import sys
for path in sorted(Path(sys.argv[1]).glob('*.ndjson')):
    print(f'{path.name}: {sum(1 for _ in path.open())} lines')
PY
