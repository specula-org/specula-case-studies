# MC-2 Investigation (Phase 1 — evidence only)

**Finding:** A waiting joiner can receive `ThreadNotFound` instead of the exit status.
**Invariant:** `JoinGetsStatus`  **Source:** MC (real counterexample).
**CE:** `spec/output/MC_hunt_scenario2_mc2_final.out`  **Cfg:** `MC_hunt_scenario2_mc2.cfg`

## Step 1 — Code audit (facts)

Cited sites (worktree):
- `src/kernel/src/pm/process/state/running.rs:541` — `RunningProcess::try_join_thread`.
- `src/kernel/src/pm/process/manager/unsafe.rs:742` — `ProcessManager::join_thread`.

`try_join_thread(tid)` resolution order (running.rs:546-620):
1. If `self.running.id() == tid` → `OperationNotPermitted`.
2. Search `zombie` queue: if found and detached → error; else `zombie.take()` +
   `remove_if(id==tid)` → **removes** the zombie and returns `Ok(zombie_thread)`.
3. Search `ready` / `sleeping` / `interrupted`: if found (and not detached) → return
   `Err(Ok(join_cond))` (caller must park on the target's join condvar).
4. Fall through → `Err(Err(Error::new(ErrorCode::NoSuchProcess, "thread not found")))`
   (running.rs:618-620).

`join_thread(pid,tid)` loop (unsafe.rs:751-768):
```
loop {
  match try_join_thread(pid,tid) {
    Ok(zombie)      => { status = zombie.status(); harvest_zombie_thread(...); break Ok(status) }
    Err(Ok(cond))   => { cond.wait(None)?; }          // park, then RE-RESOLVE next iteration
    Err(Err(error)) => break Err(SleepError::Generic(error))   // ThreadNotFound propagates
  }
}
```
The loop re-resolves the target purely by **identity** after every `Condvar::wait`. There is
**no binding** from the parked joiner to the target's retained zombie/status. Nothing records
"this joiner is owed t2's status"; on resume it simply re-runs `try_join_thread`.

Who can consume a **non-detached** zombie before the parked joiner resumes:
- **A second joiner** of the same target: `try_join_thread` reap path (running.rs:561-566). The
  join kcall (`kcall/join_thread.rs`) places **no guard** against two threads joining one target.
- **A concurrent `detach(target)`**: `RunningProcess::detach_thread` on a zombie returns
  `Ok(Some(zombie))` — it **removes** the zombie for immediate harvest (running.rs:626-636; see
  existing test `test_detach_zombie_immediate_harvest`). The detach kcall has no guard either.
(`reap_deferred` only touches *detached* zombies; `harvest_zombies` only runs for a *zombie
process* — not applicable while the joiner's process is still alive. So the real consumers are the
two above, matching the cfg comment: "a concurrent detach / second joiner reaps the target".)

Exit/wakeup path (unsafe.rs:533-561): `exit_thread` → `do_exit_thread` turns the target into a
zombie and returns its `join_cond`; then `join_cond.notify_all()` moves **every** parked joiner
sleeping→ready; then it context-switches to the next thread. `Condvar::wait` (sync/condvar.rs:232)
parks via `ProcessManager::sleep`, so between notify and the woken joiner actually re-running
`try_join_thread`, other ready threads run first — a legitimate scheduler interleaving.

Concurrency model: single-CPU kernel, interrupts disabled in these critical sections; "concurrency"
is the interleaving of threads across context switches. The race window (joiner woken → other
consumer reaps target → joiner resumes) is a normal interleaving.

Reachability: fully reachable via the public kcall API (`create_thread`, `join_thread`,
`detach_thread`); no guard rejects a second join or a detach-during-join.

## Step 2 — Developer-knowledge search (evidence)

- `git blame` running.rs:618-620: authored 2025-02 (P. Penna); **no comment** acknowledging a
  join-vs-reap race at the fall-through `NoSuchProcess`.
- `git log` on the two files: related but **different** fixes — "Fix zombie loss on exit"
  (4764fa974), "Defer detached zombie reap" (92bad91f2), "Skip stale condvar waiters" (6055a7366),
  "Add detach_thread kernel call" (464dc9848). None address a resumed joiner re-resolving to
  `ThreadNotFound`.
- No `TODO`/`FIXME`/"known"/"race" comment at the join re-resolution site.
- Existing test `test_detach_zombie_immediate_harvest` shows the immediate-harvest-on-detach path
  is intended, but asserts nothing about a concurrent joiner.

## Step 3 — Known-status / precedent

Prior-report search (issue tracker / git history only):
- Upstream `nanvix/nanvix`. Local repo has **no remote**; git log shows no report of this mechanism.
- GitHub issue queries: `#2334`/`PR #2331` = *adding* in-kernel detach unit tests (not this race);
  `#1403` = intermittent **TLS** corruption race in `thread_local.c` (different mechanism).
- Web search surfaced only the detach-test issues; nothing on a joiner receiving `ThreadNotFound`
  after a concurrent reap.
→ No existing issue/PR/CVE reports THIS mechanism at THIS site. **Novelty: NEW.**
MC-sourced with a real counterexample → proceed to Phase 2 (no pre-filter drop).

## Trigger scenario (concrete)

1. Process p1 has running thread t1; creates t2 (and, for the two-joiner variant, t3).
2. t1 calls `join(t2)` while t2 is live → `try_join_thread` returns `Err(Ok(cond))`; t1 parks on
   t2's join condvar.  (Two-joiner variant: t3 also `join(t2)` and parks on the same condvar.)
3. t2 runs and exits → becomes a zombie; `exit_thread` `notify_all()`s the condvar, moving the
   parked joiner(s) to **ready**; context switch.
4. Before t1 resumes, a concurrent consumer reaps t2's zombie:
   - two-joiner: t3 is scheduled first, `try_join_thread(t2)` → `Ok(zombie)`, harvests t2; **or**
   - detach: another thread calls `detach(t2)` → `Ok(Some(zombie))`, harvests t2.
5. t1 resumes; the `join_thread` loop re-runs `try_join_thread(t2)` → target absent from every
   queue → `Err(Err(NoSuchProcess "thread not found"))`.
6. `join_thread` `break Err(...)`; the join kcall returns the error to userspace (join_thread.rs:72)
   instead of t2's exit status.

## Consequence / consumer

The userspace `join()` call (`kcall/join_thread.rs:72`, `ProcessManager::join_thread(pid,tid)?`)
returns `NoSuchProcess` to the caller instead of the joined thread's exit status. The status is
lost permanently — the winning consumer already harvested the zombie; `join_thread` does not retry
or recover. Not masked by any downstream mechanism.
