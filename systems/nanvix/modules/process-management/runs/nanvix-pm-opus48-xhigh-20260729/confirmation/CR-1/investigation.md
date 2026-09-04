# CR-1 Investigation

Finding: `join_thread` can lose a thread's exit status / leak the zombie slot on a bad status pointer.
Source: code-review. Cited site: `src/kernel/src/pm/kcall/join_thread.rs:70`.

## Step 1 — Code audit (facts)

### The kcall wrapper (the defect site)
`src/kernel/src/pm/kcall/join_thread.rs:57-78`:
```rust
pub unsafe fn join_thread(pid, arg0, arg1) -> Result<ExitStatus, SleepError> {
    let tid = ThreadIdentifier::try_from(arg0)?;         // arg0 = user tid
    let retval: *mut ExitStatus = arg1 as *mut ExitStatus; // arg1 = USER status pointer (line 70)
    let status: ExitStatus = ProcessManager::join_thread(pid, tid)?;   // (A) REAPS the zombie
    pm::copy_to_user::<ExitStatus>(ProcessManager::get_mut(), pid, retval, &status)
        .map_err(SleepError::Generic)?;                  // (B) may fail; NO rollback of (A)
    Ok(ExitStatus::ok())                                  // returns 0, NOT the real status
}
```
Order is: **reap first (A), copy second (B)**. On a bad `retval`, (B) fails and returns `Err`,
but (A) has already consumed the zombie. There is no rollback and no way to re-obtain the status.

### (A) consumes the zombie irreversibly
`ProcessManager::join_thread` (`process/manager/unsafe.rs:742-769`):
- `try_join_thread` -> `RunningProcess::try_join_thread` (`process/state/running.rs:561-566`)
  **removes** the zombie from the process's zombie list (`remove_if`), returning it.
- `harvest_zombie_thread` (`unsafe.rs:654-709`) reclaims stacks and calls
  `tm.on_thread_reaped()` (`thread/mod.rs:272-282`) which **decrements `live_count`** (frees the slot).
After (A) returns, the zombie no longer exists in any queue and its slot accounting is released.

### The real status only travels through the user pointer
On success the kcall returns `Ok(ExitStatus::ok())` = `ExitStatus(0)` (`libs/sys/.../exit_status.rs:63`).
The dispatcher (`kcall/dispatcher.rs:82-83`) puts that 0 in the syscall return register.
=> The **only** channel for the thread's real exit status is the `copy_to_user` write to `retval`.
If (B) fails, the status is irretrievably lost.

### `copy_to_user` on a bad pointer — TWO distinct outcomes
`copy_to_user` -> `vmcopy_to_user` -> `ProcessState::copy_to_user_unaligned` ->
`Vmem::copy_to_user_unaligned` (`mm/virt/vmem.rs:1482`), a two-pass (dry-run + real) copy.
User space = `[USER_BASE=0x40000000, USER_END=0xf0000000)` (`libs/config/src/lib.rs`).

1. **`retval` outside user range (e.g. NULL=0, or any kernel-range/oversized addr):**
   dry-run's `is_user_region(dst)` is false -> returns `Err(BadAddress)` **gracefully**
   (`vmem.rs:1357-1364`). The kcall returns `Err`. Zombie already reaped =>
   **exit status lost, join un-retriable.** (This is exactly the finding's claim.)

2. **`retval` inside user range but unmapped (e.g. 0x60000000 = USER_MMAP_BASE):**
   dry-run does NOT check the mapping (`find_user_frame` is only in the non-dry-run pass).
   The real pass runs `resolve_cow_for_region` (returns `Ok` for an unmapped page via
   `resolve_cow_at` -> `Ok(false)`, `vmem.rs:1056-1058`), then reaches
   `find_user_frame(vaddr)` which **panics** (`vmem.rs:1414-1422`). => user-triggerable
   **kernel panic (DoS)**, again after the zombie is already reaped.
   Note the doc on `is_user_region_writable` (`vmem.rs:472-481`) confirms callers are expected
   to pre-check user-controlled destinations; `join_thread` does not.

Both outcomes stem from the same defect (reap-before-copy, no validation/rollback).

### Reachability
`arg1` flows unmodified from the user syscall (`kcall/dispatcher.rs:60` `do_kcall(.., arg1, ..)`).
A user program calling `thread_join(tid, &status)` with an invalid `&status` reaches this directly.
`ProcessManager::join_thread` has no kernel-process guard, so any running process can join.

## Step 2 — Developer-knowledge search
- `git log` on `join_thread.rs`: commits `d6d48c1e8 Thread Create/Exit/Join`,
  `0203a2c83 Join Thread from Dispatcher`, `b15feb11f Blocking join_thread`,
  `9b033522e Use ExitStatus`, `ef77f89d4 Improve Safety`, `7f7da1d47 Safe Conversions`,
  `d902a4066 Fixing Log Statements`. None addresses copy-after-reap ordering / bad-pointer rollback.
- No comment / TODO / FIXME at the site acknowledges the ordering hazard.
- No test sets up join-with-bad-pointer. `is_user_region_writable` exists as the intended
  pre-write validation helper but is not used by `join_thread`.
=> No developer report of THIS mechanism found.

## Step 3 — Known-status / precedent
- Searched git history / commit messages / in-tree comments: no issue/PR/commit reporting
  "join_thread loses status on bad pointer" or the reap-before-copy ordering.
- (No access to other findings / bug-report per instructions.)
=> Novelty: NEW (searched history + comments; nothing reports this mechanism at this site).

## Reproduction plan (Phase 2)
Level 2 state injection driven through the REAL, unmodified kcall:
- Inject a joinable zombie thread (known status S) into the running process — the exact state
  produced by a normal `thread_create` + child `thread_exit` — with correct `live_count`
  accounting (allocate a real tid + `commit_next_tid`).
- Positive control: `ProcessManager::join_thread(pid, tid)` (inner fn) returns `Ok(S)` — proves the
  zombie is joinable and carries S, and that the status IS available at the wrapper boundary.
- Bug: full kcall `pm::join_thread(pid, tid, arg1=0)` (NULL, graceful BadAddress) -> `Err`;
  then retry `pm::join_thread(pid, tid, ...)` -> `Err(NoSuchProcess)` => status S permanently lost,
  join un-retriable. This is outcome (1) above.
Build test kernel + uservm, boot under QEMU (known-good recipe from prior repros).

---

## Step 3 (updated) — issue-tracker / upstream search (concrete)
- Upstream `nanvix/nanvix` default-branch `join_thread.rs` (blob SHA `0fa519e6...`)
  has the **identical** reap-before-copy ordering — unfixed upstream.
- Issue/PR search (`join_thread`, `copy_to_user join retval`, `join exit status
  lost`, `join_thread retval EFAULT`): the only related hits are **#2344 /
  PR #2345 "Defer detached zombie reap"** — a *different* mechanism (detached-thread
  `exit_thread` drops the zombie while a raw `ctx` pointer is still needed by the
  context switch → use-after-free). Different site (`running.rs exit_thread`),
  different consequence (memory corruption), already fixed by deferring reap. It
  does NOT touch the join-path reap-before-copy ordering.
- No report of THIS mechanism at THIS site → **Novelty: NEW**.

## Reproduction result — REPRODUCED (Level 2 in-kernel test)
Test: `repro/test_bugCR-1_join_reap_before_copy.rs` (wired as
`pm::process::state::join_status_loss_test`, run via `make run-kernel-tests`).
It replays the kcall's exact chain — real `try_join_thread` (reap) → real
`ZombieThread::harvest` → real `copy_to_user_unaligned` — on a state reachable via
create+exit. Real serial output:
```
[ERROR][vmem] copy_to_user_unaligned_unchecked(): destination memory region does not lie entirely in user space (dst=0x00000000, src=0x001c6948, size=4)
[INFO][join_status_loss_test] buggy order: copy_to_user(retval=NULL) failed as expected: Err(BadAddress ...)
[ERROR][running] try_join_thread(): "thread not found" (state={ pid: 1 })
[INFO][join_status_loss_test] BUG CONFIRMED (CR-1): after the failed retval copy, join tid=2 is un-retriable; exit status 42 is permanently LOST
[INFO][join_status_loss_test] correct order: exit status 42 is preserved and the thread remains joinable
[INFO][join_status_loss_test] passed: test_join_thread_loses_status_when_retval_copy_fails
```
Buggy order (reap→copy) loses status and the retry returns `NoSuchProcess`
("thread not found"); correct order (copy→reap) preserves it. Consequence is
permanent (no path re-creates the zombie/status). Note: `live_count` IS correctly
decremented, so the demonstrated harm is **lost status / un-retriable join**, not
a slot leak (the finding's "may be misaccounted" did not reproduce as a leak).

---

## Independent verification (this confirmation run)
Reproduced with an in-kernel test module `join_status_test`
(`src/kernel/src/pm/process/state/join_status_test.rs`), wired into
`pm::process::state::test()` (feature="test"). It drives the REAL reap
(`RunningProcess::try_join_thread` + `ZombieThread::harvest`) and the REAL copy
(`ProcessState::copy_to_user_unaligned` -> `Vmem::copy_to_user_unaligned`) on a
running process owning a joinable zombie sibling tid=2 (status 42) — the exact
state `create_thread(2)`+child `exit_thread(42)` produces.

Build: `make all-test-kernel all-uservm`. Boot: `./bin/uservm.elf -kernel
bin/kernel-test.elf -kernel-args test_magic=0xDEADBEEF` (exit 0, boots to
"hello, world!"). Runner: `repro/test_bugCR-1_join_reap_before_copy.sh` (exit 0).
Real serial output:
```
[ERROR][vmem] copy_to_user_unaligned_unchecked(): destination memory region does not lie entirely in user space (dst=0x00000000, src=0x001c6338, size=4)
[INFO][join_status_test] buggy order (reap->copy): copy_to_user(retval=NULL) failed as expected: Error { code: BadAddress, ... }
[ERROR][running] try_join_thread(): "thread not found" (state={ pid: 1 })
[INFO][join_status_test] BUG CONFIRMED (CR-1): after the failed retval copy, join tid=2 is un-retriable (NoSuchProcess); exit status 42 is permanently LOST
[INFO][join_status_test] correct order (validate->reap): NULL retval rejected up front; zombie NOT reaped
[INFO][join_status_test] correct order: exit status 42 preserved and thread still joinable
```
Escalation level reached: Level 2 (real-API-reachable zombie precondition + real
NULL `retval` trigger; real reap/copy functions unmodified). Consequence is
permanent — no path re-creates the zombie/status; the control proves the fix
(validate-before-reap) preserves it. Note: `on_thread_reaped` IS called, so the
demonstrated harm is lost status / un-retriable join, not a slot leak.
Verdict: REPRODUCED. Source: Code Review. Novelty: NEW.
