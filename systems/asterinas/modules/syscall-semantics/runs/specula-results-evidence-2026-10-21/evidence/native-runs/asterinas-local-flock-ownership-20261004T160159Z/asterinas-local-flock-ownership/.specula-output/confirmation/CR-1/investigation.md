# CR-1 Investigation (Phase 1 — evidence only)

Finding: "OFD identity and compatible ownership across independent opens and dup aliases"
Source: code-review (no MC counterexample; hunts C01/C02 exhausted their reachable state graphs
without violations — recorded in the campaign brief; not re-read here per the Do-NOT list).

## Step 1: Code audit

Pinned source 0c60537098f4c2949ad2d382aaf499de72263d76 in this worktree (with the campaign's
reviewed trace instrumentation applied on top; none of the instrumented hunks alter the
identity/ownership logic — all trace calls are `if trace::at(..)`-guarded observations).

### Identity representation

- `kernel/core/src/fs/file/flock.rs:26-33` (clean tree): a `Flock` holds
  `owner: Weak<dyn FileLike>` — a weak reference to the *file object* (the open file
  description, OFD), never the fd number and never the process.
- `flock.rs:29-33` `FlockItem::new(owner: &Arc<dyn FileLike>, ..)` downgrades a strong Arc
  captured by the syscall to this Weak; the waitqueue is per FlockItem.
- `flock.rs:43-45` `same_owner_with` = `self.lock.owner.ptr_eq(&other.lock.owner)` — Arc
  allocation pointer identity. Dead Weaks still compare by pointer (same allocation).
- `flock.rs:47-58` `conflict_with`: same owner => never conflicts; different owner +
  either side ExclusiveLock => conflict. So two independent OFDs with SH are compatible;
  SH+EX across OFDs conflict.
- `flock.rs:114-134` `try_set_lock` (entire body under `FlockList::inner` Mutex):
  first scans for a conflicting item (EAGAIN, enqueues waker in the blocking mode), else
  `position(same_owner_with)` -> `list[idx] = req_lock.clone()` (replace, cited lines
  122-127) or push. Any request by an OFD that already has an item replaces that item;
  two items for one OFD can only be installed if two `try_set_lock` calls with ptr-equal
  owners both take the push branch — impossible while each call runs once under the
  mutex, because the second call finds the first's item via `same_owner_with`.
- `flock.rs:139-160` `set_lock`: LOCK_NB delegates to `try_set_lock(.., None)`; blocking
  mode retries `try_set_lock(Some(waker))` inside `Waiter::pause_until` until it stops
  returning EAGAIN.
- `flock.rs:164-185` `unlock(req_owner: &InodeHandle)`: retains items whose upgraded owner
  does NOT ptr-eq `req_owner`; a matching item is removed after `wake_all()` on its
  waitqueue; items whose Weak no longer upgrades are removed as dead. Note (recorded,
  judged elsewhere): the dead-owner branch removes without `wake_all()`; on
  InodeHandle::drop the dying owner's Weak cannot upgrade (strong count already 0), so
  death-close removal takes that no-wake branch. Waiter-wake behavior belongs to the
  S3/S4 findings, not to this identity finding; this repro accordingly probes states with
  LOCK_NB only.

### OFD creation, aliasing, and descriptor removal

- `kernel/core/src/syscall/open.rs:102-126` (worktree lines; clean tree equivalent)
  `do_open`: every successful open produces a fresh `Arc::new(InodeHandle::..)` OR
  matches O_CREAT with a fresh `InodeHandle`. Independent opens therefore always create
  distinct Arc allocations = distinct OFDs.
- `kernel/core/src/fs/file/file_table.rs:139-167` `dup_ceil` / `:169-179` `dup_exact`
  call `duplicate_entry` (`:181-188`), which clones the *Arc* out of the source slot
  (`entry.file.clone()`), so a dup alias is a second strong reference to the same
  allocation = same OFD. `dup_exact` first `close_file(new_fd)` and the caller
  (`syscall/dup.rs:78-86`) drops the replaced file after releasing the write lock — so a
  dup2 onto an fd holding the last reference to a locked OFD releases that OFD's flock
  inside the dup2 syscall, matching Linux.
- `file_table.rs:190-194` `insert` uses `SlotVec::put` (lowest free slot) and
  `:196-205` `close_file` uses `SlotVec::remove`, so fd numbers are reused deterministically
  after close (lowest-number-first). The fd number and the OFD are never conflated by the
  flock code: the FlockList keys on the Weak pointer, not the fd.
- `syscall/close.rs:47-67`: close removes the entry under the write lock, then drops
  `ClosedFile` (and with it possibly the last Arc) *before returning*, so lock release on
  last close is synchronous with close() — same as Linux close(2) dropping the last
  struct file reference inside the syscall.
- `kernel/core/src/fs/file/inode_handle.rs:230-238` `set_flock` resolves the per-inode
  `FsLockContext::flock_list()`; `:240-256` `unlock_flock`; `:545-553` (worktree)
  `impl Drop for InodeHandle` calls `unlock_flock()` — so the flock is released exactly
  when the last strong reference to the OFD disappears or on explicit LOCK_UN.

### get_file_fast! capture path (cited file_table.rs:341-361)

- `file_table.rs:341-375` `get_file_fast!`: fast path when the thread's `RwArc<FileTable>`
  is not shared (`RwArc::get` returns Some iff `num_rw <= 1`, `ostd/src/sync/rwarc.rs:66-80`)
  — returns `Cow::Borrowed(&Arc)` with no refcount change; slow path (multi-threaded
  process) clones the Arc under the read lock and drops the lock immediately, returning
  `Cow::Owned`. In both cases `FlockItem::new` downsamples the *same allocation* into the
  Weak owner, so alias identity is identical on both paths.
- Fast-path safety while a blocking flock holds the borrowed Arc: the table is
  unshared, so no other thread can remove the fd concurrently; the only thread able to
  close the descriptor is the blocked one itself.
- Slow-path safety: the request retains its own strong clone, so fd removal by another
  thread cannot destroy the OFD mid-request; pending lock acquisition then completes and
  the lock evaporates when the syscall's clone drops — Linux-equivalent (flock(2) holds a
  struct-file reference for the duration of the call).

### Reachability

All cited paths are reached by ordinary public syscalls: open/openat -> do_open;
dup/dup2/dup3 -> dup_ceil/dup_exact; close -> close_file/ClosedFile; flock ->
get_file_fast! + FlockItem::new + set_flock/try_set_lock/unlock. No internal-only entry.

### Trigger scenario (candidate consequence to test at runtime)

Black-box contract checks derived from the Linux identity contract (flock(2)):
1. Two independent opens = two OFDs: SH+SH compatible; EX vs anything (other OFD) conflicts.
2. dup alias = same OFD: EX request via alias silently converts an SH held via the
   original fd (no self-conflict), and LOCK_UN via either descriptor clears it.
3. Closing one descriptor of an aliased OFD keeps the lock; closing the last one drops it
   without any explicit unlock; no stale item survives.
4. fd-number reuse must not transfer ownership: a fresh open that recycles a closed fd
   number while an alias still holds the lock is a *different* owner (conflict applies),
   and previous requests' ownership is unaffected.
5. dup2 replacing a locked fd releases the replaced OFD's lock within the syscall.
6. A same-OFD conversion loop must never deadlock on itself nor leave duplicate/stale
   items (probed via a third independent OFD after LOCK_UN).
Threaded variants of 1-2 exercise the shared-file-table slow path (Arc clone per request).

### Safeguards encountered (recorded, not dismissed)

- FlockList Mutex entirely serializes conflict check + replace/push (single critical
  section) — prevents same-OFD double install absent a foreign writer.
- `InodeHandle::drop` releases the flock on last-reference death — prevents stale locks
  after last close (fd-reuse ABA on the kernel heap cannot resurrect a removed item).
- `close` drops `ClosedFile` before returning — lock release is synchronous with close.
- Dead-owner items are purged in `unlock` retain — bounds any transient death window.

## Step 2: Developer-knowledge search

- `git log` on flock.rs / file_table.rs (this checkout): flock history is
  `ce2af1eb0` (add flock and sys_flock),
  `e5fd8e747` "Fix flock lost-wakeup bugs, replace RwMutex -> Mutex" (fixes issue #1474,
  waiter semantics — not identity),
  `7fbe997bb` "Fix range_lock and flock to support signal interrupts and comply with wait API
  design" (wait/signal semantics — not identity),
  `7c7dd47b9` (SCML scaffolding), plus refactors. No commit message states anything about
  OFD identity, dup aliases, fd reuse, or double install; no TODO/FIXME comments on the
  cited lines (checked with grep: no TODO/FIXME in flock.rs / file_table.rs / open.rs cited
  ranges).
- `syscall/close.rs:60-64` carries the comment "We don't mind the races between closing the
  file descriptor and using the file descriptor, because such races are explicitly allowed
  in the man pages" (close(2) Multithreaded processes section) — evidence the developers
  accept fd-use/close races as permitted, and handle lifetime via the ClosedFile drop.
- Tests in tree: no flock regression test exists (only fcntl_lock.c for POSIX locks), so
  no test asserts the current identity behavior as intended.

## Step 3: Known-status / precedent

Upstream tracker + history search performed (web search over github.com/asterinas plus
git history in this checkout):
- Issue #1474 "Infinite waiting in flock due to waiting on a None condition" — waiter
  wake condition bug, fixed by e5fd8e747. Not this mechanism (identity/ownership capture),
  and already fixed.
- Issue #1550 "Look up the file table with zero atomic operations" — design discussion of
  get_file_fast! (the cited macro); no defect report on ownership.
- Issue #1303 (RwMutex lost wakeup), #1588/#1602 (deadlocks elsewhere), PR #1466/#2515
  (futex) — unrelated sites.
- No issue, PR, CVE or advisory reports: OFD identity violations across independent
  opens/dup aliases, owner change on FD removal/reuse, or one OFD installing two flock
  items at `fs/file/flock.rs` / `fs/file/file_table.rs`. Recent merged/closed flock-adjacent
  PRs (#2521 memfd, #2877 pidfd, #3048 dentry cache, #3185 O_TMPFILE) do not touch the
  flock identity mechanism.
=> No prior report of THIS defect: the pre-filter (code-review x known) does NOT drop.
Novelty: NEW (tracker + git-history searched; nothing matches this mechanism/site).

## Input/trigger reachability conclusion (fact, not verdict)

Every check in the trigger scenario is reachable through real public syscalls on an
ordinary ramfs file, single- and multi-threaded. The reproduction will run them as the
guest's init on the campaign's reviewed kernel build.

# Phase 2: Reproduction (escalation record + outcome)

Test: `repro/test_bugCR-1_flock_ofd_identity.c` (guest fixture, 18 checks)
Driver: `repro/test_bugCR-1_flock_ofd_identity.sh` — runs a Linux control on the
container's real Linux (tmpfs) and 3 Asterinas guest boots on the campaign's
reviewed kernel build (container specula-flock-harness-20261005, kernel ELF
sha256 d51c2205..., reviewed-hash gate re-verified before each run).
Run artifacts: `repro/cr1-run-20261006T001826Z/` (initial run) and
`repro/cr1-run-20261006T002047Z/` (final, corrected test).

## Escalation ladder

- Level 0 (pure black-box): the full identity-contract matrix above via public
  syscalls only (open/dup/dup2/close/flock, LOCK_NB probes; one natural blocking
  acquisition with a 200 ms observation sleep; threads for the shared-table slow
  path). Result: 18/18 PASS on Linux control AND on all 3 Asterinas guest runs
  (2 vCPU/2 GiB, reviewed flock OSDK scheme). No divergence from Linux observed.
- Level 1 (timing assistance): only the single msleep in g4 to observe the
  blocked waiter; nothing to widen because no race symptom exists to widen.
- Level 2 (state injection): not reached — Level 0 did not fail; there is no
  symptom to force, and injecting states or patching sources to create one is
  prohibited. Every state the hypothesis named (fd removal, fd reuse, dup
  aliasing, table mutation during shared use) is directly reachable and was
  exercised at Level 0.
- Level 3 (source patch): not reached, same reason.

## Test-bug note (first run, cr1-run-20261006T001826Z)

The first run's only failure, f2_conversion_blocked_by_other_ofd, was the test's
own premise error: after e1's dup2(fdB, fdA), fdA aliases fdB's OFD (proved by
e2 passing), so f2's "two independent holders" assumption was false — the
kernel's same-OFD EX conversion succeeding was correct Linux behavior. Fixed by
opening fresh independent descriptors in f2; the corrected test passes 18/18
everywhere. No kernel divergence occurred in either version of the run.

## Outcome

- No wrong outcome was produced on any reachable path, single- or
  multi-threaded: independent opens conflict/compatibility, alias conversion and
  unlock through any descriptor, close-one/close-last semantics (incl. dup2
  replacement and freed-allocation ABA cycling), fd-number reuse never
  transfers ownership, conversion loops never deadlock nor leave stale items,
  and a blocking acquisition installs a lock owned by the waiter's own OFD.
- Phase 1 audit found no residual reachable gap in the mechanism: ownership is
  keyed on the OFD Arc allocation (Weak ptr identity), the FlockList mutex
  serializes conflict-check + replace/push, and InodeHandle::drop plus
  synchronous ClosedFile dropping remove items at the right lifetime points.
- The one adjacent anomaly recorded in Step 1 (dead-owner branch in
  FlockList::unlock removing without wake_all) is a waiter-notification concern
  that belongs to the S3/S4 close/wake findings, is not an identity defect, and
  this repro deliberately avoids depending on it; it does not mask any identity
  defect because none exists.
- Verdict: FALSE POSITIVE (code-review candidate with no counterexample; the
  hypothesized identity/ownership mechanism is implemented correctly —
  demonstrated Linux-equivalent on every exercised path).
