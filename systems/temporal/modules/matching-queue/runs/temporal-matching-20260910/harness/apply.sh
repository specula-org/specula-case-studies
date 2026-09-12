#!/usr/bin/env bash
set -euo pipefail
harness_dir="$(cd "$(dirname "$0")" && pwd)"
source_dir="${1:-${SOURCE_DIR:-/home/ubuntu/temporal-investigation-20260909/parallel-20260910/source-matching}}"
python3 "$harness_dir/apply.py" "$source_dir"
