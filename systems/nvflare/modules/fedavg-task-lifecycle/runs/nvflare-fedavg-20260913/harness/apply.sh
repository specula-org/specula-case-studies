#!/usr/bin/env bash
set -euo pipefail
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$HARNESS_DIR/src/instrument_source.py"
