#!/usr/bin/env bash
# CR-5 reproduction driver.
#
# Bug: A caught signal (handler disposition) posted via kill() to a purely CPU-bound thread that
# never issues a kernel call is never delivered while it spins, because the kernel's ONLY caught-
# signal delivery checkpoint is at the kernel-call return-to-user boundary (deliver_pending_signals
# at the end of do_kcall, src/kernel/src/kcall/dispatcher.rs:245). The timer-interrupt return path
# (src/kernel/src/pm/clock.rs:109 timer_handler -> ProcessManager::tick(), manager/unsafe.rs:899)
# only reschedules and never delivers signals; kill() for a caught signal only interrupts a
# *suspended* candidate (manager/mod.rs:1009 scans only `suspended`). The design spec (issue #2694)
# required a delivery checkpoint "plus on return from interrupt/exception to a user thread" — that
# half was never implemented.
#
# This driver builds the standalone `test-rust-kill.initrd` image (which includes the added guest
# test `test_cr5_caught_signal_to_cpu_bound`) and boots it under nanvixd on the KVM microvm. The
# guest test forks a CPU-bound child that installs a SIGUSR1 handler and spins, the parent posts
# SIGUSR1 while the child spins, and the parent reaps the child. On a correct kernel the handler
# runs during the spin (child exit=71 DELIVERED). On this kernel the handler is never delivered and
# the child completes its whole spin (child exit=72 NOT_DELIVERED), which the parent's assertion
# rejects — reproducing CR-5.
#
# Level 0 (pure black-box): only public APIs; no failpoints, no injection, no kernel source patch.
#
# Exit 0  => bug reproduced (caught signal NOT delivered to the CPU-bound thread).
# Exit 1  => NOT reproduced (handler ran during the spin) — bug appears fixed/absent.
# Exit 2  => environment/setup error.
set -u

WT="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260729/nanvix/.specula-output/confirmation/CR-5/worktree"
RUN_LOG="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260729/nanvix/.specula-output/repro/test_bugCR-5_cpu_bound_caught_signal.run.log"
IMG="./bin/test-rust-kill.initrd"

cd "$WT" || { echo "ENV ERROR: worktree not found: $WT"; exit 2; }

# Guard: the reproduction test must be registered in the kill() suite.
if ! grep -q "test_cr5_caught_signal_to_cpu_bound" src/tests/integration/test-rust-kill/src/tests/kill.rs; then
    echo "ENV ERROR: CR-5 reproduction test not present in test-rust-kill suite"; exit 2
fi

echo "== Building Nanvix (all-nanvix) =="
if ! make all-nanvix -j"$(nproc)" > /tmp/cr5_repro_build.log 2>&1; then
    echo "ENV ERROR: build failed; see /tmp/cr5_repro_build.log"; tail -20 /tmp/cr5_repro_build.log; exit 2
fi
[ -f "$IMG" ] || { echo "ENV ERROR: image not built: $IMG"; exit 2; }

echo "== Booting test-rust-kill image under nanvixd (KVM microvm), timeout 200s =="
mkdir -p logs
timeout 200 ./bin/nanvixd.elf -console-file /dev/stdout -log-dir logs -- "$IMG" > "$RUN_LOG" 2>&1
echo "nanvixd exit=$? (4 == guest process killed by default action after the CR-5 assertion panic)"

echo
echo "== Reproduction signature =="
grep -nE "\[CR-5\]|child exit=72|child exit=71|Ticks:" "$RUN_LOG" | head -20

# Decide the outcome from the captured console.
if grep -q "\[CR-5\] REPRODUCED" "$RUN_LOG" && grep -q "child exit=72" "$RUN_LOG"; then
    echo
    echo "RESULT: REPRODUCED — a caught SIGUSR1 posted to a CPU-bound thread was never delivered"
    echo "        while it spun (child exited NOT_DELIVERED=72), despite the timer preempting it"
    echo "        thousands of times (see 'Ticks:' above). The kernel has no signal-delivery"
    echo "        checkpoint on timer-interrupt return."
    exit 0
elif grep -q "\[CR-5\] not-reproduced" "$RUN_LOG"; then
    echo "RESULT: NOT REPRODUCED — the handler ran during the spin (child exited DELIVERED=71)."
    exit 1
else
    echo "RESULT: INCONCLUSIVE — no CR-5 signature found; inspect $RUN_LOG"
    exit 2
fi
