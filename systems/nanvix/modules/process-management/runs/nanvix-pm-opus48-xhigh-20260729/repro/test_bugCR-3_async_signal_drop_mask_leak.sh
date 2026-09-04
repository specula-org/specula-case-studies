#!/usr/bin/env bash
#
# Reproduction driver for finding CR-3:
#   "Async caught signal dropped when no signal restorer is installed; sigsuspend temp mask leaks"
#
# Mechanism (src/kernel/src/pm/process/manager/signal.rs:257-269):
#   ProcessManager::try_deliver_signal() is the asynchronous return-to-user delivery checkpoint.
#   When a caught signal is deliverable but the target process has NO restorer trampoline registered
#   (sigaction() installs a Handler independently of sig_restorer(); crt0 registers the restorer only
#   best-effort), the branch logs an error, CLEARS the pending signal, and returns
#   SignalDeliveryOutcome::None. The caller deliver_pending_signals() (src/kernel/src/kcall/handler.rs:190)
#   treats None as "nothing to do", so the signal is silently swallowed (the synchronous path,
#   try_deliver_synchronous_signal(), instead returns Terminate — a loud failure). Worse, if a
#   sigsuspend() had installed a temporary mask (saved_blocked = pre-suspend mask, blocked = temp),
#   the None return means sigreturn() never runs, so saved_blocked is never consumed and the thread's
#   blocked mask stays stuck at the temporary sigsuspend mask forever — a permanent per-thread mask
#   corruption that violates the POSIX sigsuspend contract.
#
# This driver builds the in-kernel test harness (kernel `test` feature) that contains the Rust
# reproduction test
#   src/kernel/src/pm/process/manager/test.rs
#     :: test_async_delivery_without_restorer_drops_signal_and_leaks_sigsuspend_mask
# and boots it under the standalone UserVM (QEMU), capturing serial output. The test builds a REAL
# running process with a real kernel stack + synthetic ring-3 trap frame, installs a REAL sigsuspend
# mask via ProcessManager::install_sigsuspend_mask(), posts a caught signal, and drives the REAL
# ProcessManager::try_deliver_signal(). It asserts the CORRECT behavior (Escalate/terminate, or the
# sigsuspend mask restored); under the current code both fail -> the test FAILS, proving the bug.
#
# Escalation level: Level 2 (state injection). The injected precondition is reachable through the
# real kernel API: sigaction(handler) without sig_restorer(), then sigsuspend(mask), then kill().
#
# Exit code: 0 if the bug reproduced (markers found), 1 otherwise.

set -u

WORKTREE="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260729/nanvix/.specula-output/confirmation/CR-3/worktree"
LOG="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260729/nanvix/.specula-output/repro/test_bugCR-3_async_signal_drop_mask_leak.run.log"
BOOT_TIMEOUT=150

cd "$WORKTREE" || { echo "[repro] cannot cd to worktree"; exit 1; }

echo "[repro] building test-enabled kernel + uservm ..."
if ! timeout 900 make all-test-kernel all-uservm > /tmp/cr3_build.log 2>&1; then
    echo "[repro] BUILD FAILED (see /tmp/cr3_build.log)"; tail -20 /tmp/cr3_build.log; exit 1
fi

echo "[repro] booting kernel-test.elf under uservm (timeout ${BOOT_TIMEOUT}s) ..."
timeout "${BOOT_TIMEOUT}" ./bin/uservm.elf \
    -kernel ./bin/kernel-test.elf \
    -kernel-args test_magic=0xDEADBEEF > "$LOG" 2>&1
echo "[repro] uservm exit code: $?"

echo "===================================================================="
echo "[repro] relevant serial output:"
grep -nE "no signal restorer registered|CR-3-REPRO|FAILED: test_async|assertion failed" "$LOG" || true
echo "===================================================================="

if grep -q "CR-3-REPRO: BUG REPRODUCED" "$LOG" \
   && grep -q "try_deliver_signal(): no signal restorer registered" "$LOG"; then
    echo "[repro] RESULT: BUG REPRODUCED"
    echo "[repro]   - real try_deliver_signal() hit the no-restorer branch (from kernel code, not the test)"
    echo "[repro]   - caught signal was silently dropped (outcome=None, no terminate)"
    echo "[repro]   - sigsuspend() temporary mask leaked (blocked stuck at temp, saved_blocked never restored)"
    echo "[repro]   Full serial log: $LOG"
    exit 0
fi

echo "[repro] RESULT: bug NOT reproduced (markers absent) — see $LOG"
exit 1
