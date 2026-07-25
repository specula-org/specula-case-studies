#!/usr/bin/env bash
# Reproduction for Bug 4 (Family 4): TC::get_winning_proposals assigns
# winning_view := timeout.view instead of *other_view (the QC's actual view).
#
# Demonstrated by:
#   - test_da5_viewchange_wrong_winning_view  -- builds two timeouts where the
#                                                timeout with the lower QC view
#                                                wins because winning_view was
#                                                inflated to timeout.view.
#
# Pass criterion: "DA-5 CONFIRMED" emitted; test exit code 0.

set -e
REPO=/home/ubuntu/Specula/case-studies/autobahn_3/artifact/autobahn-artifact
cd "$REPO"

echo "=== Bug 4 reproduction ==="
timeout 5m cargo test -p primary --lib \
    test_da5_viewchange_wrong_winning_view \
    -- --nocapture 2>&1 | tail -8
