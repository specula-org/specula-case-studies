# MC-8 — Investigation Notes

**Finding:** `kill` posts a caught signal onto a zombie process
**Invariant:** `NoSignalToZombie`  **Source:** model-checking  **Scenario:** 4 (kill vs. lifecycle)
**Counterexample:** `spec/output/MC_hunt_scenario4_mc8_final.out`

## 1. Counterexample (what the model says)

Read via the invariant-checking tool:
- Violation: `NoSignalToZombie`, trace length 6.
- Final state: process `p1` is in state `zombie` with disposition `["handler"]`, and it
  **gains a process-directed pending signal** `pd:[1]`; the guard `sigToZombie` flips to `true`.
- The offending step is the `Kill` action posting signal `1` to `p1` while `p1` is already a zombie.

This matches the finding text exactly: a caught (handler) signal is queued into a zombie.

## 2. Code audit (Rust is ground truth)

All line numbers in `src/kernel/src/pm/process/manager/mod.rs` unless noted.

### 2a. The kill target lookup returns zombies
`find_process_mut` (2885–2901) searches running → ready → suspended → interrupted → **zombies**:
```
2894  } else if let Some(process) = self.zombies.iter_mut().find(|p| p.state().pid() == pid) {
2895      Ok(ProcessRefMut::Zombie(process))
```
(`find_process` at 2867–2883 does the same for the read path, 2876–2877.) So `kill` can resolve a
zombie as its target.

### 2b. The post path enqueues without a runnability/zombie guard
`kill` (810–…) permission/existence/null/SIG_MAX/SIGKILL checks, then the post branch:
```
849  let action: PostAction = {
850      let mut process: ProcessRefMut = self.find_process_mut(target)?;
851      let signals: &mut SignalControl = process.state_mut().signals_mut();
852      match signals.disposition(signum) {
853          Some(SignalDisposition::Ignore) => PostAction::None,
854          Some(SignalDisposition::Handler(_)) => {
855              signals.post(signum);          // <-- posts into a zombie's pending set
856              PostAction::Interrupt
857          },
```
There is **no check** that `process` is runnable / not a zombie before `signals.post(signum)`.
A caught signal is therefore queued into a process that can never run a handler.

### 2c. Why nothing wakes up (mask part 1)
The `PostAction::Interrupt` is consumed by `interrupt_signal_candidate` (1009–1019), which scans
**only** `self.suspended`:
```
1010  let candidate = self.suspended.iter()
1011      .find(|process| process.state().pid() == pid)
1012      .and_then(|process| process.candidate_tid_for(signum));
```
A zombie lives in `self.zombies`, not `self.suspended`, so it is never selected, never interrupted,
never scheduled. (My reproduction confirms the ready/interrupted/zombie queue lengths are unchanged.)

### 2d. Why nothing reads it (mask part 2)
- `sigpending` (685–…) returns the **caller's own** pending set (`self.get_running()`); a zombie can
  never be the running caller, so no one queries a zombie's pending via this path.
- `try_deliver_signal` (state/signal.rs) inspects only the **running** thread at a delivery
  checkpoint; a zombie never runs.
- At harvest/reap the entire `ZombieProcess` (including its `SignalControl` pending set) is dropped.

So the wrongly-queued signal is **discarded at reap** and **never observed** by any live consumer.

## 3. Reachability of the injected zombie (for Level-2 state injection)

`RunnableProcess::terminate()` (state/runnable.rs) returns `Err(ZombieProcess::new(state, threads,
status))`, and `ProcessManager::terminate` pushes it via `self.zombies.push_back(...)`. The real API
sequence: `create_process` → `sigaction(Handler)` installs a handler disposition →
all threads exit → the process becomes a queued `ZombieProcess`. My reproduction builds the zombie
**identically** (`ZombieProcess::new(state, NonEmptyVecDeque::new(ReadyThread::terminate()),
ErrorCode::Interrupted.into())`) and pushes it with the same `push_back`, so the injected
pre-condition is a state the real sequence reaches — and it corresponds to the counterexample's
zombie-with-handler state.

## 4. Developer intent (git history)

- `git log` of the post path: the `Handler => post()` branch was introduced by the signal-posting
  feature commits `68495ea22` ("[kernel] E: Implement signal posting") and `094b4cd3d`
  ("[kernel] F: Deliver Signals To Blocked Threads"). Neither adds a zombie/runnability guard.
- Zombie-lifecycle work exists (`#2500` enhancement-kernel-harvest "Reap zombies on demand",
  `#2508` fix-deferred-thread-zombies "Reap deferred thread zombies on demand") but concerns
  **reaping/harvesting**, not rejecting signal posting to a zombie.
- No commit, guard, or comment anywhere handles "post a signal to a zombie"; `signal.rs`'s
  `pending()` accessor is `#[allow(dead_code)]` ("read by a later phase of the signals effort"),
  i.e. a live pending-reader is *planned but not yet present*.
- Prior-report search (git history / issue references only): no upstream issue or merged/closed PR
  addresses this mechanism or `NoSignalToZombie`. → **Novelty: NEW** for this mechanism.

## 5. Reproduction (Phase 2)

In-kernel unit test driving the real `ProcessManager::kill` path against a real zombie, booted in
QEMU/uservm. Test: `src/kernel/src/pm/process/state/kill_test.rs::
test_kill_posts_caught_signal_to_zombie` (+ `#[cfg(feature="test")]` helpers in `manager/mod.rs`).
Deliverable/driver: `.specula-output/repro/test_bugMC-8_kill_zombie_signal.sh`.

Captured output (SIGUSR1 = signum 10, bit 0x200 = 512):
```
MC-8: kill(KERNEL -> zombie pid=7, signum=10) outcome=Ok(Done)
MC-8: zombie pending after kill = Some(512) (signal bit 0x200 present = true)
MC-8: queues before=(0, 0, 0, 1) after=(0, 0, 0, 1) (no live thread scheduled/woken = true)
MC-8: after harvest -> zombie removed=true pending=None (signal discarded = true)
MC-8 REPRODUCED: caught signal 10 was queued into zombie pid=7 (NoSignalToZombie violated);
                 consequence masked because the pending set is discarded at reap and no live
                 consumer reads it.
passed: test_kill_posts_caught_signal_to_zombie
```

## 6. Verdict reasoning

The defect is **real**: `kill` posts a caught signal into a zombie's pending set (missing
runnability guard; `NoSignalToZombie` genuinely violated by the implementation). But **no live
consumer observes a wrong outcome** — the zombie is never scheduled (`interrupt_signal_candidate`
scans only `suspended`) and its pending set is discarded at reap with no reader
(`sigpending`/`try_deliver_signal` never touch a zombie). `kill` even returns `Ok(Done)`, which is
POSIX-consistent (kill to a zombie is a no-op). The harm is therefore **masked** by
(a) the discard-at-reap and (b) the absence of any zombie-pending reader.

→ **VERDICT: MASKED.** Not `REPRODUCED` (no consumer sees wrong behavior); not `FALSE POSITIVE`
(the code really does the wrong internal thing, and MC-source forbids FALSE POSITIVE/DROPPED anyway);
not `INVARIANT`/over-flag (posting a caught signal into a corpse is a genuine implementation defect,
not a benign state the invariant mis-flags). The mask would evaporate the moment a zombie-pending
reader is added (the planned `pending()` consumer), turning this into a wasted pending slot /
misrepresented deliverability.

## 7. Repair-round-1 continuation (re-confirmation)

- **New counterexample** `spec/output/MC_hunt_scenario4_mc8_repaired.out` is byte-identical to the
  prior `_final.out` except for TLC seeds/PIDs/timestamps: same violation `NoSignalToZombie`, trace
  length 6, same `Kill`-into-zombie step. The round-1 spec repair did **not** eliminate the
  violation — consistent with this being a real (unmasked-in-spec) implementation defect, not a
  spec/fault-model/invariant artifact.
- **Source is unchanged** at the affected sites (verified against the current pristine worktree):
  the read-path lookup returns a zombie at `manager/mod.rs:2833` (`find_process`) and the
  mutable-path lookup at `:2851` (`find_process_mut`); the post path still enqueues a caught signal
  with no runnability guard at `:850–856` (`Some(SignalDisposition::Handler(_)) => signals.post(...)`).
  The mask mechanisms are unchanged: `interrupt_signal_candidate` (`:1009`) scans only
  `self.suspended`; `try_deliver_signal` (`manager/signal.rs:206–250`) reads only the running thread;
  `sigpending` (kcall passes the caller's own pid); the zombie's pending set is dropped at reap via
  `pop_zombie_process` → `zombie.bury()`. The only reader of *all* processes' pending sets is
  `state/tla_world.rs::proc_pending` — trace instrumentation, not a production consumer.
- **Reproduction re-executed** (my prior in-kernel test edits had been reset with the worktree; I
  re-applied them and rebuilt): `repro/test_bugMC-8_kill_zombie_signal.sh` exit 0; the caught signal
  (10, bit 0x200=512) is queued into zombie pid=7 via the real `kill` path; queues unchanged
  (nothing scheduled/woken); pending discarded at reap. 101/101 in-kernel tests pass, no panic.
- **Disposition unchanged: MASKED.** No prior statement in this file is disproved by the current
  source/trace evidence. `PENDING REPAIR` is inapplicable — the CE is fully reachable in the real
  code, so there is no missing guard / inadmissible fault / unpromised-property artifact to cite.
