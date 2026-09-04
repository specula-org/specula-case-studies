#!/usr/bin/env bash
#
# Reproduction driver for finding MC-1:
#   "Lost condvar/join notification to a sleeper embedded in an interrupted process"
#   invariant NoLostNotify (MCNoLostNotify), config MC_hunt_scenario1.cfg,
#   counterexample spec/output/MC_hunt_MC-1.out (trace length 10).
#
# MC CE (verbatim actions):
#   Initial -> MCCreateProcess -> MCCreateThread -> MCSleep -> MCSchedule -> MCSleep
#           -> MCSchedule -> MCAlarmFire -> MCNotifyDequeue -> MCWakeDequeued
#   Final: procState[p1]=interrupted, threadState[t3]=sleeping, threadOwner[t3]=p1,
#          condWaiters[c1]=[] (t3 dequeued by notify), lostNotify=TRUE.
#
# ROOT CAUSE (real code): ProcessManager::try_wakeup (manager/mod.rs:1880) scans only `suspended`
#   and `ready`; try_wakeup_thread (1852) also checks `running`. NONE scan `interrupted`. The
#   condvar/join wakeup path Condvar::notify_first (sync/condvar.rs:118) ->
#   ProcessManager::wakeup_waiter (manager/unsafe.rs:1142) -> try_wakeup_thread (and do_wakeup,
#   mod.rs:1821, wraps the same fn) therefore CANNOT find a residual sleeper parked inside an
#   interrupted process, so notify_first discards the dequeued waiter (Ok(0)) while it stays asleep.
#
# HOW THIS REPRODUCES IT (in-kernel, feature = "test", REAL PM / type-state methods, no product
# logic altered): mc1_repro.rs builds a fully-suspended two-thread process via the REAL chain
# (new -> run -> add_thread -> sleep -> run -> sleep), applies the REAL signal transition
# interrupt_suspended_thread(sibling) to move it to `interrupted` (this is what kill ->
# interrupt_signal_candidate does), then invokes the REAL condvar wakeup
# ProcessManager::wakeup_waiter(waiter) (== do_wakeup):
#   BUG        [interrupted] -> wakeup_waiter=false / do_wakeup=NoSuchEntry, waiter still sleeping
#   CONTROL    [suspended]   -> identical wakeup succeeds
#   PERMANENCE [resume()->ready] -> real resume() does NOT wake the residual sleeper
#   ISOLATION  [ready]       -> the SAME wakeup now succeeds (loss is solely the interrupted-list gap)
#
# Usage: ./test_bugMC-1_lost_wakeup_interrupted.sh
# Exit 0 iff the BUG / CONTROL / PERMANENCE / ISOLATION markers and "MC-1 BUG REPRODUCED" are
# present, the test aggregator logged "passed: test_mc1_lost_wakeup_to_interrupted_sleeper", and
# the kernel reached a clean shutdown.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKTREE="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260729/nanvix/.specula-output/confirmation/MC-1/worktree"
LOG="$HERE/test_bugMC-1_lost_wakeup_interrupted.run.log"
BUILD_LOG="$HERE/test_bugMC-1_build.log"
MODULE_SRC="$HERE/test_bugMC-1_lost_wakeup_interrupted.rs"
MGR_DIR="$WORKTREE/src/kernel/src/pm/process/manager"
MGR_MOD="$MGR_DIR/mod.rs"

fail() { echo "[repro] $*"; exit 2; }

cd "$WORKTREE" || fail "worktree not found: $WORKTREE"
[ -f "$MODULE_SRC" ] || fail "module source not found: $MODULE_SRC"

# 1) Install the in-kernel test module (idempotent).
cp -f "$MODULE_SRC" "$MGR_DIR/mc1_repro.rs" || fail "copy module"

# 2) Declare the module in process/manager/mod.rs, right after `mod test;` (idempotent).
if ! grep -q "mod mc1_repro;" "$MGR_MOD"; then
    perl -0777 -pi -e 's/(#\[cfg\(feature = "test"\)\]\nmod test;\n)/$1#[cfg(feature = "test")]\nmod mc1_repro;\n/' "$MGR_MOD"
fi

# 3) Wire it into the manager test runner test() (idempotent).
if ! grep -q "mc1_repro::run" "$MGR_MOD"; then
    perl -0777 -pi -e 's/pub\(super\) fn test\(\) -> bool \{\n    test::test\(\)\n\}/pub(super) fn test() -> bool {\n    let mut passed: bool = test::test();\n    passed &= mc1_repro::run();\n    passed\n}/' "$MGR_MOD"
fi

grep -q "mod mc1_repro;" "$MGR_MOD" && grep -q "mc1_repro::run" "$MGR_MOD" \
    || fail "failed to wire the MC-1 test module into $MGR_MOD"
echo "[repro] MC-1 test module installed + wired."

# 4) Build the test kernel + uservm.
echo "[repro] building test kernel + uservm (timeout 45m) ..."
timeout 45m make all-test-kernel all-uservm >"$BUILD_LOG" 2>&1 \
    || { echo "[repro] build failed; see $BUILD_LOG"; tail -120 "$BUILD_LOG"; exit 2; }

# 5) Boot the test kernel in the uservm.
echo "[repro] booting test kernel in uservm (timeout 5m) ..."
timeout 5m ./bin/uservm.elf -kernel bin/kernel-test.elf -kernel-args "test_magic=0xDEADBEEF" \
    > "$LOG" 2>&1
echo "[repro] uservm exit=$?  (full console captured to $LOG)"

echo
echo "==================== MC-1 reproduction markers ===================="
grep -nE "MC-1|passed: test_mc1|FAILED: test_mc1" "$LOG"
echo "==================================================================="
echo

# Success criterion: precondition established, bug lost the notify, control delivered, permanence
# and isolation shown, verdict marker present, aggregator passed, kernel shut down cleanly.
if grep -q "MC-1 PRECONDITION: process on .interrupted., waiter .* still sleeping = true" "$LOG" \
   && grep -qE "MC-1 BUG \[interrupted\]: wakeup_waiter\(.*\)=false .*lost=true .*stranded\)=true" "$LOG" \
   && grep -qE "MC-1 CONTROL \[suspended\]: wakeup_waiter\(.*\)=true" "$LOG" \
   && grep -qE "MC-1 PERMANENCE \[after resume\(\)->ready\]: waiter .* still sleeping=true" "$LOG" \
   && grep -qE "MC-1 ISOLATION/2 \[ready\]: wakeup_waiter\(.*\)=true" "$LOG" \
   && grep -q "MC-1 BUG REPRODUCED" "$LOG" \
   && grep -q "passed: test_mc1_lost_wakeup_to_interrupted_sleeper" "$LOG" \
   && grep -q "hello, world!" "$LOG"; then
    echo "[repro] MC-1 REPRODUCED: a condvar/join notification to a still-sleeping waiter embedded"
    echo "        in an interrupted process is LOST because try_wakeup omits the interrupted list;"
    echo "        the identical wakeup succeeds when the process sits on suspended/ready."
    exit 0
else
    echo "[repro] markers missing or differential not observed — inspect $LOG"
    exit 1
fi
