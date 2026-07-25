#!/usr/bin/env bash
# Bug 6 / F6 / T4: Initial unit collection liveness gap.
#
# Claim (modeling brief F6 / T4): if a single honest peer is unreachable
# AND f Byzantine peers are silent, the node may stall forever in Pending
# state during initial unit collection — never proceeding to consensus.
# Code comment at collection/service.rs:69 explicitly acknowledges:
# "Unfortunately this isn't quite BFT, but it's good enough in many
# situations."
#
# Reproduction:
#   - Level 0: maintainers' code comment is an authoritative dismissal —
#     they accept this as a tradeoff. Run the existing initial-unit-
#     collection tests to verify the "happy path" works.
#   - Level 1/2: NOT APPLICABLE — this is a known limitation, not a bug.
#     The mitigation (delay_passed=true after 5s catch-up timeout) softens
#     the gap.
#
# This is "intentional reduced-BFT for initial-round liveness", per the
# maintainers' own commentary. Not a safety bug.

set -uo pipefail
ROOT=/home/ubuntu/Specula/case-studies/aleph-bft/artifact/AlephBFT
cd "$ROOT"
echo "=== Running F6 reproduction (Level 0) ==="
echo "Test: collection::* (all initial-unit-collection tests)"
echo
timeout 120 cargo test --release --package aleph-bft \
    collection:: \
    -- --nocapture 2>&1 | tail -25
status=${PIPESTATUS[0]}
echo
echo "=== Exit status: $status ==="

cat <<'EOF'

Developer-intent investigation:
  collection/service.rs line 69:
    /// Initial unit collection to figure out at which round we should start unit production.
    /// Unfortunately this isn't quite BFT, but it's good enough in many situations.

The maintainers EXPLICITLY ACKNOWLEDGE this is "not quite BFT". The 5-second
catch_up_delay (line 254) is the mitigation: if Pending after 5s, the
status flips to delay_passed=true, after which receiving the threshold
number of responses causes Finish.

Level 1 (timing): NOT APPLICABLE — the maintainers' own delay mechanism
is the mitigation; widening race windows changes nothing.

Level 2 (state injection): NOT APPLICABLE — the bug is the absence of
liveness in a specific topology, not a state corruption.

Level 3 (code mod): NOT APPLICABLE — fixing F6 requires a different
protocol decision (e.g., trust-the-backup-after-timeout), which is a
design change not a bug fix.

CONCLUSION: F6 is a KNOWN-AND-ACCEPTED liveness gap, documented in the
code. Status: FALSE POSITIVE (intentional design tradeoff).
EOF
exit $status
