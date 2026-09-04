#!/usr/bin/env bash
#
# Reproduction for finding CR-1:
#   "join_thread may lose a thread exit status (reap precedes copy-out to a bad retval pointer)"
#   code-review finding, cited site src/kernel/src/pm/kcall/join_thread.rs:70-77.
#
# ROOT CAUSE (real code):
#   kcall::join_thread reaps the target zombie FIRST, then copies its exit status to the
#   caller-supplied `retval` pointer:
#       let status = ProcessManager::join_thread(pid, tid)?;               // (A) reaps zombie
#       pm::copy_to_user::<ExitStatus>(get_mut(), pid, retval, &status)    // (B) may fail
#           .map_err(SleepError::Generic)?;
#   (A) removes the zombie from the process queue (RunningProcess::try_join_thread, running.rs:561-566)
#   and harvests it (harvest_zombie_thread, unsafe.rs:654-709). If the user `retval` pointer is
#   invalid, (B) returns Err(BadAddress) AFTER the zombie is already gone, so the exit status is lost
#   and a retried join returns NoSuchProcess (running.rs:618-620).
#
# HOW THIS REPRODUCES IT (in-kernel, feature = "test"; real functions, no product logic altered):
#   join_status_test.rs builds a running process that owns a JOINABLE zombie sibling tid=2 carrying
#   exit status 42 -- exactly the state a normal create_thread(2) + child exit_thread(42) produces --
#   then replays the kcall body against it using the REAL RunningProcess::try_join_thread (reap),
#   the REAL ZombieThread::harvest, and the REAL Vmem::copy_to_user_unaligned (bad NULL retval).
#     BUGGY ORDER (reap->copy): copy fails; retry join tid=2 -> NoSuchProcess; status 42 LOST.
#     CORRECT ORDER (validate->reap): NULL retval rejected up front; zombie retained; status 42 kept.
#
# Usage: ./test_bugCR-1_join_reap_before_copy.sh
# Exit 0 iff the "BUG CONFIRMED (CR-1) ... permanently LOST" marker and the correct-order control are
# present and the kernel booted to completion ("hello, world!").

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKTREE="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260729/nanvix/.specula-output/confirmation/CR-1/worktree"
LOG="$HERE/test_bugCR-1_join_reap_before_copy.run.log"
BUILD_LOG="$HERE/test_bugCR-1_build.log"
MODULE_SRC="$HERE/test_bugCR-1_join_reap_before_copy.rs"
STATE_DIR="$WORKTREE/src/kernel/src/pm/process/state"
STATE_MOD="$STATE_DIR/mod.rs"

fail() { echo "[repro] $*"; exit 2; }

cd "$WORKTREE" || fail "worktree not found: $WORKTREE"
[ -f "$MODULE_SRC" ] || fail "module source not found: $MODULE_SRC"

# 1) Install the in-kernel test module (idempotent).
cp -f "$MODULE_SRC" "$STATE_DIR/join_status_test.rs" || fail "copy module"

# 2) Declare the module in process/state/mod.rs, right before `mod kill_test;` (idempotent).
if ! grep -q "mod join_status_test;" "$STATE_MOD"; then
    perl -0777 -pi -e 's/(mod interrupted;\n)(#\[cfg\(feature = "test"\)\]\nmod kill_test;)/$1#[cfg(feature = "test")]\nmod join_status_test;\n$2/' "$STATE_MOD"
fi

# 3) Wire it into the state test aggregator (process/state/mod.rs::test()) (idempotent).
if ! grep -q "join_status_test::test()" "$STATE_MOD"; then
    perl -0777 -pi -e 's/(\n    passed &= kill_test::test\(\);\n)/$1    passed &= join_status_test::test();\n/' "$STATE_MOD"
fi

grep -q "mod join_status_test;" "$STATE_MOD" && grep -q "join_status_test::test()" "$STATE_MOD" \
    || fail "failed to wire the CR-1 test module"
echo "[repro] CR-1 test module installed + wired."

# 4) Build the test kernel + uservm.
echo "[repro] building test kernel + uservm (timeout 45m) ..."
timeout 45m make all-test-kernel all-uservm >"$BUILD_LOG" 2>&1 \
    || { echo "[repro] build failed; see $BUILD_LOG"; tail -60 "$BUILD_LOG"; exit 2; }

# 5) Boot the test kernel in the uservm.
echo "[repro] booting test kernel in uservm (timeout 5m) ..."
timeout 5m ./bin/uservm.elf -kernel bin/kernel-test.elf -kernel-args "test_magic=0xDEADBEEF" \
    > "$LOG" 2>&1
echo "[repro] uservm exit=$?  (full console captured to $LOG)"

echo
echo "==================== CR-1 reproduction markers ===================="
grep -nE "join_status_test|BUG CONFIRMED \(CR-1\)|thread not found|hello, world" "$LOG"
echo "==================================================================="
echo

# Success criterion: buggy-order status loss + correct-order preservation + clean boot.
if grep -q "BUG CONFIRMED (CR-1)" "$LOG" \
   && grep -q "exit status 42 is permanently LOST" "$LOG" \
   && grep -q "correct order: exit status 42 preserved" "$LOG" \
   && grep -q "hello, world" "$LOG"; then
    echo "[repro] CR-1 REPRODUCED: join_thread reaps the zombie before copying the exit status out;"
    echo "        a bad retval pointer makes copy_to_user fail after the reap, so the exit status is"
    echo "        permanently lost and the join returns NoSuchProcess on retry."
    exit 0
else
    echo "[repro] markers missing — inspect $LOG"
    exit 1
fi
