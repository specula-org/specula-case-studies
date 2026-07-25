#!/usr/bin/env bash
# apply.sh — Apply TLA trace instrumentation to artifact/libspdm
# Run from the experiment root directory: bash harness/apply.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "[apply.sh] Applying instrumentation..."
python3 harness/patches/patch_library.py
echo "[apply.sh] Done."
