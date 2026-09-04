# MC-1 Investigation — Unsafe deferred reap skips live-count decrement

Source: **MC** (real counterexample: `spec/output/MC_hunt_scenario2_mc1_final.out`, invariant
`LiveCountAccurate`). Worktree: `confirmation/MC-1/worktree`.

## Step 1 — Code audit

### Cited sites
- `src/kernel/src/pm/process/manager/unsafe.rs:654` `harvest_zombie_thread(pid, zombie_thread)`
  - `:657` `if let (Some(_k), Some(user_stack)) = zombie_thread.harvest()` (drops `ThreadState`)
  - `:662-670` `match find_process_mut(pid)` → **`:668 return;`** (early return on `Err`)
  - `:708` `Self::get_mut().tm.on_thread_reaped();` — the live-count decrement, **skipped** by the early return.
- `src/kernel/src/pm/thread/zombie.rs:110` `harvest(mut self)` — moves out the stacks; `self.state`
  (`Box<ThreadState>`) is dropped when `harvest` returns.
- `src/kernel/src/pm/thread/mod.rs:272-282` `on_thread_reaped()` decrements `ThreadManager::live_count`
  (the real accounting counter; gate for `try_next_tid` at `:229`, `MAX_THREADS`).

### The twin (the "correct" version)
`src/kernel/src/pm/process/manager/mod.rs:3330` `reap_deferred_zombie_threads` does the SAME job but
its `find_process_mut` **`Err` branch falls through** (`:3375-3379`) to `self.tm.on_thread_reaped()`
(`:3387`). So on a missing/buried process it STILL decrements. The `unsafe.rs` twin early-returns and
does not. This is the exact divergence the finding names.

### Who drains `deferred_reap`, and when
Two drainers consume the same `self.deferred_reap` vec:
1. **Buggy:** `reap_deferred()` (`unsafe.rs:610`) → `harvest_zombie_thread` (early return). Called at
   the **start of every PM yield/entry point**: `exit` (`:290`), `exec` (`:361`), `exit_thread`
   (`:535`), `join_thread` (`:749`), `detach_thread` (`:801`), `sleep` (`:847`), `giveup` (`:939`),
   and `tick`→`giveup`. Confirmed by commit `92bad91f2` ("drains and harvests these zombies at the
   beginning of every PM entry point ... only after the previous context switch has fully completed").
2. **Correct:** `reap_deferred_zombie_threads()` via `reap_pending_zombies` (`mod.rs:3284`,`:3309`),
   called on-demand from `try_next_tid_reaping` when admission hits `MAX_THREADS`. In that function
   `harvest_zombies` (which *buries* processes) runs first (`:3294`), then the **correct** drainer
   (`:3309`) — so a just-buried process is handled by the fall-through, not the early return.

### When can `find_process_mut(pid)` fail (the early-return trigger)?
`find_process_mut` (`mod.rs:2842`) searches running/ready/suspended/interrupted/**zombies**. It fails
only if `pid` is in NONE of them = the process has been **buried**. Burial = removal from all queues =
`self.zombies.pop_front()` at `mod.rs:2444`, inside `pop_zombie_process`, called **only** by
`harvest_zombies` (`mod.rs:3444`). `harvest_zombies` is called **only** from the idle loop
(`kcall/handler.rs:81`,`:168`) and from `reap_pending_zombies` (`mod.rs:3294`, admission).

### Deferral precondition (`running.rs:371-393`)
A detached thread's zombie is deferred **only** when `is_detached && has_other_threads`, where
`has_other_threads = ready.is_some() || interrupted.is_some() || sleeping.is_some()` (`:371-372`).
It does **not** count zombie siblings. When the detached thread is the last *live* thread (only a
zombie sibling remains) `deferred_zombie = None` and the zombie is folded into the ZombieProcess's own
`zombie_threads`, later reaped by the `harvest_zombies` loop (`mod.rs:3444-3483`, one
`on_thread_reaped` per thread). No deferral, no leak.

### Reachability conclusion (the key finding)
The buggy early-return at `unsafe.rs:668` requires `reap_deferred()` to run on a deferred zombie whose
process is **already buried**. That state is **unreachable** in the implementation:
- To reach the idle-loop `harvest_zombies` (the only burial site besides the admission path), a thread
  must yield via `giveup`/`tick`/`sleep`/`exit`/`exit_thread` — each runs `reap_deferred()` FIRST. So
  any pending detached zombie is drained **while its process is still in a findable queue**
  (ready/suspended/interrupted/zombie) — including after the process reaches `self.zombies` but before
  it is popped/buried. `find_process_mut` therefore succeeds and `on_thread_reaped` runs.
- The admission burial path (`reap_pending_zombies`) uses the **correct** fall-through drainer.
- The buggy drainer and `harvest_zombies` never interleave (uniprocessor, no yield inside either).

The counterexample bypasses BOTH implementation guards:
- CE State 3 makes `t1` a **zombie**, then CE State 5 **defers `t2`** with only that zombie sibling —
  which `has_other_threads` (`running.rs:377`) forbids (real code would fold `t2` and reap it).
- CE State 6 **buries `p1`**, then CE State 7 fires `ReapDeferredUnsafe` on the buried `p1` — which the
  yield-point ordering of `reap_deferred()` forbids.

So the CE is a **spec over-approximation**: the modeled `DetachedThreadExit`/`ReapDeferredUnsafe`
actions lack the implementation's `has_other_threads` guard and the "process still findable / drained
at yield before burial" ordering.

## Step 2 — Developer knowledge
- `92bad91f2` "[kernel] B: Defer detached zombie reap" — introduces `deferred_reap` + `reap_deferred`;
  documents that it runs "at the beginning of every PM entry point ... only after the previous context
  switch has fully completed", and that the deferred zombie exists only "when the exiting thread is
  detached and other threads remain". A `debug_assert!` guards the zombie-only branch (no deferred
  zombie when no other threads remain) — `mod.rs:2241-2244`.
- `4113651ed` / PR #2500 "enhancement-kernel-harvest" ("[kernel] B: Reap deferred thread zombies on
  demand", "[kernel] E: Reap zombies on demand") — adds the CORRECT `reap_deferred_zombie_threads`
  whose `Err` branch intentionally falls through to `on_thread_reaped`, because in its call context
  (right after `harvest_zombies` buries processes) the process CAN be gone. The `unsafe.rs` twin
  predates this (`f2603a5f8`, 2026-05-11) and was not revisited — its early return is safe only because
  of its yield-point call context.
- Comments at `unsafe.rs:665-666` and `mod.rs:3376-3377` both label the find-failure "Unexpected" — the
  developers treat a missing process at reap time as not-normally-occurring.

## Step 3 — Known-status / precedent
- No open/closed issue, PR, CVE, or advisory found in the git history reporting THIS mechanism (an
  `on_thread_reaped`/live-count skip in `reap_deferred`/`harvest_zombie_thread`). Searched
  `git log --all -i --grep` for `reap_deferred|live_count|on_thread_reaped|thread slot|leak|deferred
  zombie|harvest`. PR #2500 concerns on-demand harvesting, not this skip. → **Novelty: NEW**.
- MC-sourced (real counterexample) → not eligible for the code-review×known pre-filter; proceed to
  Phase 2.
