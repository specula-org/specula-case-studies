#!/usr/bin/env bash
#
# Reproduction driver for finding MC-2:
#   "Caught signal never delivered to a sleeper in a non-suspended process"
#   invariant MCSignalReachesSafety, config MC_hunt_scenario1.cfg,
#   counterexample spec/output/MC_hunt_MC-2.out (trace length 7).
#
# MC CE (verbatim actions):
#   Initial -> MCCreateProcess -> MCCreateThread -> MCSetDisposition -> MCSleep -> MCSchedule
#           -> MCPostSignalHandler
#   Final: procState[p1]="ready" (RunnableProcess), threadState[t1]="sleeping", t3="ready",
#          disposition[p1][1]="handler", pending[p1]={1}, signalDeliveryFailed=TRUE.
#
# ROOT CAUSE (real code): ProcessManager::interrupt_signal_candidate (manager/mod.rs:1009) resolves
#   the candidate ONLY from `self.suspended`; it never scans `ready` (RunnableProcess) or
#   `interrupted` (InterruptedProcess), both of which can carry sleeping threads. kill() ->
#   PostAction::Interrupt -> interrupt_signal_candidate (mod.rs:892-894) therefore interrupts nothing.
#   The other path, try_deliver_signal (manager/signal.rs:206, run at every kcall return), delivers
#   only to the *running* thread, masked by its blocked set. So a caught signal whose sole unmasked
#   eligible thread is a sleeper embedded in a non-suspended process is starved.
#
# HOW THIS REPRODUCES IT (in-kernel, feature = "test", REAL PM / type-state methods + REAL public
# kill() entry, no product logic altered): mc2_repro.rs builds three processes via the REAL chain
# (new -> run -> add_thread -> sleep) and drives the REAL ProcessManager::kill():
#   CE-FAITHFUL [ready, unmasked sibling]  -> nothing interrupted (matches the CE)
#   BUG         [ready, sibling MASKS sig] -> nothing interrupted + sibling cannot take it => STARVED
#   CONTROL     [suspended]                -> the SAME kill() interrupts the sleeper => delivered
#
# Usage: ./test_bugMC-2_signal_starved_nonsuspended_sleeper.sh
# Exit 0 iff the CE/BUG/CONTROL markers and "MC-2 BUG REPRODUCED" are present, the aggregator logged
# "passed: test_mc2_signal_starved_in_nonsuspended_process", and the kernel reached a clean shutdown.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKTREE="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260729/nanvix/.specula-output/confirmation/MC-2/worktree"
LOG="$HERE/test_bugMC-2_signal_starved_nonsuspended_sleeper.run.log"
BUILD_LOG="$HERE/test_bugMC-2_build.log"
MODULE_SRC="$HERE/test_bugMC-2_signal_starved_nonsuspended_sleeper.rs"
MGR_DIR="$WORKTREE/src/kernel/src/pm/process/manager"
MGR_MOD="$MGR_DIR/mod.rs"

fail() { echo "[repro] $*"; exit 2; }

cd "$WORKTREE" || fail "worktree not found: $WORKTREE"
[ -f "$MODULE_SRC" ] || fail "module source not found: $MODULE_SRC"

# 1) Install the in-kernel test module (idempotent).
cp -f "$MODULE_SRC" "$MGR_DIR/mc2_repro.rs" || fail "copy module"

# 2) Declare the module in process/manager/mod.rs, right after `mod test;` (idempotent).
if ! grep -q "mod mc2_repro;" "$MGR_MOD"; then
    perl -0777 -pi -e 's/(#\[cfg\(feature = "test"\)\]\nmod test;\n)/$1#[cfg(feature = "test")]\nmod mc2_repro;\n/' "$MGR_MOD"
fi

# 3) Wire it into the manager test runner test() (idempotent).
if ! grep -q "mc2_repro::run" "$MGR_MOD"; then
    perl -0777 -pi -e 's/pub\(super\) fn test\(\) -> bool \{\n    test::test\(\)\n\}/pub(super) fn test() -> bool {\n    let mut passed: bool = test::test();\n    passed &= mc2_repro::run();\n    passed\n}/' "$MGR_MOD"
fi

grep -q "mod mc2_repro;" "$MGR_MOD" && grep -q "mc2_repro::run" "$MGR_MOD" \
    || fail "failed to wire the MC-2 test module into $MGR_MOD"
echo "[repro] MC-2 test module installed + wired."

# 4) Build the test kernel + uservm.
echo "[repro] building test kernel + uservm (timeout 45m) ..."
timeout 45m make all-test-kernel all-uservm >"$BUILD_LOG" 2>&1 \
    || { echo "[repro] build failed; see $BUILD_LOG"; tail -140 "$BUILD_LOG"; exit 2; }

# 5) Boot the test kernel in the uservm.
echo "[repro] booting test kernel in uservm (timeout 5m) ..."
timeout 5m ./bin/uservm.elf -kernel bin/kernel-test.elf -kernel-args "test_magic=0xDEADBEEF" \
    > "$LOG" 2>&1
echo "[repro] uservm exit=$?  (full console captured to $LOG)"

echo
echo "==================== MC-2 reproduction markers ===================="
grep -nE "MC-2|passed: test_mc2|FAILED: test_mc2" "$LOG"
echo "==================================================================="
echo

# Success criterion: CE-faithful (no interrupt), BUG (starved), CONTROL (delivered), verdict marker,
# aggregator passed, and a clean kernel boot ("hello, world!").
if grep -qE "MC-2 CE \[ready, unmasked sibling\]:.*not interrupted\)=true" "$LOG" \
   && grep -qE "MC-2 BUG \[ready, sole eligible thread is the sleeper\]:.*caught signal STARVED=true" "$LOG" \
   && grep -qE "MC-2 CONTROL \[suspended.*\]:.*->.interrupted.=true" "$LOG" \
   && grep -q "MC-2 BUG REPRODUCED" "$LOG" \
   && grep -q "passed: test_mc2_signal_starved_in_nonsuspended_process" "$LOG" \
   && grep -q "hello, world!" "$LOG"; then
    echo "[repro] MC-2 REPRODUCED: a caught signal posted to a non-suspended process whose sole"
    echo "        unmasked eligible thread is a sleeper is never delivered (interrupt_signal_candidate"
    echo "        scans only the suspended list); the identical kill() delivers when the process is suspended."
    exit 0
else
    echo "[repro] markers missing or differential not observed — inspect $LOG"
    exit 1
fi
