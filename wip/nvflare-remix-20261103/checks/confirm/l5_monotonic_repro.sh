#!/usr/bin/env bash
# Export the pinned source (read-only git archive), add the L5 repro next to the
# upstream task-execution integration tests, and run it with the NVFlare venv.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
SRC=/home/ubuntu/nvflare-integrated-model-20261103/sources/current
REV=c411a201ead0ec2d4bd0df27fc8b88955c086cfd
PY=/home/ubuntu/specula-nvflare-gpt-continuation-20260926/nvflare-venv/bin/python
COPY="$WS/.tmp/nvflare-src"
if [ ! -f "$COPY/nvflare/__init__.py" ]; then
  mkdir -p "$COPY" && git -C "$SRC" archive "$REV" | tar -x -C "$COPY"
fi
cp "$HERE/l5_monotonic_repro_test.py" "$COPY/tests/integration_test/fast/l5_monotonic_repro_test.py"
cd "$COPY"
L5_TIMENS_EXEC="$HERE/timens_exec.py" PYTHONDONTWRITEBYTECODE=1 "$PY" -B -m pytest -p no:cacheprovider -q -s \
  --basetemp="$WS/.tmp/pt/l5" tests/integration_test/fast/l5_monotonic_repro_test.py "$@"
