#!/usr/bin/env bash
# Reproduction for finding MC-7 — "Orphaned mutex-map slot after an interrupted cond_wait reacquire"
# Invariant violated (model checking): SyncSlotConservation
# Counterexample: spec/output/MC_hunt_MC-7.out
#
# WHAT THIS REPRODUCES
# --------------------
# The only mutex-map reclaimer is ProcessState::put_mutex (src/kernel/src/pm/process/state/mod.rs:652),
# reached solely from a successful guard take (remove_mutex_guard -> put_mutex). In wait_cond
# (src/kernel/src/pm/kcall/wait_cond.rs) the mutex reacquire is:
#     126:  let mutex = ProcessManager::get_mutex(mutex_addr)?;   // (re)creates the map slot
#     127:  let guard = mutex.lock(None)?;                        // INTERRUPTED -> returns via `?`
#     128:  ProcessManager::put_mutex_guard(mutex_addr, guard)?;  // never reached on the error path
# When line 127 is interrupted the function returns before line 128, and put_mutex is never called,
# so the slot created by line 126 lingers: mutexInMap=TRUE while the mutex is unlocked / unowned /
# unheld. Every such leak permanently consumes one of MUTEX_OPEN_MAX (=32) slots until the process
# exits, so a real caller (lock_mutex kcall -> get_mutex) is eventually rejected with OutOfMemory
# even though the process holds no mutex.
#
# ESCALATION LEVEL: 2 (state injection through the REAL ProcessState / Mutex API).
#   The reproduction driver `run_mc7_repro` (src/kernel/src/pm/process/state/tla_world.rs) drives the
#   REAL ProcessState::{get_mutex,put_mutex,contains_mutex} and the REAL Mutex/MutexGuard through the
#   EXACT operation sequence of wait_cond, matching the counterexample steps:
#       State 2  MCLockMutexAcquire          <-> lock_mutex.rs:92-93 (get_mutex + lock)
#       State 3  MCCondWaitUnlock            <-> wait_cond.rs:105     (drop guard + put_mutex)
#       State 4  MCCondWaitRelockInterrupted <-> wait_cond.rs:126-127 (get_mutex; interrupted lock
#                                                returns before put_mutex_guard -> put_mutex skipped)
#   Level 0/1 (a real signal/kill interrupting a real, contended blocked reacquire) is not runnable in
#   the single-threaded in-kernel test harness; scenario5 (single process) cannot set up the contended
#   reacquire. The state-injected sequence instantiates the admissible counterexample steps exactly and
#   does not fabricate any illegal state — it only replays wait_cond's own operations, including the
#   documented `?` early return.
#
# USAGE:   bash test_bugMC-7_mutex_map_leak.sh
# EXIT:    0 => MC-7 reproduced (LEAK CONFIRMED + CONSUMER HARM CONFIRMED observed on a clean boot)
#          1 => not reproduced / environment failure
set -uo pipefail

WORKTREE="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260729/nanvix/.specula-output/confirmation/MC-7/worktree"
OUT_DIR="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260729/nanvix/.specula-output/repro/mc7_orphan"
BUILD_LOG="$OUT_DIR/build.log"
CONSOLE_LOG="$OUT_DIR/console.log"
KERNEL="$WORKTREE/bin/kernel-test.elf"
USERVM="$WORKTREE/bin/uservm.elf"

mkdir -p "$OUT_DIR"
cd "$WORKTREE" || { echo "FATAL: worktree not found: $WORKTREE"; exit 1; }

echo "=================================================================="
echo " MC-7 reproduction — orphaned mutex-map slot (SyncSlotConservation)"
echo " worktree = $WORKTREE"
echo "=================================================================="

# --- 1. Build the test-enabled kernel + UserVM (idempotent; sccache-cached). --------------------
echo "[repro] building test-kernel + uservm (timeout 1500s)..."
if ! timeout 1500 make all-test-kernel all-uservm > "$BUILD_LOG" 2>&1; then
    echo "[repro] BUILD FAILED (see $BUILD_LOG)"; tail -30 "$BUILD_LOG"; exit 1
fi
echo "[repro] build ok."

[ -x "$KERNEL" ] || { echo "FATAL: missing $KERNEL"; exit 1; }
[ -x "$USERVM" ] || { echo "FATAL: missing $USERVM"; exit 1; }

# --- 2. Boot the kernel in the UserVM and capture the console. ----------------------------------
echo "[repro] booting kernel-test.elf in uservm (timeout 120s)..."
timeout 120 "$USERVM" -kernel "$KERNEL" -kernel-args "test_magic=0xDEADBEEF" > "$CONSOLE_LOG" 2>&1 || true

echo "[repro] --- MC7_REPRO evidence lines -------------------------------------------------------"
grep -nE "MC7_REPRO|passed: mc7_repro_orphaned_mutex_map_slot|hello, world" "$CONSOLE_LOG" | grep -v "@@TLA@@"
echo "[repro] ------------------------------------------------------------------------------------"

# --- 3. Verdict. --------------------------------------------------------------------------------
BASE=$(grep -c "MC7_REPRO: baseline OK"               "$CONSOLE_LOG" || true)
LEAK=$(grep -c "MC7_REPRO: LEAK CONFIRMED"            "$CONSOLE_LOG" || true)
HARM=$(grep -c "MC7_REPRO: CONSUMER HARM CONFIRMED"   "$CONSOLE_LOG" || true)
DONE=$(grep -c "hello, world"                         "$CONSOLE_LOG" || true)

echo "[repro] baseline-control=$BASE  leak-confirmed=$LEAK  consumer-harm=$HARM  clean-boot=$DONE"
if [ "$BASE" -ge 1 ] && [ "$LEAK" -ge 1 ] && [ "$HARM" -ge 1 ] && [ "$DONE" -ge 1 ]; then
    echo "[repro] RESULT: MC-7 REPRODUCED — mutex-map slot orphaned after interrupted cond_wait reacquire."
    exit 0
fi
echo "[repro] RESULT: NOT reproduced (see $CONSOLE_LOG)."
exit 1
