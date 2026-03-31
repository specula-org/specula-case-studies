#!/bin/bash
# Bug TV-1: Receiver::len() panics in debug mode at u64 position wraparound
#
# broadcast.rs line 1251:
#   (next_send_pos - self.next) as usize
#
# Uses non-wrapping subtraction. When tail.pos wraps past u64::MAX back to
# small values, next_send_pos < self.next, causing u64 underflow panic in
# debug builds. In release builds, wrapping arithmetic gives the correct answer.
#
# The rest of the codebase consistently uses wrapping_add/wrapping_sub for
# position arithmetic. This is an oversight.
#
# Reproduction: Level 3 (minimal source modification)
# Change initial tail.pos to u64::MAX - 5 so wraparound occurs after 6 sends.

set -euo pipefail

TOKIO_DIR="/home/ubuntu/Specula/case-studies/tokio-broadcast/artifact/tokio"
BROADCAST="$TOKIO_DIR/tokio/src/sync/broadcast.rs"

echo "=== Bug TV-1: Receiver::len() u64 wraparound panic ==="
echo ""

cleanup() {
    echo "[cleanup] Reverting source modifications..."
    cd "$TOKIO_DIR" && git checkout -- tokio/src/sync/broadcast.rs 2>/dev/null || true
    rm -f "$TOKIO_DIR/tokio/tests/test_len_wraparound.rs"
}
trap cleanup EXIT

# Step 1: Patch source — start tail.pos near u64::MAX
echo "[1/4] Patching broadcast.rs to start tail.pos at u64::MAX - 5..."

# Change initial tail position from 0 to u64::MAX - 5
# Line: pos: 0,  (in the Tail struct initialization)
sed -i 's/tail: Mutex::new(Tail {/tail: Mutex::new(Tail {/' "$BROADCAST"
sed -i '/tail: Mutex::new(Tail {/{n;s/pos: 0,/pos: u64::MAX - 5,/}' "$BROADCAST"

# Change initial slot positions to be relative to the new start
sed -i 's/pos: (i as u64)\.wrapping_sub(capacity as u64),/pos: (u64::MAX - 5).wrapping_add(i as u64).wrapping_sub(capacity as u64),/' "$BROADCAST"

# Change initial receiver next from 0 to match tail.pos
# In channel() function: next: 0,
sed -i '/let rx = Receiver {/{n;n;s/next: 0,/next: u64::MAX - 5,/}' "$BROADCAST"

# Also fix the emit_subscribe call that hardcodes 0 for pos
sed -i 's/tla_trace::emit_subscribe(ts, ts, &format!("r{}", trace_id), 0, 1);/tla_trace::emit_subscribe(ts, ts, \&format!("r{}", trace_id), u64::MAX - 5, 1);/' "$BROADCAST"

echo "  Patch applied."

# Step 2: Write integration test
echo "[2/4] Writing integration test..."
cat > "$TOKIO_DIR/tokio/tests/test_len_wraparound.rs" << 'TESTEOF'
use tokio::sync::broadcast;

#[tokio::test(flavor = "current_thread")]
async fn len_panics_at_u64_wraparound() {
    // With the patch, tail.pos starts at u64::MAX - 5.
    // Channel capacity = 4 (rounded to power of 2).
    let (tx, mut rx) = broadcast::channel::<i32>(4);

    // Send 8 values to wrap tail.pos past u64::MAX.
    // tail.pos advances: MAX-5, MAX-4, MAX-3, MAX-2, MAX-1, MAX, 0, 1, 2
    // After 8 sends: tail.pos = (MAX-5).wrapping_add(8) = 2
    for i in 0..8 {
        let _ = tx.send(i);
    }

    // Receiver starts at next = MAX-5. After 8 sends with capacity 4,
    // the receiver is lagged. First try_recv returns Lagged.
    match rx.try_recv() {
        Err(broadcast::error::TryRecvError::Lagged(n)) => {
            eprintln!("  Lagged by {} (expected)", n);
        }
        other => {
            eprintln!("  First recv: {:?}", other);
        }
    }

    // After lag recovery, rx.next = tail.pos - capacity = 2.wrapping_sub(4) = u64::MAX - 1
    // Now: tail.pos = 2, rx.next = u64::MAX - 1
    //
    // len() computes: (2) - (u64::MAX - 1) = UNDERFLOW
    //   - Debug mode: PANIC (attempt to subtract with overflow)
    //   - Release mode: wrapping gives 3 (correct answer)
    eprintln!("  About to call rx.len() [next={}, tail.pos should be ~2]...", rx.len());
    eprintln!("  If you see this line, the bug was NOT triggered.");
}
TESTEOF

# Step 3: Run in debug mode
echo "[3/4] Running test in DEBUG mode (expecting panic from u64 underflow)..."
echo ""
set +e
OUTPUT=$(cd "$TOKIO_DIR" && cargo test -p tokio --features "sync,macros,rt" --test test_len_wraparound -- --nocapture 2>&1)
EXIT_CODE=$?
set -e

echo "--- DEBUG MODE OUTPUT (last 40 lines) ---"
echo "$OUTPUT" | tail -40
echo "--- END OUTPUT ---"
echo ""

if [ $EXIT_CODE -ne 0 ] && echo "$OUTPUT" | grep -qi "overflow\|underflow\|panicked\|subtract"; then
    echo "*** BUG REPRODUCED: len() panicked due to u64 underflow in debug mode ***"
    DEBUG_RESULT="REPRODUCED"
else
    echo "*** Bug NOT triggered in debug mode (exit=$EXIT_CODE) ***"
    DEBUG_RESULT="NOT_TRIGGERED"
fi

# Step 4: Run in release mode
echo ""
echo "[4/4] Running test in RELEASE mode (expecting success via wrapping arithmetic)..."
set +e
OUTPUT_REL=$(cd "$TOKIO_DIR" && cargo test --release --test test_len_wraparound -- --nocapture 2>&1)
EXIT_CODE_REL=$?
set -e

echo ""
echo "--- RELEASE MODE OUTPUT (last 20 lines) ---"
echo "$OUTPUT_REL" | tail -20
echo "--- END OUTPUT ---"
echo ""

if [ $EXIT_CODE_REL -eq 0 ]; then
    echo "*** Release mode: PASS (wrapping arithmetic gives correct result) ***"
    RELEASE_RESULT="PASS"
else
    echo "*** Release mode: FAIL (exit=$EXIT_CODE_REL) ***"
    RELEASE_RESULT="FAIL"
fi

echo ""
echo "=== SUMMARY ==="
echo "  Debug mode:   $DEBUG_RESULT"
echo "  Release mode: $RELEASE_RESULT"
echo "  Bug TV-1 is a debug-mode panic in Receiver::len() at u64 position wraparound."
echo "  In release mode, wrapping arithmetic accidentally gives the correct result."
echo "==="
