#!/usr/bin/env bash
#
# CR-4 reproduction: a thread that exits while holding a mutex defers the unlock (and the
# Condvar::notify that would wake a blocked sibling) until the zombie is harvested.
#
# Level 0 (real API, no timing tricks). The reproduction is an in-kernel unit test added to the
# process-state test suite (src/kernel/src/pm/process/state/mutex_exit_test.rs). It drives the
# EXACT kernel path:
#   - Mutex::try_lock() + RunningThread::put_mutex_guard()   == lock_mutex() kcall
#   - RunningThread::exit()                                  == thread exit (running.rs:195)
#   - drop(ZombieThread) -> ThreadState::drop               == zombie harvest (state.rs:574)
# A sibling blocked in lock_mutex() performs exactly Mutex::try_lock(); we use that as the
# sibling's acquisition probe. The kernel is built with the `test` feature and booted under the
# standalone uservm; the in-kernel test runs at boot and prints [CR-4] markers on the serial
# console.
#
# PASS (bug reproduced) iff, after the owner exits, the mutex is STILL locked, and it is released
# only after the zombie's ThreadState is dropped (harvest).
set -u

WT="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260729/nanvix/.specula-output/confirmation/CR-4/worktree"
SERIAL_LOG="$(dirname "$0")/test_bugCR-4_mutex_hold_on_exit_defers_release.run.log"

cd "$WT" || { echo "worktree not found: $WT"; exit 2; }

echo "=== [CR-4] building test kernel + uservm ==="
timeout 600 make all-test-kernel all-uservm >/tmp/cr4_build.log 2>&1 || {
    echo "build failed; see /tmp/cr4_build.log"; tail -20 /tmp/cr4_build.log; exit 2;
}

echo "=== [CR-4] booting test kernel under uservm (capturing serial) ==="
timeout 120 ./bin/uservm.elf -kernel ./bin/kernel-test.elf \
    -kernel-args test_magic=0xDEADBEEF > "$SERIAL_LOG" 2>&1
echo "uservm exit=$?"

echo
echo "=== [CR-4] relevant serial output ==="
grep -nE "\[CR-4\]|dropping thread state with locked mutexes|passed: test_bug_cr4" "$SERIAL_LOG"

echo
# Assert the deferral: still locked after exit, released after harvest, and confirmed.
if grep -q "\[CR-4\] after owner exit(): sibling try_lock() -> Err (STILL LOCKED)" "$SERIAL_LOG" \
   && grep -q "\[CR-4\] after zombie harvest (ThreadState drop): sibling try_lock() -> Ok (released now)" "$SERIAL_LOG" \
   && grep -q "\[CR-4\] CONFIRMED:" "$SERIAL_LOG"; then
    echo "RESULT: REPRODUCED — mutex release+notify deferred from thread-exit to zombie-harvest."
    exit 0
else
    echo "RESULT: NOT reproduced (mutex released at exit, or harness did not run)."
    exit 1
fi
