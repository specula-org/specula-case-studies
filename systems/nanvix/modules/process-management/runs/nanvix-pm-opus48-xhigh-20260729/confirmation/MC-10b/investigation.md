# MC-10b Investigation — RestartAttribution ("SA_RESTART applied per the delivered signal, not the interrupting one")

## Finding
- id: MC-10b, source: model-checking, invariant: `RestartAttribution` (ghost `restartMisattributed`)
- config: `MC_hunt_scenario7.cfg`, counterexample: `spec/output/MC_hunt_MC-10b.out`
- claim: `try_deliver_signal` consumes a signum-less restart record and applies `SA_RESTART`
  based on the lowest-numbered *delivered* caught signal, not the signal that interrupted the call.

## Step 1 — Code audit (ground truth = Rust)

### The restart record is created with NO signal number
- `kcall/dispatcher.rs:274-288` `handle_sleep_error(InterruptReason::Signaled)` ->
  `set_running_thread_restart(KcallRestart { number, args })`. Only the interrupted CALL's
  number/args are recorded; NO signal number.
- `pm/thread/state.rs:56-62` `struct KcallRestart { number, args }` — no signal field.
- `pm/thread/state.rs:528-544` `set_restart` / `take_restart` — opaque record, no signal identity.

### The delivered signal governs restart (signal.rs:206-316)
- `:220` `take_restart()` consumes the record unconditionally at EVERY return-to-user boundary.
- `:240-254` selects the LOWEST-numbered deliverable caught signal:
  `deliverable = (signals.pending() | thread_pending) & !blocked`, then loops taking the lowest set
  bit whose disposition is `Handler` (non-handler dispositions are skipped, left pending).
- `:280-284` applies restart iff `restart.is_some() && (sa_flags & SA_RESTART) != 0`, where
  `sa_flags` are the DELIVERED signal's flags.

### This matches POSIX/Linux exactly
Linux `dequeue_signal` delivers the lowest-numbered pending unblocked signal first; `handle_signal`
decides syscall restart from THAT signal's `SA_RESTART` (`-ERESTARTSYS` -> restart iff
`ka->sa.sa_flags & SA_RESTART`); the first handler seen governs, later ones do not re-decide.
Nanvix's loop (lowest deliverable CAUGHT signal governs) is identical. There is no separate
"interrupting signal" notion in real Unix restart semantics — the DELIVERED (dequeued) signal
governs. sigsuspend never leaves a restart record (`pm/kcall/sigsuspend.rs:44,127-129`), so it is
never spuriously restarted.

### Reachability of the CE state
CE (`MC_hunt_MC-10b.out`): disposition p1 = <<default, handler>>, pending = {2}, `intrSig[t1]=1`,
`restart[t1]=TRUE`, then `MCDeliverSignal` sets ghost `restartMisattributed=TRUE`. i.e. the model
marks the call "interrupted by signal 1" while signal 1 is DEFAULT-disposition and NOT pending,
then delivers signal 2. In the real code a default, non-pending signal can never create a restart
record (only a caught signal that interrupts does, and it posts itself to `pending`). The `intrSig`
the invariant attributes against DOES NOT EXIST in the implementation.

## Step 2 — Developer-knowledge / intent (verbatim)
- `pm/process/state/tla_world.rs:528` comment: "Bug-ghost fields: always false on a real
  (non-buggy) execution." and `:532` hardcodes `,"restartMisattributed":false`. The
  implementation-to-model bridge asserts this ghost can never be true on a real run.
- `pm/process/state/tla_world.rs:1055-1061` `mark_interrupted(sig)`: "records a signum-less
  restart record on the running thread" — it stores `KcallRestart { number:0, args:[0;4] }` and
  emits `sig` only as trace metadata; the interrupting-signal number is DISCARDED by the real code.
- `signal.rs:275-284`, `dispatcher.rs:274-286`, `thread/state.rs:51-54` document intent: restart is
  governed by the DELIVERED handler's `SA_RESTART`, "the kernel's analog of Linux's ERESTARTSYS".
- `MC_hunt_scenario7.cfg` (this finding's own config) NOTE: "the former MC-10b RestartAttribution
  invariant was removed as a spec artifact -- the implementation applies SA_RESTART per the
  DELIVERED (lowest-numbered deliverable caught) signal (signal.rs:240-283), exactly as POSIX/Linux,
  and the signum-less KcallRestart record carries no 'interrupting signal' to attribute against."
  The cfg's `INVARIANTS` list no longer contains `MCRestartAttribution`.

## Step 3 — Known-status / precedent
MC-sourced with a real counterexample => not subject to the code-review x known pre-filter; proceeds
to Phase 2.

## Preliminary reading (verdict decided in Phase 2)
The implementation applies `SA_RESTART` per the delivered (lowest deliverable caught) signal —
POSIX/Linux-correct. The invariant `RestartAttribution` / ghost `restartMisattributed` checks
attribution against a model-only `intrSig` that the implementation neither tracks nor promises
(signum-less record; bug-ghost hardcoded false). The path is benign; the oracle over-flags =>
candidate INVARIANT artifact (PENDING REPAIR), pending the reproduction result.

## Phase 2 — Reproduction (independent re-confirmation)
- Repro: `repro/test_bugMC-10b_restart_attribution.c` (Level 0, real public API on host Linux, which
  Nanvix explicitly emulates — thread/state.rs:51-54 "analog of Linux's ERESTARTSYS").
- Part B (deterministic): the DELIVERED signal's SA_RESTART flag ALONE governs whether an interrupted
  `read()` restarts, independent of signal number — USR1/USR2 × {SA_RESTART, none} = {RESTART, EINTR}
  all PASS. Mirrors signal.rs:280-283.
- Part C: faithful port of try_deliver_signal (signal.rs:240-284) on the CE pending set {2} with a
  signum-less restart record delivers sig2 and governs restart by ITS flag, agreeing with the POSIX
  rule from Part B. No signum in the record to attribute against.
- Part A (informational): real-OS multi-signal delivery order is POSIX-unspecified (this host delivered
  [12,10]); irrelevant to attribution.
- Escalation ladder: Level 0 sufficed to establish the semantics; a full Nanvix boot + userspace
  handler trigger (Level 2/3) is unnecessary because the flagged behavior is confirmed benign/
  POSIX-correct by code audit + host POSIX ground truth; the model's `intrSig`/interrupting-signal
  identity does not exist in the implementation (signum-less KcallRestart; ghost hardcoded false).
- Novelty: git history has no restart-attribution fix commit; GitHub code search + web search found no
  issue/PR reporting this mechanism -> NEW.
- Verdict: PENDING REPAIR (INVARIANT). The path reproduces but has no wrong consequence, and developer
  intent (bridge hardcodes `restartMisattributed:false`; signum-less record; EINTR/SA_RESTART tests)
  shows the implementation does not promise per-interrupting-signal attribution. Repair draft written to
  `repair-request.body.md`.
