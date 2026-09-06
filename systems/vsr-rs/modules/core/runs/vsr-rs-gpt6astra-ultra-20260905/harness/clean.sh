#!/usr/bin/env bash
set -euo pipefail
HARNESS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SOURCE_DIR=${VSR_SOURCE_DIR:-"$(dirname -- "$(dirname -- "$HARNESS_DIR")")/source"}
python3 "$HARNESS_DIR/manage.py" clean "$SOURCE_DIR"
