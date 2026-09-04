#!/usr/bin/env bash
#
# Reproduction driver for finding MC-3:
#   "Terminated/exited process resumes user code on a carried-forward interrupted thread"
#   invariant TerminatedThreadsDie, config MC_hunt_scenario2.cfg,
#   counterexample spec/output/MC_hunt_MC-3.out (trace length 11).
#
# MC CE (verbatim actions):
#   Initial -> MCCreateThread -> MCSleep -> MCRunnableTerminate -> MCResumeInterrupted -> MCSchedule
#           -> MCSleep -> MCAlarmFire -> MCResumeInterrupted -> MCSchedule -> MCDispatcherCheckpoint
#   Final: procTerminated[p1]=true, procState[p1]="running", threadState[t1]="running",
#          resumedAfterTerminate=true  (a TERMINATED process runs user code).
#
# ROOT CAUSE (real code): termination is enforced ONLY by marking a thread's interrupt reason
#   `Killed` (so kcall/sleep.rs:62-66 routes it to exit()). InterruptedProcess::terminate
#   (state/interrupted.rs:110-125) force-marks every already-interrupted thread Killed, but the two
#   sibling paths do NOT: RunnableProcess::terminate (state/runnable.rs:180-181) and
#   RunningProcess::exit (state/running.rs:293-294) both `take()` the interrupted set and re-attach it
#   UNCHANGED, so a pre-existing TimedOut/Signaled reason survives. kcall/sleep.rs:64 maps
#   Interrupted(TimedOut) -> Ok(()), so the terminated thread returns to user code.
#
# HOW THIS REPRODUCES IT (in-kernel, feature = "test", REAL PM type-state methods only; no product
# logic altered; no illegal injection): mc3_repro.rs drives the REAL chain
#   RunnableProcess::new -> run -> add_thread -> sleep(alarm) -> run -> sleep(alarm)
#     -> SleepingProcess::wakeup_alarm(now)  [two expired alarms -> two TimedOut interrupts]
#     -> InterruptedProcess::resume()        [carries one interrupted thread forward, TimedOut]
#   then:
#     CONTROL [InterruptedProcess::terminate]: survivor re-marked Killed          (correct sibling)
#     BUG A   [RunnableProcess::terminate]:     survivor keeps reason=TimedOut     (expected Killed)
#     BUG B   [RunningProcess::exit]:           returns Ok(RunnableProcess) and run() surfaces
#                                               Some(TimedOut) == the value pm::sleep maps to Ok(())
#
# Usage: ./test_bugMC-3_terminated_thread_resumes.sh
# Exit 0 iff the CONTROL/BUG-A/BUG-B markers and "MC-3 BUG REPRODUCED" are present, the aggregator
# logged "passed: test_mc3_terminated_thread_resumes_on_carried_interrupted", and the kernel reached
# a clean shutdown ("hello, world!").

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKTREE="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260729/nanvix/.specula-output/confirmation/MC-3/worktree"
LOG="$HERE/test_bugMC-3_terminated_thread_resumes.run.log"
BUILD_LOG="$HERE/test_bugMC-3_build.log"
MODULE_SRC="$HERE/test_bugMC-3_terminated_thread_resumes.rs"
STATE_DIR="$WORKTREE/src/kernel/src/pm/process/state"
STATE_MOD="$STATE_DIR/mod.rs"

fail() { echo "[repro] $*"; exit 2; }

cd "$WORKTREE" || fail "worktree not found: $WORKTREE"
[ -f "$MODULE_SRC" ] || fail "module source not found: $MODULE_SRC"

# 1) Install the in-kernel test module (idempotent).
cp -f "$MODULE_SRC" "$STATE_DIR/mc3_repro.rs" || fail "copy module"

# 2) Declare the module in process/state/mod.rs, right after `mod kill_test;` (idempotent).
if ! grep -q "mod mc3_repro;" "$STATE_MOD"; then
    perl -0777 -pi -e 's/(#\[cfg\(feature = "test"\)\]\nmod kill_test;\n)/$1#[cfg(feature = "test")]\nmod mc3_repro;\n/' "$STATE_MOD"
fi

# 3) Wire it into the state test runner test(), after kill_test::test() (idempotent).
if ! grep -q "mc3_repro::run" "$STATE_MOD"; then
    perl -0777 -pi -e 's/(    passed &= kill_test::test\(\);\n)/$1    passed &= mc3_repro::run();\n/' "$STATE_MOD"
fi

grep -q "mod mc3_repro;" "$STATE_MOD" && grep -q "mc3_repro::run" "$STATE_MOD" \
    || fail "failed to wire the MC-3 test module into $STATE_MOD"
echo "[repro] MC-3 test module installed + wired."

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
echo "==================== MC-3 reproduction markers ===================="
grep -nE "MC-3|MC3-REPRO|passed: test_mc3|FAILED: test_mc3" "$LOG"
echo "==================================================================="
echo

# Success criterion: CONTROL correct (Killed), BUG A (TimedOut retained), BUG B (runnable + TimedOut),
# verdict marker, aggregator passed, and a clean kernel boot ("hello, world!").
if grep -qE "MC-3 CONTROL \[InterruptedProcess::terminate\]:.*reason=Killed" "$LOG" \
   && grep -qE "MC-3 BUG A \[RunnableProcess::terminate\]:.*reason=TimedOut \(expected Killed\)" "$LOG" \
   && grep -qE "MC-3 BUG B \[RunningProcess::exit\]:.*surfaces Some\(TimedOut\)" "$LOG" \
   && grep -q "MC-3 BUG REPRODUCED" "$LOG" \
   && grep -q "passed: test_mc3_terminated_thread_resumes_on_carried_interrupted" "$LOG" \
   && grep -q "hello, world!" "$LOG"; then
    echo "[repro] MC-3 REPRODUCED: RunnableProcess::terminate and RunningProcess::exit carry a"
    echo "        pre-existing interrupted thread forward with reason TimedOut (not Killed); when"
    echo "        resumed, kcall/sleep.rs:64 maps Interrupted(TimedOut) -> Ok(()) so the terminated/"
    echo "        exited process's thread returns to user code (TerminatedThreadsDie violation)."
    exit 0
else
    echo "[repro] markers missing or differential not observed — inspect $LOG"
    exit 1
fi
