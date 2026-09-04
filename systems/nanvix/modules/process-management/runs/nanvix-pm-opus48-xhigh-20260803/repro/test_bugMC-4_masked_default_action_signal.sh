#!/usr/bin/env bash
# Reproduction for finding MC-4 — "A masked default-action signal is acted upon while masked"
# (invariant MaskedSignalDeferred; CE: spec/output/MC_hunt_scenario4_mc4_repaired.out).
#
# WHAT IT DOES
#   Builds and boots the REAL Nanvix microkernel (feature=test) via the standalone UserVM and runs
#   an in-kernel unit test that drives the REAL ProcessManager::kill() through the public API only
#   (Level 0 — sigprocmask + kill, no injected state, no timing hacks, no source modification):
#
#     test_mc4_masked_default_action_signal_acted_upon
#
#   The test, on the running (kernel) process:
#     1. sigprocmask(SIG_BLOCK, {SIGTERM}) blocks SIGTERM on the running thread.
#     2. kill(self, self, SIGTERM) posts SIGTERM, whose disposition is the default (terminate).
#        BUG: kill() resolves DefaultAction::Terminate and returns KillOutcome::TerminateSelf
#             (the kill kcall handler acts on this by terminating the caller) WITHOUT consulting
#             the thread mask, and the signal is NOT left pending.
#        Correct (POSIX / this kernel's own candidate_tid_for design): defer it — return Done and
#             leave SIGTERM pending until unblocked.
#     3. CONTROL: identical masked-then-kill flow but with a *handler* (caught) disposition on
#        SIGINT -> kill returns Done and leaves SIGINT pending (correctly deferred). This isolates
#        the defect to the default-action branch at manager/mod.rs:858.
#
#   The test emits "BUG MC-4 REPRODUCED" plus the two outcome lines to the kernel serial console;
#   this script boots the kernel, captures serial output, and asserts the markers (and a clean
#   boot: "hello, world!").
#
# ESCALATION LEVEL: Level 0 — pure black-box public API (sigprocmask + kill), normal operations.
#
# Exit 0 = bug reproduced. Non-zero = not reproduced.
set -u

WT="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260803/nanvix/.specula-output/confirmation/MC-4/worktree"
KERNEL="$WT/bin/kernel-test.elf"
USERVM="$WT/bin/uservm.elf"
SERIAL="$(mktemp /tmp/mc4_repro_serial.XXXXXX.log)"
BOOT_TIMEOUT=120

say(){ printf '%s\n' "$*"; }

say "==================================================================================="
say "MC-4 reproduction — real Nanvix kernel, in-kernel ProcessManager::kill() (Level 0)"
say "==================================================================================="

cd "$WT" || { say "[ERROR] worktree not found: $WT"; exit 2; }

say "[1/2] Building test-feature kernel + UserVM (make all-test-kernel all-uservm)..."
if ! make all-test-kernel all-uservm > /tmp/mc4_repro_build.log 2>&1; then
  say "[ERROR] build failed; tail of build log:"; tail -20 /tmp/mc4_repro_build.log; exit 2
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
grep -nE 'MC-4: SIGTERM|MC-4: SIGINT|BUG MC-4 REPRODUCED|passed: test_mc4_|FAILED: test_mc4_|hello, world!' "$SERIAL" \
  || say "  (no matching lines)"
say "-----------------------------------------------------------------------------------"
say ""

fail=0
grep -q 'BUG MC-4 REPRODUCED'                                        "$SERIAL" || { say "[MISS] REPRODUCED marker";                      fail=1; }
grep -q 'MC-4: SIGTERM (default, masked) -> kill outcome=Ok(TerminateSelf)' "$SERIAL" || { say "[MISS] SIGTERM acted-upon (TerminateSelf) line"; fail=1; }
grep -q 'sigpending&SIGTERM=0x0'                                     "$SERIAL" || { say "[MISS] SIGTERM-not-pending evidence";           fail=1; }
grep -q 'MC-4: SIGINT (handler, masked) -> kill outcome=Ok(Done)'    "$SERIAL" || { say "[MISS] control: SIGINT deferred (Done) line";   fail=1; }
grep -q 'sigpending&SIGINT=0x2'                                      "$SERIAL" || { say "[MISS] control: SIGINT-pending evidence";       fail=1; }
grep -q 'passed: test_mc4_masked_default_action_signal_acted_upon'   "$SERIAL" || { say "[MISS] test did not run";                       fail=1; }
grep -q 'hello, world!'                                              "$SERIAL" || { say "[MISS] kernel did not finish booting";          fail=1; }

say "==================================================================================="
if [ "$fail" -eq 0 ]; then
  say "RESULT: REPRODUCED — kill() acted upon a masked default-action SIGTERM (returned"
  say "        TerminateSelf, signal not left pending) while an identically-masked caught SIGINT"
  say "        was correctly deferred (Done, SIGINT pending), in the real kernel. Matches CE"
  say "        MC_hunt_scenario4_mc4_repaired.out (MaskedSignalDeferred violated)."
  say "==================================================================================="
  exit 0
else
  say "RESULT: NOT reproduced (see missing markers above)."
  say "==================================================================================="
  exit 1
fi
