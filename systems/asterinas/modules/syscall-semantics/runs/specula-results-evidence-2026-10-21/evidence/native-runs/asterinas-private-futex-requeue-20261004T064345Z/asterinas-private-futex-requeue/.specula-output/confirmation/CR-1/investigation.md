# CR-1 Investigation record (Phase 1 — evidence only)

Finding: "A user value update and WAKE can overlap WAIT registration, including
the unlocked fault-retry window." Code-review Scenario 1, severity High, no
counterexample (MC hunt configs ran clean). The open question: can the atomic
comparison/registration contract let a wait miss a required wake?

## Step 1: Code audit

### Sites (worktree = upstream 0c6053709 + Specula probes)

1. `kernel/core/src/process/posix_thread/futex.rs:79-150` — `futex_wait_bitset`:
   - Loop: lock bucket → `with_page_fault_disabled(atomic_load::<u32>)` → on
     success break with `(guard, val)`; on fault: `drop(futex_bucket)`,
     `handle_page_fault(READ)`, retry loop (re-lock + re-load).
   - Under the still-held lock: compare `val != futex_val` → mismatch:
     drop lock, drop item, return `EAGAIN` (no registration).
   - Match: `futex_bucket.add_item(futex_item)` under the lock, then
     `drop(futex_bucket)`, then `waiter.pause_timeout(...)`.
   - Comment at the lock site: "Lock the futex bucket first to avoid race
     conditions."
   - Cleanup after pause: re-lock, `remove_by_waker`; `item.is_none()` ⇒ item
     was removed by a wake ⇒ report `Ok(())`.
2. `kernel/core/src/process/posix_thread/futex.rs:249-275` — `futex_wake_bitset`:
   same bucket (same `FutexKey` → same index in `FutexBucketVec`, `hash & (size-1)`),
   `lock()` → `remove_and_wake_items(key, max_count)` → drop. Wake dequeue+`wake_up`
   happens entirely under the bucket lock.
3. `kernel/core/src/process/posix_thread/thread_local.rs:102-135` —
   `with_page_fault_disabled`: page-fault handler fails fast with `EFAULT` while a
   spin lock (atomic mode) is held; the caller must exit atomic mode, resolve the
   fault, and retry. This is why the futex load-fault path drops the bucket lock.
4. `ostd/src/sync/wait.rs:170-201, 262-321` — `Waker::wake_up` sets
   `has_woken` (Release) then unparks; `Waker::do_wait` swaps `has_woken` to false
   (Acquire) before parking, so a wake landing between enqueue and park is latched
   and `pause_timeout` returns immediately. Memory-order rationale documented at
   the top of the file.

### Call chain / reachability

`sys_futex` (kernel/core/src/syscall/futex.rs) → op dispatch →
`futex_wait`/`futex_wait_bitset` and `futex_wake`/`futex_wake_bitset` with
`FUTEX_PRIVATE_FLAG` → `FutexKey::new` (Private identity = vmar snapshot + addr,
4-byte alignment enforced) → `get_futex_bucket` → the audited paths. Fully
reachable through the public `futex(2)` syscall; nothing gated.

### The serialization contract (what the finding hypothesizes might fail)

Let W = waiter thread ops (1) lock, (2) load val, (3) compare, (4) enqueue,
(5) unlock, (6) park; K = waker thread ops (a) user atomic store of new value,
(b) WAKE: lock, dequeue+wake, unlock.

- If [b] completes before W's (1): W's lock acquire reads K's lock release
  (program order puts (a) before K's release), so W's load (2) observes the new
  value → mismatch → EAGAIN, no park. The wake "missed" the waiter only because
  the waiter never registered, and the mismatch tells the user so — Linux's
  contract (futex_wait_setup in kernel/futex/waitwake.c does the same locked
  load + queue_futex).
- If W's (1)-(5) complete first: the item is enqueued before K can take the
  lock, so [b] finds and wakes it. The pending-wake latch in ostd covers any
  wake landing between (5) and (6).
- Fault-retry window (the finding's specific worry): when W's load faults, W
  drops the lock between attempts. Any store+wake slipping into that window
  behaves exactly like the first case for the *next* locked attempt: if the
  wake's critical section completed, the re-load sees the new value → EAGAIN;
  otherwise the item enqueues before the wake takes the lock → woken. The retry
  loop re-establishes the contract on every attempt; the unlocked window does
  not let a wake fall between a load and its enqueue.

Conclusion of the audit (recorded as fact, not verdict): the load, compare and
enqueue are atomic with respect to wake's dequeue because both hold the same
bucket SpinLock; the fault path re-loads under the lock; the enqueue→park gap is
covered by the `has_woken` latch. This matches Linux waitwake.c's locked reload
and `queue_futex` discipline.

### Trigger scenario (constructed for Phase 2)

Two pinned threads, private futex word `w` in an anonymous page. Per iteration:
waiter waits on expected 0 with a bounded timeout; waker does
`atomic_store(w,1,release)` then `FUTEX_WAKE_PRIVATE(1)` exactly once.
Contract: the waiter must never time out — every interleaving yields EAGAIN
(load saw the store) or woken (wake found the enqueued item). A timeout with
word==1 is a missed required wake. Fault-window variant: waiter issues
`madvise(MADV_DONTNEED)` on the page before each wait (supported:
kernel/core/src/syscall/madvise.rs:37 → `vmar.discard_pages`), forcing the
locked load to fault so the store+wake races into the unlocked
fault-resolution window.

### Safeguards encountered (recorded, to be proven in Phase 2)

- Bucket SpinLock held across load/compare/enqueue (futex.rs loop + add_item).
- Locked reload after fault retry (the loop structure itself).
- ostd `has_woken` latch between enqueue and park (wait.rs do_wait).
- Cleanup `remove_by_waker` distinguishing "woken" (`item.is_none()` → Ok) from
  timeout/spurious.

## Step 2: Developer knowledge

- `git log --follow` on futex.rs and grep for futex commits:
  - `6c4f56723 Fix futex lost wakeup` (Nov 2024): made `FutexItem::wake()`
    `#[must_use]` and count only accepted wakes — wake-side counting, not the
    registration window.
  - `888eecb35 Patch a futex vulnerability` (Aug 2025, fixes issue #1587):
    dequeue by unique waker on timeout/signal — the cleanup path, a different
    mechanism from this finding.
  - `5b9106431 Add a method that disables page fault handlers` (Jul 2025): the
    commit that introduced `with_page_fault_disabled` and the fault-retry loop
    in `futex_wait_bitset` (subject only, no body). Follow-up to the
    atomic-mode discipline; issue #2306 (page fault in atomic mode during
    futex) is the historical driver.
  - `e4fafb13 Add atomic operations for VM readers/writers` — atomic fallible
    loads/stores for user memory; issue #981-era non-atomic-read repair.
  - `bc5a058fc Add TODO for a potential vulnerability in futex implementation`
    — TODO was later fixed by `888eecb35` (cleanup-path leak).
  - `046c9f6a9 Improve futex code and log clarity` — includes the "Lock the
    futex bucket first to avoid race conditions" comment.
- FIXME in current code (futex.rs, cleanup): `pause_timeout` should return
  `Ok(())` when woken but "currently may return errors due to race conditions" —
  developer-acknowledged wart in the *return-code* path, not a lost wake (the
  wake itself is not lost; the item is gone and `item.is_none()` reports Ok).
- Existing tests: test/initramfs regression suite has futex tests
  (pthread_signal_test.c from `6c4f56723`; specula_futex scenarios 1-18 built
  during harness validation). No existing test races store+WAKE against WAIT
  registration with a fault-retry window.

None of the developer commentary claims the registration window tolerates a
missed wake; the code structure asserts the opposite (lock first).

## Step 3: Known-status / precedent

Searches run: upstream issue tracker via web (issues/PRs mentioning futex
wait/wake/lost-wakeup/registration race), plus git history in the worktree
(`git log --grep=futex -i`, --grep for 981/2306), plus the current upstream
`main` futex.rs fetched from GitHub.

- Issue #1587 / commit 888eecb35: cleanup-path item removal — different site
  and mechanism (post-pause dequeue), not the registration window.
- Issue #2306 / commit 5b9106431: page-fault-in-atomic-mode — the *repair* that
  created the current fault-retry structure; it is the context this finding
  questions, not a report of a missed wake.
- Issue #981 era / commit e4fafb13: non-atomic user read — repaired with atomic
  fallible loads; again the historical context named in the finding.
- Upstream `main` (fetched 2026-10) still contains the identical mechanism:
  locked load/compare/enqueue, fault-retry with unlock→fault→relock→reload,
  wake under the same bucket lock. No upstream commit, PR, or issue reports a
  lost-registration defect at this site.

No existing report of THIS mechanism (store+WAKE overlapping WAIT
registration incl. fault-retry window causing a missed wake) exists upstream.
This is a mechanism hypothesis without a counterexample, entering Phase 2 as an
unreported code-review candidate.

## Phase 2 reproduction record (addendum)

Test: .specula-output/repro/test_bugCR-1_lost_wake_race.c (+ runners
test_bugCR-1_lost_wake_race.sh, cr1_inner.sh; Level 3: -l3.sh, cr1_l3_inner.sh).
Guest: prebuilt campaign kernel (identity verified: c39392f9…, source 0c6053709)
for Levels 0/1; Level 3 used a rebuilt kernel from l3run/source = campaign
source + a 6-line timing-only patch (futex.rs: ~200us tr::stamp() spin inside
the unlocked fault-retry window after handle_page_fault; no logic altered;
rebuilt kernel sha256 dbebc79c…). QEMU q35/KVM, SMP 2, 2G (policy limits).

Outcome classes observed prove real interleaving in both directions (woken and
EAGAIN in every racy phase). MADVISE_CHECK works=yes confirms phases B/D really
forced the locked load to fault (opening the kernel's unlock->fault->relock
window). Level 3's widened window flipped the outcome distribution from 72%
woken to 3.5% woken — i.e. the store+WAKE completed inside the unlocked window
~22,500 times, exactly the hypothesized adversarial overlap — with the reload
catching the store every time (EAGAIN) or the enqueue preceding the wake
(woken). Zero timeouts (lost wakes), zero unexpected errnos, zero
counted-but-lost wakes across 396,000 racing iterations.

Escalation ladder:
- Level 0 (phase A, 200k iters): no trigger.
- Level 1 (phases B/C/D, 170k iters incl. 70k fault-window): no trigger.
- Level 2 (state injection): inapplicable — the hypothesized bad state (a
  wake's critical section landing between the waiter's locked load and its
  enqueue) is unreachable through any real-API sequence because load and
  enqueue are one continuous lock hold; fabricating it would require removing
  the bucket lock (a prohibited logic change that would prove nothing).
- Level 3 (kernel-side ~200us window widening, 25k iters): no trigger.
