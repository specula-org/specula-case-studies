#!/usr/bin/env bash
set -euo pipefail
harness_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
python3 "$harness_dir/clean.py"
