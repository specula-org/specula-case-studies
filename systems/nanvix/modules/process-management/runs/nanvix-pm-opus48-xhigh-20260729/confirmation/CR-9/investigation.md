# CR-9 Investigation — CondvarInner::drop panics with a non-empty waiter queue

- **Finding source:** code-review (CR-3 brief §6.3). No MC counterexample.
- **Cited site:** `src/kernel/src/pm/sync/condvar.rs:286-291`

## Step 1 — Code audit

`CondvarInner::drop` (condvar.rs:286):
```rust
impl Drop for CondvarInner {
    fn drop(&mut self) {
        if !self.sleeping.borrow().is_empty() { panic!("{self:?}"); }
    }
}
```
Sibling `ThreadState::drop` (thread/state.rs:574) is log-only (`error!`) for its
`locked_mutexes` — the asymmetry the finding names is real.

`Condvar { inner: Arc<CondvarInner> }`. `CondvarInner::drop` runs only when the
LAST `Arc<CondvarInner>` is dropped. So the panic requires: strong_count -> 0
while `sleeping` is non-empty.

### Reference-counting lifecycle (the decisive facts)

- **A waiter holds an `Arc` clone while blocked.** `wait_cond` (wait_cond.rs:110-111)
  does `get_cond(cond_addr)` -> `cond.wait(alarm)`; the `cond` clone lives in the
  wait_cond frame *on the thread's kernel stack*, which is preserved across
  `ProcessManager::sleep` -> `Self::switch` (unsafe.rs:845-861). So for the entire
  blocked duration the Condvar strong_count includes that clone.
- **`wait()` pairs push_back with cleanup** (condvar.rs:257-266): on the `Err`
  wakeup (timeout / signal / kill) the resuming waiter runs
  `retain(|&t| t != tid)`, removing its own tid before its clone drops. On the
  `Ok` wakeup the notifier already `pop_front`'d the tid.
- **The kernel only wakes a condvar waiter with `Ok(())` via the condvar's own
  notify** (`wakeup_waiter` -> `try_wakeup_thread`, no interrupt reason set),
  which pops the tid first. The only external `ProcessManager::wakeup(tid)`
  callers are IPC rendezvous (`ipc/rendezvous.rs`), never condvar waiters. So an
  `Ok` return always corresponds to a popped tid — no "stale tid + dropped clone".
- **`put_cond` drop-guard** (state/mod.rs:721-724): drops the map entry only when
  `reference_count() <= 1` (the no-waiter baseline). A blocked waiter makes it
  >= 2, so it is never dropped while a waiter is enqueued. Mutex mirrors this:
  `MutexInner` embeds a `Condvar` (mutex.rs:38); a mutex waiter holds an
  `Arc<MutexInner>` clone, and `put_mutex` guards with `<= 2` (mod.rs:660-663).
- **Forced teardown LEAKS the suspended clone.** `ThreadState` (thread/state.rs)
  holds `kernel_stack: Option<KernelStack>`; dropping it frees the stack buffer
  as raw bytes and never unwinds the suspended `wait_cond` frame, so the `cond`
  clone in that frame is leaked (strong_count never decremented). `terminate`
  converts sleeping threads to `InterruptedThread(Killed)` (sleeping.rs:97-109),
  and killed condvar waiters actually resume, run `wait()`'s `retain`, and exit
  via `handle_sleep_error` -> `exit` (dispatcher.rs:172-179,264-269) — so the
  queue is cleaned before the clone drops in that path too.

### Consequence of the above

Whenever `sleeping` is non-empty, strong_count is >= 2, so `put_cond`/`put_mutex`
never drop it; and on forced teardown the last live clone is leaked, so
strong_count never reaches 0 with a non-empty queue. `CondvarInner::drop`
therefore runs only on an EMPTY queue. The `panic!` branch is a defensive
assertion guarding an invariant the reference-counting discipline maintains; it
is **not reachable** through real API sequences (`wait_cond`/`signal_cond`,
`lock_mutex`/`unlock_mutex`, terminate/kill/exec/exit).

## Step 2 — Developer knowledge

- Blame: the `panic!`-on-non-empty-drop exists since the original condvar impl
  (2d36cd4bc, 2025-06); d902a4066 only reformatted the message. Long-standing
  deliberate assertion.
- Commit `6055a7366 "Skip stale condvar waiters"`: developers explicitly model
  timed-out tids lingering in the sleeping queue and handle them in notify. They
  did not touch the Drop assertion — consistent with relying on the invariant
  that a Condvar is never dropped with waiters.
- A generic web summary of the exact panic message characterizes it as "an
  intended safeguard: the OS is correctly enforcing that synchronization
  primitives must not outlive waiters."

## Step 3 — Known-status / precedent

- `nanvix/nanvix` issue+PR search for condvar / condition-variable + drop + panic
  returned only an unrelated tokio dependabot PR (#2948). Git history shows no
  fix for this mechanism. => **NOT previously reported => Novelty: NEW.**
  (Not a code-review × known drop.)

## Reproduction (Phase 2) — EXECUTED

`repro/test_bugCR-9_condvar_drop_masked.rs` replicates the verbatim
`CondvarInner`/`Condvar`/`Drop` plus the real reference-counting lifecycle
(`get_cond`/`put_cond`, `notify_first`, `wait`-enqueue + retain). Built with
`rustc -O` and run; actual output:

```
[A normal-wait/notify] OK: completed with NO panic (queue empty at every drop)
[B live-waiter-blocks-reclaim] OK: completed with NO panic (queue empty at every drop)
[C terminate/kill-of-waiter] OK: completed with NO panic (queue empty at every drop)
[D injected-unreachable-state] forcing non-empty queue on a lone Arc, then dropping...
[D] PANIC as designed: Drop fired -> mechanism is real, but state is injected/unreachable
RESULT: No real flow (A/B/C) reaches a non-empty-queue drop; the panic fires
        ONLY under the injected, unreachable state (D). ... DoS is MASKED ...
```

- A (Level 0, normal wait/notify/resume/put_cond): NO panic, queue empty at drop.
- B (Level 1, notify wakes one, second waiter stays): `put_cond` guard refuses to
  reclaim while a waiter holds a clone (refcount 2, queue=[B]) — **mask fires**.
- C (Level 2, terminate/kill of a blocked waiter): kill path drains the tid via
  `retain` before the clone drops; leak path keeps the Arc alive — no panic.
- D (Level 2, injected UNREACHABLE state): a lone Arc's queue is force-filled then
  dropped -> the `Drop` DOES `panic!`. Confirms the code is genuinely panic-capable,
  but that precondition is unreachable through real flows (masked by A/B/C).

## Verdict

Real code hazard (a panicking destructor, asymmetric with the log-only
`ThreadState::drop`, that would turn any future refcount/queue inconsistency into
a hard kernel panic / DoS), but the crash consequence is currently **MASKED** by
the condvar/mutex reference-counting discipline. => **MASKED** (a finding).

## Re-verification (independent re-audit)

Re-audited the full lifecycle independently and confirmed the prior conclusion:
- Only `Condvar::wait` (condvar.rs:257) ever pushes a tid; grep-verified.
- No `Wakeup` kcall exists (kcall/dispatcher.rs); the only non-condvar
  `ProcessManager::wakeup` callers are IPC rendezvous, which never target
  condvar waiters — so a `wait()` `Ok` return always corresponds to a popped tid.
- `exec` (do_execv) is rejected for multi-threaded processes (manager/mod.rs:2008),
  blocking the finding's "exec image replacement" scenario.
- `wakeup`/`resume` only flip scheduler state (`ReadyThread::from_state`); they
  never rewrite the saved context, so a resumed waiter always unwinds `wait()`.
- `harvest` (zombie.rs:110) frees the kernel stack as raw bytes, leaking the
  suspended `wait()` frame's `Condvar` clone -> CondvarInner stays alive (no drop).
- git blame: panic present since 2d36cd4bc (2025-06); 6055a7366 "Skip stale
  condvar waiters" handled stale tids in notify but left the Drop assertion.
  No issue/PR/commit reports or fixes THIS drop-panic mechanism -> Novelty NEW.

Fresh reproduction `repro/test_bugCR-9_condvar_drop_masked.rs` executed (rustc -O):
A/B/C (reachable teardown) -> NO panic; B proves the put_cond `<=1` mask fires
(refcount 2, queue=[20]); C proves the forced-kill leak keeps CondvarInner alive
(strong_count 2, queue=[99]); D (injected unreachable state) -> PANIC.

Verdict: MASKED (real panicking-destructor hazard, DoS consequence masked by the
refcount/leak discipline).
