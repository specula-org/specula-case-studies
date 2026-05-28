#!/usr/bin/env bash
# Runs every Specula reproduction test for aptos-quorum-store.
#
# Two stages:
#   1. Standalone Rust binary at repro/T3/ — Level 0 black-box pattern repro
#      for the BatchRequester subscriber_rx mishandling (T3).
#   2. In-workspace integration tests at consensus/src/quorum_store/tests/
#      specula_repro_tests.rs — every R*/T*/B* finding gets an audit or
#      reproduction. The two REPRODUCED bugs (R5, T3) use #[should_panic].
#
# Re-run as:  bash run_all.sh   (from inside .specula-output/repro/)

set -euo pipefail

cd "$(dirname "$0")"
REPRO_DIR="$(pwd)"
ROOT="$REPRO_DIR/../../artifact/aptos-core"

echo "==[ Stage 1 ]== Standalone Rust binary repro for T3 (pattern-level)"
(
    cd "$REPRO_DIR/T3"
    timeout 60 cargo run --release --quiet 2>&1 | tail -20
)
echo

echo "==[ Stage 2 ]== In-workspace specula_repro_tests"
(
    cd "$ROOT"
    timeout 180 cargo test -p aptos-consensus --lib specula_repro -- --nocapture 2>&1 | tail -30
)
