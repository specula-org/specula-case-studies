# Bug Report — jonhoo/left-right (Round 2)

## Summary

- Bug families tested: 4 (F1 UAF, F2 panic, F3 liveness, F4 snap-loop interleaving)
- Bugs found: **2** real implementation bugs (F1, F2), plus liveness violation under caller-misuse (F3 unfair) confirming the documented contract
- Configs run: `MC_hunt_F1_uaf.cfg`, `MC_hunt_F1_uaf_fixed.cfg`, `MC_hunt_F2_panic.cfg`, `MC_hunt_F3_liveness.cfg`, `MC_hunt_F3_liveness_fair.cfg`, `MC_hunt_F4_snap.cfg`

| Config | Mode | Result | Diameter | Distinct states | Output |
|--------|------|--------|----------|-----------------|--------|
| `MC_hunt_F1_uaf.cfg` | BFS | **VIOLATION** `MCStaleSnapshotIsCaught` | 20 (incomplete – terminated at first violation) | 12943 | `output/F1_uaf_bfs.out` |
| `MC_hunt_F1_uaf_fixed.cfg` | BFS | No violation (PR #144 fix verified) | 78 | 13 679 047 | `output/F1_uaf_fixed_bfs.out` |
| `MC_hunt_F2_panic.cfg` | BFS | **VIOLATION** `MCNoUnreachablePanic` | 20 (incomplete – terminated at first violation) | 7602 | `output/F2_panic_bfs.out` |
| `MC_hunt_F3_liveness.cfg` | BFS (no fairness) | **PROPERTY VIOLATED** `EventualPublish` (expected — confirms caller-misuse window) | 31 | 97 382 | `output/F3_liveness_bfs.out` |
| `MC_hunt_F3_liveness_fair.cfg` | BFS (with fairness) | No violation — liveness HOLDS under reader-fairness | 43 | 182 368 | `output/F3_liveness_fair_bfs.out` |
| `MC_hunt_F4_snap.cfg` | BFS | No violation (per-reader split snap is consistent) | 72 | 11 245 538 | `output/F4_snap_bfs.out` |

All BFS runs completed under 30 min (the longest was F1-fixed at 40s). For
the configs whose BFS reached a violation at depth 20, the violation was
found before exhausting BFS so simulation follow-up is unnecessary. For the
no-violation configs, BFS reached diameters of 43–78, well above the 25
threshold in `validation-workflow/guide.md` § Bug Hunting, so simulation
follow-up was not required.

---

## Bug 1: `take_inner` stale-snapshot use-after-free (PR #144)

- **Bug Family**: F1 — take_inner stale-snapshot UAF
- **Severity**: **High** (use-after-free; data race confirmed by upstream TSAN)
- **Invariant violated**: `MCStaleSnapshotIsCaught` (precursor to `MCNoDropWhileRead`)
- **Config**: `MC_hunt_F1_uaf.cfg` (`ApplyPR144Fix = FALSE`, `MaxTakeInner = 1`, `MaxPublish = 2`)
- **Counterexample**: 16 states, `output/F1_uaf_bfs.out`

### Trace Summary

This is the headline finding of Round 2.  The bug is a stale snapshot in
`WriteHandle::wait`: the per-reader `last_epochs` snapshot is taken
*before* a reader can establish a guard on the about-to-be-released
buffer, and the post-NULL-swap `wait` then mistakenly classifies that
reader as quiesced.

| Step | Action | Effect |
|------|--------|--------|
| 1 | `Init` | `inner_ptr=L`, `writerCopy=R`, `lastEpochs=[R1→0,R2→0]`, `first=TRUE` |
| 2 | `MCWriterStartTakeInner` | `taken := TRUE`, writer enters `take_inner` |
| 3 | `MCWriterTakeInnerMaybePublishGo` | `first=TRUE` ⇒ writer must run an internal `publish()` first (`write.rs:166-167`) |
| 4 | `MCWriterTakeInnerPubWait` | wait succeeds (no readers yet) |
| 5 | `MCWriterTakeInnerPubApply` | `first := FALSE` |
| 6 | `MCWriterTakeInnerPubSwap` | `inner_ptr := R`, `writerCopy := L` (atomic swap, `write.rs:455`) |
| 7 | `MCWriterTakeInnerPubFence` | SeqCst fence (`write.rs:462`) |
| 8 | `MCWriterTakeInnerPubBeginSnap` | begin per-reader snap loop (`write.rs:464-466`); `snapPending = {R1, R2}` |
| 9 | **`MCWriterTakeInnerPubSnapReader(R1)`** | `lastEpochs[R1] := epoch[R1] = 0` (R1 still idle); `snapPending = {R2}` |
| 10 | **`MCReaderEnterFreshBumpEpoch(R1)`** | R1 begins enter, `epoch[R1] := 1`. *This is the racing event — it slots between two iterations of the snap loop.* |
| 11 | **`MCReaderEnterFreshLoad(R1)`** | R1 reads `inner_ptr = R`, mints `ReadGuard` aliasing `R`. `readerHolding[R1] = R`, `enters[R1] = 1` |
| 12 | `MCWriterTakeInnerPubSnapReader(R2)` | `lastEpochs[R2] := 0`; snap loop ends with **`lastEpochs[R1] = 0` (stale)** |
| 13 | `MCWriterTakeInnerPubFinishSnap` | release the lock; `wPC = TINullReady` |
| 14 | **`MCWriterTakeInnerNullSwap`** | `releasedCopy := inner_ptr = R`, `inner_ptr := null` (`write.rs:175`). *The buffer R1 still aliases is now ear-marked for drop.* |
| 15 | `MCWriterTakeInnerLock` | re-acquire mutex (`write.rs:178-179`) |
| 16 | **`MCWriterTakeInnerWait`** | wait skip rule (`write.rs:272-274`) sees `lastEpochs[R1] = 0` (even) ⇒ skips R1 ⇒ wait succeeds. **`MCStaleSnapshotIsCaught` violated**: a registered reader (R1) holds `releasedCopy` but `lastEpochs[R1]` is even. |

If TLC continued past the invariant violation, the next step (in the
unmodified buggy code) would be `WriterTakeInnerFence` →
`WriterTakeInnerDropFirst` (drops `writerCopy = L` — fine) →
`WriterTakeInnerDropSecond` (drops `releasedCopy = R` — **UAF**, since
R1's `ReadGuard` still aliases `R`).

### Root Cause

`WriteHandle::wait` (`write.rs:247-307`) uses `self.last_epochs`, which
is populated by the per-reader Acquire load loop at `write.rs:464-466`
*inside the prior `update_and_swap`*.  The skip rule at `write.rs:272`
classifies a reader as "quiesced" if `last_epochs[ri] % 2 == 0`.

The fundamental invariant the rule relies on is: **a reader whose
`last_epochs` was even at snap time cannot hold a guard on a buffer that
predates the snap**.  This holds within a single `update_and_swap` —
where the snap follows the swap by a SeqCst fence — but it breaks for
`take_inner` when the per-reader snap loop is interleavable:

1. The snap loop is per-reader (`epochs.iter()`), with no atomicity
   across iterations (`write.rs:464-466`).
2. Between iteration `i` (snap of R1) and iteration `i+1` (snap of R2),
   R1 can run `enter()` and grab a `ReadGuard` aliasing the
   *post-swap* read pointer (`write.rs:455`), which becomes
   `releasedCopy` after the upcoming NULL swap.
3. R1's `last_epochs` retains the value from iteration `i` (even), so
   the post-NULL-swap `wait` (`write.rs:180`) mistakenly skips R1, and
   the subsequent drops at `write.rs:190` and `write.rs:135` (via
   `Taken::Drop`) free a buffer that R1 still references.

The bug is independent of whether `take_inner` ran an internal
`publish()` (`write.rs:166-167`) — what matters is that the most
recent snap of R1 happened strictly before R1's racing enter, and that
no resnap occurs between that point and the wait.

### Affected Code

- `write.rs:149-210` — `WriteHandle::take_inner`: missing `last_epochs` refresh after the NULL swap.
- `write.rs:247-307` — `WriteHandle::wait`: skip rule at line 272 (`if self.last_epochs[ri] % 2 == 0 { continue; }`) is sound only relative to the snap that produced the values; it is not sound when a reader entered between snap iterations.
- `write.rs:464-466` — per-reader snap loop: not atomic across iterations.
- `write.rs:175` — the NULL-swap that captures the about-to-be-released pointer without refreshing `last_epochs`.
- `write.rs:190` and `write.rs:135` — the `drop_first` / `drop_second` calls that consummate the UAF when the wait incorrectly succeeds.

### Recommendation

Apply the fix proposed in upstream PR #144 (`Fix data race on
writehandle drop`):

After the NULL swap at `write.rs:175`, before calling `wait`, refresh
`last_epochs` for every registered slot — i.e., perform a
per-reader Acquire load loop equivalent to `update_and_swap`'s snap
loop, but *after* the NULL swap.  Any reader that entered between the
prior snap and the NULL swap will then be visible (with an odd
`last_epochs[r]`), and the skip rule will spin on them until they
release.

Verification: with `ApplyPR144Fix = TRUE`, the spec's
`WriterTakeInnerResnapshot` action fires after the NULL swap and
before `WriterTakeInnerWait`.  The `MC_hunt_F1_uaf_fixed.cfg` BFS run
completed at depth 78 with 13.7 M distinct states and **no
violation** — confirming the fix closes the race within the modeled
state space.

---

## Bug 2: Reentrant `enter()` panics on dropped `WriteHandle`

- **Bug Family**: F2 — Reentrant enter() panic on NULL pointer
- **Severity**: **Medium** (process abort via `unreachable!()`; soundness-adjacent)
- **Invariant violated**: `MCNoUnreachablePanic`
- **Config**: `MC_hunt_F2_panic.cfg` (`MaxTakeInner = 1`, `MaxClientHolds = 0`)
- **Counterexample**: 16 states, `output/F2_panic_bfs.out`

### Trace Summary

A reader holding an outer `ReadGuard` cannot survive a concurrent
`WriteHandle::drop` if it ever calls `enter()` *again* on the same
`ReadHandle`.  The reentrant path (`enters > 0`) takes a code path that
asserts `inner_ptr` is non-NULL — but `take_inner` may have already
NULLed it.

| Step | Action | Effect |
|------|--------|--------|
| 1 | `Init` | `inner_ptr=L`, `writerCopy=R`, `first=TRUE` |
| 2 | `MCWriterAppend` | `copyData[R] := 1` (first-mode direct apply, `write.rs:564-574`) |
| 3 | `MCReaderEnterFreshBumpEpoch(R1)` | `epoch[R1] := 1`, `rPC[R1] = EpochBumped` |
| 4 | `MCWriterStartTakeInner` | `taken := TRUE` |
| 5–7 | `MCWriterTakeInnerMaybePublishGo`, `…PubWait`, `…PubApply` | internal publish progresses through wait (R1 still in EpochBumped, but `lastEpochs[R1] = 0` even, so skip rule lets writer proceed); `first := FALSE` |
| 8 | `MCReaderEnterFreshLoad(R1)` | R1 finishes `enter()`: reads `inner_ptr = L` (pre-swap), holds it. `readerHolding[R1] = L`, `enters[R1] = 1` |
| 9–14 | `MCWriterTakeInnerPubSwap`, `…PubFence`, `…PubBeginSnap`, `…PubSnapReader(R1/R2)`, `…PubFinishSnap` | swap `inner_ptr := R`, snap correctly captures `lastEpochs[R1] = 1` (odd, so wait will spin); `wPC = TINullReady` |
| 15 | **`MCWriterTakeInnerNullSwap`** | `inner_ptr := null`, `releasedCopy := R`. *Note R1 holds `L`, not the null target — and yet the very next nested `enter()` will hit NULL.* |
| 16 | **`MCReaderEnterNestedLoad(R1)`** | R1 calls `enter()` again. `enters[R1] = 1 > 0` so the code takes the reentrant branch (`read.rs:120-148`). It reloads `inner_ptr = null` (`read.rs:126`), enters the `else` arm, and hits `unreachable!()` at **`read.rs:146`** ⇒ **PANIC**. `panicked[R1] := TRUE` ⇒ `MCNoUnreachablePanic` violated. |

The panic fires *while* the writer is still inside `take_inner` (in
this trace, `wPC = TINulled`, before the post-NULL `wait` has even
re-acquired the mutex).  The writer's `wait` would correctly spin
on R1's odd epoch and never proceed to drops — but the panic in R1
aborts the reader thread regardless.

### Root Cause

`ReadHandle::enter` has two paths:

1. **Non-reentrant** (`enters == 0`, `read.rs:177-214`): bumps the
   epoch, fences, loads `inner_ptr`, and **gracefully returns `None`**
   if the pointer is NULL (`read.rs:206-213`).
2. **Reentrant** (`enters != 0`, `read.rs:120-148`): does NOT bump the
   epoch (the outer guard's odd epoch is still in effect); just
   reloads `inner_ptr` and **asserts non-NULL** at the
   `unreachable!()` (`read.rs:146`).

The reentrant branch's claim — that "if pointer is null, no ReadGuard
should have been issued" — is incorrect.  A reader can mint an outer
guard while `inner_ptr` is non-NULL, then have `inner_ptr` switched to
NULL by a concurrent `WriteHandle::drop` → `take_inner`, and then call
`enter()` again.  The outer guard is still valid (the writer's `wait`
inside `take_inner` is correctly blocked on R1's odd epoch), but the
*new* nested `enter()` cannot mint a guard from a NULL pointer.

### Affected Code

- `read.rs:120-148` — reentrant `enter()` branch.
- `read.rs:146` — `unreachable!("if pointer is null, no ReadGuard should have been issued")` is reachable.
- `write.rs:175` — `take_inner`'s NULL swap is the trigger.

### Recommendation

Mirror the non-reentrant path's NULL handling.  In the reentrant branch:

```rust
return if let Some(r_handle) = r_handle_ref {
    // ... existing nested-mint code ...
    __tla_guard
} else {
    // OUTER guard is still valid (epoch was bumped before its load saw a non-null ptr).
    // We just cannot mint a NEW nested guard from a NULL pointer.  Return None.
    None
};
```

This is a one-line change (the `else { unreachable!(...) }` becomes
`else { None }`).  Callers of `enter()` already handle `None` from
the non-reentrant path; they will continue to handle it identically
for the nested case.  The return type is already `Option<ReadGuard>`,
so no API change is needed.

This bug is **not yet reported upstream**; the modeling brief explicitly
flags it as a finding for this round (modeling-brief.md §2 F2).

---

## Bug 3 (informational): caller-misuse — long-held guard starves writer

- **Bug Family**: F3 — Long-held guard blocks publish (liveness)
- **Severity**: Medium (documented but unenforced contract)
- **Property violated**: `EventualPublish` (under `MCSpec`, no fairness)
- **Property holds**: under `MCSpecWithReleaseFairness` (see F3 fair config)
- **Configs**: `MC_hunt_F3_liveness.cfg` (violation), `MC_hunt_F3_liveness_fair.cfg` (holds)
- **Counterexample**: 31 states, `output/F3_liveness_bfs.out`

This is an *intended* finding of Round 2: it confirms the documented
contract on the reader side.  `lib.rs:142-143` warns that "for as long
as the guard lives, a writer that tries to call `WriteHandle::publish`
will be blocked from making progress."  The spec models this by
requiring weak fairness on `ClientHoldGuardRelease` (i.e. the reader
must eventually release the guard) for `EventualPublish` to hold.
Without that fairness — i.e. when a reader holds a `ReadGuard` across
an `await`, channel receive, slow user code, or a `thread::sleep` —
the writer's `wait` spins forever.

### Recommendation

This is a documented behavior, not a bug to fix.  However, the spec
makes the dependency explicit: any safe usage of `left-right` requires
that a `ReadGuard` is released "soon" (no yield points inside the
critical section).  Adding a `#[clippy::deny]`-style lint that flags a
`ReadGuard` held across `.await` would catch the most common form of
this misuse at compile time, but is out of scope for the library
itself.

---

## Not Reproduced

| Bug Family | Config | Diameter | Distinct states | Result |
|------------|--------|----------|-----------------|--------|
| F1 with PR #144 fix | `MC_hunt_F1_uaf_fixed.cfg` | 78 | 13 679 047 | **No violation** — verifies that refreshing `last_epochs` after the NULL swap closes the race |
| F4 — Per-reader snapshot consistency | `MC_hunt_F4_snap.cfg` | 72 | 11 245 538 | **No violation** — confirms that splitting the snap loop per-reader does not introduce a new race when a reader's epoch transitions between iterations.  The `MCPerReaderSnapshotConsistency` invariant holds. |
| F3 — Liveness under reader-fairness | `MC_hunt_F3_liveness_fair.cfg` | 43 | 182 368 | **No violation** — under weak fairness on `ClientHoldGuardRelease` (the documented contract), `EventualPublish` holds. |

All three "no violation" runs completed within their 30-minute budget
and reached BFS diameters comfortably above the 25-state threshold,
so simulation follow-up is not required.

---

## Convergence Summary

- **Trace validation** (Phase 1): all four traces (`sequential`, `slow_reader_overlap`, `nested_enters`, `try_publish`) passed first try; no spec modifications.
- **Model checking** (Phase 2): `MC.cfg` finished in 14 s at diameter 54 with 318 897 distinct states and **no violations**.  No spec modifications.
- **Convergence**: 1 round, 0 spec modifications.
- **Spec modifications during bug hunting**: none — all violations are real implementation findings (Cases C).
