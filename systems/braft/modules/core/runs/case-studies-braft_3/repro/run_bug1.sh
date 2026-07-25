#!/bin/bash
# Reproduction script for Bug 1: elect_self sends RequestVote RPCs before persisting (term, votedFor)
#
# Method (Level 2 — state injection via FailableMetaStorage wrapper):
#   - Three-node cluster started normally.
#   - The target follower's _meta_storage pointer is replaced with a FailableMetaStorage
#     wrapper that returns EIO on set_term_and_votedfor.
#   - Leader is stopped; target follower's election timer fires.
#   - elect_self() increments _current_term in memory, sends RequestVote RPCs,
#     then attempts to persist via set_term_and_votedfor() which fails.
#   - Test asserts in-memory term > persisted term.
#
# The failable wrapper simulates the same divergence that a crash between
# the RPC send (node.cpp:1735) and persist completion (node.cpp:1738) would
# produce: peers observe term T while the local disk still records term T-1.
#
# Real-world trigger paths for the same divergence:
#   - ENOSPC/EIO on the meta-storage write (modeled directly here).
#   - Power loss / process kill between line 1735 and line 1748.
#
# The bug-confirmation skill's escalation-ladder note: Level 0 (pure
# black-box) cannot trigger this because real disks rarely fail in tests;
# Level 1 (timing only) cannot, because the persist path is synchronous.
# We use Level 2 (state injection of a failable storage) — minimum invasion
# needed to expose the persistence path's failure handling.

set -e

REPRO_DIR="$(cd "$(dirname "$0")" && pwd)"
BRAFT_DIR="/home/ubuntu/Specula/case-studies/braft_3/artifact/braft"
TEST_SRC="$REPRO_DIR/test_bug1_elect_self_persist.cpp"
TEST_DEST="$BRAFT_DIR/test/test_bug_repro.cpp"
BUILD_DIR="$BRAFT_DIR/build"

echo "=== Bug 1 reproduction: elect_self persist divergence ==="
echo

# Stage the test into the braft_3 test/ directory and build it.
cp "$TEST_SRC" "$TEST_DEST"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
cmake -DBUILD_UNIT_TESTS=ON .. > /dev/null
make -j4 test_bug_repro 2>&1 | tail -3

# Run the test.
cd "$BUILD_DIR/test"
echo
echo "=== Running test ==="
timeout 60s ./test_bug_repro --gtest_filter="*ElectSelfPersistFailureNoTermRollback*" 2>&1 | \
    grep -E "BUG C CONFIRMED|in-memory _current_term|persisted term|term_before|\[       OK \]|\[  PASSED  \]|\[  FAILED  \]"
