#!/bin/bash
# Remove the instrumented copy and harness build products (the arm's source tree is never modified by apply.sh).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
rm -rf "$SCRIPT_DIR/build"
echo "removed $SCRIPT_DIR/build"
