#!/usr/bin/env bash
# Self-contained reproduction runner for solana_4 bugs.
#
# Bug 1 (set_genesis_block PreFFA): integration test inside agave-votor-messages crate.
# Bug 2 (BankForks triple deadlock): standalone Rust file, no agave deps.
# Bug 3 (spec-overpermissive double vote): standalone Rust file, no agave deps.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
AGAVE="$HERE/../../artifact/agave"
TMP="${TMPDIR:-/tmp}"

echo "============================================================"
echo "Bug 1: set_genesis_block PreFFA panic"
echo "============================================================"
# Copy into agave's votor-messages crate as an integration test.
mkdir -p "$AGAVE/votor-messages/tests"
cp "$HERE/test_bug1_set_genesis_block_preffa.rs" "$AGAVE/votor-messages/tests/"
( cd "$AGAVE" \
  && timeout 300 cargo test --quiet -p agave-votor-messages \
      --test test_bug1_set_genesis_block_preffa \
      --features agave-unstable-api 2>&1 | tail -30 )

echo
echo "============================================================"
echo "Bug 2: BankForks triple-thread deadlock"
echo "============================================================"
cp "$HERE/test_bug2_bankforks_deadlock.rs" "$TMP/"
timeout 60 rustc --edition 2021 --test "$TMP/test_bug2_bankforks_deadlock.rs" -o "$TMP/test_bug2"
timeout 60 "$TMP/test_bug2" --test-threads=1 --nocapture 2>&1 | tail -30

echo
echo "============================================================"
echo "Finding 3: spec-overpermissive double vote (Case B)"
echo "============================================================"
cp "$HERE/test_bug3_double_vote_spec_overpermissive.rs" "$TMP/"
timeout 60 rustc --edition 2021 --test "$TMP/test_bug3_double_vote_spec_overpermissive.rs" -o "$TMP/test_bug3"
timeout 30 "$TMP/test_bug3" --test-threads=1 --nocapture 2>&1 | tail -40
