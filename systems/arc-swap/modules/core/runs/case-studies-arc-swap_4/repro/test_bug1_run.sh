#!/usr/bin/env bash
# Reproduce arc-swap Bug 1 (Family 5 — generation-wrap panic in confirm_helping).
#
# This script assumes the patch in test_bug1_arc_swap.patch has been applied
# to the working tree (it has, in this round-4 artifact).
#
# We run the in-tree unit test alone (filter) so we don't race with the rest
# of the suite.  Side note: the panicking thread leaves the helping slot's
# `control` set to GEN_TAG, which will cascade-panic any other thread that
# subsequently claims the same Node — yet another consequence of the same
# bug.  Our test cleans up after itself when run alone, but tests racing
# concurrently with it would observe the cascade.  --test-threads=1 sidesteps
# this for ergonomics; running just the one test (cargo test ... <name>) also
# works.

set -euo pipefail

ARC_SWAP_DIR="${ARC_SWAP_DIR:-/home/ubuntu/Specula/case-studies/arc-swap_4/artifact/arc-swap}"
TEST_NAME="confirm_helping_panic_after_generation_wrap"

cd "$ARC_SWAP_DIR"

echo ">>> arc-swap dir: $ARC_SWAP_DIR"
echo ">>> running:      cargo test --lib $TEST_NAME -- --nocapture --test-threads=1"
echo

OUT=$(timeout 5m cargo test --lib "$TEST_NAME" -- --nocapture --test-threads=1 2>&1)

echo "$OUT"
echo
echo ">>> --- evidence check ---"

if echo "$OUT" | grep -q "panicked at src/debt/list.rs:313:37:" \
   && echo "$OUT" | grep -q "LocalNode::with ensures it is set" \
   && echo "$OUT" | grep -qE "test result: ok\. 1 passed; 0 failed"; then
    echo ">>> REPRODUCED: panic at src/debt/list.rs:313 with the documented message."
    exit 0
else
    echo ">>> REPRODUCTION FAILED — see output above."
    exit 1
fi
