# MC-4 Investigation

Finding: Kernel panic — `do_exit` dereferences the emptied running slot during rendezvous cleanup.
Source: model-checking (counterexample `spec/output/MC_hunt_MC-4.out`, invariant `MCRunningValidAtWakeup`).

## Step 1: Code audit (facts)

### Cited sites (worktree `src/kernel/src/pm/process/manager/mod.rs`)
- `do_exit` (line 2103). Order of operations:
  - `2116`: `let running_process: RunningProcess = self.take_running();`
  - `2124-2126`: kernel-pid guard (`panic!("kernel process cannot exit")`).
  - `2130`: `self.cleanup_rendezvous(running_process.state().pid(), "do_exit");`
- `take_running` (2780-2783): `self.running.take().expect("the kernel should be running")` → sets `self.running = None`.
- `get_running` (2785-2788): `self.running.as_ref().expect("the kernel should be running")` → **panics if `running` is `None`**.
- `cleanup_rendezvous` (2766-2778): calls `crate::ipc::rendezvous::cleanup_process(pid)` → for each orphaned tid, `self.do_wakeup(tid)`.
- `do_wakeup` (1821) → `try_wakeup_thread` (1852).
- `try_wakeup_thread` (1854): **first statement** is `if self.get_running().find_thread(tid).is_some()` → `get_running()` panics before any other check.

### Panic call chain (during `do_exit`)
```
do_exit
  2116 take_running()              -> self.running = None
  2130 cleanup_rendezvous(pid)
        -> ipc::rendezvous::cleanup_process(pid)  returns [counterpart_tid, ...] (non-empty)
        -> do_wakeup(counterpart_tid)
             -> try_wakeup_thread(counterpart_tid)
                  -> 1854 get_running()          -> self.running.as_ref().expect(..) PANIC
```
Panic message: `the kernel should be running` (kpanic).

### Who produces an orphaned counterpart tid — `ipc/rendezvous.rs::cleanup_process` (651)
`cleanup_process(pid)` scans the global PENDING lists and collects tids of **counterpart threads in OTHER processes**:
- pending push with `push.dst_pid == pid` (a thread in another process pushing TO the exiting process) → collect `push.tid` (666-670).
- pending pull with `pull.src_pid == pid` (a thread in another process pulling FROM the exiting process) → collect `pull.tid` (686-691).
Entries are registered by the real IPC path `do_push` (406) / `do_pull` (576) when a pusher/puller blocks waiting for its counterpart.

So: whenever a thread in process A is blocked in a rendezvous push/pull whose counterpart is process B, and B exits, `cleanup_process(B)` returns A's tid → `do_wakeup` → `get_running()` panics.

### Reachability
- `do_exit` is reached from the real `exit` kernel call: `ProcessManager::exit` (manager/unsafe.rs:286-299) → `do_exit`.
- A pending rendezvous counterpart entry is produced by the real push/pull kcalls (feature commit 70b7691454 added push/pull IPC + the `cleanup_rendezvous` call in `do_exit`).
- The panic requires only: (a) `running == None` (guaranteed by `take_running()` at 2116 for every non-kernel exit), and (b) >=1 counterpart entry targeting the exiting pid. Both are normal, non-adversarial states. `get_running()` panics BEFORE `find_thread`, so the counterpart tid need not even still be alive.

### Contrast with `terminate` (2268) — finding's claim verified
`terminate(pid)`:
- 2277: refuses if the target is the running process (`self.running.is_some() && get_running().pid()==pid`).
- 2285: `self.cleanup_rendezvous(pid, "terminate")` — but `self.running` is **still `Some(..)`** (the caller, a different process). It never calls `take_running()`.
Therefore during `terminate`, `get_running()` in `try_wakeup_thread` succeeds → no panic. The bug is specific to `do_exit`'s ordering (null-running-then-cleanup).

## Step 2: Developer-knowledge search (evidence)
- `git blame`: the buggy call `cleanup_rendezvous(.., "do_exit")` at 2130 was added in commit **70b7691454** ("[kernel] F: Add rendezvous push/pull IPC kernel calls", ppenna, 2026-02-24). `take_running()` at 2116 predates it (2024). The bug was introduced by inserting the cleanup AFTER the running slot is emptied. Commit message shows no awareness of the ordering hazard.
- No code comment / TODO / FIXME at the site acknowledges the `running == None` hazard.
- Related issue **#2351** ("Rendezvous push/pull IPC can deadlock if a peer hangs or dies", closed 2026-05-17) is the ENHANCEMENT that MOTIVATED `cleanup_rendezvous`: it asks the kernel to scan for threads blocked in push/pull targeting a dying process and unblock them. It describes the *deadlock* (missing wakeup) — the OPPOSITE failure mode. It does NOT report the panic-during-cleanup that MC-4 identifies.

## Step 3: Known-status / precedent
- Searched nanvix/nanvix issue tracker:
  - `rendezvous in:title` → #2351 (deadlock enhancement), #2904/#2905 (timeouts), #1530 (test race). None report the `do_exit`/`running==None` panic.
  - `cleanup_rendezvous panic`, `do_exit running None`, `get_running panic exit` → 0 results.
- `git log --all` grep for `cleanup_rendezvous` / `take_running` / `do_exit panic` → no fix commit.
- The mechanism (peer-death unblock calling `get_running()` after `take_running()` nulled it, in `do_exit`) is not reported by any issue/PR. → **Novelty: NEW.**

## Preliminary trigger scenario (for Phase 2)
1. Process A thread pushes/pulls to/from process B via the rendezvous IPC kcall; no counterpart present → A registers a pending entry (dst_pid/src_pid = B) and blocks.
2. Process B runs and calls `exit()` → `ProcessManager::exit` → `do_exit`.
3. `do_exit` `take_running()` → `running = None`; then `cleanup_rendezvous(B)` finds A's tid and calls `do_wakeup(A_tid)` → `try_wakeup_thread` → `get_running()` → **kernel panic (DoS)**.

Source = MC (real counterexample). Not eligible for the code-review x known pre-filter. Proceed to Phase 2.

### Novelty verification (my own searches, Phase-1 Step 3)
- `git blame` line 2130: `cleanup_rendezvous(.., "do_exit")` introduced by commit **70b7691454**
  (2026-02-24, "Add rendezvous push/pull IPC kernel calls"); `take_running()` @2116 predates it
  (2814175155, 2024-12-24). `git log -S cleanup_rendezvous` on manager/mod.rs → only the introducing
  commit; **no fix commit** exists in history.
- Recent commits touching `manager/mod.rs` (job control, signal delivery, etc.) contain no fix for
  a do_exit/running==None panic.
- Web/issue search: **#2351** = rendezvous push/pull *deadlock* if a peer dies (the enhancement that
  motivated cleanup_rendezvous — OPPOSITE failure mode: missing wakeup, not panic). **#2344** =
  use-after-free in the *detached-thread* exit path (different site/mechanism). Neither reports the
  `take_running`-before-`cleanup_rendezvous` `get_running()` panic in `do_exit`.
- Conclusion: **Novelty = NEW** (no prior report for THIS mechanism at THIS site).

## Phase 2 — Reproduction plan (executed)
- Vehicle: in-kernel test harness booted by the standalone UserVM — drives the REAL `ProcessManager`
  singleton + REAL `ipc::rendezvous` PENDING lists. `make all-test-kernel` + `make all-uservm`,
  `scripts/run-uservm.py bin/kernel-test.elf 120 --wait-for-string "hello, world!"`. Baseline boot
  prints "hello, world!" (all in-kernel tests pass) — CONFIRMED before any change.
- Level 0/1: not applicable in isolation — the panic needs a rendezvous counterpart targeting the
  exiting process; timing alone does not create it. Level 2 used.
- Level 2 (state injection consistent with CE steps MCRegisterRendezvous + MCExitTakeRunning):
  1. Register a real pending-push counterpart (dst_pid = victim) via a test-only shim that inserts
     exactly the `PendingPush` a real blocking `do_push` (@406-413) leaves behind.
  2. Positive control: call the real `cleanup_rendezvous(victim)` with `running` still `Some`
     (terminate ordering) → must NOT panic → prints `MC4-CONTROL-OK`.
  3. Reproduction: execute do_exit's exact sub-sequence on the real manager — `take_running()`
     (do_exit:2116) then `cleanup_rendezvous(victim)` (do_exit:2130) — driving the real
     do_wakeup → try_wakeup_thread → get_running() path.
- Success oracle: kernel panic `file='.../manager/mod.rs', line=2787 :: the kernel should be running`
  (kpanic), preceded by `MC4-CONTROL-OK`; "hello, world!" NOT reached.
- Patch is applied by `repro/test_bugMC-4_do_exit_rendezvous_panic.sh` via `git apply`, built, booted,
  captured, then reverted with `git checkout` so the worktree is left clean.
