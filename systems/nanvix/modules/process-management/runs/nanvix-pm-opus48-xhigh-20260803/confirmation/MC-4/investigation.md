# MC-4 — Investigation record (Phase 1)

Finding: "A masked default-action signal is acted upon while masked"
Invariant: MaskedSignalDeferred | Source: model-checking (real CE)
CE: spec/output/MC_hunt_scenario4_mc4_final.out (trace_length 3: Initial → MCNext(pmask) → MCNext(kill))

## Step 1 — Code audit (facts)

Cited site: src/kernel/src/pm/process/manager/mod.rs:858 (the `SignalDisposition::Default` arm of
`ProcessManager::kill`, lines 849-897).

`kill()` resolves a posted signal's action from the *disposition* only:
- `Ignore`            -> PostAction::None
- `Handler(_)`        -> `signals.post(signum)` + PostAction::Interrupt  (posted pending; the mask is
                         consulted LATER at the return-to-user delivery checkpoint, where
                         `deliverable = (pending|thread_pending) & !blocked` — signal.rs:242)
- `Default`+Terminate -> PostAction::Terminate -> `kill_terminate` (mod.rs:917) -> for self returns
                         KillOutcome::TerminateSelf; cross-process calls `terminate(target)` (zombie).
- `Default`+Stop      -> PostAction::Stop -> `stop_process`.

The `Default` (and `Stop`) arms NEVER read the target thread's `blocked()` mask. SIGKILL/SIGSTOP are
correctly special-cased as unblockable elsewhere; the bug is that ALL other default-action signals
(SIGTERM, SIGINT, SIGHUP, job-control stop, ...) bypass the mask too.

The kernel's own design intends deferral: `sleeping::candidate_tid_for` (state/sleeping.rs:89) doc
says *"A blocked signal must remain pending rather than interrupt a blocking call"* and skips masked
threads — but that check lives only on the caught/interrupt path, not the default-action path.

Reachability: fully reachable via public kcalls. `sigprocmask` (mod.rs:642) sets the per-thread
blocked mask; `kill` (mod.rs:810) is the kill kcall's primitive (kcall/kill.rs:67). Real consumer of
the wrong outcome: kcall/kill.rs:72 acts on `TerminateSelf` by calling the self-exit primitive
(terminates the caller); the cross-process arm calls `terminate(target)` (mod.rs:925) -> zombie.

Trigger scenario: a thread blocks SIGTERM (e.g. around a critical section), then SIGTERM is sent
(kill). Expected: deferred (pending) until unblocked. Actual: process terminated immediately.

## Step 2 — Developer-knowledge search (evidence)

- `git blame` mod.rs:849-897: the `Default => Terminate => PostAction::Terminate` line and the
  mask-aware `Interrupt`/`candidate_tid_for` path were introduced TOGETHER in commit
  094b4cd3 "[kernel] F: Deliver Signals To Blocked Threads". Its message: "Replace the
  (terminate, wake) post-action pair in kill() with a PostAction enum that also interrupts a
  suspended candidate thread, selecting a sleeping thread that does not block the signal." The
  mask-awareness was added ONLY to the interrupt/handler path; the default-action arms were left
  ungated. No commit note claims default-action masking is intentionally deferred.
- No TODO/FIXME/"future work"/"known limitation" comment near the default-action arms about masking.
- Design intent (candidate_tid_for doc) is that masked signals stay pending — the default arm
  contradicts the kernel's own stated rule. => real defect, not documented/intended behavior.

## Step 3 — Known-status / precedent

- `git log --all -i --grep` over mask/defer/pending/default-action/SIGTERM/signal: no filed issue or
  PR reports THIS mechanism (masked default-action signal acted upon). No merged fix exists at HEAD
  (the default arm still lacks a mask check).
- MC-sourced with a real counterexample -> never a Phase-1 drop. Novelty: NEW.

## Verdict inputs
Reachable (real sigprocmask+kill), real consequence (process terminated / TerminateSelf), permanent
(no downstream un-terminate/resend/guard). => proceed to Phase 2; reproduced at Level 0.

## Repair-round 1 re-verification (continuation)

Phase 3 repair round 1 produced a NEW counterexample `spec/output/MC_hunt_scenario4_mc4_repaired.out`.
Re-checked it: identical mechanism to the original `_final.out` — trace_length 3,
`Initial -> MCNext(pmask: t1.bl=[15]) -> MCNext(kill: p1 alive->zombie, g.maskedActed=true)`,
invariant `MaskedSignalDeferred` violated. The spec repair did NOT remove the CE, which is correct:
this is a real code defect faithfully modeled, so no spec repair can (or should) hide it.

Source re-audit: the worktree was reset between rounds (my repro test edit was lost; the current
worktree carries only the Specula trace harness: tla_world.rs/tla_trace.rs + pm/{mod,test}.rs,
process/state/mod.rs). `manager/mod.rs:849-897` is UNCHANGED — the `Default` arm still maps
Terminate/Core -> PostAction::Terminate and Stop -> PostAction::Stop with NO mask check. Bug intact.

Re-reproduced at Level 0 against the real kernel (rebuilt test kernel + UserVM, booted). Verdict
unchanged: REPRODUCED. No prior statement is disproved; only the CE citation is updated
_final.out -> _repaired.out.

## Repair-round 1 — fresh re-execution (this turn)

The prior continuation turn crashed before emitting a canonical VERDICT (see error.txt:
"output has no canonical VERDICT"); its worktree edits were reset and no build artifacts remained
(bin/kernel-test.elf and bin/uservm.elf absent; in-kernel test gone). Re-established the Level-0
in-kernel test `test_mc4_masked_default_action_signal_acted_upon` in `pm/test.rs` (drives the REAL
`ProcessManager::kill()` via public API: `sigprocmask` + `kill` + `sigpending`, plus a caught-SIGINT
control), fixing one import (`::sys::pm::{SIGINT, SIGTERM}` — the `signal` submodule is private).
Rebuilt (`make all-test-kernel all-uservm`, exit 0) and booted via UserVM. Fresh serial output:

  test_mc4...: MC-4: SIGTERM (default, masked) -> kill outcome=Ok(TerminateSelf), sigpending&SIGTERM=0x0
  test_mc4...: MC-4: SIGINT (handler, masked) -> kill outcome=Ok(Done), sigpending&SIGINT=0x2
  test_mc4...: BUG MC-4 REPRODUCED ... MaskedSignalDeferred violated at manager/mod.rs:858.
  test(): passed: test_mc4_masked_default_action_signal_acted_upon
  kernel_magic_string(): hello, world!

`git blame` at HEAD reconfirms the `Default` arm (mod.rs:858-871) still has NO mask check (most
recent touch 787aa7534 "Add SIGCHLD and Stop/Cont job control", 2026-06-28, added the Stop arm —
still ungated); mask-awareness (094b4cd3) was added only to the Handler/Interrupt path. No filed
issue/PR reports or fixes THIS mechanism => Novelty NEW stands. Final verdict: REPRODUCED.
