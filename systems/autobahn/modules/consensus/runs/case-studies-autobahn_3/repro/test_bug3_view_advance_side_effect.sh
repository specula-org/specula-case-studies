#!/usr/bin/env bash
# Reproduction for Bug 3 (Family 3): view advances inside is_valid(Prepare)
# even when the Prepare is rejected.
#
# Demonstrated by:
#   - bug4_view_advance_side_effect  -- spins up a real Core; sends an INVALID
#                                       Prepare(slot=1, view=3, tc=None) which
#                                       gets rejected; then sends a VALID
#                                       Prepare(slot=1, view=1, tc=None). The
#                                       valid Prepare is NOT voted on because
#                                       views[1] was advanced to 3 as a side
#                                       effect of the rejected message.
#
# Pass criterion: "BUG-04 CONFIRMED" line emitted; test exit code 0.

set -e
REPO=/home/ubuntu/Specula/case-studies/autobahn_3/artifact/autobahn-artifact
cd "$REPO"

echo "=== Bug 3 reproduction ==="
timeout 5m cargo test -p primary --lib \
    bug4_view_advance_side_effect \
    -- --nocapture 2>&1 | tail -12
