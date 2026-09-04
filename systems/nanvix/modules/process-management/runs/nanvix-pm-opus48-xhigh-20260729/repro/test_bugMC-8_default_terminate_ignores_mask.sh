#!/usr/bin/env bash
#
# Reproduction for finding MC-8:
#   "Blockable default-Terminate signal ignores the per-thread mask"
#   invariant MaskHonored (MCMaskHonored), config MC_hunt_scenario6.cfg,
#   counterexample spec/output/MC_hunt_MC-8.out (trace length 6).
#
# CE trace (verbatim actions):
#   Initial -> MCCreateProcess(p2) -> MCMaskChange(t1 blocks sig 1)
#           -> MCSleep(p1 suspended, t1 sleeping) -> MCSchedule(p2 running)
#           -> MCPostSignalDefaultTerminate
#   State 6: procTerminated[p1]=TRUE, maskViolated=TRUE, though sig 1 is blocked on p1's only
#            thread t1.
#
# ROOT CAUSE (real code):
#   ProcessManager::kill (manager/mod.rs:810) maps a Default disposition whose default_action is
#   Terminate/Core to PostAction::Terminate (:858-866) and calls kill_terminate() UNCONDITIONALLY
#   (:892-893) -- NO per-thread blocked-mask check. Only the Handler arm (:854-856) posts to the
#   pending set and routes through the mask-gated interrupt_signal_candidate (:894 -> candidate_tid_for,
#   state/sleeping.rs:89). So a blockable signal with a fatal default action (e.g. SIGTERM) terminates
#   a target that has the signal masked on every thread, contrary to POSIX (blocked terminate-default
#   signal must remain pending). SIGKILL is handled separately at :842.
#
# HOW THIS REPRODUCES IT (in-kernel, feature = "test"; real entry points, NO product logic altered):
#   mc8_repro.rs builds an ISOLATED ProcessManager (live kernel lists untouched), constructs four
#   single-threaded suspended targets through the REAL create path (RunnableProcess::new -> run ->
#   sleep(None)), sets the per-thread mask via REAL sigprocmask(SIG_BLOCK,{SIGTERM}), the disposition
#   via REAL sigaction, and posts SIGTERM via REAL kill from a caller granted
#   Capability::ProcessManagement via REAL capctl. It then reads the REAL manager list / interrupt
#   reason / pending set:
#     D_MASKED   [Default, SIGTERM blocked; EXACT CE] -> suspended -> interrupted, thread Killed  (BUG)
#     D_UNMASKED [Default, unblocked]                 -> interrupted, thread Killed  (baseline)
#     H_MASKED   [Handler, SIGTERM blocked]           -> stays suspended, SIGTERM pending (mask honored)
#     H_UNMASKED [Handler, unblocked]                 -> interrupted/Signaled, SIGTERM pending (baseline)
#
# Usage: ./test_bugMC-8_default_terminate_ignores_mask.sh
# Exit 0 iff the D_MASKED/H_MASKED markers and the "MC-8 BUG REPRODUCED" verdict marker appear.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKTREE="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260729/nanvix/.specula-output/confirmation/MC-8/worktree"
LOG="$HERE/test_bugMC-8_default_terminate_ignores_mask.run.log"
BUILD_LOG="$HERE/test_bugMC-8_build.log"
MODULE_SRC="$HERE/test_bugMC-8_default_terminate_ignores_mask.rs"
MGR_DIR="$WORKTREE/src/kernel/src/pm/process/manager"
MGR_MOD="$MGR_DIR/mod.rs"
MGR_TEST="$MGR_DIR/test.rs"

fail() { echo "[repro] $*"; exit 2; }

cd "$WORKTREE" || fail "worktree not found: $WORKTREE"
[ -f "$MODULE_SRC" ] || fail "module source not found: $MODULE_SRC"

# 1) Install the in-kernel test module (idempotent).
cp -f "$MODULE_SRC" "$MGR_DIR/mc8_repro.rs" || fail "copy module"

# 2) Declare the module in manager/mod.rs, right after `mod test;` (idempotent).
if ! grep -q "mod mc8_repro;" "$MGR_MOD"; then
    perl -0777 -pi -e 's/(#\[cfg\(feature = "test"\)\]\nmod test;\n)/$1\n#[cfg(feature = "test")]\nmod mc8_repro;\n/' "$MGR_MOD"
fi

# 3) Wire it into the manager test aggregator (manager/test.rs::test()) (idempotent).
if ! grep -q "mc8_repro::run" "$MGR_TEST"; then
    perl -0777 -pi -e 's/(\n    passed\n\})/\n    passed &= super::mc8_repro::run();$1/' "$MGR_TEST"
fi

grep -q "mod mc8_repro;" "$MGR_MOD" && grep -q "mc8_repro::run" "$MGR_TEST" \
    || fail "failed to wire the MC-8 test module"
echo "[repro] MC-8 test module installed + wired."

# 4) Build the test kernel + uservm.
echo "[repro] building test kernel + uservm (timeout 45m) ..."
timeout 45m make all-test-kernel all-uservm >"$BUILD_LOG" 2>&1 \
    || { echo "[repro] build failed; see $BUILD_LOG"; tail -80 "$BUILD_LOG"; exit 2; }

# 5) Boot the test kernel in the uservm.
echo "[repro] booting test kernel in uservm (timeout 5m) ..."
timeout 5m ./bin/uservm.elf -kernel bin/kernel-test.elf -kernel-args "test_magic=0xDEADBEEF" \
    > "$LOG" 2>&1
echo "[repro] uservm exit=$?  (full console captured to $LOG)"

echo
echo "==================== MC-8 reproduction markers ===================="
grep -n "MC-8" "$LOG"
echo "==================================================================="
echo

# Success criterion: D_MASKED terminated (suspended->interrupted, thread killed); H_MASKED survived
# with SIGTERM pending; plus the verdict marker.
if grep -Eq "MC-8 D_MASKED .*after=interrupted thread_reason=killed" "$LOG" \
   && grep -Eq "MC-8 H_MASKED .*after=suspended thread_reason=sleeping" "$LOG" \
   && grep -q "MC-8 BUG REPRODUCED" "$LOG"; then
    echo "[repro] MC-8 REPRODUCED: kill(SIGTERM) with a Default (fatal) disposition terminated a"
    echo "        target whose only thread blocks SIGTERM (suspended -> interrupted, thread Killed),"
    echo "        while the otherwise-identical Handler-disposition target under the SAME mask stayed"
    echo "        suspended with SIGTERM merely pending. The per-thread mask is honored on the"
    echo "        Handler/interrupt path but ignored on the Default-Terminate path"
    echo "        (kill -> PostAction::Terminate -> kill_terminate, manager/mod.rs:858-866,:892-893)."
    exit 0
else
    echo "[repro] markers missing or differential not observed -- inspect $LOG"
    exit 1
fi
