#!/usr/bin/env bash
#
# Reproduction for finding MC-9:
#   "Immortal pending signal after a disposition change"
#   invariant NoImmortalPending (MCNoImmortalPending), config MC_hunt_scenario6.cfg,
#   counterexample spec/output/MC_hunt_MC-9.out (trace length 5).
#
# CE trace (verbatim actions):
#   Initial -> MCCreateProcess(p1) -> MCSetDisposition(disposition[p1][1]=handler)
#           -> MCPostSignalHandler(pending[p1]={1}) -> MCSetDisposition(disposition[p1][1]=default)
#   State 5: pending[p1]={1}, disposition[p1][1]=default, immortalPending=TRUE.
#
# ROOT CAUSE (real code):
#   SignalControl::set_disposition (state/signal.rs:364-371) only core::mem::replace's the
#   disposition slot; it never clears a pending instance. ProcessManager::sigaction
#   (manager/mod.rs:583-614, set_disposition at :605) never touches the pending set. kill
#   (manager/mod.rs:849-882) posts to the process pending set only on the Handler arm (:854-855);
#   try_deliver_signal (manager/signal.rs:240-253) delivers only Handler dispositions and skips
#   every other pending signal, leaving it pending. So a signal posted while caught, then
#   re-dispositioned to SIG_DFL/SIG_IGN, is neither delivered nor discarded -> stuck pending forever,
#   contrary to POSIX SIG_IGN pending-discard semantics.
#
# HOW THIS REPRODUCES IT (in-kernel, feature = "test"; real entry points, NO product logic altered):
#   mc9_repro.rs builds an ISOLATED ProcessManager (live kernel lists untouched), constructs each
#   single-threaded target through the REAL create path (RunnableProcess::new -> run -> sleep(None)),
#   installs a handler and posts SIGTERM through the REAL sigaction/kill entry points from a caller
#   granted Capability::ProcessManagement via REAL capctl, re-dispositions via REAL sigaction, and
#   observes the wrong outcome through the REAL sigsuspend() deliverability oracle
#   (install_sigsuspend_mask) and the REAL pending set (signals().pending()):
#     CONTROL [handler, never re-dispositioned]      -> deliverable=true  (caught pending IS deliverable)
#     CASE B  [handler -> post -> SIG_DFL, exact CE]  -> pending STILL set, deliverable=false, permanent
#     CASE A  [handler -> post -> SIG_IGN -> reinstall handler]
#                                                     -> pending NOT discarded, then spuriously deliverable
#
# Usage: ./test_bugMC-9_immortal_pending.sh
# Exit 0 iff the CONTROL/CASE-B/CASE-A markers and the "MC-9 BUG REPRODUCED" verdict marker appear.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKTREE="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260729/nanvix/.specula-output/confirmation/MC-9/worktree"
LOG="$HERE/test_bugMC-9_immortal_pending.run.log"
BUILD_LOG="$HERE/test_bugMC-9_build.log"
MODULE_SRC="$HERE/test_bugMC-9_immortal_pending.rs"
MGR_DIR="$WORKTREE/src/kernel/src/pm/process/manager"
MGR_MOD="$MGR_DIR/mod.rs"
MGR_TEST="$MGR_DIR/test.rs"

fail() { echo "[repro] $*"; exit 2; }

cd "$WORKTREE" || fail "worktree not found: $WORKTREE"
[ -f "$MODULE_SRC" ] || fail "module source not found: $MODULE_SRC"

# 1) Install the in-kernel test module (idempotent).
cp -f "$MODULE_SRC" "$MGR_DIR/mc9_repro.rs" || fail "copy module"

# 2) Declare the module in manager/mod.rs, right after `mod test;` (idempotent).
if ! grep -q "mod mc9_repro;" "$MGR_MOD"; then
    perl -0777 -pi -e 's/(#\[cfg\(feature = "test"\)\]\nmod test;\n)/$1\n#[cfg(feature = "test")]\nmod mc9_repro;\n/' "$MGR_MOD"
fi

# 3) Wire it into the manager test aggregator (manager/test.rs::test()) (idempotent).
if ! grep -q "mc9_repro::run" "$MGR_TEST"; then
    perl -0777 -pi -e 's/(\n    passed\n\})/\n    passed &= super::mc9_repro::run();$1/' "$MGR_TEST"
fi

grep -q "mod mc9_repro;" "$MGR_MOD" && grep -q "mc9_repro::run" "$MGR_TEST" \
    || fail "failed to wire the MC-9 test module"
echo "[repro] MC-9 test module installed + wired."

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
echo "==================== MC-9 reproduction markers ===================="
grep -n "MC-9" "$LOG"
echo "==================================================================="
echo

# Success criterion: CONTROL deliverable; CASE B pending set after SIG_DFL, not deliverable, permanent;
# CASE A pending set after SIG_IGN then spuriously deliverable; plus the verdict marker.
if grep -Eq "MC-9 CONTROL .*sigsuspend_deliverable=true" "$LOG" \
   && grep -Eq "MC-9 CASE B .*pending_after_dfl=0b?0*1[01]* .*sigsuspend_deliverable=false" "$LOG" \
   && grep -Eq "MC-9 CASE A .*spurious_deliverable_after_reinstall=true" "$LOG" \
   && grep -q "MC-9 BUG REPRODUCED" "$LOG"; then
    echo "[repro] MC-9 REPRODUCED: a SIGTERM posted while caught and then re-dispositioned to SIG_DFL"
    echo "        stayed pending forever (real sigsuspend() oracle reports it non-deliverable and it"
    echo "        survives further sigaction/kill), while an otherwise-identical never-re-dispositioned"
    echo "        target was deliverable. Under SIG_IGN the pending instance was not discarded and a"
    echo "        later handler reinstall spuriously resurrected it. set_disposition (state/signal.rs:364)"
    echo "        only swaps the slot; sigaction (manager/mod.rs:605) never clears pending."
    exit 0
else
    echo "[repro] markers missing or differential not observed -- inspect $LOG"
    exit 1
fi
