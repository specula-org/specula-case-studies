#!/usr/bin/env bash
#
# Reproduction for MC-8 — "kill posts a caught signal onto a zombie process"
# Invariant: NoSignalToZombie   Source: model-checking   Scenario: 4 (kill vs. lifecycle)
#
# WHAT THIS REPRODUCES
# --------------------
# The target lookup used by ProcessManager::kill (`find_process_mut`,
# src/kernel/src/pm/process/manager/mod.rs:2885-2901) returns *zombie* processes
# (branch at :2894-2895 -> ProcessRefMut::Zombie). The kill post path
# (mod.rs:849-857) then, for a caught (Handler) disposition, calls
# `signals.post(signum)` with NO runnable/zombie guard. A caught signal is thus
# enqueued into the pending set of a process that can never run a handler.
#
# This is a REAL defect (missing runnability guard on the post path), but its
# consequence is MASKED:
#   * the "Interrupt" wakeup (`interrupt_signal_candidate`, mod.rs:1009-1019)
#     scans only `self.suspended`, so a zombie is never scheduled/woken; and
#   * the zombie's whole state (incl. the pending set) is discarded at
#     harvest/reap, and no live consumer ever reads a zombie's pending set
#     (`sigpending` reads the *caller's* own set; `try_deliver_signal` reads only
#     the *running* thread).
# So nothing observes a wrong outcome -> verdict MASKED (not REPRODUCED).
#
# HOW IT IS REPRODUCED (in-kernel unit test, real kill path, QEMU/uservm)
# ----------------------------------------------------------------------
# The reproduction runs *inside* the real kernel via the in-kernel test harness
# (`pm::test()` -> state::kill_test::test()). It drives the genuine
# `ProcessManager::kill` entry point against a genuine zombie and observes the
# pending set directly. The test and its (test-only) helpers are embedded below
# for the record; they live in the build tree at:
#   * src/kernel/src/pm/process/state/kill_test.rs
#       - fn handler_disposition()
#       - fn test_kill_posts_caught_signal_to_zombie()  (registered in test())
#   * src/kernel/src/pm/process/manager/mod.rs  (#[cfg(feature = "test")] helpers)
#       - test_push_zombie / test_zombie_pending / test_remove_zombie /
#         test_queue_lengths
#
# REACHABILITY of the injected zombie (Level-2 state injection is admissible):
# the zombie is built EXACTLY as production builds one —
# `ZombieProcess::new(state, <terminated ReadyThread(s)>, status)` — which is what
# `RunnableProcess::terminate()` returns and `terminate()` pushes onto
# `self.zombies` (mod.rs `self.zombies.push_back(...)`). The real API sequence that
# reaches it: create_process -> sigaction(Handler for signum) -> all threads exit
# -> ZombieProcess queued. It also corresponds to the MC counterexample step where
# process p1 is in state `zombie` with disposition `handler` and Kill posts the
# signal (spec/output/MC_hunt_scenario4_mc8_final.out).
#
# ---------------------------------------------------------------------------
# EMBEDDED KERNEL TEST (verbatim, for the record) — do not execute this block
# ---------------------------------------------------------------------------
# fn handler_disposition() -> SignalDisposition {
#     SignalDisposition::Handler(Box::new(SignalHandler {
#         entry: VirtualAddress::new(0x1000), mask: 0, flags: 0, sigaction: 0,
#     }))
# }
#
# fn test_kill_posts_caught_signal_to_zombie() -> bool {
#     let signum: usize = SIGUSR1;                         // = 10
#     let zpid = ProcessIdentifier::from(7);
#     let bit: u64 = 1u64 << (signum - 1);                 // = 0x200 = 512
#
#     // Build a real zombie whose disposition for `signum` is a handler.
#     let vmem = make_test_vmem()?;                        // (Some/None handled)
#     let mut state = Box::new(ProcessState::new(zpid, ProcessIdentifier::KERNEL, vmem));
#     state.signals_mut().set_disposition(signum, handler_disposition());
#     let zombie_thread = make_ready_thread(9).terminate();
#     let zombie = ZombieProcess::new(state, NonEmptyVecDeque::new(zombie_thread),
#                                     ErrorCode::Interrupted.into());
#
#     let pm = unsafe { ProcessManager::get_mut() };
#     let _ = pm.capctl(ProcessIdentifier::KERNEL, Capability::ProcessManagement, true);
#     pm.test_push_zombie(zombie);
#     let before = pm.test_queue_lengths();
#
#     let outcome = pm.kill(ProcessIdentifier::KERNEL, zpid, signum);   // REAL kill path
#
#     let pending_after_kill = pm.test_zombie_pending(zpid);
#     let after = pm.test_queue_lengths();
#     let removed = pm.test_remove_zombie(zpid);           // stands in for reap/harvest
#     let pending_after_reap = pm.test_zombie_pending(zpid);
#
#     let queued      = matches!(pending_after_kill, Some(p) if (p & bit) != 0);
#     let no_schedule = after.0 == before.0 && after.2 == before.2 && after.3 == before.3;
#     let discarded   = removed && pending_after_reap.is_none();
#     // ... info! logging (see expected output below) ...
#     queued && no_schedule && discarded
# }
# ---------------------------------------------------------------------------
#
# EXPECTED (captured) OUTPUT — the MC-8 evidence:
#   [INFO][kill_test] ...: MC-8: kill(KERNEL -> zombie pid=7, signum=10) outcome=Ok(Done)
#   [INFO][kill_test] ...: MC-8: zombie pending after kill = Some(512) (signal bit 0x200 present = true)
#   [INFO][kill_test] ...: MC-8: queues before=(0, 0, 0, 1) after=(0, 0, 0, 1) (no live thread scheduled/woken = true)
#   [INFO][kill_test] ...: MC-8: after harvest -> zombie removed=true pending=None (signal discarded = true)
#   [INFO][kill_test] ...: MC-8 REPRODUCED: caught signal 10 was queued into zombie pid=7 (NoSignalToZombie violated); ... masked ...
#   [INFO][kill_test] test(): passed: test_kill_posts_caught_signal_to_zombie
#
# USAGE
#   ./test_bugMC-8_kill_zombie_signal.sh            # boot existing test kernel, watch for evidence
#   ./test_bugMC-8_kill_zombie_signal.sh --rebuild  # full `make run-kernel-tests` (authoritative)
#
# NOTE: `make run-kernel-tests` intentionally waits for a userspace banner
# ("hello, world!") that the pure in-kernel test build does not emit, so that make
# target exits non-zero even though every in-kernel test passes. This script
# therefore keys success off the MC-8 evidence lines, NOT the make exit code.
#
set -u

WORKTREE="/home/ruize/Specula/runs/nanvix-pm-opus48-xhigh-20260803/nanvix/.specula-output/confirmation/MC-8/worktree"
CARGO="/opt/rust/cargo/bin/cargo"
RUSTC="/opt/rust/cargo/bin/rustc"
LOG="/tmp/test_bugMC-8_kill_zombie_signal.log"
WAIT_STR="MC-8 REPRODUCED: caught signal"
REBUILD=0
[ "${1:-}" = "--rebuild" ] && REBUILD=1

cd "$WORKTREE" || { echo "[FATAL] worktree not found: $WORKTREE"; exit 2; }

if [ "$REBUILD" -eq 1 ]; then
    echo "[*] Full rebuild + boot via make run-kernel-tests (authoritative) ..."
    make run-kernel-tests CARGO="$CARGO" RUSTC="$RUSTC" \
        TARGET=x86 MACHINE=microvm LOG_LEVEL=info >"$LOG" 2>&1
    echo "[*] make exit=$? (non-zero expected: missing userspace 'hello, world!' banner)"
else
    if [ ! -f bin/kernel-test.elf ] || [ ! -f bin/uservm.elf ]; then
        echo "[*] Test artifacts missing; building (make all-test-kernel all-uservm) ..."
        make all-test-kernel all-uservm CARGO="$CARGO" RUSTC="$RUSTC" \
            TARGET=x86 MACHINE=microvm LOG_LEVEL=info >"$LOG" 2>&1 \
            || { echo "[FATAL] build failed; see $LOG"; exit 2; }
    fi
    echo "[*] Booting existing bin/kernel-test.elf in uservm; capturing full output ..."
    # Invoke uservm directly (run-uservm.py suppresses the captured log on success,
    # and its "hello, world!" gate is a userspace banner absent from the in-kernel
    # test build). --kernel-args is mandatory: kmain (kmain.rs:247) panics on an
    # empty args string. uservm exits on its own once the kernel halts.
    timeout 240 ./bin/uservm.elf -kernel bin/kernel-test.elf \
        -kernel-args "test_magic=0xDEADBEEF" >"$LOG" 2>&1
    echo "[*] uservm exit=$? (124 => timeout cap hit; kernel normally halts on its own)"
fi

echo
echo "===================== MC-8 evidence (from $LOG) ====================="
grep -nE "MC-8:|MC-8 REPRODUCED|passed: test_kill_posts_caught_signal_to_zombie" "$LOG"
echo "====================================================================="
echo

# Success criteria: the buggy state was produced AND the mask was confirmed.
q1=$(grep -c "signal bit 0x200 present = true" "$LOG")
q2=$(grep -c "no live thread scheduled/woken = true" "$LOG")
q3=$(grep -c "signal discarded = true" "$LOG")
q4=$(grep -c "MC-8 REPRODUCED: caught signal 10 was queued into zombie" "$LOG")
q5=$(grep -c "passed: test_kill_posts_caught_signal_to_zombie" "$LOG")

if [ "$q1" -ge 1 ] && [ "$q2" -ge 1 ] && [ "$q3" -ge 1 ] && [ "$q4" -ge 1 ] && [ "$q5" -ge 1 ]; then
    echo "[PASS] MC-8 reproduced in the real kernel: a caught signal (10) was queued into"
    echo "       zombie pid=7 via the real kill() path (NoSignalToZombie violated); the"
    echo "       consequence is MASKED (nothing scheduled; pending discarded at reap)."
    exit 0
else
    echo "[FAIL] MC-8 evidence incomplete (q1=$q1 q2=$q2 q3=$q3 q4=$q4 q5=$q5). See $LOG."
    exit 1
fi
