# CR-3 Investigation — "Last descriptor removal is not final OFD release" (Scenario 4)

Phase 1 evidence record. No verdict here (per skill); verdict decided after Phase 2.

## Step 1: Code audit

### Cited sites (worktree at pinned 0c60537098f4c2949ad2d382aaf499de72263d76, with the campaign's reviewed trace instrumentation in syscall/flock paths)

| Site | What it does |
|---|---|
| `kernel/core/src/fs/file/file_table.rs:196-205` (`FileTable::close_file`) | Removes the fd's entry from the table and wraps the removed `Arc<dyn FileLike>` in a `ClosedFile`. It does **not** destroy the file object; it only drops the table's strong reference when `ClosedFile` is dropped. Comment documents the POSIX-vs-flock distinction: range locks are dropped on ANY close per fcntl(2); flock is deliberately not released here. |
| `kernel/core/src/fs/file/file_table.rs:274-298` (`ClosedFile` + `Drop`) | Holds one strong `Arc<dyn FileLike>`. `Drop` calls only `release_range_locks` (POSIX). `#[must_use]` doc: "Dropping this value may block, so it must be dropped after releasing the file-table lock" — this is the pending-cleanup window between fd removal and final reference drop. |
| `kernel/core/src/fs/file/file_table.rs:337-364` (`get_file_fast!`) | Shared file table (CLONE_FILES threads) → slow path: read lock, `Arc::clone`, release lock; the syscall then operates on its own strong reference for the whole syscall duration, including while blocked. Unshared table → borrowed fast path (no extra ref; safe because no other thread can reach the table). |
| `kernel/core/src/syscall/close.rs:22-35` (`sys_close`) | Under the table write lock: EBADF check + `close_file`. Then drops `closed_file` **after** releasing the table lock, i.e. final cleanup runs synchronously inside `close()` before it returns. Comment: "We don't mind the races between closing the file descriptor and using the file descriptor, because such races are explicitly allowed in the man pages. See the 'Multithreaded processes and close()' section in close(2)." |
| `kernel/core/src/fs/file/inode_handle.rs:536-541` (`Drop for InodeHandle`) | The final flock release: `unlock_flock()` runs only when the last strong `Arc` to the OFD drops — i.e. after the fd table entry, the in-flight syscall reference, and any pending `ClosedFile` are all gone. |

Supporting facts:
- `FlockItem.lock.owner` is a `Weak<dyn FileLike>` (`flock.rs:16-21`): the flock list never keeps an OFD alive; it is a non-owning registration whose death is cleaned by `InodeHandle::drop` (primary) or the dead-Weak backstop in `FlockList::unlock`'s `retain` (`flock.rs:249-282`, the `else { false }` branch).
- `dup`/`dup2` (`file_table.rs:168-186`): the alias's table entry holds a **clone of the same `Arc`** — same OFD, so closing one alias cannot drop the last strong reference while the other alias remains.
- Threads: `kernel/core/src/process/clone.rs:739-746` — `CLONE_FILES` shares the same `RwArc<FileTable>` (→ `get_file_fast!` Arc-clone slow path); fork without `CLONE_FILES` copies entries (`fork_from`), each still holding a strong `Arc` to the same OFD.
- `sys_flock` (`syscall/flock.rs:14-48`): captures the file via `get_file_fast!`, then `set_flock`/`unlock_flock` on the `InodeHandle`; blocking happens inside `FlockList::set_lock` → `Waiter::pause_until`, with the syscall's owned `Arc` alive throughout.

### Call chain / reachability

Fully reachable through the public syscall interface with an ordinary file and two threads:
`flock(fd, LOCK_EX)` (thread T1, shared table) → `get_file_fast!` Arc clone → blocks in `FlockList::set_lock` → meanwhile `close(fd)` in T2 → `FileTable::close_file` (fd number freed) → `drop(ClosedFile)` (range locks only) → Arc strong count ≥ 1 (T1's syscall ref) → `InodeHandle` NOT destroyed → T1 still blocked, conflict unchanged → blocker released → T1's `pause_until` re-runs `try_set_lock`, acquires, returns 0 → syscall locals drop → last Arc drops → `InodeHandle::drop` → `unlock_flock` → item removed, waiters woken.

### Linux contract (the oracle)

- flock(2): "Locks created by flock() are associated with an open file description… duplicate file descriptors (created by, for example, fork(2) or dup(2)) refer to the same lock… the lock is released either by an explicit LOCK_UN operation on any of these duplicate file descriptors, or when all such file descriptors have been closed."
- close(2) CAVEATS, "Multithreaded processes and close()": "On Linux… the blocking I/O system call holds a reference to the underlying open file description, and this reference keeps the description open until the I/O system call completes. Thus, the blocking system call in the first thread may successfully complete after the close() in the second thread."

So the three behaviors the finding hypothesizes — (a) alias's flock preserved across the other descriptor's close, (b) captured blocking syscall completing after its own FD is removed rather than returning EBADF, (c) final cleanup completing once external references drain — are each **required Linux behavior** (the analog of Linux `struct file` refcounting: fdget → close → fput → __fput → locks removal). A deviation in **any** direction would be a real bug:
- flock dropped early on close of one alias (violates OFD association),
- flock surviving the return of the final `close()`/draining of references (stale item → later lockers permanently denied; "expired ownership" not removed),
- blocked flock returning EBADF/EINTR because its fd was closed,
- final destructor never running (blocked syscall never completes or lock never cleaned).

### Safeguards / masking candidates noted (not dismissed, to be exercised in Phase 2)

- The dead-`Weak` backstop in `FlockList::unlock`'s `retain` removes expired owners — but it runs only when some thread calls `unlock_flock`/`FlockList::unlock`; it is not a periodic GC. `InodeHandle::drop` → `unlock_flock` is the primary release.
- `FlockItem::drop` wakes all waiters (covers release via replacement in `try_set_lock` too).
- The "temporary owner reference" (a transient `Weak::upgrade` strong ref inside the `retain` closure of `FlockList::unlock`) is Scenario 5 / MC-2's mechanism and is out of scope for CR-3 except where the final destructor fails to complete (my test asserts the destructor DOES complete by observing post-drain lockability).

## Step 2: Developer-knowledge search

- `git log` on the sites: `ClosedFile` introduced by e631da203 "Introduce ClosedFile to avoid breaking the atomic mode" (defer blocking cleanup out of the table lock). `InodeHandle::drop → unlock_flock` since 1bf5b398d (Dec 2025, "Remove inode_handle/dyn_cap.rs and HandleInner"). flock history: ce2af1eb0 (introduce), e5fd8e747/#1486 (lost-wakeup fix), 7fbe997bb (signal interrupts). Nothing touching close-vs-flock lifetime.
- Comments: close.rs's comment explicitly accepts close-vs-in-use races and cites close(2); file_table.rs's comment documents the deliberate range-lock-vs-flock release distinction. Both show the deferral is a design decision modeled on Linux, not an accident.
- Tests: no flock lifetime regression test in the tree — only trivial `flock(LOCK_SH)/(LOCK_UN)/(LOCK_EX)` in `test/initramfs/src/regression/io/file_io/access_err.c:83-86`; gVisor `flock_test` is blocklisted for exfat only. Nothing asserts the close/alias/in-flight contract.
- No TODO/FIXME about flock release timing at these sites.

## Step 3: Known-status / precedent

Issue-tracker + git-history search (GitHub asterinas/asterinas, including recently closed issues and merged PRs):
- #1474 / PR #1486 (Oct 2024): flock lost-wakeup (waiter wake condition) — different mechanism, different site (`set_lock` wait predicate, not OFD lifetime on close).
- PR #1217 (Aug 2024): fcntl range locks released on any fd close — the POSIX side of the distinction; different mechanism.
- No issue, PR, CVE, or advisory reports "last descriptor removal is not final OFD release" / flock kept alive by dup alias, in-flight syscall reference, or pending ClosedFile at these sites.
→ Novelty: NEW (nothing found reporting THIS mechanism at THIS site).

Not dropped: this is a code-review-sourced finding and no prior report exists → proceed to Phase 2.

## Trigger scenario constructed for Phase 2

All at Level 0 (public syscalls only, threads to force the shared-table `get_file_fast!` Arc-clone path):

- **A (alias preservation)**: `open` fdA, `flock(fdA,LOCK_EX)`, `dup`→fdB, `close(fdA)` → independent `open` fdC must see the lock still held (LOCK_EX|LOCK_NB → EAGAIN); `flock(fdB,LOCK_UN)` (release via the surviving alias) must succeed; `close(fdB)` (last descriptor) → fdC must then acquire.
- **B (in-flight reference after close)**: fdA holds LOCK_EX; thread T1 does blocking `flock(fdD,LOCK_EX)` (independent open; T1 blocked holding an Arc ref); main thread `close(fdD)`; re-`open` (number reuse check — new OFD is independent, still denied); release blocker via `flock(fdA,LOCK_UN)`; T1's syscall must return **0** (not EBADF/EINTR) — Linux documented behavior; after T1 joins, the acquired-but-fd-less lock must be gone (fdE `LOCK_EX|LOCK_NB` succeeds — no stale "expired ownership").
- **C (synchronous final release in close)**: fdA holds LOCK_EX, no aliases, no in-flight refs; `close(fdA)`; immediately `open` fdC and `flock(fdD',LOCK_EX|LOCK_NB)` must succeed — final cleanup (ClosedFile drop → InodeHandle::drop → unlock_flock) must complete within the close syscall.
- **D (release-by-close wakes the deferred waiter)**: as B, but the blocker is released by `close(fdA)` itself (not LOCK_UN): the pending ClosedFile → final drop → unlock_flock → wake must let T1 complete and then the lock must be fully gone after T1's reference drains.

---

# Phase 2: Reproduction record (appended)

Test: `repro/test_bugCR-3_ofd_ref_lifetime.c` + driver `repro/test_bugCR-3_ofd_ref_lifetime.sh`
Executed: 2026-10-06, output dir `repro/cr3-run-20261006T014446Z` (final 45-check version; an earlier identical 40-check version ran before the two extra delete-path cases were added: `repro/cr3-run-20261006T014153Z`, also all-PASS ×3).

Environment: campaign's reviewed container `specula-flock-harness-20261005` (kernel ELF sha256 d51c220500302e72765e313e754fc780d89cfd8ddbacfea4a40f853c122d1dbb = reviewed harness build, hash-gated), Asterinas guest via `cargo osdk run --scheme flock` (x86_64, OVMF, 2 vCPU / 2 GiB — SMP≥2 for concurrency claims), no kernel rebuild (initramfs-only). Linux control: same static binary on the container's Linux on tmpfs. All runs bounded by `timeout`; driver exits recorded in `driver.log`.

## Escalation ladder

- **Level 0 (pure black-box)** — the entire hypothesized mechanism was exercised through public syscalls only (open/dup/fork/close/close_range/dup2/flock; pthreads = CLONE_FILES shared file table, forcing the `get_file_fast!` Arc-clone slow path for the blocked in-flight syscalls):
  - `case_alias_preservation` (A1/A2): OK — alias's flock survives close of the other descriptor (independent open denied EAGAIN), LOCK_UN via the surviving alias works, file then free.
  - `case_alias_last_close_releases` (A3): OK — close of the last alias releases the lock synchronously within close().
  - `case_single_close_releases` (C): OK — single-descriptor close releases synchronously (ClosedFile→InodeHandle::drop→unlock_flock completes inside sys_close).
  - `case_closed_fd_ebadf` (E0 control): OK — with no in-flight reference, flock on the closed fd gives EBADF (so EBADF applies only to the never-captured case, exactly the contrast CR-3 hinges on).
  - `case_inflight_close` (B ×3, D ×3): OK on every iteration — close of the waiter's own fd while blocked succeeds (fd number observed REUSED by a subsequent open in all 6 iterations, proving real table removal); the re-opened independent OFD still sees the blocker; after blocker release (LOCK_UN in B, close() in D) the blocked syscall **completed with ret=0 within 2 s** (never EBADF, never a hang); after it returned and its reference drained, the lock it transiently acquired was gone (independent open acquires — no stale/expired ownership).
  - `case_fork_reference` (G): OK — the forked child's inherited entry keeps the locked OFD alive across the parent's close; after child exit drains the last external reference the flock is gone (also no stale lock).
  - `case_close_range_releases` (C2): OK — close_range removal path releases synchronously.
  - `case_dup2_replacement_releases` (C3): OK — dup2 replacement of the last descriptor of a locked OFD releases that OFD's flock in-syscall; the replacing alias is functional.
  Result: **0 divergences from the Linux contract.** Linux control (real kernel, tmpfs): 45/45 PASS — the encoded expectations are the real Linux contract. Asterinas guest: 45/45 PASS in 3/3 runs (and 40/40 in the 3 earlier runs). Host NixOS runs also 45/45 ×3 (fixture self-validation).
- **Level 1–3**: not escalated — there was no symptom to widen. The deferral races the finding hypothesized were additionally covered by the campaign's targeted MC hunts (C03 alias preservation, C10 in-flight-after-close), which exhausted their state graphs with no violations; nothing indicates a window where the contract breaks.

## Answers to the reproduction checklist (routing honesty)

1. Level 0 alone fully exercised the mechanism through real public syscalls and threads — but produced **no divergence**; there was nothing to trigger.
2. n/a (no Level 2/3 state injection used).
3. **No consumer observes a wrong outcome.** The alias holder, the blocked syscall's caller, and the post-drain third-party contender each observe exactly the Linux-mandated result (verified against the real-Linux control): preserved lock, completed syscall, released file. The deferral itself is a mechanism description, not a consequence.
4. There is no bad state: the deferred destruction is bounded (syscall end / table-entry removal / process exit) and provably completes — post-drain lock acquisition succeeded in every drain scenario (6 in-flight iterations, fork exit, close_range, dup2).

## Verdict reasoning

The finding is a hypothesis about whether the reference accounting behind "last descriptor removal ≠ final release" breaks the Linux-visible contract. Phase 1 established the mechanism is the deliberate port of the Linux `struct file` lifetime (comments citing close(2)/fcntl(2); ClosedFile/InodeHandle-drop design; Weak-owned flock items). Phase 2 exercised the full hypothesized matrix at Level 0 on the pinned Asterinas build and on real Linux as the oracle: every behavior — alias preservation, blocked syscall completing with 0 after its own fd's removal (with observed fd-number reuse), synchronous release inside close()/close_range()/dup2(), post-drain removal of expired ownership, EBADF only in the reference-never-captured case — matches the Linux contract, on both systems, across repeated runs. The targeted MC hunts found no violations. No consumer consequence exists; nothing is masked (the behavior is correct, not harm hidden by a guard). Not DROPPED (tracker/git search found no prior report of this mechanism, so the code-review × known pre-filter does not apply → the finding had to be reproduced to be settled, and it was).

→ **FALSE POSITIVE**: the hypothesized deviation is not a defect. The deferral mechanism exists and is live exactly as described, and it is the documented, intended, Linux-conformant design. (The descriptor-to-destructor chain's real known defect is Scenario 5's temporary-owner-reference mechanism, carried by MC-2 as a separate finding, outside CR-3's scope.)
