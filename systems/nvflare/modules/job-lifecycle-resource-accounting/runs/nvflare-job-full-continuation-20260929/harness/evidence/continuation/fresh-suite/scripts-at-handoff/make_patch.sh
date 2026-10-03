#!/bin/bash
# Regenerate patches/instrumentation.patch from the edited instrumented copy (harness/build/nvflare_src).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
git -C "$SCRIPT_DIR/build/nvflare_src" diff > "$SCRIPT_DIR/patches/instrumentation.patch"
echo "wrote $SCRIPT_DIR/patches/instrumentation.patch ($(grep -c 'TLA-TRACE' "$SCRIPT_DIR/patches/instrumentation.patch") TLA-TRACE markers)"
