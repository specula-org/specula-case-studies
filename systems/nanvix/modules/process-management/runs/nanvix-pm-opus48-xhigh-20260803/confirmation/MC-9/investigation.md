# MC-9 Investigation

Finding: execv is spuriously refused at MAX_THREADS (non-healing admission).
Invariant: ExecAdmission. Source: MC (counterexample `output/MC_hunt_scenario2_mc9_final.out`).
Config: `MC_hunt_scenario2_mc9.cfg` (MaxThreads=2, Enabled includes "execR" and "reapSafe" as
separate actions).

## Step 1 — Code audit

### Cited sites
- `do_execv` admission: `src/kernel/src/pm/process/manager/mod.rs:2023`
  `let (tid, next_tid) = self.tm.try_next_tid()?;`  — NON-healing.
- Healing variant: `try_next_tid_reaping` at `mod.rs:3410-3428`; used by create_thread
  (`mod.rs:421`) and fork/duplicate_process (`mod.rs:1558`).
- `ThreadManager::try_next_tid` (`src/kernel/src/pm/thread/mod.rs:227`): rejects with OutOfMemory
  when `live_count >= MAX_THREADS`.
- `on_thread_reaped` (`thread/mod.rs:272`): `live_count -= 1` (frees a slot).

### Call chain / entry point (decisive)
The reachable consumer is the execv() kcall. Its entry point is
`KernelProcessManager::exec` at `src/kernel/src/pm/process/manager/unsafe.rs:351`:

    351  pub unsafe fn exec(pid, args) -> Error {
    361      Self::reap_deferred();                 // FIRST step, unconditional
    ...
    434      match pm.do_execv(mm, pid, ...) { ... } // admission (try_next_tid) runs here

`reap_deferred` (`unsafe.rs:610`) drains the `deferred_reap` queue and for each entry calls
`harvest_zombie_thread` (`unsafe.rs:654`), whose final act is
`Self::get_mut().tm.on_thread_reaped()` (`unsafe.rs:708`) — decrementing `live_count`.

EVERY PM entry point performs this reap first (exit:290, exec:361, exit_thread:535, join:749,
detach:801, sleep:847, giveup:939). So a deferred detached-thread zombie is ALWAYS drained
before any admission check.

### Trigger scenario (from the CE)
1. p1 main thread t1 running (live_count=1).
2. t1 creates a detached thread t2 -> live_count=2 (== MaxThreads).
3. t2 runs and exits; being detached with t1 still live, its zombie is pushed to `deferred_reap`
   (`do_exit_thread`, `mod.rs:2226`); the slot is NOT yet returned.
4. t1 calls execv(). CE fires `ExecRefuse` while `deferred={t2}` -> execRefused=TRUE.

### Reachability of the CE transition in the implementation
UNREACHABLE. Step 4 in the real code first runs `reap_deferred()` (unsafe.rs:361), which reaps t2
via `on_thread_reaped()` (unsafe.rs:708), lowering live_count 2->1. Then `do_execv`'s
`try_next_tid()` sees live_count=1 < MAX and ADMITS. `ExecRefuse` with a non-empty deferred set
cannot occur. The model treats `reapSafe` (ReapDeferredSafe) as an INDEPENDENT action (cfg
`Enabled`), so TLC schedules `execR` before it — an interleaving the coupled kcall forbids.

Note (out of CE scope): exec's entry-point `reap_deferred()` reaps deferred detached-thread
zombies but NOT zombie *processes*; only the create/fork `try_next_tid_reaping` harvests zombie
processes. That is a different mechanism (a zombie-process-held slot), not what this CE
(`deferred={t2}`) demonstrates, and is tracked elsewhere (dedup_note -> CR-2). It does not make
the CE's deferred-thread transition reachable.

## Step 2 — Developer-knowledge search
- `git log -S try_next_tid_reaping`: commit `a85226542` "[kernel] E: Reap zombies on demand"
  (Fixes: #2495). It explicitly wires ONLY `create_thread()` and `duplicate_process()` to
  `try_next_tid_reaping()`; execv is not mentioned. Intent: make create/fork admission
  self-healing against reclaimable zombie slots.
- `git log -S reap_deferred`: `4113651ed` "[kernel] B: Reap deferred thread zombies on demand"
  and `92bad91f2` "[kernel] B: Defer detached zombie reap" — add the deferred-reap queue and its
  on-demand drain; `342efe35a` "[kernel] E: Add execv() kernel call".
- Model comment `tla_world.rs:622`: "ExecRefuse(caller): admission refused at MAX_THREADS (the
  non-healing exec path)". The harness deliberately models exec as non-healing but does NOT model
  the mandatory entry-point `reap_deferred()` that precedes `do_execv`.

## Step 3 — Known-status / precedent
No issue/PR/CVE reports THIS mechanism (a spurious ExecRefuse at MAX_THREADS with a reclaimable
deferred zombie). #2495 is a *different* site (create/fork admission), already fixed there. The
execv non-healing gap is not an existing filed report. Source is MC (real counterexample), so the
code-review x known pre-filter does not apply regardless. Novelty: NEW.

## Conclusion feeding Phase 2
The CE's `ExecRefuse`-while-`deferred!={}` transition is unreachable in the implementation because
the execv kcall unconditionally reaps the deferred zombie first. This is an over-permissive
modeled action (`ExecRefuse` lacks the entry-point reap guard) -> SPEC_REPAIR (PENDING REPAIR).
