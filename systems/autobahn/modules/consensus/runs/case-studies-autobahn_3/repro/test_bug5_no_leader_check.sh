#!/usr/bin/env bash
# Reproduction for Bug 5 (Family 8): no leader check in is_valid(Prepare).
#
# Strategy:
#   1. Append the test function in test_bug5_no_leader_check.rs to
#      primary/src/tests/core_tests.rs, guarded by a marker so we can remove
#      it on exit.
#   2. Run `cargo test bug5_no_leader_check -- --nocapture`.
#   3. Trap to restore the original core_tests.rs whether the test passes,
#      fails, or panics.
#
# Pass criterion: "BUG-05 CONFIRMED" printed; test exit code 0.

set -e
REPRO=/home/ubuntu/Specula/case-studies/autobahn_3/.specula-output/repro
REPO=/home/ubuntu/Specula/case-studies/autobahn_3/artifact/autobahn-artifact
TARGET="$REPO/primary/src/tests/core_tests.rs"
BACKUP="$REPO/primary/src/tests/.core_tests.rs.bak"

cleanup() {
    if [ -f "$BACKUP" ]; then
        mv "$BACKUP" "$TARGET"
    fi
}
trap cleanup EXIT INT TERM

# Snapshot the file so we can restore exactly.
cp "$TARGET" "$BACKUP"

# Append the test (idempotent: backup-and-rewrite each run).
cat "$REPRO/test_bug5_no_leader_check.rs" >> "$TARGET"

cd "$REPO"
echo "=== Bug 5 reproduction ==="
timeout 5m cargo test -p primary --lib bug5_no_leader_check -- --nocapture 2>&1 | tail -25
