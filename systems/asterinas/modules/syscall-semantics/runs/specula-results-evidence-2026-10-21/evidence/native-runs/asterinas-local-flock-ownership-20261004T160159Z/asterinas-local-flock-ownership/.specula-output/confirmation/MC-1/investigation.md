# MC-1 Investigation — Conflicting conversions retain the old shared flock

Phase 1 evidence record (no verdict here; verdict decided after Phase 2).

## Step 1: Code audit

### Cited sites (pinned commit 0c60537098f4c2949ad2d382aaf499de72263d76)

`kernel/core/src/fs/file/flock.rs` (HEAD, uninstrumented):

- flock.rs:114 — `fn try_set_lock(&self, req_lock: &FlockItem, waker: Option<&Arc<Waker>>)`: locks the
  list Mutex, then **first** runs the conflict search
  `list.iter().find(|l| req_lock.conflict_with(l))` (line 116). On conflict it enqueues the waker on
  the conflicting lock's waitqueue (line 118) and returns EAGAIN (line 120). Only the `else` branch
  (no conflict) reaches the same-owner replacement `list[idx] = req_lock.clone()` (line 124) or the
  append (line 127).
- flock.rs:147 — `let (waiter, waker) = Waiter::new_pair();` in `FlockList::set_lock`: the blocking
  path calls `try_set_lock(&req_lock, Some(&waker))` inside `waiter.pause_until(...)` (lines 148-155).
  A blocked conversion therefore parks **while the caller's old FlockItem stays in the list**.
- `FlockItem::conflict_with` (flock.rs:54-66) returns false for the same owner, so the caller's own
  old SH lock is never the blocker — but every *other* holder's lock is, and the caller's old SH
  item is only removed by the replacement in the no-conflict branch. There is no code path that
  removes the caller's old mode before or after a failed/blocked conversion.

### Call chain (public API → cited code, all normal usage)

`flock(2)` → `sys_flock` (kernel/core/src/syscall/flock.rs:12, public syscall dispatch; builds
`FlockItem::new(&file, type_)`, calls `inode_file.set_flock(flock, is_nonblocking)`) →
`InodeHandle::set_flock` (kernel/core/src/fs/file/inode_handle.rs:228; rejects only O_PATH, then
`fs_lock_context_or_init().flock_list()`) → `FlockList::set_lock` (flock.rs:139) →
`FlockList::try_set_lock` (flock.rs:114) / `Waiter::new_pair` (flock.rs:147).

Reachability: plain `flock(fd, LOCK_SH/LOCK_EX/LOCK_UN [| LOCK_NB])` calls on an ordinary
ramfs/tmpfs file through independent `open`s. No special state, no internal API, no fault.

### Trigger scenario (from the MC counterexample + Linux oracle)

Sequential (C05): A and B hold SH flocks on the same inode through independent opens. A requests
`flock(a, LOCK_EX|LOCK_NB)`. Asterinas: conflict search finds B's SH first → EAGAIN, A's old SH
stays in the list. B unlocks. C (a third independent open) requests `flock(c, LOCK_EX|LOCK_NB)` →
Asterinas still sees A's retained SH → EAGAIN. Linux v6.16.5 `flock_lock_inode`
(fs/locks.c:1101-1108): the same-file scan **deletes the caller's different-mode lock before** the
`find_conflict` loop (1109-1125), so a conflicting SH→EX|NB conversion returns EAGAIN with the old
SH already removed; after B unlocks, C's EX succeeds. The counterexample
(MC_hunt_2_conversion_oracle-bfs.log, C05, 80 states) violates the ConversionOracle invariant at
exactly this point: `items` retains `[SH@b, SH@a]` while `linuxMode` for `a` is "UN".

Concurrent (C06): A and B hold SH; A enters blocking `flock(a, LOCK_EX)`, B enters blocking
`flock(b, LOCK_EX)`. Asterinas: A registers on B's SH waitqueue and parks still holding A's SH; B
registers on A's SH waitqueue and parks still holding B's SH. Neither SH is ever released (both
owners are parked inside the syscall), so both waiters block forever — mutual deadlock, no signal
excluded per campaign scope. Linux: the first converter deletes its own SH before blocking; the
second converter deletes its own SH and finds nothing left to conflict with, so it succeeds
immediately; the first is woken when the second's deletion unlinks and wakes (fs/locks.c:866-870)
and then also succeeds. The C06 counterexample (MC_hunt_2_converters, ConvertersDrain, 57 concrete
states + stuttering) ends in the mutual-block state. Runtime prefix evidence for both cases exists
in the campaign's v10/v12 guest runs (harness/evidence/attempt-*/C05.log, C06.log: C05 shows C's
EX|NB returning EAGAIN with blocker `{owner:1001, mode:SH}` after B's unlock; C06 ends
`complete:false, prefix:true` with tid2 registered on q1002 and tid3 registered on q1001, both
parked).

### Safeguards encountered

- `FlockItem::conflict_with` excludes same-owner items (flock.rs:57-59): prevents self-conflict but
  also means the conflict branch never touches the caller's old item.
- `set_lock`'s `pause_until` retry loop (flock.rs:148-155): re-runs the whole conflict check on wake.
  It cannot resolve the C06 mutual block — each retry re-registers on the other owner's live SH.
- Signal interruption (`sys_flock` EINTR→ERESTARTSYS, syscall/flock.rs:33-35): a signal would break
  the C06 park, but signals are outside the modeled scope and ERESTARTSYS re-enters the same path.
  Not a mask for the sequential C05 divergence at all (EAGAIN is returned, not interrupted).
- Close of the last FD (`InodeHandle::drop` → `unlock_flock`, inode_handle.rs:539) removes the
  retained SH. That is the same "external unlock" my repro uses to drain the guest test; it does not
  fire on its own in either scenario.
- The gVisor flock conformance suite is blocklisted wholesale for the blocking cases
  (test/initramfs/src/conformance/gvisor/blocklists/flock_test, unchanged since the original flock
  commit ce2af1eb0); no listed test exercises conversion failure.

## Step 2: Developer-knowledge search

- `git log --follow -- kernel/core/src/fs/file/flock.rs`: ce2af1eb0 "Add flock and sys_flock"
  (2024-08-12, also created the flock blocklist), e5fd8e747 "Fix flock lost-wakeup bugs, replace
  RwMutex -> Mutex" (PR #1486, fixes #1474 — waiting on a None condition), 7fbe997bb "Fix
  range_lock and flock to support signal interrupts" (PR #1563), then import-path/refactor commits
  only (c2edfe05c, 3c94b3a24, 969be51af, 819e7a826, b9cfb5ccf). No commit mentions conversion
  semantics, upgrade, downgrade, or EAGAIN retention. The conflict-before-replacement order is
  unchanged since the original commit.
- Comments/docs: `try_set_lock`'s doc comment (flock.rs:108-113) documents conflict→EAGAIN and
  grant/replacement but says nothing about the caller's pre-existing mode during a failed
  conversion. No TODO/FIXME/known-issue comments near the site.
- Book: `book/src/kernel/linux-compatibility/README.md:96` marks syscall 73 `flock` as fully covered
  (💯), and `fully_covered.scml:123` lists all four flags. The project claims Linux-compatible flock
  semantics; nothing documents the conversion-failure divergence.
- Tests: no Asterinas-side flock conversion test exists (only the blocklisted gVisor suite; none of
  its 9 blocklisted names is a conversion case). No test asserts the retained-SH behavior as
  intended.

## Step 3: Known-status / precedent

Searched the upstream tracker (gh, account chinrw) — issues and PRs (open, closed, merged):

- Issues matching "flock": #3283 (open; stale-waker accumulation/wraparound in WaitQueue — different
  mechanism), #2931, #2579, #2826 (fcntl F_SETLK overflow), #2630, #1497, #1474 (old None-condition
  wait, fixed by PR #1486). None describes conversion retention at flock.rs.
- Issues matching "flock conversion|upgrade|downgrade|EAGAIN|lock mode|retention": no results.
- PRs matching "flock": #3576 (open, syscall restart refactor), #3500 (open, F_SETSIG), #3754, #3434
  (closed unmerged; stale-waker pruning for #3283 — different mechanism), #3113, #3086, #2927, #2786
  (SCML docs), #2603, #3009, #3028, #2966, #2984, #2563, #1486 (lost wakeup), #968 (original
  implementation), #1563 (signal interrupts), #1466 (range_lock wakeup). None touches conversion
  ordering.
- Upstream commits touching kernel/core/src/fs/file/flock.rs (GitHub API): b9cfb5ccf (2026-08-13) and
  819e7a826 (2026-08-11), both visibility/refactor renames — the two most recent in the pinned
  history. Nothing after the pin (0c6053709, 2026-10) changes the mechanism.

Conclusion: no existing report (issue, PR, CVE, advisory, or prior dataset entry) describes the
same mechanism at the same site → Novelty: NEW (search performed; covers recently merged/closed PRs,
not just open issues).

## Reproduction environment preflight (Phase 2 reuse check)

- Build artifacts: the campaign `source` tree (byte-identical to this finding's worktree: identical
  `git diff`, identical tracked index, identical untracked `ostd/src/flock_trace.rs`) holds the v12
  build: `target/osdk/asterinas-osdk-bin.elf` sha256 `d51c2205...` matches
  `harness/evidence/build-sha256.txt` from the successful build (attempt-20261005T165124,
  build.exit=0). ISO repacking per case explains the ISO hash drift; the kernel binary is unchanged.
- Known-good recipe: `harness/src/build.sh` + `harness/src/run_case.sh` (compile scenario → cpio →
  `cargo osdk run --scheme flock --initramfs ...` from /source/kernel with
  PATH+=/source/target/harness-osdk/debug). Guest: `-bios OVMF.fd -machine q35 -accel kvm -cpu host
  -m 2G -smp 2` (SMP ≥ 2 for concurrency claims). Container base image
  `asterinas/kernel-dev:0.18.1-20260926` (present locally). The v12 container itself was removed, so
  a fresh container is created from the same image; no kernel recompile is needed (source unchanged
  since the successful build), only ISO repack + QEMU boot.
- Resources: the heavy lock is held by this campaign's controller run (the dispatcher of this
  confirmation), so the lane's allocation is active; not reacquired (per the phase-worker rule).
  MemAvailable at preflight ≈ 9.9 GiB — below the 10 GiB *kernel-build* admission threshold, which
  does not apply (no build; guest is capped at 2G + QEMU overhead). /dev/kvm present. No semantic
  change is made to model/spec/harness/instrumentation, so the corrective review gate does not
  apply; this is a new confirmation-only repro test.
