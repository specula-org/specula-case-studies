# CR-5 Investigation (Phase 1 — evidence only)

Finding: "CPU-bound thread may never receive a caught signal because delivery only happens at a
kcall/timer checkpoint." Source: code-review. Affected: src/kernel/src/kcall/dispatcher.rs:240.

## Step 1 — Code audit (facts)

### The sole caught-signal delivery checkpoint
- `deliver_pending_signals(result)` is called at **exactly one** site: `do_kcall`'s epilogue,
  `src/kernel/src/kcall/dispatcher.rs:245` (comment at :240). `grep -rn deliver_pending_signals src`
  returns only the definition (`kcall/handler.rs:189`) and this one call.
- `deliver_pending_signals` → `ProcessManager::try_deliver_signal(result)`
  (`pm/process/manager/signal.rs:206`). This is the ONLY function that redirects a running thread
  through its user handler. It operates on the **currently running thread** (`self.get_tid()`,
  `self.get_running_mut()`) and only when `returning_to_user(esp0)` is true (signal.rs:230) — i.e.
  at a kernel→user return boundary.

### The timer / scheduler path performs NO signal delivery
- Periodic timer: `hal/arch/shared/cpu/interrupt/xapic.rs:599` starts a **1ms periodic LAPIC timer**.
- Timer ISR: `pm/clock.rs:109 timer_handler` → `ProcessManager::tick()`
  (`pm/process/manager/unsafe.rs:899`) → on quantum expiry `Self::giveup()` (unsafe.rs:937) →
  `schedule()` → `switch()`. **None** of `timer_handler` / `tick` / `giveup` / `schedule` / `switch`
  calls `deliver_pending_signals` / `try_deliver_signal`.
- HW interrupt return path is pure `context_save → call do_interrupt → context_restore → iret`
  (`hal/arch/x86/asm/hooks.rs:255 _do_hwint_macro`). No signal checkpoint on interrupt return.
- Therefore a thread resumed by the timer (either continuing its slice or re-selected after a context
  switch) returns to user mode via `iret` **without any delivery attempt**.

### What `kill()` does to a RUNNING (non-suspended) target
- `pm/kcall/kill.rs:49` → `ProcessManager::kill` (`pm/process/manager/mod.rs:810`).
- For a caught signal (a `Handler` disposition), the action is `PostAction::Interrupt`
  (mod.rs:854-856): it `signals.post(signum)` (adds to the pending set) then calls
  `interrupt_signal_candidate(target, signum)` (mod.rs:894).
- `interrupt_signal_candidate` (mod.rs:1009) only scans `self.suspended` and interrupts a
  **fully-suspended** candidate thread. A running/ready thread is NOT on `suspended`, so this is a
  **no-op** for it. The signal is left merely pending.
- Developer comment, mod.rs:1000-1002 (verbatim): *"Only a fully-suspended process needs explicit
  help; a process that still has a ready or running thread reaches its own checkpoint without being
  woken."* This is the design assumption that fails for a CPU-bound thread that never makes a kernel
  call: it never reaches "its own checkpoint" (the `do_kcall` epilogue), and the timer path does not
  deliver.

### Reachability
- Fully reachable via the public ABI: `sigaction` (install a handler), `fork`, `kill` (cross-process
  post), and a user compute loop with no syscalls. All are normal operations.
- Consequence: a caught signal posted to a single-threaded, CPU-bound process is **starved** — the
  handler never runs while the thread stays in user compute, even though the timer preempts and
  reschedules it thousands of times per second. It is delivered only when/if the thread finally makes
  some kernel call.

## Step 2 — Developer-knowledge search (evidence, not classification)

- Commit `c7cb73b66` "[kernel] F: Deliver Caught Signals" (closes #2694, part of #2690) introduced
  the checkpoint: *"Add a deliver_pending_signals() checkpoint at the end of do_kcall, mirroring
  poll_ikc_messages()."* Only the kcall site was added.
- **Design spec issue #2694** (closed, completed) explicitly required, under "Delivery checkpoint":
  *"Add a `deliver_pending_signals()` check at the return-to-user boundary — the same point where the
  dispatcher already calls `poll_ikc_messages()` at the end of `do_kcall` … **plus on return from
  interrupt/exception to a user thread**."* The umbrella #2690 repeats: delivery happens *"after a
  kernel call … plus on return from interrupt/exception"*. The **interrupt/exception-return half was
  never implemented** — no phase in the #2690 plan (Phases 1–7 / #2691–#2697) covers it, and the code
  audit confirms its absence. So the implementation deviates from the developers' own stated design.
- `interrupt_signal_candidate` doc-comment (mod.rs:995-1002) states the running/ready-thread
  assumption above — evidence of the design gap, not of intent to starve CPU-bound threads.
- Existing user test `test_kill_running_process` (test-rust-kill/src/tests/kill.rs:311) kills a
  **spinning** child with **SIGTERM** and succeeds — but SIGTERM's default action *terminates
  directly inside `kill()`* (mod.rs:858-893 `PostAction::Terminate`→`kill_terminate`), bypassing the
  user checkpoint. There is **no** test that posts a **caught** (handler) signal to a spinning
  process; that is exactly the untested gap CR-5 identifies.

## Step 3 — Known-status / precedent

- Issue-tracker search (GitHub `nanvix/nanvix`, open+closed incl. recently merged) for
  "return from interrupt" signal, "CPU-bound", "tight/compute loop", signal starvation: no issue/PR
  reports THIS defect (a caught signal never delivered to a CPU-bound thread / the missing
  interrupt-return checkpoint). #2690/#2694 *specify the intended* interrupt-return delivery but do
  not report its omission; a closed feature spec that prescribes behavior is not a filed bug report of
  the implementation gap.
- Per the skill, developer awareness / a design note about the intended behavior does NOT make the
  defect "known". No prior Specula dataset entry cited for this mechanism.
- **Novelty: NEW.** **Not** a code-review × known drop → proceed to Phase 2 reproduction.

## Trigger scenario (concrete)
1. Process P: `sigaction(SIGUSR1, handler)` (caught disposition; crt0 has registered a restorer).
2. P `fork`s a helper H.
3. P enters a pure user compute loop (no syscalls).
4. H `kill(P, SIGUSR1)` — posts the caught signal to P's pending set. P is running/ready (not
   suspended) → `interrupt_signal_candidate` is a no-op; the signal is merely pending & deliverable
   (`(pending & !blocked)` has SIGUSR1).
5. The 1ms timer preempts and reschedules P many times; none of those returns delivers the signal.
6. The handler never runs while P computes; it runs only at P's first subsequent kernel call
   (the sole `do_kcall` checkpoint).
