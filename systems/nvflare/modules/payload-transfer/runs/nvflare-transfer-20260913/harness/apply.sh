#!/usr/bin/env bash
set -euo pipefail
HARNESS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_DIR=${NVFLARE_SOURCE:-/home/ubuntu/nvflare-runs-20260913/source-transfer}
PYTHON=${NVFLARE_PYTHON:-/home/ubuntu/nvflare-runs-20260913/venv-transfer/bin/python}
PIN=53ba7ee567468ea7971dad4faccef13c6cb35dc2
test "$(git -C "$SOURCE_DIR" rev-parse HEAD)" = "$PIN"
PATCH="$HARNESS_DIR/patches/instrumentation.patch"
if git -C "$SOURCE_DIR" apply --reverse --check "$PATCH" 2>/dev/null; then
    echo 'Instrumentation patch already applied'
else
    git -C "$SOURCE_DIR" apply --check "$PATCH"
    git -C "$SOURCE_DIR" apply "$PATCH"
fi
cp "$HARNESS_DIR/src/specula_trace.py" "$SOURCE_DIR/nvflare/fuel/f3/streaming/specula_trace.py"
echo "Instrumentation ready at $SOURCE_DIR"
