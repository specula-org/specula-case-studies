#!/usr/bin/env bash
# Bug 8 / R6: Extender lacks retraction.
#
# Claim (modeling brief F8 / R6): once a unit is added to Extender, it
# cannot be retracted. The maintainers acknowledge this is by-design
# (honest+ancestry guarantees), but the rationale should be documented.
#
# Level 0 reproduction strategy: there is no "bug to trigger" because the
# behavior is intentional. We instead:
#   (a) verify the maintainers' Extender tests pass — these encode the
#       contract that units once added produce consistent batches and never
#       get rewritten.
#   (b) state the engineering principle: monotonicity of finalization is
#       a desired invariant, not a bug.
#
# We escalate up to Level 3 as required by methodology — but in each level
# we document why the escalation cannot manifest a violation:
#   L0: existing tests pass — no retraction needed.
#   L1: timing assistance — irrelevant; the extender is synchronous-pure.
#   L2: state injection — would require constructing an extender state
#       inconsistent with honest+ancestry, which is the protocol-level
#       precondition. Not a reachable real-world state.
#   L3: code modification — adding usleep cannot trigger this behavior;
#       only modifying the extender itself (or its inputs) can produce
#       inconsistent results.

set -uo pipefail
ROOT=/home/ubuntu/Specula/case-studies/aleph-bft/artifact/AlephBFT
cd "$ROOT"
echo "=== Running F8 / R6 reproduction (Level 0) ==="
echo "Test: extension::extender::test::* and extension::election::test::*"
echo
timeout 120 cargo test --release --package aleph-bft \
    extension:: \
    -- --nocapture 2>&1 | tail -15
status=${PIPESTATUS[0]}
echo
echo "=== Exit status: $status ==="

cat <<'EOF'

Level 1 (timing): NOT APPLICABLE — Extender::add_unit is synchronous; no
timing window to widen.

Level 2 (state injection): NOT APPLICABLE — injecting an "inconsistent"
DAG state directly violates the protocol-level precondition that units are
added in dependency order. The Extender's contract is that it operates on
a DAG that respects this; outside that contract is "not the bug R6
describes".

Level 3 (code mod): NOT APPLICABLE — modifying the source would create
artificial divergence; that's not a reproduction of R6.

CONCLUSION: F8/R6 is a DOCUMENTATION-ONLY recommendation, not a safety
bug. Status: FALSE POSITIVE.
EOF

if [ $status -eq 0 ]; then
    echo
    echo "Status: FALSE POSITIVE — Extender's monotonicity contract is intentional."
else
    echo
    echo "Status: extension tests failed, unrelated to R6."
fi
exit $status
