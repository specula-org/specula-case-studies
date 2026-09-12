#!/usr/bin/env bash
set -euo pipefail
harness_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_dir="${1:-${TEMPORAL_SOURCE:-/home/ubuntu/temporal-investigation-20260909/restart-20260909-1600/source-update}}"
exec python3 "$harness_dir/apply.py" "$source_dir"
