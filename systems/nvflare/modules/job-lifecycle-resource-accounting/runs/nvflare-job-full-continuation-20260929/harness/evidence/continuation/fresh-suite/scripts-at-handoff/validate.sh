#!/bin/bash
# Schema + scenario integrity, then one budgeted TLC task at a time (2 GiB heap, 1 GiB offheap, 1 worker).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/paths.sh"
exec "$NVF_PYTHON" "$SCRIPT_DIR/src/validate_traces.py" "$@"
