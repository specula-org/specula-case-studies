#!/usr/bin/env bash
# Bug 9 / F9: AsyncWrite::flush not necessarily durable (fsync).
#
# Claim (modeling brief F9 / R3): BackupSaver::save_unit calls
# `write_all + flush` on the embedder-provided AsyncWrite. Per the
# AsyncWrite trait contract, `flush` is NOT fsync — it pushes buffered
# data downstream, but doesn't guarantee disk durability. The contract
# requires the embedder to back the AsyncWrite with an fsync'd layer.
#
# This is a documentation hazard: the AlephBFT library is a *library*, not
# an embedder; the user must wire up durable storage. The brief says R3
# is "Documentation PR" — not a code defect.
#
# Level 0: We verify that BackupSaver's behavior is exactly what the code
# claims: writes encoded units, flushes them, responds back. We use the
# existing `test_proper_relative_responses_ordering` test.
#
# Level 1/2/3: NOT APPLICABLE — this is a contract gap delegated to the
# embedder, not a code defect.

set -uo pipefail
ROOT=/home/ubuntu/Specula/case-studies/aleph-bft/artifact/AlephBFT
cd "$ROOT"
echo "=== Running F9 reproduction (Level 0) ==="
echo "Test: backup::saver::tests::test_proper_relative_responses_ordering"
echo
timeout 60 cargo test --release --package aleph-bft \
    backup::saver \
    -- --nocapture 2>&1 | tail -10
status=${PIPESTATUS[0]}
echo
echo "=== Exit status: $status ==="

cat <<'EOF'

Level 1 (timing): NOT APPLICABLE — durability depends on embedder layer.

Level 2 (state injection): NOT APPLICABLE — to "inject" the non-durable
state, we would have to simulate a power loss inside the embedder's
storage backend. That is OUTSIDE the AlephBFT library, which is the
defendant of this finding.

Level 3 (code mod): NOT APPLICABLE — fsync would have to be added at the
library level, but the design decision is to delegate to embedder.

CONCLUSION: F9 is a CONTRACT-INTENT recommendation. The library's
contract with the embedder is "you give us an AsyncWrite, we'll write+flush".
Whether the embedder honors fsync semantics is outside this library's
scope. The MC report rightly classifies it as "documentation hazard,
not a code defect".

Status: FALSE POSITIVE (documentation/contract issue, not a code bug).
EOF
exit $status
