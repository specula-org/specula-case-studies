# MC-2 investigation record (Phase 1 — evidence only)

Finding: "A final temporary reference can deadlock flock cleanup" (MC-2, scenario 5 / C11,
invariant NoRecursiveListWait, severity High).

Worktree: `.specula-output/confirmation/MC-2/worktree` at pinned commit
`0c60537098f4c2949ad2d382aaf499de72263d76` plus the campaign's reviewed v12 trace
instrumentation (trace-only; verified by diff: `flock.rs`/`inode_handle.rs`/`close.rs`/
`open.rs`/`flock.rs`/wait.rs/scheduler/prctl changes only emit events and add the prctl
`0x53504543` test-gate interface; the flock control flow, reference semantics, and mutex
behavior are unchanged from the pinned commit).

## Step 1: Code audit

### The mechanism (all line numbers at the pinned commit)

1. `kernel/core/src/fs/file/flock.rs:166` — `FlockList::unlock` acquires the per-inode
   flock-list mutex: `let mut list = self.inner.lock();` (`ostd::sync::Mutex`, non-recursive).
2. `flock.rs:168` — inside `list.retain(...)`, each item's owner is upgraded:
   `if let Some(owner) = lock.owner()` → `FlockItem::owner()` → `Weak::upgrade`
   (flock.rs:74). The returned `Arc<dyn FileLike>` (= `Arc<InodeHandle>`) is a closure-local
   temporary: it is dropped at the end of the if-let, i.e. **while the `list` guard is still
   held** (the guard is dropped only at flock.rs:181 after `retain` returns).
3. `kernel/core/src/syscall/close.rs:19-35` + `file_table.rs:196-205, 274-298` —
   `close(fd)` removes the fd-table entry under the table write lock, moves the table's
   `Arc` into `ClosedFile`, releases the table lock, then drops `ClosedFile` — decrementing
   the strong count **outside** the table lock. If a scan holds a temporary Arc at that
   moment, the decrement leaves count = 1 (temp only) and `close` returns normally.
4. When the retain closure for that item then drops the temporary Arc (count 1→0),
   `InodeHandle::drop` runs **synchronously in the scanning thread, under the held list
   mutex**: `kernel/core/src/fs/file/inode_handle.rs:537-541` → `let _ = self.unlock_flock();`
   → `flock_list.unlock(self)` → flock.rs:166 `self.inner.lock()` again.
5. `ostd/src/sync/mutex.rs:35` — `Mutex::lock` = `self.queue.wait_until(|| self.try_lock())`.
   The mutex is a plain `AtomicBool` + waitqueue; there is **no recursive-owner fast path**.
   `try_lock` fails forever (the bool was set to true by the same thread's outer guard), so
   `wait_until` enqueues a waker and parks (`ostd/src/sync/wait.rs:80-96`, `wait.rs:241-258`
   `wait_until_or_cancelled` → `Waiter::wait` → `do_wait` parks the task). The only wake
   source for that waitqueue is `Mutex::unlock`, which runs only when the outer guard drops —
   but the outer guard is owned by the now-parked thread itself. **Permanent self-deadlock.**

Reference-count precondition: the victim OFD (b) must hold exactly one fd-table entry and no
other strong reference at close time — `FlockItem.owner` is a `Weak` (flock.rs:18), the
waitqueue holds no owner reference, and `ClosedFile` cleanup releases POSIX range locks
through a different `RwMutex` (`range_lock/mod.rs:217-225`), not flock.

### Call chain from public APIs (reachability)

- `flock(fd_a, LOCK_UN)` on *any* fd of the inode (even one owning no lock) reaches the scan:
  `sys_flock` (syscall/flock.rs) → `get_file_fast!` → `InodeHandle::unlock_flock`
  (inode_handle.rs:242) → `FlockList::unlock` (flock.rs:164). Both OFDs share the same
  per-inode `FsLockContext`/`FlockList` (inode_ext.rs:11, 73-82; ramfs extension is
  inode-scoped, ramfs/fs.rs:163-164).
- `close(fd_b)` from another thread of the same process (shared file table) or another
  process reaches the fd-table ref drop: `sys_close` → `FileTable::close_file` →
  `drop(closed_file)` (close.rs:33).
- Natural interleaving required: thread A upgrades b's Weak; thread B's close decrements the
  fd-table ref; thread A drops the temp Arc. The vulnerable window is the temp Arc's
  lifetime inside one retain iteration (a pointer comparison + branch, ~tens of ns), so the
  natural race is narrow but a tight `flock(UN) ∥ open+flock+close` loop crosses it with
  non-negligible probability (est. on the order of 0.1-1% per racing close).

### Safeguards encountered (recorded, not dismissed)

- Expired-owner compensation: if the upgrade *fails* (owner already destroyed), the item is
  removed (flock.rs:179) — that path cannot deadlock because the destructor already ran (or
  runs in the closing thread, which parks briefly and is woken when the scanner releases).
- `get_file_fast!` keeps the *syscall's own* OFD alive (Cow::Owned clone for a shared table),
  so the syscall's own fd cannot hit count 0 mid-scan; only a *different* OFD's item is
  vulnerable.
- Extra dup alias, or any concurrent in-flight syscall holding a clone of b, keeps count ≥ 1
  → no destructor under the guard (this is the C12-alias control).
- No deferred-drop list, no recursive mutex fast path, no timeout in `wait_until`
  (verified across flock.rs / inode_handle.rs / mutex.rs / wait.rs).

### Trigger scenario (concrete)

1. Open file F twice in one multithreaded process (or two processes): fd_a (OFD a),
   fd_b (OFD b).
2. Thread B: `flock(fd_b, LOCK_EX|LOCK_NB)` (or SH) — inserts a FlockItem with owner
   `Weak(b)`.
3. Thread A: `flock(fd_a, LOCK_UN)` — takes the list mutex, retain upgrades b's Weak to a
   temporary Arc.
4. Thread B: `close(fd_b)` — drops the fd-table ref (count 2→1) and returns.
5. Thread A: retain closure for b's item ends — temp Arc dropped (count 1→0) —
   `InodeHandle::drop(b)` runs under A's guard → nested `FlockList::unlock` →
   `inner.lock()` → A parks forever holding the mutex. All subsequent `flock`/close-cleanup
   on this inode park forever.

## Model counterexample (what MC found)

`spec/output/round1-20261005T202037Z/MC_hunt_5_temporary_last_reference-bfs.log` (34 states):
t2 opens b, `flock(fd2, SH|NB)`; t1 `flock(fd1, UN|NB)` → `FlockListUnlockAcquire`
(listOwner=t1) → `FlockOwnerUpgrade` (refs b 1→2, temp=b) → `FlockOwnerKeep`; t2
`MCClose(fd2)` → `CloseFileTableUnlock` → `ClosedFileDrop` (refs b 2→1); t1
`ArcPutTemporary` (refs b→0, life="destroying", stack push resume=afterTemp) →
`InodeHandleDropEnter` → `FlockListUnlockEnter` (nested, same thread) → **NoRecursiveListWait
violated**. Controls (`MC_hunt_5_extra_alias_control`, `close_before`, `close_after`) had no
violation. The trace steps map 1:1 to the source audit above.

## Step 2: Developer-knowledge search

- Upstream issue tracker (gh, searched "flock", "flock deadlock", "recursive mutex",
  "reentrant", "Weak upgrade", "unlock scan", "InodeHandle drop", "temporary reference";
  issues and PRs, all states): only #3283 (stale wait-queue wakers — different mechanism),
  #1474/#1486 (lost wakeup / `None` condition — different), #1563 (signal interrupts),
  #2579 (configfs inode), #1497 (Mutex unlock/wake atomicity — different site). Nothing
  reports a destructor re-entering the flock-list mutex from an unlock-scan upgrade.
- Git history of the site: the `retain`+upgrade unlock scan predates 2024-10;
  `e5fd8e747` "Fix flock lost-wakeup bugs, replace RwMutex -> Mutex" (2024-10-24, issue
  #1474/PR #1486) is what introduced the current **non-recursive** `Mutex` — no comment
  about re-entrancy in the commit or the code. Later touches (7fbe997bb signal interrupts,
  renames) don't mention it.
- Comments/docs near the code: the `unlock` doc comment describes cleanup semantics only;
  no TODO/FIXME/"known issue" about the temp-Arc destructor or recursion.
- Tests: no in-tree test exercises concurrent `flock(UN) ∥ close` (regression tests cover
  fcntl range locks; gVisor `flock_test` is blocklisted). No test asserts this behavior is
  intended.
- Prior campaign runtime evidence (harness phase, not a finding document): the reviewed v12
  guest run `harness/evidence/attempt-20261005T165124-821788448/C11.log` (SMP=2, ramfs,
  instrumented pinned kernel, gate-assisted) captured the full chain on tid2 ending at
  `FlockListUnlockEnter selfHeld:true` entered from `InodeHandleDropEnter` (dtor=1002,
  resume `afterTemp`), with tid1's `ClosedFileDrop` showing `strong:1` and
  `SPECULA_END complete:false, prefix:true` — the worker syscall never returned. C12-alias /
  C12-before / C12-after controls completed with no violation.

## Step 3: Known-status / precedent

Searched the issue tracker (open + merged/closed PRs) on 2026-10-06 via `gh` and the
campaign's recorded 2026-10-04 tracker sweep (`analysis-evidence/github/*.json`). No public
issue/PR/CVE/advisory or prior dataset entry reports this mechanism (temporary owner
upgrade in the unlock scan → last-reference `InodeHandle::drop` under the held list mutex →
self-deadlock) at this site. Developer awareness (none found beyond unrelated flock fixes)
would not make it KNOWN anyway. → **Novelty: NEW**. Not code-review-sourced, so the
code-review × known pre-filter does not apply; proceed to Phase 2.

## Phase 2 plan (recorded for the reproduction)

- Environment: the campaign's private container `specula-flock-harness-20261005` holds the
  reviewed instrumented source `/source` and the already-built kernel ELF
  (`asterinas-osdk-bin.elf`, sha256 `d51c2205…`, identical to the build that produced the
  reviewed v12 traces). Guest runs need only a userspace initramfs rebuild (gcc + cpio) and
  `cargo osdk run --scheme flock` (QEMU, `-smp 2 -m 2G -accel kvm`) — no kernel rebuild, so
  the 10 GiB *build* admission threshold does not apply (host MemAvailable ~8.9 GiB at plan
  time; guest needs 2 GiB). Heavy lock is controller-held; not reacquired.
- Level 0: natural-race loop (A: `flock(fd_a, LOCK_UN)` spin; B: `open+flock(SH|NB)+close`
  spin), 90 s bounded, controller detects counter freeze, then a fresh `flock(LOCK_SH|LOCK_NB)`
  probe (must return instantly in a healthy system) to prove the flock-list mutex is
  permanently poisoned.
- Level 1: deterministic gate-assisted sequence (the C11 shape) via the reviewed prctl test
  hooks (`gate(b)`, boundary 2 = `FlockOwnerUpgrade`, release, boundary 3 = nested
  `FlockListUnlockEnter` selfHeld), plus the same LOCK_NB permanence probe and an alias
  negative control (C12-alias shape) to show the fixture is not generically broken.

# Phase 2: Reproduction record (executed 2026-10-06)

Test files: `repro/test_bugMC-2_flock_temp_ref_deadlock.c` (guest fixture),
`repro/test_bugMC-2_flock_temp_ref_deadlock.sh` (host driver).  Runs:
`repro/mc2-run-20261005T235447Z/` (MC2-L1, MC2-L1-ctl, MC2-L0) and
`repro/mc2-run-plain-20261005T235758Z/` (MC2-L0-plain).  Kernel: the reviewed
instrumented build at the pinned commit (ELF sha256 `d51c2205…`, identical to the
harness-phase build), guest SMP=2 ramfs, KVM; only the userspace initramfs was
regenerated per case (no kernel rebuild; 10 GiB build threshold not applicable).

## Escalation ladder

- **Level 0 (hooks fully disabled, MC2-L0-plain)**: pure public-API race
  (flock(UN) loop ∥ open+flock(SH|NB)+close loop), no trace slots registered, gate
  never armed.  After 128 unlock / 64 open-flock-close rounds both loops froze, but
  the fresh LOCK_NB probe *returned* (`flock(fd5, LOCK_SH|LOCK_NB) → 0`), proving the
  flock-list Mutex was free: the freeze was a *different* defect — a lost-wakeup /
  stale-waker hang of the family of known upstream issue #3283, parked in unrelated
  waits (tid2 never returned from flock, tid3 froze in `open`), not MC-2.  The
  probe correctly rejected it (`deadlock:false, mutex_poisoned:false`).  Documented
  as a separate observation; MC-2 did not trigger within its 128 bounded crossings
  (the pristine window is only a few tens of ns wide).
- **Level 0+observers (MC2-L0, no gate)**: same pure syscall race with the trace
  observers enabled (they lengthen the in-window critical section to ~0.5 µs but
  inject nothing and the gate stays disarmed).  **Hit after 3 unlock crossings**:
  full chain captured with zero dropped events (strong counts 3→2/1→… below),
  both racing syscalls never returned, LOCK_NB probe blocked 2000 ms →
  `deadlock:true, mutex_poisoned:true`.
- **Level 1 (MC2-L1, gate-assisted)**: deterministic reproduction of the exact C11
  shape using the campaign's reviewed prctl test gate (timing-only park inside the
  retain window).  Boundary 3 (nested `FlockListUnlockEnter`, `selfHeld:true`)
  observed; tid2's 10-event buffer ends at that event; flock never returned;
  LOCK_NB probe blocked → `deadlock:true, mutex_poisoned:true`.
- **Negative control (MC2-L1-ctl, C12-alias shape)**: identical schedule plus one
  extra dup alias.  All 8 assertions passed — unlock returned 0, the LOCK_NB probe
  returned `EAGAIN` instantly, unlock-via-alias and all closes returned;
  `deadlock:false`.  (Bonus contrast: the controller's later closes show
  `InodeHandleDropEnter → FlockListUnlockEnter` completing normally when the
  thread does *not* already hold the Mutex.)

## Level-0 (MC2-L0) interleaving with exact reference counts (TSC ns, CPU0 clock)

- 25141888972 tid2 `FlockOwnerUpgrade` ofd=3001 strong=2  (ClosedFile-held ref + scan temp Arc)
- 25141889291 tid3 `ClosedFileDrop`   ofd=3001 strong=1  (close returns; temp Arc is now the only ref)
- 25141910386 tid2 `ArcPutTemporary`  ofd=3001 strong=0 life=destroying (retain closure drops the last ref under the held Mutex; stack push resume=afterTemp)
- 25141938809 tid2 `InodeHandleDropEnter` → `FlockListUnlockEnter` **selfHeld=true** — tid2's final recorded event; the thread then parks inside `Mutex::lock` → `wait_until`.
- tid3 round-2 `TrySetLockEnter` with no `TrySetLockAcquire` (parked at the same Mutex); tid4 probe likewise blocked.

Both deadlocked runs match the MC counterexample step-for-step (states 26–34:
FlockListUnlockAcquire → FlockOwnerUpgrade → close/ClosedFileDrop → ArcPutTemporary
(strong→0) → InodeHandleDropEnter → nested FlockListUnlockEnter) and the same
root-cause code path.  The harm is permanent: only the parked thread's own guard
drop could wake it (mutex.rs:35 → wait.rs wait_until has no timeout and the only
wake source is that guard's `unlock`).
