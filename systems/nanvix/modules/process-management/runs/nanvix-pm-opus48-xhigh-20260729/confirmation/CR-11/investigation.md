# CR-11 Investigation — on_thread_reaped runtime assert vs live_count underflow

## Cited code
- src/kernel/src/pm/thread/mod.rs:272 `ThreadManager::on_thread_reaped`
  `assert!(self.live_count > 1, "live_count underflow: ...")` then `live_count -= 1`.

## Accounting model (Step 1 audit)
- `live_count` init = 1 (kernel thread, tid 0), never reaped.
- Incremented **once per thread creation** via `commit_next_tid` (thread/mod.rs:261).
  Commit sites: create_thread (mod.rs:459), create_process/spawn (mod.rs:1205),
  duplicate_process/fork (mod.rs:1623), exec/replace_image (mod.rs:2065).
- Decremented **once per reaped zombie thread** via `on_thread_reaped`.
  Reap sites (3): harvest_zombie_thread (unsafe.rs:708, from join_thread + reap_deferred),
  reap_deferred_zombie_threads (mod.rs:3387), harvest_zombies (mod.rs:3482).

## Balance verification (each reap matched by exactly one prior commit)
A thread becomes a ZombieThread exactly once (exit / terminate-fold / detach-of-zombie),
and its zombie goes to exactly ONE destination, reaped exactly once:
- Joinable zombie -> process `zombie` list. join_thread's `try_join_thread`
  (running.rs:561-566) uses `remove_if` to REMOVE it before harvest_zombie_thread reaps it,
  so harvest_zombies cannot later re-reap it. detach-of-zombie (running.rs:651-660) likewise
  `remove_if` + single harvest.
- Last-thread / non-joinable -> ZombieProcess.zombie_threads -> harvest_zombies reaps each once.
- Detached-exit-with-other-threads / exec-old-thread -> `deferred_reap` queue -> drained
  atomically by `core::mem::take` in reap_deferred (unsafe.rs:611) OR
  reap_deferred_zombie_threads (mod.rs:3331). mem::take => a zombie is in the queue once and
  drained once; the two drainers cannot both see it.
- Kernel thread (tid 0) is never turned into a zombie; the `> 1` guard makes underflow of the
  kernel slot impossible even in principle.

Conclusion: reaps == commits for every non-kernel thread; no double-reap, no reap-without-commit.
The assert's precondition (live_count <= 1 at a reap) is unreachable through the real API.

## Developer intent (Step 2)
Commit 4764fa974 "[kernel] E: Add system-wide thread count cap" (Pedro Penna), closing #2329,
#1270, states verbatim: "add on_thread_reaped() with a runtime assert (not debug_assert) to
prevent silent usize wrap in release builds." The in-code comment (thread/mod.rs:273-276)
repeats this: the assert deliberately converts a hypothetical accounting bug into a loud panic
rather than a silent usize wrap that would permanently break admission control.
=> The assert is intended, documented defensive hardening, not an accidental fragile guard.

## Known-status / precedent (Step 3)
Issue-tracker + code search (GitHub) for on_thread_reaped / live_count / "thread count" underflow
/ double reap: matches are the FEATURE work (#2329, #2330 add cap; #2495 on-demand reaping;
#2497 tests) — NONE is a filed bug report about this assert firing or a reap imbalance.
#1270 is the heap-exhaustion motivation, not this mechanism. => No prior report of THIS defect.
Novelty: NEW. Not the code-review x known drop (no filed report).

## Verdict direction
Code-review finding. Trigger (assert firing = kernel panic) requires a reap/commit imbalance
that the audited state machine cannot produce; the guard is intended, documented defensive code.
No reachable defect => FALSE POSITIVE (subject to reproduction confirming balance holds).
