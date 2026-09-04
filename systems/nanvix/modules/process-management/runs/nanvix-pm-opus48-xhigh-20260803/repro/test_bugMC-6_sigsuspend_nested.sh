#!/usr/bin/env bash
# Reproduction for MC-6: "Nested signal delivery during sigsuspend corrupts the saved mask".
#
#   Invariant (model checking) : SigsuspendMaskRestored
#   Counterexample             : spec/output/MC_hunt_scenario4_mc6_final.out
#   Affected code (worktree)   : src/kernel/src/pm/process/manager/mod.rs:734  (install_sigsuspend_mask)
#                                src/kernel/src/pm/process/manager/signal.rs:607 (sigreturn_restore)
#                                src/kernel/src/pm/thread/state.rs:105          (single saved_blocked slot)
#
# END-TO-END, REAL-CODE reproduction. It builds the actual Nanvix `test`-feature kernel and boots it
# in the standalone UserVM. During PM init the in-kernel trace harness (pm/process/state/tla_world.rs)
# runs scenario_mc6_nested_sigsuspend(), which drives the REAL per-thread signal state
# (ThreadState::{set_saved_blocked,take_saved_blocked,set_blocked,blocked}) and the REAL per-process
# SignalControl through the exact counterexample sequence:
#
#     sigaction(sig1=handler); kill(sig1); AsyncDeliver;      # frame1 saves {}, blocked={1}
#     kill(sig1); Sigsuspend({});                             # save {1} into the single slot, install {}
#     AsyncDeliver;                                           # nested: frame2 saves {}, blocked={1}
#     Sigreturn;  # nested return: take_saved_blocked() -> {1}, CONSUMES the slot (the defect)
#     Sigreturn;  # sigsuspend unwind: slot empty -> frame {} restored instead of pre-suspend {1}
#
# It then reads the REAL thread's blocked() mask and prints an @@MC6@@ marker. POSIX requires
# sigsuspend() to leave the blocked mask exactly as it was before the call; the bug leaves it wrong.
#
# PASS (bug reproduced) == the console contains "@@MC6@@ REPRODUCED" with restored_ok=false.
#
# Usage:  bash test_bugMC-6_sigsuspend_nested.sh
set -uo pipefail

WORKTREE="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260803/nanvix/.specula-output/confirmation/MC-6/worktree"
OUTDIR="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260803/nanvix/.specula-output/confirmation/MC-6"
CONSOLE="$OUTDIR/console.log"
BUILD_LOG="$OUTDIR/build.log"

echo "== [1/3] building test-kernel + uservm (real kernel, test feature) =="
if [ ! -x "$WORKTREE/bin/kernel-test.elf" ] || [ ! -x "$WORKTREE/bin/uservm.elf" ]; then
    ( cd "$WORKTREE" && timeout 1200 make all-test-kernel all-uservm ) > "$BUILD_LOG" 2>&1
    rc=$?
    if [ $rc -ne 0 ]; then
        echo "BUILD FAILED (rc=$rc); see $BUILD_LOG"; tail -30 "$BUILD_LOG"; exit 2
    fi
else
    echo "   (reusing existing kernel-test.elf / uservm.elf)"
fi

echo "== [2/3] booting kernel in UserVM (timeout 180s) =="
timeout 180 "$WORKTREE/bin/uservm.elf" -kernel "$WORKTREE/bin/kernel-test.elf" \
    -kernel-args "test_magic=0xDEADBEEF" > "$CONSOLE" 2>&1
echo "   boot rc=$? ; console -> $CONSOLE"

echo "== [3/3] result =="
grep -n "@@MC6@@" "$CONSOLE" || { echo "NO @@MC6@@ MARKER FOUND (harness did not run)"; exit 3; }

if grep -q "@@MC6@@ REPRODUCED" "$CONSOLE"; then
    echo
    echo "RESULT: BUG REPRODUCED on the real kernel."
    echo "        sigsuspend left the thread's real blocked mask corrupted"
    echo "        (restored_mask=0x0, expected pre_suspend_mask=0x1)."
    exit 0
else
    echo "RESULT: property held (restored_ok=true) -- bug NOT reproduced."
    exit 1
fi
