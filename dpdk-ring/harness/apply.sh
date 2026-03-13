#!/usr/bin/env bash
# Apply TLA+ trace instrumentation to DPDK ring source.
# Run from the case-study root: cd case-studies/dpdk-ring && bash harness/apply.sh

set -euo pipefail

CASE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DPDK_DIR="$CASE_DIR/artifact/dpdk"
HARNESS_DIR="$CASE_DIR/harness"

echo "=== Applying instrumentation ==="

# 1. Clean DPDK source to known state
echo "Resetting DPDK source..."
git -C "$DPDK_DIR" checkout -- .

# 2. Copy trace header into ring library
echo "Copying trace header..."
cp "$HARNESS_DIR/src/rte_ring_tla_trace.h" "$DPDK_DIR/lib/ring/"

# 3. Apply instrumentation patch
echo "Applying instrumentation patch..."
cd "$DPDK_DIR"
git apply "$HARNESS_DIR/patches/instrumentation.patch"

echo "=== Instrumentation applied ==="
