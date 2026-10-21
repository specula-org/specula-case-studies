#!/usr/bin/env bash
set -euo pipefail
h=$(cd -- "$(dirname -- "$0")" && pwd)
out=$(dirname "$h")
run=$(dirname "$out")
reuse=0
if [[ ${1:-} == --reuse-kernel && $# == 1 ]]; then
    python3 "$h/identity.py" "$h" "$run/source" --check-built
    reuse=1
    python3 "$h/preflight.py" "$h" --reuse-kernel
else
    [[ $# == 0 ]]
    bash "$h/apply.sh"
    # The receiver owns heavy.lock throughout this phase. Do not reacquire its lock.
    python3 "$h/preflight.py" "$h"
fi
sudo -n docker -H unix:///var/run/docker.sock image inspect asterinas/kernel-dev:0.18.1-20260926 > "$h/logs/image.json"
sudo -n docker -H unix:///var/run/docker.sock run --rm --cpus=2 --memory=8g --pids-limit=512 --device=/dev/kvm \
    -e SPECULA_CASES="${SPECULA_CASES:-1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18}" \
    -e SPECULA_REUSE_KERNEL="$reuse" \
    -v "$run:/work" asterinas/kernel-dev:0.18.1-20260926 bash /work/.specula-output/harness/container.sh
python3 "$h/normalize.py"
wc -l "$out"/traces/*.ndjson
