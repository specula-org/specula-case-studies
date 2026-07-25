#!/usr/bin/env bash
# Reproduction for Bug 2 (Family 2): TC::verify short-circuits.
#
# Demonstrated by:
#   - test_da3_tc_verify_always_passes      -- empty TC and under-quorum TC
#                                              both pass TC::verify because
#                                              impl PartialEq for TC returns
#                                              true and the genesis match
#                                              short-circuits.
#   - test_da13_qc_partialeq_always_false   -- mirror image for QC: PartialEq
#                                              always returns false, so the
#                                              QC genesis path is dead code.
#
# Pass criterion: both tests print "CONFIRMED" lines and exit 0.

set -e
REPO=/home/ubuntu/Specula/case-studies/autobahn_3/artifact/autobahn-artifact
cd "$REPO"

echo "=== Bug 2 reproduction ==="
timeout 5m cargo test -p primary --lib \
    test_da3_tc_verify_always_passes \
    -- --nocapture 2>&1 | tail -8

timeout 5m cargo test -p primary --lib \
    test_da13_qc_partialeq_always_false \
    -- --nocapture 2>&1 | tail -8
