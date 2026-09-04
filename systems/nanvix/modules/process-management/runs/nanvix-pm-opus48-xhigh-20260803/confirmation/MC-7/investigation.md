# MC-7 Investigation — sigaction to SIG_DFL/SIG_IGN strands an already-pending signal

Source: **MC** (real counterexample `spec/output/MC_hunt_scenario4_mc7_final.out`,
invariant `NoStrandedProcPending`, also `SignalEventuallyDelivered`).

## Step 1 — Code audit (facts)

### Cited sites
- `src/kernel/src/pm/process/manager/mod.rs:603-611` — `ProcessManager::sigaction()` installs the
  new disposition via `signals.set_disposition(signum, disposition)` and returns. It does **not**
  touch the pending set. (Finding also cited `sync/signal.rs:248`; that path does not exist — the
  real disposition/pending primitives live in `process/state/signal.rs` and the delivery selector
  lives at `process/manager/signal.rs:248`.)
- `src/kernel/src/pm/process/state/signal.rs:364-371` — `SignalControl::set_disposition()`:
  `mem::replace` of the slot only. No pending reconciliation.
- `src/kernel/src/pm/process/state/signal.rs:387-395,422-426` — `post()` / `clear_pending()`:
  the only mutators of the `pending: u64` bitset.

### How a signal becomes process-pending (the producer)
`ProcessManager::kill()` (`manager/mod.rs:849-882`) resolves the target's disposition:
- `Ignore` → `PostAction::None` (discarded — nothing posted).
- `Handler(_)` → **`signals.post(signum)`** + `PostAction::Interrupt`.  ← the ONLY path that sets a
  process-pending bit.
- `Default` → immediate effect (terminate / stop / continue / ignore); nothing left pending.

So a process-directed pending bit can ONLY be created while the signal's disposition is a
`Handler`.

### The consumer that observes the wrong outcome
`ProcessManager::try_deliver_signal()` (`manager/signal.rs:206-316`), the return-to-user delivery
checkpoint. Its selection loop (lines 242-253):
```
let mut deliverable: u64 = (signals.pending() | thread_pending) & !blocked;
loop {
    if deliverable == 0 { return None; }
    let signum = deliverable.trailing_zeros()+1;
    if let Some(Handler(h)) = signals.disposition(signum) { break deliver(h); }
    deliverable &= deliverable - 1;   // "Not a caught signal: leave it pending ... consider next."
}
```
A pending signal whose disposition is **not** a `Handler` is skipped and **left pending** — never
delivered, never drained. The same handler-only filter appears in `install_sigsuspend_mask()`
(`mod.rs:739-746`). `sigpending()` (`mod.rs:685-696`) reports the stranded bit forever.

### Trigger (real API sequence, reachable at Level 0)
1. `sigaction(N, handler)` — install a catching disposition for signal N.
2. `sigprocmask(SIG_BLOCK, {N})` **or** simply not yet at a delivery checkpoint — so delivery is
   deferred and N stays pending.
3. `kill(_, self, N)` — disposition is `Handler` ⇒ `post(N)` sets the process-pending bit.
4. `sigaction(N, SIG_IGN)` **or** `sigaction(N, SIG_DFL)` — `set_disposition` swaps the slot to a
   non-handler disposition. **Pending bit N is left set.**

Result: N is process-pending with a non-handler disposition. `try_deliver_signal` skips it forever;
it is never dispatched as a handler and never drained. Exactly the CE:
`default,pd={}` → `handler` (sigaction) → `handler,pd={1}` (kill) → `default,pd={1}` (sigaction) ⇒
`NoStrandedProcPending` violated.

### Permanence / safeguards
No path reconciles a non-handler process-pending bit. It is cleared ONLY by
`reset_for_exec()` (`state/signal.rs:490-498`, image replacement) or process termination — neither
resolves it for the running image. So the stranded state is **permanent** for the process's
current image. This is a durable-state defect, not a transient snapshot.

## Step 2 — Developer-knowledge search (evidence, not a verdict)
- `git blame` mod.rs:603-611 → commit `9c727ee21` "[kernel] F: Implement sigaction and sigprocmask"
  (ppenna, 2026-06-25). The install block only calls `set_disposition`; no pending handling.
- Comment at `manager/signal.rs:236-239` explains the handler-only skip is intended **for
  job-control stop/continue that `kill()` records for a later phase** — NOT for disposition-change
  reconciliation. (In fact `kill()` currently never posts a non-handler signal, so today the only
  way a non-handler pending bit exists is this bug.)
- Upstream tracker (`nanvix/nanvix`): the signals work is tracked as **feature** issues
  (#2690 umbrella "Enable POSIX Signal Support"; #2692 "Signal Dispositions and Thread Masks
  (sigaction/sigprocmask)", closed/completed). #2692's disposition table states **`SIG_IGN` =
  "Discard the signal"** — i.e. the *intended* semantics. No filed **bug** reports the
  already-pending-signal reconciliation gap. #3013 "stranded" is a different mechanism
  (blocking-syscall RPC responses). #2908 is bulk-pull timeouts (unrelated).
- POSIX (IEEE Std 1003.1): "Setting a signal action to SIG_IGN for a signal that is pending shall
  cause the pending signal to be discarded, whether or not it is blocked." nanvix does not do this.
- No test asserts the current (buggy) post-disposition-change pending behavior.

## Step 3 — Known-status / precedent
- MC-sourced with an actual counterexample ⇒ NOT eligible for the code-review×known pre-filter;
  proceeds to Phase 2 regardless.
- Novelty: **NEW** — issue-tracker search (open + closed/merged) found only feature issues for the
  signals effort; no filed bug for "sigaction strands an already-pending signal" at this site.

## Phase-1 checklist answers
1. Level 0 alone triggers it — pure public API (`sigaction` + `kill`), normal ops, no timing needed
   (the disposition change is a deterministic edit; no race). **yes.**
2. n/a (Level 0).
3. Real consumer observing wrong outcome: `ProcessManager::try_deliver_signal`
   (`manager/signal.rs:242-253`) skips the pending signal forever; `sigpending`
   (`mod.rs:685-696`) reports it forever. Concrete wrong outcome.
4. Permanent — only exec/termination clears it; no reconciliation path. Not masked by any
   downstream mechanism.
