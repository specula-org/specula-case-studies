#!/usr/bin/env bash
# Run the v11 Attach trace harness on the exported copy of the pinned source.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../../.." && pwd)"
SRC=/home/ubuntu/nvflare-integrated-model-20261103/sources/current
REV=c411a201ead0ec2d4bd0df27fc8b88955c086cfd
PY=/home/ubuntu/specula-nvflare-gpt-continuation-20260926/nvflare-venv/bin/python
COPY="$WS/.tmp/nvflare-src"
if [ ! -f "$COPY/nvflare/__init__.py" ]; then
  mkdir -p "$COPY" && git -C "$SRC" archive "$REV" | tar -x -C "$COPY"
fi
cp "$HERE/tv_attach_test.py" "$COPY/tests/integration_test/fast/tv_attach_test.py"
cd "$COPY"
TV_ATTACH_OUT="$HERE/traces" PYTHONDONTWRITEBYTECODE=1 "$PY" -B -m pytest -p no:cacheprovider -q -s \
  --basetemp="$WS/.tmp/pt/tvat" tests/integration_test/fast/tv_attach_test.py "$@"
