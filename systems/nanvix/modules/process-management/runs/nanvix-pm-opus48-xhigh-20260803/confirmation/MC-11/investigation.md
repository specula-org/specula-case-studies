# MC-11 Investigation — put_cond destroys a condvar with a parked waiter → CondvarInner::drop panics

## Finding (as handed)
- Source: model-checking, invariant `NoDestroyWithWaiter`, cfg `MC_hunt_scenario3_destroy.cfg`.
- Counterexample: `spec/output/MC_hunt_scenario3_destroy_final.out`.
- Claim: `put_cond` (state/mod.rs:702-716) removes condvar entries with `reference_count() <= 1`
  via `extract_if` without checking the wait queue. When the map holds the last reference, the
  dropped `CondvarInner` (condvar.rs:286-292) panics if its `sleeping` queue is non-empty →
  kernel DoS reachable from ordinary condvar usage.

## Step 1 — Code audit (facts)

### The drop panic (sync/condvar.rs)
- `CondvarInner { sleeping: RefCell<VecDeque<ThreadIdentifier>> }` (l.42-44).
- `Condvar { inner: Arc<CondvarInner> }` (l.51-54), `#[derive(Clone)]`.
- `reference_count(&self) -> usize { Arc::strong_count(&self.inner) }` (l.93-95). Its `# Safety`
  doc explicitly warns the strong count can change between reading and acting on it.
- `wait(&self, alarm)` (l.232-267): pushes `tid` onto `sleeping` (l.257), then blocks in
  `ProcessManager::sleep(alarm)` (l.259). On the error path it removes itself:
  `sleeping.retain(|&t| t != tid)` (l.263). **`wait` takes `&self`**, so the caller's `Condvar`
  clone is alive for the whole call, including while the thread is parked inside `sleep`.
- `Drop for CondvarInner` (l.286-292): `if !self.sleeping.borrow().is_empty() { panic!(...) }`.
  Introduced deliberately (commit 2d36cd4bc2, Pedro H. Penna, 2025-06-08) as a defensive
  "should never happen" assertion.

### The destroy (process/state/mod.rs put_cond, l.702-716)
```
extract_if(.., |&addr, cond| cond_addr == addr && cond.reference_count() <= 1)
```
- Destroys the entry (dropping its `CondvarInner`) **only when `reference_count() <= 1`** — i.e.
  the map's entry is the sole `Arc` holder.
- `conditions: BTreeMap<ConditionAddress, Condvar>` lives in **`ProcessState`** (l.234): condvars
  are per-process; `release_cond` acts on `get_running_mut().state_mut()` (manager/mod.rs:2580).
- Mutex sibling `put_mutex` uses the threshold `<= 2` (l.651); condvar uses `<= 1`. The difference
  reflects the reference-holding pattern of each call site (git commit 417b12702 only migrated the
  `extract_if` signature; thresholds unchanged).

### Call chain / reachability
- Only callers of `put_cond`/`release_cond`: `signal_cond.rs:72` and `wait_cond.rs:123`
  (both via `ProcessManager::put_cond` → `release_cond`). No other caller (no termination/cleanup
  path calls it).
- `wait_cond` (kcall/wait_cond.rs:104-130):
  1. `get_cond(cond_addr)` → returns a **clone** (`Condvar`) → refcount = map(1) + local `cond`(1) = 2.
  2. `cond.wait(alarm)` → pushes `tid`, parks. The local `cond` stays alive on the parked thread's
     stack frame ⇒ refcount stays ≥ 2 while the tid is in the queue.
  3. block ends → local `cond` dropped (refcount → 1) → **then** `put_cond(cond_addr)` (l.123).
- `signal_cond` (kcall/signal_cond.rs:63-72): `get_cond` (refcount 2), notify (pops woken tids),
  drop local `cond` (refcount 1), `put_cond`.

### Core invariant established by the audit
> **A tid is in `sleeping` ⟺ a thread is parked inside `wait()` holding a live `Condvar` clone.**

Consequences:
- Whenever `sleeping` is non-empty, ≥1 parked waiter holds a clone ⇒ `reference_count() >= 2` ⇒
  `put_cond`'s predicate `reference_count() <= 1` is **false** ⇒ the condvar is **not** destroyed ⇒
  `CondvarInner::drop` is not run ⇒ no panic.
- The only way `CondvarInner` is dropped with `count → 0` is when the map holds the last ref
  (count 1), which requires **no** parked waiter, i.e. an **empty** queue ⇒ `Drop` sees
  `sleeping.is_empty()` ⇒ no panic.

### Cleanup / termination paths (checked per skill guidance)
- `terminate` (manager/mod.rs:2268): a **suspended (parked)** process → `InterruptedProcess`
  (l.2311-2315). When rescheduled, the parked thread **resumes** from inside `sleep()` which
  returns `Err(Interrupted)`; `wait()`'s error path removes its tid (l.263) **before** returning,
  then `wait_cond` drops `cond` and calls `put_cond`. Order preserved: tid removed → clone dropped.
  No window with (tid in queue ∧ refcount 1).
- SIGKILL/force-zombie: the parked thread's saved kernel stack is freed **without** unwinding Rust
  destructors, so its `cond` clone is **leaked** (Arc never decremented). refcount stays ≥ 2 ⇒
  `put_cond` never destroys and a later drop of the `conditions` map still sees count ≥ 1 (leaked
  clone) ⇒ `CondvarInner` is never dropped ⇒ leak, **not** panic. (A leak is MC-3 territory, a
  separate finding — not this drop-panic.)
- The kernel is a **uniprocessor cooperative** kernel (`sleep`/`giveup` run with interrupts
  disabled, PM access synchronized). Kernel calls are serialized; the operations above are atomic
  w.r.t. each other, so there is no true-concurrency window that could break the invariant.

**Reachability assessment: the `CondvarInner::drop` panic (non-empty `sleeping`) is NOT reachable
through the real API.** The `reference_count() <= 1` guard, combined with the queued-waiter ⟺
live-clone invariant, prevents destroying a condvar that has a parked waiter.

## Step 2 — Developer-knowledge search
- `git blame`: the `<= 1` guard (put_cond) and the `Drop` panic are both deliberate, authored by
  the maintainer (Pedro H. Penna). The `reference_count()` doc-comment explicitly acknowledges the
  refcount-race semantics ("Another thread can change the strong count at any time…"), i.e. the
  refcount is the intended lifetime guard.
- The `Drop` panic is an intentional defensive assertion ("this should never happen"), consistent
  with the guard making it unreachable.
- No TODO/FIXME/"known issue"/"racy" comment near either site.

## Step 3 — Known-status / precedent
- No git remote in the worktree. GitHub code search (`nanvix/microkernel`) and web search for
  "Nanvix condvar CondvarInner drop panic put_cond" returned **no** matching issue/PR/CVE/advisory
  reporting this mechanism at this site.
- MC-sourced (a real counterexample exists) ⇒ not subject to the code-review×known pre-filter.
- Novelty: **NEW** (searched issue tracker surrogate + web; nothing reports this mechanism).

## Counterexample cross-check (`MC_hunt_scenario3_destroy_final.out`)
- 3-state trace. State 3 sets `g.destroyWaiter |-> TRUE` while, notably, `co = (cv1 :> [ex |-> TRUE,
  q |-> <<>>])` — the **condvar** exists with an **empty** queue — and the change is on the
  **mutex**: `mu.mx1.ex : TRUE → FALSE` (a Put destroys `mx1`; `mu.mx1.ow = t1`, `q = <<>>`).
- `destroyWaiter` is a **shared** witness set by both the PutMutex and PutCond branches (finding
  text confirms "the same NoDestroyWithWaiter witness … is set by the PutCond branch"). This
  minimal BFS counterexample reaches it via the mutex branch; MC-11's *claim* is the condvar branch.
- Either way, the spec's Put actions destroy the resource **without** modelling the implementation's
  `reference_count()` guard. For the condvar branch, the missing guard is `reference_count() <= 1`
  at state/mod.rs:712 (a queued waiter ⟺ refcount ≥ 2, so the impl never destroys with a waiter).

## Preliminary routing (decided after Phase 2)
The counterexample requires a state the implementation cannot reach (destroy a condvar while its
queue is non-empty). This is a **spec artifact**: the model's PutCond under-models the refcount
guard. Expected verdict: **PENDING REPAIR (SPEC_REPAIR)**, citing the missing guard at
state/mod.rs:712 (+ condvar.rs:93, wait_cond.rs:110-123). Confirm with reproduction (Phase 2).
