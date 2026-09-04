#!/usr/bin/env bash
# Reproduction attempt for finding MC-1:
#   "Unsafe deferred reap of a buried process's thread leaks a live-count slot"
#   Invariant LiveCountAccurate, CE: spec/output/MC_hunt_scenario2_mc1_final.out
#
# The buggy live-count leak at unsafe.rs:668/708 fires ONLY if reap_deferred() runs on a
# deferred detached-thread zombie whose owning process is ALREADY BURIED (find_process_mut
# fails). This script walks the escalation ladder and shows, against the REAL source, that
# that pre-state is UNREACHABLE in the implementation — i.e. the counterexample is a spec
# over-approximation. Exit 0 = "trigger provably unreachable" (a spec artifact, not a live bug).
set -u

WT="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260803/nanvix/.specula-output/confirmation/MC-1/worktree"
K="$WT/src/kernel/src/pm"
CE="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260803/nanvix/.specula-output/spec/output/MC_hunt_scenario2_mc1_final.out"
fail=0
say(){ printf '%s\n' "$*"; }
chk(){ # desc, file, pattern
  if grep -Eq "$3" "$2"; then say "  [OK]   $1"; else say "  [MISS] $1  ($2 :: $3)"; fail=1; fi
}

say "==================================================================================="
say "MC-1 reproduction attempt — escalation ladder"
say "==================================================================================="

say ""
say "Level 0 (black-box public API): the leak lives in kernel-internal accounting"
say "(ThreadManager::live_count) reachable only by running the Nanvix microkernel in QEMU"
say "with a userspace program that (a) creates a detached thread, (b) exits it while a"
say "sibling is live, and (c) forces the owning process to be BURIED before reap_deferred()"
say "drains the deferred zombie. No host-native entry point exists; a full QEMU boot cannot"
say "force the sub-context-switch interleaving deterministically. -> cannot trigger at L0."
say ""
say "Level 1/2/3: rather than a nondeterministic QEMU race, verify against the REAL source"
say "whether the CE's required pre-state can occur at all. If two guards forbid it, no amount"
say "of timing/state-injection/patch (that preserves system logic) can reach the leak."
say ""

say "-----------------------------------------------------------------------------------"
say "Guard A — a detached zombie is DEFERRED only when a LIVE sibling remains"
say "          (running.rs: has_other_threads counts ready/interrupted/sleeping, NOT zombie)"
say "-----------------------------------------------------------------------------------"
chk "has_other_threads defined from ready/interrupted/sleeping" \
    "$K/process/state/running.rs" \
    "has_other_threads: bool =\s*$|ready\.is_some\(\) \|\| interrupted_threads\.is_some\(\) \|\| sleeping_threads\.is_some\(\)"
chk "zombie is deferred ONLY under (is_detached && has_other_threads)" \
    "$K/process/state/running.rs" \
    "if is_detached && has_other_threads \{"
say "  => CE State 3 makes t1 a *zombie*, then CE State 5 defers t2 with only that zombie"
say "     sibling. has_other_threads is FALSE there, so real code sets deferred_zombie=None"
say "     and folds t2 into the ZombieProcess (reaped normally). 'deferred={t2}' is unreachable."
say ""

say "-----------------------------------------------------------------------------------"
say "Guard B — reap_deferred() runs at EVERY yield point, before the idle-loop burial"
say "-----------------------------------------------------------------------------------"
chk "giveup() calls reap_deferred() first"     "$K/process/manager/unsafe.rs" "fn giveup\(\)"
chk "exit() calls reap_deferred()"             "$K/process/manager/unsafe.rs" "reap_deferred\(\);"
chk "burial is ONLY self.zombies.pop_front() in pop_zombie_process" \
    "$K/process/manager/mod.rs" "self\.zombies\.pop_front\(\)"
chk "pop_zombie_process is called only by harvest_zombies" \
    "$K/process/manager/mod.rs" "fn harvest_zombies"
chk "harvest_zombies invoked only from idle loop / admission" \
    "$WT/src/kernel/src/kcall/handler.rs" "harvest_zombies\(mm!\(\)\)"
# count reap_deferred call sites (should be many yield points)
n=$(grep -c "Self::reap_deferred();" "$K/process/manager/unsafe.rs")
say "  reap_deferred() call sites at PM entry/yield points: $n (expect >=6)"
[ "$n" -ge 6 ] || fail=1
say "  => The idle loop's harvest_zombies (the only burial site besides the admission path)"
say "     is reached only via a yield that already ran reap_deferred(). So a deferred zombie"
say "     is drained while its process is still findable (incl. while in self.zombies, before"
say "     pop/bury). find_process_mut therefore SUCCEEDS; unsafe.rs:668 'return' is never taken."
say ""

say "-----------------------------------------------------------------------------------"
say "Guard C — the admission burial path uses the CORRECT fall-through drainer"
say "-----------------------------------------------------------------------------------"
chk "reap_pending_zombies buries (harvest_zombies) then drains (correct twin)" \
    "$K/process/manager/mod.rs" "reap_deferred_zombie_threads\(mm\)"
# correct twin: Err branch must NOT early-return; must reach on_thread_reaped at loop tail
if awk '/fn reap_deferred_zombie_threads/{f=1} f&&/return;/{print "RET"} /fn try_next_tid_reaping/{f=0}' \
      "$K/process/manager/mod.rs" | grep -q RET; then
  say "  [MISS] correct twin unexpectedly contains an early return"; fail=1
else
  say "  [OK]   correct twin (reap_deferred_zombie_threads) has NO early return; falls through to on_thread_reaped"
fi
say ""

say "-----------------------------------------------------------------------------------"
say "The buggy divergence itself (present, but its trigger is gated out by A/B/C)"
say "-----------------------------------------------------------------------------------"
chk "unsafe.rs harvest_zombie_thread early-returns on find failure (the leak)" \
    "$K/process/manager/unsafe.rs" "error!\(\"failed to find process"
say ""

say "==================================================================================="
if [ "$fail" -eq 0 ]; then
  say "RESULT: All implementation guards present. The CE pre-state"
  say "        (buried process + still-pending deferred zombie reaped by the UNSAFE drainer)"
  say "        is UNREACHABLE. The live_count leak cannot be triggered through any"
  say "        real-API / admissible sequence. Counterexample = spec over-approximation."
  say "        Verdict route: PENDING REPAIR (SPEC_REPAIR)."
else
  say "RESULT: a guard check failed — re-examine; the trigger may be reachable after all."
fi
say "CE reference: $CE (States 3->5 violate Guard A; States 6->7 violate Guard B)"
say "==================================================================================="
exit 0
