#!/usr/bin/env bash
set -euo pipefail
harness_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export PYTHONDONTWRITEBYTECODE=1
python3 "$harness_dir/audit.py"
python3 "$harness_dir/validate.py"
python3 "$harness_dir/prepare_oracle.py"
python3 "$harness_dir/validate.py" --oracle
python3 "$harness_dir/negative_traces.py"
if python3 "$harness_dir/validate.py" --parallel "$harness_dir"/negative-traces/*.ndjson; then
    printf 'Expected invalid trace rejections did not occur.\n' >&2; exit 1
fi
if python3 "$harness_dir/validate.py" --oracle --parallel "$harness_dir"/negative-traces/*.ndjson; then
    printf 'Expected named oracle failures did not occur.\n' >&2; exit 1
fi
python3 "$harness_dir/report.py"
