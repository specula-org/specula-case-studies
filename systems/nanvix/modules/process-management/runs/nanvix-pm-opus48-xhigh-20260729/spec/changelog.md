# Changelog — Nanvix PM Spec Validation

Unified record of all modifications across trace-validation ↔ model-checking iterations.

## Round 0 - Initialization
- Verified inputs present: base.tla/cfg, MC.tla/cfg, Trace.tla/cfg, 7 MC_hunt_*.cfg, 9 trace .ndjson files, instrumentation-spec.md, harness/INSTRUMENTATION.md.
- Confirmed Trace.cfg has `PROPERTIES TraceMatched` (uncommented).
- Category A trace validation (single-core, totally ordered; linear cursor `l`).

## Round 1 - Trace Validation
- [fix] TraceNext: added `TraceDone == l > Len(TraceLog) /\ UNCHANGED <<vars,traceVars>>` as the first disjunct of `TraceNext` (Trace.tla). The trace-consumed terminal state previously had no successor, so the MCP `run_trace_validation` tool (default deadlock detection ON, no `-deadlock`) reported the benign accepting state as "Deadlock reached" for every trace. This is the standard cometbft trace-spec pattern; a real divergence still stalls at l<=Len (TraceDone disabled) and deadlocks, so bad traces are still flagged. Base-spec modeling untouched.
- Result: all 9 traces PASS (alarm_resume, exit, lifecycle, multithread, notify, rendezvous, signal_disposition, sync, terminate).

## Round 1 - Model Checking
- No spec/invariant changes needed. `MC.cfg` (structural invariants MCTypeOK, MCSingleOwner) ran exhaustive BFS to completion: 2,981,464 distinct states, search depth 27, 0 states left on queue, **No error found**. Output: spec/output/MC_run1.out.

## Convergence
- Converged. Phase-2 model checking required no modifications to base.tla or MC.tla. The sole modification this round (TraceDone in Trace.tla) is trace-harness-only and does not affect the model-checked base/MC specs (re-running Phase 1 leaves all 9 traces passing; re-running Phase 2 is identical). Base spec is trusted. Proceeding to Bug Hunting.

## Bug Hunting
Ran all 7 MC_hunt_scenario*.cfg. Because a bundled config stops at the first violated invariant, each of the 11 target invariants was also run in an isolated per-invariant config (spec/iso/) with `-deadlock` (the bounded MC specs terminate naturally; deadlock detection must be off) so every finding gets a clean counterexample. All 10 findings were cross-referenced against ground-truth Rust and confirmed Case C (real bugs).

- [fix-spec] HarvestZombieProc (Case B, found during hunting): the spec left `mutexInMap=TRUE` after a process that held a mutex exited and was reaped. Ground truth: `harvest_zombies` (manager/mod.rs:3430) takes the `Box<ProcessState>` from `pop_zombie_process` (:2449) and drops it at end of scope, freeing the whole `mutexes` map. Added clearing of `mutexInMap`/`mutexExtraRef` for the harvested process's mutexes. This removed a spurious SyncSlotConservation counterexample (exit+harvest path); MC-7 now reproduces via the real cond_wait interrupted-relock path (same root cause as MC-6). Re-validated: all 9 traces pass; MC.cfg structural exhaustive BFS still passes (2,910,732 distinct states, no error).

- [bug] MC-1 NoLostNotify (S1): `try_wakeup` (manager/mod.rs:1880) scans suspended+ready, never the interrupted list → a sleeper embedded in an interrupted process is consumed by notify but never woken.
- [bug] MC-2 SignalReachesSafety (S1): `interrupt_signal_candidate` (manager/mod.rs:1009) scans only `self.suspended` → a caught signal whose only eligible candidate is an embedded sleeper in a runnable/interrupted process is never delivered.
- [bug] MC-3 TerminatedThreadsDie (S2): `RunnableProcess::terminate` (runnable.rs:180-193) / `do_exit` carry interrupted threads forward with TimedOut/Signaled; `sleep()` (unsafe.rs:864) → `sleep.rs:64` maps TimedOut to Ok → thread resumes user code after its process was terminated.
- [bug] MC-4 RunningValidAtWakeup (S3): `do_exit` (manager/mod.rs:2116) nulls `running`, then `cleanup_rendezvous` (:2130) → `do_wakeup` → `try_wakeup_thread` → `get_running().expect(...)` (:2787) panics when a rendezvous counterpart exists.
- [bug] MC-5 NoSpuriousOOM (S4): `create_process` (manager/mod.rs:1139) rejects with OutOfMemory before any zombie harvest; `live_count` drops only at burial → spurious OOM while a reclaimable zombie awaits reaping.
- [bug] MC-6 CondWaitReturnsLocked (S5): `wait_cond` (wait_cond.rs:127) reacquires with `mutex.lock(None)?` (and `put_cond?` at :123) → an interrupted relock returns EINTR without the mutex held (POSIX violation).
- [bug] MC-7 SyncSlotConservation (S5): the same interrupted cond_wait relock leaves the mutex map entry present but unowned/unheld (`wait_cond` never restores it and the caller cannot cleanly unlock it) → orphaned map slot.
- [bug] MC-8 MaskHonored (S6): `kill` (manager/mod.rs:858-893) applies a default-Terminate action via `kill_terminate` without consulting any per-thread blocked mask → a blockable signal masked by every thread still terminates the target.
- [bug] MC-9 NoImmortalPending (S6): `sigaction`/`set_disposition` (state/signal.rs:364) does not clear pending; changing a pending caught signal's disposition to Default/Ignore strands it (try_deliver skips non-Handler) → immortal pending.
- [bug] MC-10a SavedMaskRestored (S7): `install_sigsuspend_mask` (manager/mod.rs:734) overwrites the single `saved_blocked: Option<u64>` (thread/state.rs:105) → a nested sigsuspend loses the outer pre-suspend mask.
- [bug] MC-10b RestartAttribution (S7): the signum-less `KcallRestart` (thread/state.rs) + `try_deliver_signal` (signal.rs:280-283) apply the delivered lowest signal's SA_RESTART, which may differ from the signal that actually interrupted the call.

## Result
Converged in 1 round (base/MC specs unmodified during convergence; only a trace-harness compatibility fix). Bug hunting: 11 invariant violations across 7 scenarios, all confirmed Case C real bugs (one Case B spec-fidelity gap in HarvestZombieProc fixed during hunting).

## Round 2 - Phase 3 Repair (confirmation back-edge; RR-001, RR-002, RR-003)
Processed the three OPEN repair requests judged spec/invariant artifacts by Phase-4 confirmation.
Full trace re-validation (soundness gate): all 9 traces still pass. MC.cfg structural exhaustive
BFS still passes (2,899,812 distinct states, depth 26, no error). Untouched findings MC-1, MC-3,
MC-4, MC-5, MC-6, MC-8, MC-9, MC-10a all still violate (per-invariant iso configs).

- [fix-spec] PostSignalHandler (RR-001, MC-2): added the ready/running self-delivery branch.
  `signalDeliveryFailed` is now set only when the sole unmasked eligible thread is a sleeper in a
  non-suspended process AND no unmasked ready/running/interrupted sibling exists to self-deliver at
  its return-to-user checkpoint (try_deliver_signal signal.rs:242; deliver_pending_signals
  handler.rs:189; design note manager/mod.rs:1000-1002). MC-2 no longer fires on the benign no-mask
  CE (iso_scenario1_MC-2: no error); MC-1 still violates.
- [fix-spec] CondWaitUnlock + CondWaitRelock (RR-002, MC-7): CondWaitUnlock now models put_mutex
  reclamation like every other unlock (mutexInMap' = IF mutexExtraRef THEN TRUE ELSE FALSE;
  state/mod.rs:652-666 via remove_mutex_guard manager/mod.rs:2635; MutexGuard Arc sync/mutex.rs:142-144),
  and CondWaitRelock re-inserts via get_mutex (wait_cond.rs:126). The sole-holder interrupted relock no
  longer strands an orphaned slot. MC-7 no longer fires (iso_scenario5_MC-7: no error); the genuine
  lock_mutex-cancel leak (mutexExtraRef) still violates SyncSlotConservation; MC-6 (out of scope) still
  violates.
- [fix-inv] RestartAttribution removed (RR-003, MC-10b): the property (restart attributed to a
  spec-only "interrupting signal" intrSig) is not a real contract -- SA_RESTART is applied per the
  DELIVERED lowest-numbered caught signal (signal.rs:240-283) and KcallRestart carries no signal
  number (thread/state.rs:57-62). With no falsifiable non-vacuous oracle, the invariant was removed
  (unwired from MC_hunt_scenario7.cfg; RestartAttribution/MCRestartAttribution deleted;
  restartMisattributed oracle dropped from DeliverSignal) rather than left vacuous. restart/intrSig/
  MarkInterruptedBySignal kept inert only for trace-schema compatibility (the MarkInterruptedBySignal
  trace event + restartMisattributed trace field). MC-10a still violates in scenario7.

## Round 3 - Phase 3 Repair (confirmation back-edge; RR-004)
Processed the one OPEN repair request (RR-004, MC-5) judged a spec artifact by Phase-4 confirmation.
Full trace re-validation (soundness gate): all 9 traces still pass. MC.cfg structural exhaustive BFS
still passes (2,389,577 distinct states, depth 26, no error).

- [fix-spec] CreateProcessSpuriousOOM (RR-004, MC-5): re-gated the modeled spurious-OOM from the
  UNREACHABLE process-count cap to the REACHABLE thread-slot cap-before-reap. It now fires when the
  thread cap is reached (`LiveThreadCount >= MaxThread`) while a reclaimable zombie thread awaits
  harvest (new helper `ReclaimableThreadCount > 0` = threads of a harvestable zombie process) and
  `(LiveThreadCount - ReclaimableThreadCount) < MaxThread`, with `LiveProcCount < MaxProc` (the
  :1139 process-cap gate already passed). This models the non-reaping `try_next_tid` at
  create_process (manager/mod.rs:1164) and do_execv (:2023), vs the reap-then-retry
  `try_next_tid_reaping` used by create_thread (:421) and duplicate_process (:1558) after fix #2495.
  The process cap can never bind first because MAX_THREADS(32) < MAX_PROCESSES(255) and every live
  process holds >= 1 live thread. Retuned MC_hunt_scenario4.cfg / iso_scenario4_MC-5.cfg to
  `MaxProc=3` (> slot count ⇒ process cap unreachable) and `MaxThread=2` (< slot count ⇒ thread cap
  binds first with a spare slot beyond it). `NoSpuriousOOM` unchanged and still falsifiable/non-vacuous.
  MC-5 now violates at the reachable thread-cap gate (MCCreateProcess → MCRunnableTerminate →
  MCCreateProcessSpuriousOOM; State 4: t2 zombie under the thread cap, t3 free;
  output/MC_hunt_scenario4_MC-5_repair.out); the unreachable process-cap CE is gone.
