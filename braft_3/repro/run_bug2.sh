#!/bin/bash
# Reproduction attempt for Bug 2: concurrent install_snapshot regressing
# persistedSnapshotIndex.
#
# Outcome: REPRODUCTION FAILED — the scenario the spec models is not
# reachable through real braft APIs. See confirmed-bugs.md Bug 2 for the
# code-audit reasoning. The test below executes the analogous integration
# scenario end-to-end and confirms `lastSnapshotIndex` never regresses,
# corroborating the false-positive classification.

set -e

REPRO_DIR="$(cd "$(dirname "$0")" && pwd)"
BRAFT_DIR="/home/ubuntu/Specula/case-studies/braft_3/artifact/braft"
TEST_SRC="$REPRO_DIR/test_bug2_snapshot_regression.cpp"
TEST_DEST="$BRAFT_DIR/test/test_snapshot_regression.cpp"
BUILD_DIR="$BRAFT_DIR/build"

echo "=== Bug 2 reproduction attempt: snapshot index regression ==="
echo

cp "$TEST_SRC" "$TEST_DEST"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
cmake -DBUILD_UNIT_TESTS=ON .. > /dev/null
make -j4 test_snapshot_regression 2>&1 | tail -3

cd "$BUILD_DIR/test"
echo
echo "=== Running test ==="
timeout 90s ./test_snapshot_regression 2>&1 | \
    grep -E "REPRO-RESULT|leader snapshot done|follower (before|after)|\[       OK \]|\[  PASSED  \]|\[  FAILED  \]"
