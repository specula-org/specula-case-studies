#!/usr/bin/env bash
# Bug 7 / F7: generate_salt non-cryptographic randomness.
#
# Claim (modeling brief F7): collection/mod.rs generate_salt() uses
# DefaultHasher hashing Instant::now() — not a CSPRNG. Brief says
# "current usage is safe, worth a PR to switch to rand::random()".
#
# Test: 10000 rapid calls to generate_salt_local() (replicates the function
# since it's private). Assert collision rate < 1% (production network rate
# makes tight-loop collisions a non-issue in practice).
#
# Result: documentation hazard. Not a safety bug.

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

cp "$REPRO/repro_lib.rs" "$STAGED"
cp "$MOD_FILE" "$BACKUP_MOD"
if ! grep -q "^mod repro;" "$MOD_FILE"; then
    sed -i '1a mod repro;' "$MOD_FILE"
fi

cd "$ROOT"
echo "=== Running F7 reproduction ==="
echo "Test: testing::repro::bug7_generate_salt_uniqueness (10k tight-loop calls)"
echo
timeout 120 cargo test --release --package aleph-bft \
    testing::repro::bug7_generate_salt_uniqueness \
    -- --nocapture 2>&1 | tail -20
status=${PIPESTATUS[0]}
echo
echo "=== Exit status: $status ==="
if [ $status -eq 0 ]; then
    echo "TEST PASSED: collision rate < 1% in tight loop."
    echo "F7 is a documentation/hardening hazard, not a safety bug at current usage."
    echo "Status: FALSE POSITIVE (Level 0) — confirmed as 'hardening recommendation'"
else
    echo "TEST FAILED — collision rate too high."
    echo "Status: REPRODUCED (Level 0)"
fi
exit $status
