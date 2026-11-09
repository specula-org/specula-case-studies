#!/usr/bin/env bash
# Run a real two-site Swarm job in the simulator with the v11 trace hooks.
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
SCN="${1:-swarm_ok}"
RUN="$WS/.tmp/swarm_run/$SCN"
rm -rf "$RUN" && mkdir -p "$RUN"
export TV_SWARM_LOG="$RUN/events.jsonl"
export PYTHONPATH="$HERE/hooks:$COPY"
export PYTHONDONTWRITEBYTECODE=1
cd "$COPY"
timeout 600 "$PY" -B "$HERE/run_swarm_job.py" "$RUN/ws" > "$RUN/sim.log" 2>&1 || { echo "simulator failed"; tail -30 "$RUN/sim.log"; exit 1; }
cp "$TV_SWARM_LOG" "$HERE/traces/$SCN.events.jsonl"
wc -l "$HERE/traces/$SCN.events.jsonl"
