#!/usr/bin/env bash
# Reproduction harness for Bug 1 / F1 (alerter accept-then-verify split).
#
# Strategy: stage repro_lib.rs into the consensus crate as an additional
# test module, run `cargo test` for the bug1 test, capture output. Cleanup
# always.
#
# Level 0 (black-box-ish): we use only the public alerter Service + Handler
# constructors via the same internal-test framework the AlephBFT maintainers
# use (the alerter module is `mod alerts;` private; the existing
# testing/alerts.rs already accesses it the same way).

set -uo pipefail
ROOT=/home/ubuntu/Specula/case-studies/aleph-bft/artifact/AlephBFT
REPRO=/home/ubuntu/Specula/case-studies/aleph-bft/.specula-output/repro
STAGED="$ROOT/consensus/src/testing/repro.rs"
MOD_FILE="$ROOT/consensus/src/testing/mod.rs"
BACKUP_MOD="$REPRO/.testing-mod.rs.bak"

cleanup() {
    rm -f "$STAGED"
    if [ -f "$BACKUP_MOD" ]; then
        cp "$BACKUP_MOD" "$MOD_FILE"
        rm -f "$BACKUP_MOD"
    fi
}
trap cleanup EXIT

# Stage the test file.
cp "$REPRO/repro_lib.rs" "$STAGED"

# Register the module.
cp "$MOD_FILE" "$BACKUP_MOD"
if ! grep -q "^mod repro;" "$MOD_FILE"; then
    # insert `mod repro;` right after `mod alerts;` (or wherever, top of file is fine)
    sed -i '1a mod repro;' "$MOD_FILE"
fi

cd "$ROOT"
echo "=== Running F1 reproduction ==="
echo "Test: bug1_alerter_bad_commitment_does_not_block_honest_detector"
echo "Command: cargo test --release --package aleph-bft testing::repro::bug1_alerter_bad_commitment_does_not_block_honest_detector -- --nocapture"
echo
timeout 180 cargo test --release --package aleph-bft \
    testing::repro::bug1_alerter_bad_commitment_does_not_block_honest_detector \
    -- --nocapture 2>&1 | tail -80
status=${PIPESTATUS[0]}
echo
echo "=== Exit status: $status ==="
echo
if [ $status -eq 0 ]; then
    echo "TEST PASSED: honest detector's alert succeeds even after byz bad-commitment alert."
    echo "This means the F1 bug DOES NOT MANIFEST — the dedup is per-(sender,forker),"
    echo "so the byzantine sender's bad alert occupies only its own slot."
    echo "Status: REPRODUCTION FAILED (Level 0) — bug doesn't trigger as claimed."
else
    echo "TEST FAILED: honest detector's alert was blocked."
    echo "Status: REPRODUCED (Level 0)"
fi
exit $status
