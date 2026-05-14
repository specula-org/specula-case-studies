#!/usr/bin/env bash
# Apply DPDK rte_ring trace instrumentation.
#
#   1. Reset DPDK ring sources to a clean state (git checkout).
#   2. Copy harness's trace header into lib/ring/ so `#include
#      <rte_ring_tla_trace.h>` resolves during DPDK build.
#   3. Run instrument.py to inject trace emit calls.
#
# Idempotent: re-running starts from a clean tree each time.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "$0")" && pwd)"
CASE_DIR="$(cd "$HARNESS_DIR/.." && pwd)"
DPDK_DIR="$CASE_DIR/../artifact/dpdk"
RING_DIR="$DPDK_DIR/lib/ring"

if [ ! -d "$RING_DIR" ]; then
	echo "ERROR: ring source dir not found at $RING_DIR" >&2
	exit 1
fi

echo "=== Apply: reset ring sources to clean state ==="
git -C "$DPDK_DIR" checkout -- lib/ring/

echo "=== Apply: copy trace header ==="
cp "$HARNESS_DIR/src/rte_ring_tla_trace.h" "$RING_DIR/"

# Add the new header to lib/ring/meson.build so DPDK builds with it.
MESON="$RING_DIR/meson.build"
if ! grep -q rte_ring_tla_trace.h "$MESON"; then
	python3 - <<EOF
import pathlib
p = pathlib.Path("$MESON")
src = p.read_text()
if "rte_ring_tla_trace.h" not in src:
    src = src.replace(
        "'rte_ring_core.h',",
        "'rte_ring_core.h',\n        'rte_ring_tla_trace.h',",
        1)
    p.write_text(src)
    print("  added rte_ring_tla_trace.h to meson indirect_headers")
EOF
fi

# DPDK auto-generates the ring exports map from RTE_EXPORT_*_SYMBOL
# macros; instrument.py adds RTE_EXPORT_INTERNAL_SYMBOL lines for
# __tla_lcore_fp / __tla_lcore_tid in soring.c, so the generator picks
# them up automatically.

echo "=== Apply: inject trace emits ==="
python3 "$HARNESS_DIR/instrument.py" "$DPDK_DIR"

echo "=== Apply: done ==="
