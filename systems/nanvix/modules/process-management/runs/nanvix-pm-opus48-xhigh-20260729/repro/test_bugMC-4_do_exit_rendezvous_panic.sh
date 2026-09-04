#!/usr/bin/env bash
#
# Reproduction for finding MC-4:
#   "Kernel panic: do_exit dereferences the emptied running slot during rendezvous cleanup"
#
# Mechanism (src/kernel/src/pm/process/manager/mod.rs):
#   do_exit (fn @2103):
#     2116  self.take_running()          -> self.running = None
#     2130  self.cleanup_rendezvous(pid)  -> for each orphaned rendezvous counterpart:
#             do_wakeup(tid) -> try_wakeup_thread(tid) -> get_running()  (@2787)
#             get_running() == self.running.as_ref().expect("the kernel should be running")
#             => PANIC because running is None.
#   terminate() (@2268) is safe: it calls cleanup_rendezvous WITHOUT emptying `running`.
#
# An orphaned counterpart is produced by normal cross-process rendezvous IPC: a thread in another
# process blocked in do_push (dst_pid == victim) or do_pull (src_pid == victim). When the victim
# (the running process) exits, cleanup_process(victim) returns that thread's tid.
#
# Escalation level: Level 2 (state injection consistent with the model counterexample).
#   The injected precondition -- running == None while an orphaned rendezvous counterpart is
#   registered -- is EXACTLY the intermediate state do_exit produces between its own lines 2116 and
#   2130 (CE steps MCExitTakeRunning -> MCExitCleanupRendezvous, and MCRegisterRendezvous for the
#   counterpart). The reproduction drives the REAL ProcessManager singleton and REAL ipc::rendezvous
#   module; it does not alter any system logic.
#
# The harness:
#   * builds the kernel with the `test` feature and the standalone UserVM,
#   * boots the test-kernel under the UserVM,
#   * a `test`-only in-kernel scenario (added by the patch below) first runs a POSITIVE CONTROL
#     (cleanup_rendezvous with running populated == terminate() ordering -> no panic), then
#     reproduces do_exit's take-then-cleanup ordering -> kernel panic.
#
# SUCCESS (bug reproduced) when the captured serial output contains BOTH:
#   - "MC4-CONTROL-OK"  (control: running populated is safe), and
#   - a kpanic at manager/mod.rs line 2787 with message "the kernel should be running",
#   and does NOT reach the normal boot marker "hello, world!".
#
# The patch is applied with `git apply`, built, run, then reverted with `git checkout`, so the
# worktree is left exactly as it was.
#
set -u

WORKTREE="${WORKTREE:-/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260729/nanvix/.specula-output/confirmation/MC-4/worktree}"
PATCH="${PATCH:-/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260729/nanvix/.specula-output/repro/test_bugMC-4.patch}"
LOG="${LOG:-/tmp/test_bugMC-4_run.log}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-600}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-120}"

cd "$WORKTREE" || { echo "[FATAL] worktree not found: $WORKTREE"; exit 2; }

FILES="src/kernel/src/ipc/rendezvous.rs src/kernel/src/pm/process/manager/test.rs"

cleanup() {
    # Revert ONLY the two files the patch touches (leave the pre-existing Specula harness intact).
    git checkout -- $FILES 2>/dev/null || true
}
trap cleanup EXIT

echo "[STEP] Applying instrumentation patch (adds a test-only in-kernel repro scenario)..."
git checkout -- $FILES 2>/dev/null || true
if ! git apply --check "$PATCH" 2>/tmp/mc4_apply.err; then
    echo "[FATAL] patch does not apply cleanly:"; cat /tmp/mc4_apply.err; exit 2
fi
git apply "$PATCH" || { echo "[FATAL] git apply failed"; exit 2; }

echo "[STEP] Building UserVM (host) ..."
timeout "$BUILD_TIMEOUT" make all-uservm >/tmp/mc4_build_uservm.log 2>&1 \
    || { echo "[FATAL] uservm build failed"; tail -20 /tmp/mc4_build_uservm.log; exit 2; }

echo "[STEP] Building test-kernel (with repro instrumentation) ..."
timeout "$BUILD_TIMEOUT" make all-test-kernel >/tmp/mc4_build_kernel.log 2>&1 \
    || { echo "[FATAL] test-kernel build failed"; tail -30 /tmp/mc4_build_kernel.log; exit 2; }

echo "[STEP] Booting test-kernel under UserVM (boot timeout ${BOOT_TIMEOUT}s) ..."
timeout $((BOOT_TIMEOUT + 60)) python3 scripts/run-uservm.py bin/kernel-test.elf "$BOOT_TIMEOUT" \
    --wait-for-string "hello, world!" --kernel-args "test_magic=0xDEADBEEF" > "$LOG" 2>&1
echo "[INFO] runner exit=$? (non-zero expected: the kernel panics before the pass marker)"

echo "=================== relevant serial output ==================="
grep -nE "MC4-CONTROL|MC4-REPRO|the kernel should be running|line=2787|manager/mod.rs|hello, world" "$LOG" || true
echo "============================================================="

CONTROL_OK=$(grep -c "MC4-CONTROL-OK" "$LOG")
PANIC_OK=$(grep -c "line=2787 :: the kernel should be running" "$LOG")
# The kernel prints its own boot-complete marker ("hello, world!") ONLY if pm init (and thus the
# in-kernel test suite) finished without panicking; the UserVM runner then prints the sentinel
# below. Note: the two runner banner lines that merely echo the wait-string also contain
# "hello, world!", so we must key on the runner's post-run SUCCESS sentinel, not the raw substring.
BOOT_OK=$(grep -c "\[SUCCESS\] Output contains 'hello, world!'" "$LOG")

if [ "$CONTROL_OK" -ge 1 ] && [ "$PANIC_OK" -ge 1 ] && [ "$BOOT_OK" -eq 0 ]; then
    echo "[RESULT] REPRODUCED: control safe (running=Some), then do_exit ordering panics at"
    echo "         manager/mod.rs:2787 get_running() 'the kernel should be running'."
    exit 0
else
    echo "[RESULT] NOT REPRODUCED (control_ok=$CONTROL_OK panic@2787=$PANIC_OK boot_marker=$BOOT_OK)"
    echo "         Full log at: $LOG"
    exit 1
fi
