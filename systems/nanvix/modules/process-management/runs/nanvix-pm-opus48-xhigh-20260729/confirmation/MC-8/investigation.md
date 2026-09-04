# MC-8 Investigation — Blockable default-Terminate signal ignores the per-thread mask

## Finding
`kill()` maps a `Default` disposition with a fatal `default_action` (Terminate/Core)
to `PostAction::Terminate` and calls `kill_terminate()` unconditionally, with no
per-thread blocked-mask check. Only the `Handler` path is mask-gated. So an ordinary
blockable signal (e.g. SIGTERM) with a fatal default action terminates a target that
has the signal masked on every thread — contrary to POSIX (a blocked terminate-default
signal must stay pending).

- Invariant: `MaskHonored` (`MCMaskHonored`)
- Counterexample: `spec/output/MC_hunt_MC-8.out` (trace_length 6)
- Cited code: `src/kernel/src/pm/process/manager/mod.rs:858`, `:892`

## Step 1 — Code audit (facts)

`ProcessManager::kill()` (`manager/mod.rs:810`):
- `:842` SIGKILL short-circuits to unconditional termination (documented: "bypassing
  disposition and mask checks").
- `:849-882` computes `PostAction` from the disposition ONLY:
  - `Handler(_)` → `signals.post(signum)` + `PostAction::Interrupt` (`:854-856`)
  - `Default` → `match default_action(signum)`:
    - `Terminate` → `PostAction::Terminate` (`:859`)
    - `Core` → `PostAction::Terminate` (`:860-866`)
    - `Ignore`/`Continue` → `None`; `Stop` → `Stop`
  - No per-thread `blocked` mask is consulted anywhere on the `Default` arm.
- `:892-896` acts:
  - `Terminate` → `return self.kill_terminate(caller, target)` — UNCONDITIONAL (`:893`)
  - `Interrupt` → `interrupt_signal_candidate(target, signum)` (`:894`) — mask-gated.

Mask-gating asymmetry (the crux):
- Handler path: `interrupt_signal_candidate` (`:1009`) → `SleepingProcess::candidate_tid_for`
  (`state/sleeping.rs:89`) selects a thread that does NOT block `signum`; "A blocked signal
  must remain pending rather than interrupt a blocking call." Delivery (`manager/signal.rs:242`)
  computes `deliverable = (pending | thread_pending) & !blocked` — blocked signals left pending.
- Default-terminate path: `kill_terminate` (`:917`) → `terminate(target)` (`:2268`) with NO mask
  read at all. For a non-running target it removes it from ready/suspended/interrupted and
  reaps/kills it.

`default_action` (`state/signal.rs:217`): SIGTERM (15) falls in `_ => Terminate`. SIGTERM is
blockable (`UNBLOCKABLE = {SIGKILL, SIGSTOP}` only, `signal.rs:52`).

Reachability (real API, all wired):
- `kcall/sigprocmask.rs` → `pm.sigprocmask(tid, SIG_BLOCK, {SIGTERM})` sets the per-thread mask.
- `kcall/kill.rs:67` → `pm.kill(caller, target, signum)`; cross-process gated on
  `Capability::ProcessManagement` (held by procd in production).
- Trigger: target thread blocks SIGTERM (sigprocmask) and is runnable/sleeping; a privileged
  process posts `kill(target, SIGTERM)`. `kill()` never checks the mask → target terminated.

CE trace (`MC_hunt_MC-8.out`): Initial → MCCreateProcess(p2) → MCMaskChange(t1 blocks sig 1)
→ MCSleep(p1 suspended, t1 sleeping) → MCSchedule(p2 running) → MCPostSignalDefaultTerminate:
`procTerminated[p1]=TRUE`, `maskViolated=TRUE`, though sig 1 blocked on p1's only thread t1.

## Step 2 — Developer-knowledge search (evidence)

Commits (local git history; no remote configured):
- `68495ea22` / issue #2721,#2693 "Signal Posting and Default Termination":
  "wire fatal default actions to the existing termination paths. After this change,
  kill(pid, SIGTERM) ... terminate the target process." "this phase acts on Term (and Core)."
  "**SIGKILL short-circuits to unconditional termination, bypassing disposition and mask
  checks.**" → the design singles out SIGKILL as the mask-bypassing case, implying non-SIGKILL
  signals are expected to honor the mask; but Term was wired straight to terminate().
- `094b4cd3d` / issue #2735 "Deliver Signals To Blocked Threads": adds mask-honoring for the
  CAUGHT path only (candidate thread "that does not block the signal"; `sigpending()` =
  `pending & blocked`; delivery `& !blocked`). The default-terminate path was not updated.

No source comment/TODO asserts that a *blocked* default-Terminate signal should terminate; the
code comments only say the caught path leaves blocked signals pending. This is a real gap
between the stated intent (only SIGKILL bypasses the mask) and the implementation.

## Step 3 — Known-status / precedent

Issue tracker (`api.github.com/search/issues repo:nanvix/nanvix`): matches are the signals
FEATURE/TASK issues (#2690 umbrella, #2691/#2701 plumbing, #2693/#2721 default termination,
#2731 caught delivery, #2735 blocked-thread delivery, #2766 job control) — all closed as
implemented. NONE is a bug report of "default-terminate signal ignores the per-thread mask" at
`kill():892`. The umbrella #2690 is general WIP, not a filed report of THIS defect. No merged/
closed PR fixes this mechanism.

=> Novelty: NEW (searched open+closed issues and recent commits; nothing reports this mechanism
at this site). Source: MC (real counterexample). Not a code-review×known drop.

## Reproduction plan
In-kernel test (Level 2 state injection, precondition reachable via real API): register a
runnable target whose only thread has SIGTERM blocked (as `sigprocmask(SIG_BLOCK,{SIGTERM})`
sets it), leave disposition Default, then call the REAL `pm.kill(caller, target, SIGTERM)` and
observe the target is terminated (ready → zombie) instead of the signal being left pending.
Drive via `make run-kernel-tests` (test-kernel booted in UserVM).

## Reproduction result (executed) — REPRODUCED

Added in-kernel test `test_blockable_default_terminate_ignores_thread_mask`
(`src/kernel/src/pm/process/manager/test.rs`, wired into `pm::test::test()`), built with
`make all-test-kernel` and booted via `./bin/uservm.elf -kernel bin/kernel-test.elf`.
Level 2 (state injection): a target `RunnableProcess` is placed on the ready list (exactly what
`create_process()` publishes, mod.rs:1208-1211); the mask and the kill go through the REAL entry
points `pm.sigprocmask(SIG_BLOCK,{SIGTERM})` and `pm.kill(caller,target,SIGTERM)`.

Serial output:
    [TRACE][manager] kill(): caller=0, target=4242, signum=15
    [TRACE][manager] kill(): caller=0, target=4343, signum=15
    [INFO][test] ...: mc8: default-terminate masked target -> zombie=true (BUG when true);
                       catch-handler masked target -> alive=true, pending=true (POSIX-correct)
    [ERROR][test] ...: mc8 REPRODUCED: kill(SIGTERM) terminated a target whose only thread blocks
                       SIGTERM — the per-thread mask was ignored on the default-Terminate path
    [INFO][test] test(): passed: test_blockable_default_terminate_ignores_thread_mask

Same masked precondition: Default(Terminate) → target becomes a zombie (killed); Handler → target
stays runnable with SIGTERM pending. Proves the manager owns a mask-honoring path that the
default-Terminate branch bypasses. Real caller: kcall/kill.rs:67 (`pm.kill`). Bad state permanent
(zombie; signal never left pending). Novelty NEW: git history (incl. `--all`) shows the terminate
mapping and the caught-path mask gate landed in the SAME commit 094b4cd3d ("Deliver Signals To
Blocked Threads"); no issue/PR reports this mechanism. Verdict: REPRODUCED.
