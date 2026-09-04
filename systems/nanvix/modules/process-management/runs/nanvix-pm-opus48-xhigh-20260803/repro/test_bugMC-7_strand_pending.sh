#!/usr/bin/env bash
# Reproduction for finding MC-7 — "sigaction to SIG_DFL/SIG_IGN strands an already-pending signal".
#
#   Source (model checking): invariant NoStrandedProcPending (also SignalEventuallyDelivered)
#   Counterexample         : spec/output/MC_hunt_scenario4_mc7_final.out
#   Affected code (worktree):
#     - src/kernel/src/pm/process/manager/mod.rs:603-611   (ProcessManager::sigaction install block)
#     - src/kernel/src/pm/process/manager/signal.rs:242-253 (try_deliver_signal handler-only filter)
#     - src/kernel/src/pm/process/state/signal.rs:364       (SignalControl::set_disposition)
#
# WHAT IT DOES  (END-TO-END, REAL-CODE, Level 0 — public-API-equivalent, no injected illegal state,
#                no timing hacks, no source-logic modification):
#   Builds the REAL Nanvix `test`-feature kernel and boots it in the standalone UserVM. During PM
#   init the in-kernel trace harness (pm/process/state/tla_world.rs) runs the added
#   scenario_mc7_strand_pending(), which drives the REAL per-process `SignalControl` — the exact
#   struct ProcessManager::{sigaction,kill,try_deliver_signal} operate on — through the counter-
#   example sequence, for BOTH non-handler dispositions (SIG_IGN and SIG_DFL):
#
#     Sigaction(p1, sig1, handler);   # REAL set_disposition -> Handler
#     Kill(p1, sig1);                 # Handler branch -> REAL SignalControl::post(1): pending={1}
#     Sigaction(p1, sig1, ignore|default);  # REAL set_disposition -> non-handler; pending UNTOUCHED
#     AsyncDeliver(t1);               # REAL try_deliver_signal filter (disp==Handler?) -> SKIP,
#                                     #   pending NOT drained
#
#   It then reads the REAL `SignalControl::pending()` and disposition and prints an @@MC7@@ line.
#
#   BUG: the pending bit posted while sig1 was caught is never reconciled when the disposition
#        changes to SIG_IGN / SIG_DFL, so try_deliver_signal skips it forever and it is never
#        drained (NoStrandedProcPending / SignalEventuallyDelivered). POSIX additionally requires
#        SIG_IGN to DISCARD a pending signal. Correct: pending bit for sig1 clear after the change.
#
#   PASS (bug reproduced) == console shows, for BOTH variants,
#        "@@MC7@@ variant=ignore  ... pd_after_deliver=0x1 verdict=REPRODUCED"
#        "@@MC7@@ variant=default ... pd_after_deliver=0x1 verdict=REPRODUCED"
#        plus "@@MC7@@ summary ignore_stranded=true default_stranded=true"
#        and a clean boot ("hello, world!").
#
# Exit 0 = bug reproduced. Non-zero = not reproduced / build/boot problem.
set -uo pipefail

WT="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260803/nanvix/.specula-output/confirmation/MC-7/worktree"
OUTDIR="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260803/nanvix/.specula-output/confirmation/MC-7"
KERNEL="$WT/bin/kernel-test.elf"
USERVM="$WT/bin/uservm.elf"
CONSOLE="$OUTDIR/mc7_console.log"
BUILD_LOG="$OUTDIR/mc7_build.log"
BOOT_TIMEOUT=180

say(){ printf '%s\n' "$*"; }

say "==================================================================================="
say "MC-7 reproduction — real Nanvix test-kernel, real SignalControl (Level 0)"
say "==================================================================================="

cd "$WT" || { say "[ERROR] worktree not found: $WT"; exit 2; }

say "[1/3] Building test-feature kernel + UserVM (make all-test-kernel all-uservm)..."
if ! timeout 1800 make all-test-kernel all-uservm > "$BUILD_LOG" 2>&1; then
  say "[ERROR] build failed; tail of build log:"; tail -30 "$BUILD_LOG"; exit 2
fi
[ -x "$USERVM" ] || { say "[ERROR] uservm binary missing: $USERVM"; exit 2; }
[ -f "$KERNEL" ] || { say "[ERROR] kernel-test.elf missing: $KERNEL"; exit 2; }

say "[2/3] Booting kernel via UserVM (timeout ${BOOT_TIMEOUT}s), capturing serial console..."
timeout "$BOOT_TIMEOUT" "$USERVM" -kernel "$KERNEL" -kernel-args "test_magic=0xDEADBEEF" \
  > "$CONSOLE" 2>&1
rc=$?
say "  uservm exit=$rc  (console: $CONSOLE)"

say ""
say "----- @@MC7@@ / boot lines --------------------------------------------------------"
grep -nE '@@MC7@@|hello, world!' "$CONSOLE" || say "  (no matching lines)"
say "-----------------------------------------------------------------------------------"
say ""

fail=0
grep -q '@@MC7@@ variant=ignore .*pd_after_deliver=0x1 verdict=REPRODUCED'  "$CONSOLE" || { say "[MISS] SIG_IGN stranded-pending line";  fail=1; }
grep -q '@@MC7@@ variant=default .*pd_after_deliver=0x1 verdict=REPRODUCED' "$CONSOLE" || { say "[MISS] SIG_DFL stranded-pending line";  fail=1; }
grep -q '@@MC7@@ summary ignore_stranded=true default_stranded=true'        "$CONSOLE" || { say "[MISS] summary line";                   fail=1; }
grep -q 'hello, world!'                                                     "$CONSOLE" || { say "[MISS] kernel did not finish booting";  fail=1; }

say "==================================================================================="
if [ "$fail" -eq 0 ]; then
  say "RESULT: REPRODUCED — after kill() posted a caught signal, changing its disposition to"
  say "        SIG_IGN and to SIG_DFL each left the REAL SignalControl pending bit (0x1) set with a"
  say "        non-handler disposition; try_deliver_signal skips it forever, so it is never drained"
  say "        (nor discarded, as POSIX requires for SIG_IGN). Matches CE"
  say "        MC_hunt_scenario4_mc7_final.out (NoStrandedProcPending violated)."
  say "==================================================================================="
  exit 0
else
  say "RESULT: NOT reproduced (see missing markers above)."
  say "==================================================================================="
  exit 1
fi
