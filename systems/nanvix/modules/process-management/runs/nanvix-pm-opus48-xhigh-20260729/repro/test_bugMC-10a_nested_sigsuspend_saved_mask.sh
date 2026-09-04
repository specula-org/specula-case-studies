#!/usr/bin/env bash
#
# Reproduction for finding MC-10a:
#   "Nested sigsuspend overwrites the single saved-mask slot"
#   invariant SavedMaskRestored (MCSavedMaskRestored), config MC_hunt_scenario7.cfg,
#   counterexample spec/output/MC_hunt_MC-10a.out (trace length 4).
#
# CE trace (verbatim actions):
#   Initial -> MCSetDisposition (install a handler)
#           -> MCSigSuspendInstall  (State 3: savedBlocked[t1] NoMask -> {}, slot occupied)
#           -> MCSigSuspendInstall  (State 4: SECOND install while slot occupied -> savedMaskViolated=TRUE)
#
# ROOT CAUSE (real code):
#   install_sigsuspend_mask (src/kernel/src/pm/process/manager/mod.rs:722-749) UNCONDITIONALLY does
#   `state.set_saved_blocked(Some(previous))` (:734) into ThreadState.saved_blocked, a single
#   `Option<u64>` (src/kernel/src/pm/thread/state.rs:105). A signal handler running between the outer
#   sigsuspend install and the outer sigreturn may itself call sigsuspend() (legal POSIX); that
#   nested install re-enters :734 and OVERWRITES the outer saved mask. On outer unwind the slot is
#   empty, so neither restore_sigsuspend_mask (mod.rs:771-778, no-op) nor sigreturn_restore
#   (manager/signal.rs:607-610, falls back to frame.blocked) can reinstate the pre-suspend mask.
#
# HOW THIS REPRODUCES IT (in-kernel, feature = "test"; REAL entry points, NO product logic altered):
#   mc10a_repro.rs builds an ISOLATED ProcessManager (live kernel lists untouched), creates a
#   single-threaded process through the REAL create/sleep path, then drives the exact real-API
#   sequence a nested sigsuspend produces:
#     sigprocmask(SET {SIGUSR2}=orig) -> install_sigsuspend_mask({}) [outer, saves orig]
#       -> sigprocmask(SET {SIGUSR1}) [handler-running mask] -> install_sigsuspend_mask({}) [NESTED,
#          OVERWRITES the slot] -> restore_sigsuspend_mask() [inner unwind, consumes slot]
#       -> restore_sigsuspend_mask() [outer unwind, slot empty -> orig NOT reinstated].
#   The wrong outcome is read through the REAL sigprocmask(None) mask query and the REAL sigpending
#   (pending & blocked) consumer: SIGUSR2, which the app had blocked, is now deliverable.
#   A single (non-nested) sigsuspend CONTROL correctly restores orig -> isolates the nesting as cause.
#
# Usage: ./test_bugMC-10a_nested_sigsuspend_saved_mask.sh
# Exit 0 iff the slot-overwrite + BUG/CONTROL differential + "MC-10a BUG REPRODUCED" markers appear.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKTREE="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260729/nanvix/.specula-output/confirmation/MC-10a/worktree"
LOG="$HERE/test_bugMC-10a_nested_sigsuspend_saved_mask.run.log"
BUILD_LOG="$HERE/test_bugMC-10a_build.log"
MODULE_SRC="$HERE/test_bugMC-10a_nested_sigsuspend_saved_mask.rs"
MGR_DIR="$WORKTREE/src/kernel/src/pm/process/manager"
MGR_MOD="$MGR_DIR/mod.rs"
MGR_TEST="$MGR_DIR/test.rs"

fail() { echo "[repro] $*"; exit 2; }

cd "$WORKTREE" || fail "worktree not found: $WORKTREE"
[ -f "$MODULE_SRC" ] || fail "module source not found: $MODULE_SRC"

# 1) Install the in-kernel test module (idempotent).
cp -f "$MODULE_SRC" "$MGR_DIR/mc10a_repro.rs" || fail "copy module"

# 2) Declare the module in manager/mod.rs, right after `mod test;` (idempotent).
if ! grep -q "mod mc10a_repro;" "$MGR_MOD"; then
    perl -0777 -pi -e 's/(#\[cfg\(feature = "test"\)\]\nmod test;\n)/$1\n#[cfg(feature = "test")]\nmod mc10a_repro;\n/' "$MGR_MOD"
fi

# 3) Wire it into the manager test aggregator (manager/test.rs::test()) (idempotent).
if ! grep -q "mc10a_repro::run" "$MGR_TEST"; then
    perl -0777 -pi -e 's/(\n    passed\n\})/\n    passed &= super::mc10a_repro::run();$1/' "$MGR_TEST"
fi

grep -q "mod mc10a_repro;" "$MGR_MOD" && grep -q "mc10a_repro::run" "$MGR_TEST" \
    || fail "failed to wire the MC-10a test module"
echo "[repro] MC-10a test module installed + wired."

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
echo "==================== MC-10a reproduction markers ===================="
grep -n "MC-10a" "$LOG"
echo "===================================================================="
echo

# Success criterion:
#   - the nested install overwrote the slot: saved_after_outer=Some(2048) (SIGUSR2) but
#     saved_after_nested=Some(512) (SIGUSR1), and saved_after_inner=None;
#   - the BUG lost orig: usr2_still_blocked=false AND usr2_deliverable=true;
#   - the CONTROL restored orig: usr2_still_blocked=true AND usr2_deliverable=false;
#   - the verdict marker is present.
if grep -q "saved_after_outer=Some(2048) saved_after_nested=Some(512) saved_after_inner=None" "$LOG" \
   && grep -Eq "MC-10a BUG \(nested\):.*usr2_still_blocked=false.*usr2_deliverable=true" "$LOG" \
   && grep -Eq "MC-10a CONTROL \(single\):.*usr2_still_blocked=true.*usr2_deliverable=false" "$LOG" \
   && grep -q "MC-10a BUG REPRODUCED" "$LOG"; then
    echo "[repro] MC-10a REPRODUCED: a nested sigsuspend overwrote the single saved_blocked slot"
    echo "        (install_sigsuspend_mask mod.rs:734 into Option<u64> thread/state.rs:105); the outer"
    echo "        sigsuspend could not reinstate the pre-suspend mask, leaving the app-blocked SIGUSR2"
    echo "        UNBLOCKED and deliverable, while an identical single sigsuspend restored it correctly."
    exit 0
else
    echo "[repro] markers missing or differential not observed -- inspect $LOG"
    exit 1
fi
