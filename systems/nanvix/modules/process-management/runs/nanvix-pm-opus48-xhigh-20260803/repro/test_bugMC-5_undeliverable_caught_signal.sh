#!/usr/bin/env bash
#
# Reproduction for finding MC-5:
#   "A caught signal is undeliverable - a sleeping thread in a runnable process
#    is never interrupted" (invariant NoUndeliverableCaught).
#
# What this does
# --------------
# Builds the Nanvix *test* kernel from the confirmation worktree (which contains
# two in-kernel tests wired into pm::process::manager::test) and boots it inside
# the prebuilt UserVM. The tests drive the REAL dispatcher entry point
# `ProcessManager::interrupt_signal_candidate`:
#
#   * test_mc5_caught_signal_undeliverable_to_runnable_process_sleeping_thread
#       Reproduces the bug. A caught (handler) signal is pending on a NON-suspended
#       (runnable) process whose only unmasked recipient is a sleeping thread; a
#       ready sibling masks the signal. The dispatcher scans only the fully-suspended
#       list, so it interrupts nobody and the signal stays pending forever.
#
#   * test_mc5_caught_signal_delivered_to_suspended_process_sleeping_thread
#       Positive control. The SAME sleeping unmasked thread IS interrupted once its
#       process is fully suspended — isolating the defect to non-suspended processes.
#
# PASS criteria: both tests report `passed:` AND the "undeliverable" info line is
# printed AND the kernel reaches its success magic string ("hello, world!").
#
set -u

# --- Paths ------------------------------------------------------------------
ROOT="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260803/nanvix"
WORKTREE="${ROOT}/.specula-output/confirmation/MC-5/worktree"
USERVM="${ROOT}/source/bin/uservm.elf"
KERNEL="${WORKTREE}/bin/kernel-test.elf"
CONSOLE_LOG="$(mktemp /tmp/mc5_console.XXXXXX.log)"

echo "== MC-5 reproduction =="
echo "worktree : ${WORKTREE}"
echo "uservm   : ${USERVM}"

# --- 1. Build the test kernel (Makefile provides MEMORY_SIZE_BYTES etc.) -----
echo
echo "== [1/3] Building test kernel (make all-test-kernel) =="
if ! ( cd "${WORKTREE}" && timeout 800 make all-test-kernel ) > /tmp/mc5_build.log 2>&1; then
    echo "BUILD FAILED — tail of build log:"
    tail -30 /tmp/mc5_build.log
    exit 2
fi
tail -3 /tmp/mc5_build.log

if [ ! -f "${KERNEL}" ]; then
    echo "ERROR: expected kernel image not found: ${KERNEL}"
    exit 2
fi

# --- 2. Boot the test kernel in the UserVM ----------------------------------
echo
echo "== [2/3] Booting test kernel in UserVM =="
timeout 120 "${USERVM}" -kernel "${KERNEL}" -kernel-args "test_magic=0xDEADBEEF" \
    > "${CONSOLE_LOG}" 2>&1 || true

echo "--- MC-5 relevant console lines ---"
grep -a -iE "mc5|undeliverable|hello, world" "${CONSOLE_LOG}" || true

# --- 3. Evaluate PASS/FAIL --------------------------------------------------
echo
echo "== [3/3] Verdict evaluation =="
bug_passed=$(grep -ac "passed: test_mc5_caught_signal_undeliverable_to_runnable_process_sleeping_thread" "${CONSOLE_LOG}")
ctrl_passed=$(grep -ac "passed: test_mc5_caught_signal_delivered_to_suspended_process_sleeping_thread" "${CONSOLE_LOG}")
undeliverable=$(grep -ac "left undeliverable on runnable process" "${CONSOLE_LOG}")
magic=$(grep -ac "hello, world" "${CONSOLE_LOG}")

echo "bug test passed        : ${bug_passed}"
echo "control test passed    : ${ctrl_passed}"
echo "undeliverable observed : ${undeliverable}"
echo "kernel success magic   : ${magic}"

if [ "${bug_passed}" -ge 1 ] && [ "${ctrl_passed}" -ge 1 ] && \
   [ "${undeliverable}" -ge 1 ] && [ "${magic}" -ge 1 ]; then
    echo
    echo "RESULT: REPRODUCED — caught signal left undeliverable on a runnable process"
    echo "        (sleeping unmasked thread never interrupted; signal stays pending),"
    echo "        while the suspended-process control path delivers correctly."
    echo "full console log: ${CONSOLE_LOG}"
    exit 0
fi

echo
echo "RESULT: NOT REPRODUCED — see full console log: ${CONSOLE_LOG}"
exit 1
