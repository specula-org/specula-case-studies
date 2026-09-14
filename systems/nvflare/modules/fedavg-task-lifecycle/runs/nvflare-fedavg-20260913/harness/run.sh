#!/usr/bin/env bash
set -euo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR=/home/ubuntu/nvflare-runs-20260913/source-fedavg
PYTHON=/home/ubuntu/nvflare-runs-20260913/venv-fedavg/bin/python
export TRACE_DIR="$HARNESS_DIR/../traces"
export HARNESS_REPORT_DIR="$HARNESS_DIR/reports"
export PYTHONPATH="$SOURCE_DIR:$HARNESS_DIR/src${PYTHONPATH:+:$PYTHONPATH}"
export TMPDIR=/home/ubuntu/nvflare-runs-20260913/scratch/fedavg/harness-tmp
export TLC_STATE_DIR=/home/ubuntu/nvflare-runs-20260913/scratch/fedavg/tlc
mkdir -p "$TRACE_DIR" "$HARNESS_REPORT_DIR" "$TMPDIR" "$TLC_STATE_DIR"
bash "$HARNESS_DIR/apply.sh"
timeout 60 "$PYTHON" -m compileall -q "$SOURCE_DIR/nvflare/_specula_trace.py" "$HARNESS_DIR/src"
cd "$SOURCE_DIR"
timeout 300 "$PYTHON" -m pytest -o addopts= -o cache_dir="$TMPDIR/pytest-cache" --basetemp="$TMPDIR/pytest-work" \
  "$HARNESS_DIR/src/fedavg_trace_test.py" -q "$@" 2>&1 | tee "$HARNESS_REPORT_DIR/pytest.log"
wc -l "$TRACE_DIR"/*.ndjson
timeout 60 "$PYTHON" "$HARNESS_DIR/src/audit_traces.py"
timeout 300 /home/ubuntu/nvflare-runs-20260913/specula/tools/trace_debugger/.venv/bin/python \
  "$HARNESS_DIR/src/validate_traces.py" | tee "$HARNESS_REPORT_DIR/replay.log"
