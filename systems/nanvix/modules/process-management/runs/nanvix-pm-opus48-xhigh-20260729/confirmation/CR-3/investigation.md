# CR-3 Investigation — Async caught signal silently dropped when no restorer; sigsuspend temp mask leaks

Source: Code Review (code-review TV-3). No MC counterexample. Location: `src/kernel/src/pm/process/manager/signal.rs:257`.

## Step 1 — Code audit (facts)

`ProcessManager::try_deliver_signal` (signal.rs:206-316) is the asynchronous return-to-user
delivery checkpoint (`deliver_pending_signals`, kcall/handler.rs:189). After selecting the
lowest-numbered deliverable **caught** signal (Handler disposition), it reads the restorer:

```
// signal.rs:256-270
let restorer = match self.get_running_mut().state_mut().signals_mut().restorer() {
    Some(restorer) => restorer.into_raw_value(),
    None => {
        error!("no signal restorer registered ...");
        self.get_running_mut().state_mut().signals_mut().clear_pending(signum);   // drop (process)
        if let Some(mut thread) = self.get_running_mut().find_thread_mut(tid) {
            thread.thread_state_mut().clear_pending(signum);                       // drop (thread)
        }
        return SignalDeliveryOutcome::None;                                        // <-- silent drop
    },
};
```

`SignalDeliveryOutcome::None` is consumed by `deliver_pending_signals` (handler.rs:190-191) as
"nothing to do; resume normally". So on the no-restorer branch the caught signal is **cleared from
the pending set and silently dropped**: no handler runs, and the process is NOT terminated. The
same function's `Escalate` outcome (returned when a frame cannot be built, signal.rs:291) *does*
terminate the process (handler.rs:192-204) — so the machinery to escalate exists but is not used
here.

**Asymmetry (key evidence).** The synchronous-fault delivery path
`try_deliver_synchronous_signal` (signal.rs:342-436) handles the identical "no restorer"
pre-condition differently:

```
// signal.rs:387-394
let restorer = match ...restorer() {
    Some(restorer) => ...,
    None => { error!("no signal restorer registered ..."); return SyncSignalOutcome::Terminate; }
};
```

i.e. it escalates to `Terminate` (default action). The async path drops instead.

**Second consequence — sigsuspend mask leak.** `sigsuspend()` (kcall/sigsuspend.rs) calls
`install_sigsuspend_mask` (manager/mod.rs:722-749), which saves the pre-suspend mask into
`savedBlocked` (`set_saved_blocked(Some(previous))`) and installs the temporary mask
(`set_blocked(installed)`). On the normal delivery path the temporary mask is restored by
`sigreturn()` (signal.rs:604-613: `take_saved_blocked()` -> `set_blocked(saved)`), which only runs
*after a handler frame was built and the handler returned*. On the no-restorer branch **no frame is
built and `sigreturn()` never runs**, so `savedBlocked` (the pre-suspend mask) is stranded forever
and `blocked` stays the temporary sigsuspend mask. This permanently corrupts the thread's signal
mask and violates POSIX (sigsuspend must leave the mask unchanged on return).

## Step 1 — Reachability / call chain

- `try_deliver_signal` runs at the end of every kernel call (`do_kcall` -> `deliver_pending_signals`).
- On **x86_64** `returning_to_user` always returns `false` (hal/arch/x86_64/cpu/sigframe.rs:32), so
  async delivery is inert there and the branch is unreachable. On **x86 (32-bit, the default
  TARGET)** `returning_to_user` reads the trap-frame CS RPL and the branch is reachable.
- The `restorer` is set only by the `SigRestorer` kcall (pm/kcall/sig_restorer.rs). It is `None` by
  default (`SignalControl::new`), inherited across `fork()`, and dropped by `execv()`.
- The standard runtime `nvx-crt0` registers the restorer at `_start` before `main`
  (nvx-crt0/src/lib.rs:319-324) — but **best-effort**: "a failure here only disables signal
  handlers, not startup." The kernel imposes **no ordering requirement**: `set_disposition` (the
  sigaction kcall) accepts a caught handler with no restorer. Therefore the no-restorer branch is
  reachable for any image that installs a caught handler without a registered restorer — a non-crt0
  binary, a raw-kcall program, or a crt0 program whose best-effort `SigRestorer` kcall failed. This
  is why a pure Level 0/1 black-box *crt0* program cannot trigger it (the restorer is normally
  present), but the public kcall ABI still permits the state.

Trigger sequence (real-API): `sigaction(SIGUSR1, handler)` (no `SigRestorer`) ->
`sigsuspend(mask)` (saves pre-suspend mask, installs temp) -> peer `kill(pid, SIGUSR1)` ->
return-to-user checkpoint -> `try_deliver_signal` takes the no-restorer branch.

## Step 2 — Developer-knowledge search (evidence, not a verdict)

- `git blame` signal.rs:257-268: introduced by `c7cb73b66` "[kernel] F: Deliver Caught Signals"
  (Closes #2694, part of #2690); thread-pending clear added by `3fcdf9a3c` "Map CPU Exceptions to
  Signals". Commit message states "frames that cannot be built safely escalate to the signal's
  default action" — it describes the `Escalate` design but says nothing about the no-restorer case.
- No `TODO`/`FIXME`/"known issue" near the branch.
- nvx-crt0 comment (lib.rs:321): registering the restorer is best-effort and "a failure here only
  disables signal handlers, not startup" — evidence the developers expect a process can run with
  caught handlers but no restorer; but they do not state the async path should silently drop, and
  the mask-leak is unaddressed. The sync path's `Terminate` under the same condition is evidence the
  intended default is to escalate, not drop.

## Step 3 — Known-status / precedent

- `git log`/blame: no prior issue/PR reports the async silent-drop or the sigsuspend mask leak at
  this site. Issue #2694 (cited by the web search) is the *feature* issue for async delivery
  (the commit "Closes #2694"), not a bug report of this mechanism.
- Not filed anywhere ⇒ **Novelty: NEW**. Not a code-review × known duplicate ⇒ not pre-filtered.

## Phase 2 — Reproduction (Level 2 state injection, real functions) — EXECUTED

In-kernel unit test `test_cr3_async_no_restorer_drops_signal_and_leaks_sigsuspend_mask`
(added to `src/kernel/src/pm/process/manager/test.rs`, wired into `manager::test()` under the
x86 gate). Built with the `test` feature and booted under the standalone UserVM (KVM). It swaps a
synthesized single-thread running process (real `Vmem`, real `KernelStack` carrying a ring-3 trap
frame stamped at `esp0`) into the manager's running slot; installs a caught `Handler` disposition
with **no restorer** and a process-directed pending SIGUSR1; drives the **real**
`install_sigsuspend_mask` (saves pre-suspend mask `0x60`, installs temp mask `0x80`); then calls the
**real** `try_deliver_signal(0)`, and for contrast the **real** `try_deliver_synchronous_signal`.
Every element of the injected state is reachable through the public kcall ABI (sigaction without
SigRestorer, sigprocmask, sigsuspend, kill, user-mode trap). The kernel restores its own running
process afterward; boot completes and prints the "hello, world!" magic string (suite passed, no
panic).

Commands (both succeeded): `make check-test-kernel` (clean), `make run-kernel-tests`, and the direct
capture `./bin/uservm.elf -kernel ./bin/kernel-test.elf -kernel-args test_magic=0xDEADBEEF`.

Captured console (real run — `repro/test_bugCR-3_async_no_restorer_drop_and_mask_leak.run.log`):

```
[ERROR][signal] try_deliver_signal(): no signal restorer registered (pid=4344, signum=10)
[ERROR][signal] try_deliver_synchronous_signal(): no signal restorer registered (pid=4344, signum=10)
[INFO ][test] cr3: install_ok=true pre(blocked=0x80,saved=Some(96)) async_outcome=None pending_after=0x0 post(blocked=0x80,saved=Some(96)) sync_outcome=Terminate
[ERROR][test] cr3 CONFIRMED (drop): async caught SIGUSR1 silently dropped with no restorer — try_deliver_signal returned None and cleared the pending bit; no handler ran and the process was NOT terminated (default action skipped)
[ERROR][test] cr3 CONFIRMED (mask leak): sigsuspend temporary mask leaked — blocked stuck at TEMP_MASK (0x80) and pre-suspend mask stranded in savedBlocked (Some(96)); sigreturn() never ran to restore it
[INFO ][test] contrast OK — synchronous path returns Terminate under the same no-restorer pre-condition
[INFO ][test] test(): passed: test_cr3_async_no_restorer_drops_signal_and_leaks_sigsuspend_mask
```

Reading: `async_outcome=None` + `pending_after=0x0` => the caught SIGUSR1 (default = Terminate) is
consumed with no handler and no terminate (silent drop). `post(blocked=0x80,saved=Some(96))` => temp
mask `0x80` stuck, pre-suspend mask `0x60`=96 stranded in savedBlocked (leaked). `sync_outcome=
Terminate` => the synchronous path escalates correctly under the identical pre-condition, which the
async path omits. Both defects observed.

### Pre-REPRODUCED checklist
1. Level 0/1 alone? **No.** crt0 always registers the restorer (best-effort but normally succeeds),
   so a standard user program never reaches the no-restorer branch; timing does not help.
2. Level 2 injected state reachable via real API? **Yes.** `sigaction` (set_disposition) accepts a
   caught handler with no restorer (kernel enforces no ordering); `sigsuspend`
   (install_sigsuspend_mask) saves the mask; `kill` (post) makes it pending; return-to-user invokes
   `try_deliver_signal`. The test drives the real functions, not reimplementations.
3. Real consumer observing wrong outcome? **Yes.** `deliver_pending_signals` (handler.rs:190)
   resumes normally on `None` — the delivering process loses the caught signal and, having issued
   `sigsuspend`, keeps a permanently corrupted blocked mask (pre-suspend mask stranded in
   `savedBlocked`, never restored).
4. Permanent or masked? **Permanent.** No `sigreturn()` will ever run for this delivery, so nothing
   restores the mask or re-delivers the signal. The crt0-restorer is a *reachability* barrier for
   typical programs, not a downstream mechanism that resolves the corruption once the state is
   reached.

## Conclusion
Real defect, reachable through the public kcall ABI, with a permanent in-process consequence,
reproduced by driving the real `try_deliver_signal`. **Verdict: REPRODUCED** (escalation Level 2).

---

## Phase 2 — Reproduction re-executed (this confirmation run)

Independently re-reproduced by driving the REAL `ProcessManager::try_deliver_signal` from an
in-kernel test that builds a real running process (real `KernelStack` + synthetic ring-3 trap frame
so `returning_to_user()` passes), installs a real `sigsuspend()` mask via
`install_sigsuspend_mask`, posts a caught signal (SIGUSR1), and invokes the checkpoint. Booted under
the standalone UserVM (QEMU).

Artifacts:
- Kernel test: `src/kernel/src/pm/process/manager/test.rs ::
  test_async_delivery_without_restorer_drops_signal_and_leaks_sigsuspend_mask` (wired into `test()`).
- Driver: `.specula-output/repro/test_bugCR-3_async_signal_drop_mask_leak.sh` (exit 0 = reproduced).
- Serial log: `.specula-output/repro/test_bugCR-3_async_signal_drop_mask_leak.run.log`.

Observed serial output (real kernel code emitted the first line, not the test):
```
[ERROR][signal] try_deliver_signal(): no signal restorer registered (pid=4242, signum=10)
CR-3-REPRO: outcome=None (expected Escalate to terminate on missing restorer)
CR-3-REPRO: blocked after delivery=0x10000 temp=0x10000 pre_suspend=0x800
CR-3-REPRO: saved_blocked after delivery=Some(2048) (expected None once sigsuspend unwinds)
CR-3-REPRO: caught signal D pending-after-delivery=false
CR-3-REPRO: BUG REPRODUCED: async caught signal silently dropped AND sigsuspend() mask leaked
```
signum=10=SIGUSR1 (dropped); blocked stuck at 0x10000 (SIGCHLD temp mask) instead of restored to
0x800 (SIGUSR2 pre-suspend); saved_blocked=2048=0x800 stranded. Verdict unchanged: **REPRODUCED**.
