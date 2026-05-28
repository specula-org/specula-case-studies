#!/usr/bin/env bash
# Reproduction for Bug 1 (Family 1): QC id reconstruction omits proposals.
#
# Demonstrated by three developer-shipped tests:
#   - test_da1_qc_does_not_bind_to_proposals    -- verify_commit accepts two
#                                                  Commits with same QC but
#                                                  different proposals.
#   - test_da2_timeout_digest_hashes_nothing    -- Timeout::digest hashes 0
#                                                  fields; all Timeouts collide.
#   - test_bug03_confirm_double_vote_verify     -- verify_confirm accepts two
#                                                  Confirms with same QC,
#                                                  different proposals.
#
# Pass criterion: all three tests print "CONFIRMED" lines and exit 0.

set -e
REPO=/home/ubuntu/Specula/case-studies/autobahn_3/artifact/autobahn-artifact
cd "$REPO"

echo "=== Bug 1 reproduction ==="
timeout 5m cargo test -p primary --lib \
    test_da1_qc_does_not_bind_to_proposals \
    -- --nocapture 2>&1 | tail -8

timeout 5m cargo test -p primary --lib \
    test_da2_timeout_digest_hashes_nothing \
    -- --nocapture 2>&1 | tail -8

timeout 5m cargo test -p primary --lib \
    test_bug03_confirm_double_vote_verify \
    -- --nocapture 2>&1 | tail -8
