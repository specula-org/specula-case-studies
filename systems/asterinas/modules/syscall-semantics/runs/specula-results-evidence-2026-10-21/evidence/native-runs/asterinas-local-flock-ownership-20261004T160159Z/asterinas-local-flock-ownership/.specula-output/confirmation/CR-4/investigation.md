# CR-4 investigation record (Phase 1 — evidence only)

Finding: "Successful request's local Drop drains the waiter queue outside the list Mutex"
Source: code-review (scenario 3, FL-CR-1). No counterexample; the C09 wake-race hunt
exhausted without safety violations.

## Step 1: Code audit

Pinned input: 0c60537098f4c2949ad2d382aaf499de72263d76
(inspection copy `/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source`;
workerbuild tree `.specula-output/confirmation/CR-4/worktree` — verified: kernel/ and
ostd/ differ from the clean pin only by the campaign's reviewed trace instrumentation;
flock logic byte-equivalent modulo `trace::` calls).

Cited code (line numbers in the clean pin):

- `kernel/core/src/fs/file/flock.rs:69-82` — `Clone for FlockItem` shares the
  `Arc<WaitQueue>` with every clone; `Drop for FlockItem` runs
  `self.waitqueue.wake_all()` on drop, documented as: "When a FlockItem is dropped, it
  wakes all threads that are waiting for the lock."
- `kernel/core/src/fs/file/flock.rs:124-157` — `try_set_lock` installs
  `list[idx] = req_lock.clone()` (replacement, old item dropped *inside* the critical
  section) or `list.push(req_lock.clone())` (append), then drops the list guard; the
  caller-owned `req_lock` drops when `set_lock` returns — *after* the critical
  section — running the Drop handler's `wake_all` on the queue it shares with the
  installed item.
- `ostd/src/sync/wait.rs:119-131` — `wake_all` pops wakers, releases the queue
  spinlock, then calls `Waker::wake_up` (`has_woken` swap; `scheduler::unpark_target`).

Call chain (public API → site):
`sys_flock` (`kernel/core/src/syscall/flock.rs`) → `FlockItem::new(&file, type_)`
(fresh `Arc<WaitQueue>` per request) → `InodeHandle::set_flock`
(`inode_handle.rs:230-237`, per-inode `FsLockContext` → `FlockList`) →
`FlockList::set_lock` → `try_set_lock` (install) → return path:
guard dropped inside `try_set_lock` → `pause_until` epilogue
(`pause.rs:164-166` `clear_signalled_waker`) → `set_lock` returns →
`Waiter/Waker` dropped (`WaiterClose`) → `req_lock` dropped
(`FlockItemDropRequest` → `wake_all`). Window between list-Mutex release and the
request-clone drop ≈ a few hundred ns (two returns + signal-waker removal).

Mechanism (when it can fire): waiters enqueue only on the waitqueue of an item IN
the list (`try_set_lock` conflict branch, under the Mutex). After a grant
(append, or same-owner replacement whose old-item Drop inside the critical section
wakes the old queue's waiters), a contender that re-enqueues on the just-installed
item's queue *within the grant-return window* is drained by the granting thread's
request-clone Drop, wakes, retries under the Mutex, finds the granting item still
held, and re-enqueues: one futile wake-retry-re-enqueue cycle. In steady state
(waiters parked since before the grant) the clone-drop drain takes the
`num_wakers == 0` fast path and is a no-op.

Which Drop-time `wake_all`s are load-bearing for correctness:
1. Replacement (`list[idx] = req_lock.clone()`): old item's Drop inside the critical
   section is the only notification for waiters of the replaced item (e.g. EX→SH
   downgrade unblocks SH waiters — they retry and are then compatible). Necessary.
2. `unlock()` retaining with a dead owner (Weak upgrade fails): no explicit
   `wake_all` in that branch; the item Drop's `wake_all` is the only notification.
   Necessary.
3. The successful request's clone Drop (CR-4's site): the installed item remains in
   the list; waiters on its queue are woken again later by the item's own
   removal/replacement/unlock. This wake is never needed for progress; any wake it
   delivers while the item is still held is spurious. Harmless-by-protocol: the
   `pause_until` closure re-checks under the list Mutex and just re-enqueues.

Safeguards/absorptions (recorded, proven in Phase 2):
- `Waker::wake_up` dedup via `has_woken` swap: a waiter already woken but not yet
  running is not unparked twice (second wake_up returns false).
- `wait_until_or_cancelled` + `pause_until` closure: spurious wakes are consumed by
  the retry loop; enqueue happens under the list Mutex inside the closure, so no
  lost-wakeup window is introduced (this is the fixed design of PR #1486).
- `WaitQueue::is_empty` release-load fast path: empty-queue drain costs one atomic.
- flock correctness is not implicated by the finding itself; the claim is excess
  scheduling work (wake → unpark → retry-scan → re-enqueue → park) per cycle.

Trigger scenario (concrete, real-API only): controller holds EX on file F via
independent opens a; contenders B and C issue blocking `flock(EX)` (both park on the
holder's item queue); controller `LOCK_UN` → both unparked and race on 2 vCPUs for
the list Mutex; one contender is granted (append) and its request-clone Drop drains
the queue — if the loser re-enqueued within the grant-return window it is woken
futilely, rescans, re-enqueues, re-parks; the winner's later unlock then completes
the loser. Conversion variant: controller holds SH, B waits EX on it, controller
converts SH→EX; the replaced item's Drop (inside the Mutex) wakes B, B re-enqueues on
the new EX item racing the converter's clone-drop window (B is already running —
highest-probability interleaving for the drain to pop a waker).

Reachability: real public `flock(2)` on an ordinary ramfs file, SMP>=2 (campaign
guest reports 2 CPUs, ramfs magic 0x858458f6). No fabricated state needed.

## Step 2: Developer-knowledge search

- `ce2af1eb0` "Add flock and sys_flock" (Aug 2024) introduces both the FlockItem
  Drop-wake and its doc comment — a stated uniform policy, not an accident.
- `e5fd8e747` "Fix flock lost-wakeup bugs, replace RwMutex -> Mutex" (= PR #1486,
  fixes #1474): moves waiter enqueueing under the list Mutex — lost-wakeup fixes;
  Drop-wake untouched.
- `7fbe997bb` "Fix range_lock and flock to support signal interrupts and comply with
  wait API design" switches replacement from `mem::swap` (request took over the old
  item and its queue, so the request-clone Drop *was* the notifier at that time) to
  `clone` (old item drops inside the critical section; the request-clone Drop's
  target queue becomes the new item's, usually empty). After this change the
  request-clone drop-wake stopped being load-bearing — the CR-4 site is the residue
  of the earlier design left in place under a uniform documented policy.
- Campaign contracts (`flock-wait-handoff-2026-05/flock/contracts.md`) record the
  behavior as known source behavior: "The successful acquisition stores a clone of
  the request item. That clone and the local request share a wait queue, so dropping
  the local request on return can also wake that queue without releasing the stored
  flock ... These are reasons to preserve the full retry loop, not evidence of
  duplicate ownership or a missing handoff." The Linux oracle row "Retry after
  release" states: "A wake means retry, not reservation. A waiter may lose a race,
  discover another blocker, and wait again."
- Prior real-guest evidence (v10 harness traces, `.specula-output/traces/`): C04,
  C06, C07-after, C08, C09 contain 13 successful-grant request-clone drops; every
  one drained an empty queue (`FlockItemDropRequest` → `WaitQueueFinish`, zero
  `WaitQueuePop`). The recorded loser retries either won or re-enqueued after the
  window with no futile cycle. (Single-shot cases with a boundary-polling
  controller, so weak — Phase 2 re-tests under purpose-built churn.)

## Step 3: Known-status / precedent

Upstream tracker + recently merged/closed PRs searched (web): issues #1474
(flock infinite wait, fixed by PR #1486), #1303 (RwMutex lost wakeup), #1587
(futex removal), #3283 (stale wakers in WaitQueue after interrupted flock —
different mechanism: closed wakers left in queues; counter wrap), PR #1466
(range_lock lost-wakeup/starvation discussion — different subsystem). NONE reports
CR-4's mechanism (grant-path request-clone Drop draining waiters that re-enqueue
against the still-held granting item) at this site. No recent commit changes
`flock.rs` grant-path wake behavior.

Novelty: NEW (tracker + PR search done; nothing reports this mechanism at this site).
Pre-filter: not applicable (no existing report of this exact defect) → proceed to
Phase 2.
