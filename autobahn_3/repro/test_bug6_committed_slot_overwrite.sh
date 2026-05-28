#!/usr/bin/env bash
# Reproduction for Bug 6 (composition Family 1+2+8): unconditional
# committed_slots overwrite at core.rs:1629.
#
# Same injection strategy as test_bug5_no_leader_check.sh.

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

cp "$TARGET" "$BACKUP"
cat "$REPRO/test_bug6_committed_slot_overwrite.rs" >> "$TARGET"

cd "$REPO"
echo "=== Bug 6 reproduction ==="
timeout 5m cargo test -p primary --lib bug6_committed_slot_overwrite -- --nocapture 2>&1 | tail -25
