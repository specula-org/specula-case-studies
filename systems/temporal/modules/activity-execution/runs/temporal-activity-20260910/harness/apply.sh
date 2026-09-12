#!/usr/bin/env bash
set -euo pipefail
HARNESS_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
SOURCE_DIR=${SOURCE_DIR:-/home/ubuntu/temporal-investigation-20260909/parallel-20260910/source-activity}
export SOURCE_DIR
python3 "$HARNESS_DIR/apply.py"
