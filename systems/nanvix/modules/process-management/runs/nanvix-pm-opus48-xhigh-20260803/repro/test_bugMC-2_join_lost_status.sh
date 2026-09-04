#!/usr/bin/env bash
# Reproduction for finding MC-2 — "A waiting joiner can receive ThreadNotFound instead of the
# exit status" (invariant JoinGetsStatus; CE: spec/output/MC_hunt_scenario2_mc2_repaired.out).
#
# WHAT IT DOES
#   Builds and boots the REAL Nanvix microkernel (feature=test) via the standalone UserVM and runs
#   two in-kernel unit tests that drive the REAL RunningProcess::try_join_thread / detach_thread
#   used by the ProcessManager::join_thread loop:
#
#     test_mc2_join_lost_status_second_joiner_reaps  (running.rs try_join_thread reap path)
#     test_mc2_join_lost_status_concurrent_detach_reaps  (detach reaps the zombie)
#
#   Each test:
#     1. Parks a legitimate joiner on live target t2  (Err(Ok(join_cond)), the real join path).
#     2. t2 exits -> zombie awaiting join.
#     3. A concurrent SECOND joiner (or a concurrent detach) reaps t2's zombie first — both are
#        real-API interleavings; no illegal state is injected.
#     4. The resumed joiner re-resolves t2 (as the join_thread loop does after Condvar::wait) and
#        gets Err(Err(NoSuchProcess)) — "thread not found" — instead of the exit status.
#
#   The tests emit "BUG MC-2 REPRODUCED" to the kernel serial console; this script boots the kernel,
#   captures serial output, and asserts the markers (and the real running.rs "thread not found"
#   error) appear alongside a clean boot ("hello, world!").
#
# ESCALATION LEVEL: Level 1 — state produced only by real thread type-state transitions
#   (run/exit->zombie) and driven through the real public try_join_thread/detach_thread; the sole
#   "help" is choosing the scheduler interleaving order (t3/detacher before the parked joiner),
#   which the real scheduler legitimately produces after exit_thread's notify_all.
#
# Exit 0 = bug reproduced. Non-zero = not reproduced.
set -u

WT="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260803/nanvix/.specula-output/confirmation/MC-2/worktree"
KERNEL="$WT/bin/kernel-test.elf"
USERVM="$WT/bin/uservm.elf"
SERIAL="$(mktemp /tmp/mc2_repro_serial.XXXXXX.log)"
BOOT_TIMEOUT=120

say(){ printf '%s\n' "$*"; }

say "==================================================================================="
say "MC-2 reproduction — real Nanvix kernel, in-kernel try_join_thread / detach_thread"
say "==================================================================================="

cd "$WT" || { say "[ERROR] worktree not found: $WT"; exit 2; }

say "[1/2] Building test-feature kernel + UserVM (make all-test-kernel all-uservm)..."
if ! make all-test-kernel all-uservm > /tmp/mc2_repro_build.log 2>&1; then
  say "[ERROR] build failed; tail of build log:"; tail -20 /tmp/mc2_repro_build.log; exit 2
fi
[ -x "$USERVM" ] || { say "[ERROR] uservm binary missing: $USERVM"; exit 2; }
[ -f "$KERNEL" ] || { say "[ERROR] kernel-test.elf missing: $KERNEL"; exit 2; }

say "[2/2] Booting kernel via UserVM (timeout ${BOOT_TIMEOUT}s), capturing serial console..."
timeout "$BOOT_TIMEOUT" "$USERVM" -kernel "$KERNEL" -kernel-args "test_magic=0xDEADBEEF" \
  > "$SERIAL" 2>&1
rc=$?
say "  uservm exit=$rc  (serial: $SERIAL)"

say ""
say "----- relevant serial lines -------------------------------------------------------"
grep -nE 'try_join_thread\(\): "thread not found"|BUG MC-2 REPRODUCED|passed: test_mc2_|FAILED: test_mc2_|hello, world!' "$SERIAL" \
  || say "  (no matching lines)"
say "-----------------------------------------------------------------------------------"
say ""

fail=0
grep -q 'BUG MC-2 REPRODUCED: resumed joiner'                "$SERIAL" || { say "[MISS] second-joiner variant marker"; fail=1; }
grep -q 'BUG MC-2 REPRODUCED (detach variant): resumed joiner' "$SERIAL" || { say "[MISS] detach variant marker"; fail=1; }
grep -q 'try_join_thread(): "thread not found"'              "$SERIAL" || { say "[MISS] real running.rs 'thread not found' error"; fail=1; }
grep -q 'passed: test_mc2_join_lost_status_second_joiner_reaps'    "$SERIAL" || { say "[MISS] second-joiner test did not run"; fail=1; }
grep -q 'passed: test_mc2_join_lost_status_concurrent_detach_reaps' "$SERIAL" || { say "[MISS] detach test did not run"; fail=1; }
grep -q 'hello, world!'                                      "$SERIAL" || { say "[MISS] kernel did not finish booting"; fail=1; }

say "==================================================================================="
if [ "$fail" -eq 0 ]; then
  say "RESULT: REPRODUCED — the resumed joiner received NoSuchProcess (ThreadNotFound) instead of"
  say "        the exit status, in the real kernel, via both the second-joiner and detach reap"
  say "        paths. Matches CE MC_hunt_scenario2_mc2_repaired.out (JoinGetsStatus violated)."
  say "==================================================================================="
  exit 0
else
  say "RESULT: NOT reproduced (see missing markers above)."
  say "==================================================================================="
  exit 1
fi
