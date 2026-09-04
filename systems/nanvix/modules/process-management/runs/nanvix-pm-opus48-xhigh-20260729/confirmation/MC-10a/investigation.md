# Investigation — MC-10a: Nested sigsuspend overwrites the single saved-mask slot

- **Source**: MC (real counterexample `spec/output/MC_hunt_MC-10a.out`, invariant `MCSavedMaskRestored`)
- **Config**: `MC_hunt_scenario7.cfg`

## Step 1 — Code audit (facts)

### Cited sites
- `src/kernel/src/pm/process/manager/mod.rs:722-749` — `install_sigsuspend_mask`.
  - `:733` `let previous = state.blocked();`
  - `:734` `state.set_saved_blocked(Some(previous));`  ← unconditional store into the single slot.
  - `:735` `state.set_blocked(installed);`
- `src/kernel/src/pm/thread/state.rs:105` — `saved_blocked: Option<u64>` (a single slot).
  - Doc `:100-104`: "Set by `sigsuspend()` to the mask in effect before it installed its temporary mask. When present, `sigreturn()` restores it (instead of the frame's saved mask) so the original mask is reinstated after the interrupting handler runs." No mention of nesting.
- `src/kernel/src/pm/process/manager/signal.rs:546-618` — `sigreturn_restore`.
  - `:607-610` `let restored_blocked = match state.take_saved_blocked() { Some(saved) => saved & !UNBLOCKABLE, None => frame.blocked & !UNBLOCKABLE };`  ← falls back to the on-stack frame mask when the slot is empty.
- `src/kernel/src/pm/process/manager/signal.rs:206-316` — `try_deliver_signal` (builds the frame).
  - `:221` reads `blocked = state.blocked()` (mask in effect at delivery = the temporary sigsuspend mask).
  - `:288/:495` `build_signal_frame(... blocked ...)` → `frame.blocked = blocked` (the temporary mask).
  - `:296/:300` installs `new_blocked = next_blocked(blocked, sa_mask, signum, nodefer)` for the handler.
- `src/kernel/src/pm/process/state/sigframe.rs:154-160` — `next_blocked = current | sa_mask | (1<<(signum-1))` (unless NODEFER).

### Call chain / reachability (real interface)
`sigsuspend()` kcall (`kcall/sigsuspend.rs:96`) → `install_sigsuspend_mask` (:734 saves mask). A caught signal is delivered at the return-to-user checkpoint (`try_deliver_signal`), which builds a frame and runs the user handler. **A handler is ordinary user code and may itself call `sigsuspend()`** (legal POSIX; `sigsuspend` is async-signal-safe). That nested call re-enters `install_sigsuspend_mask` and executes `:734` again — overwriting the outer saved mask. On handler return, `sigreturn()` (`sigreturn_restore`) consumes the slot.

This is exactly the counterexample: `MC_hunt_MC-10a.out` = `MCSetDisposition` (install a handler) → `MCSigSuspendInstall` (State 3: `savedBlocked[t1]` becomes `{}`) → `MCSigSuspendInstall` (State 4: second install while the slot is still occupied ⇒ `savedMaskViolated = TRUE`). Trace length 4; invariant `MCSavedMaskRestored` violated.

### Concrete trigger + consequence (worked example)
Thread T, handlers for sig1 & sig2 (empty `sa_mask`, no special flags). Pre-suspend mask `orig = {2}` (app blocks sig2).
1. Outer `sigsuspend({})`: `:734` `saved_blocked = Some({2})`; `blocked = {}`.
2. sig1 delivered: `frame1.blocked = {}` (temp mask); `blocked = {1}`; `saved_blocked = Some({2})`. Handler1 runs.
3. Handler1 calls `sigsuspend({})` (nested): `:734` `saved_blocked = Some({1})` — **overwrites `Some({2})`; `orig={2}` is lost**; `blocked = {}`.
4. sig2 delivered: `frame2.blocked = {}`; `blocked = {2}`; `saved_blocked = Some({1})`. Handler2 runs.
5. Handler2 returns → `sigreturn_restore`: `take_saved_blocked() = Some({1})` ⇒ `blocked = {1}` (correct for the inner sigsuspend); slot now `None`. Inner `sigsuspend` returns EINTR to Handler1.
6. Handler1 returns → `sigreturn_restore`: `take_saved_blocked() = None` ⇒ falls back to `frame1.blocked = {}`. **`blocked = {}`, not `orig = {2}`.**

Result: after the outer `sigsuspend` fully unwinds, the thread's blocked mask is the temporary suspend mask `{}` instead of the pre-suspend mask `{2}`. The application's blocked sig2 is now permanently unblocked — a POSIX violation ("sigsuspend shall restore the signal mask ... to the set that existed before the call").

### Real consumer of the wrong outcome
- `try_deliver_signal` (`signal.rs:242`) computes deliverability as `(pending | thread_pending) & !blocked`. With `blocked` wrongly cleared, sig2 (which the app had blocked) becomes deliverable → the handler runs when the app expected it masked.
- A subsequent `sigprocmask(SIG_SETMASK? / query)` would report the wrong mask.

### Safeguards
`install_sigsuspend_mask` has **no** guard against `saved_blocked` already being `Some` (`:734` is unconditional). `restore_sigsuspend_mask`/`sigreturn_restore` `take()` the single slot. No stack of saved masks exists. Nothing prevents or repairs the overwrite. The loss is permanent (no downstream sync/resend/guard).

### Environment note
The kernel is `#![no_std] #![no_main]` on a custom `x86` (32-bit) target; `sigreturn_restore` is gated `if !cfg!(target_arch = "x86") { return Unsupported }` (`signal.rs:551`). It cannot be linked/run as a host unit test; the literal end-to-end trigger needs a QEMU x86-32 boot + a userspace program doing nested `sigsuspend`. The bug is **deterministic** (a single-slot data-structure limitation, no race/timing), so a faithful port of the exact three functions reproduces it exactly.

## Step 2 — Developer-knowledge search (evidence)
- `git blame` mod.rs:734 → commit `094b4cd3d` "[kernel] F: Deliver Signals To Blocked Threads" (Pedro Henrique Penna, 2026-06-27). The commit/PR (#2735) adds the single-slot `saved_blocked` + `sigreturn` restore. No mention of nested sigsuspend.
- `state.rs:100-105` doc describes the single-slot design; silent on nesting.
- No `TODO`/`FIXME`/"known limitation" about nesting at the sites.
- Tests: `test-c-sigmask` (#2888) and `kill-rust` (#2735) cover single sigsuspend / EINTR / SA_RESTART, and only `sigsuspend(NULL)` for the mask path. No test exercises nested sigsuspend. No test asserts the current (buggy) nested behavior.

## Step 3 — Known-status / precedent
Upstream is `nanvix/nanvix` (monorepo; `homepage=github.com/nanvix`). Tracker searches:
- `sigsuspend repo:nanvix/nanvix` → 11 items, all feature PRs/issues (#2690 umbrella, #2691/#2701 plumbing, #2695 blocking-call interruption, #2715 add sigsuspend, #2735 deliver-to-blocked, #2888 test coverage). None report the nested-overwrite defect.
- `saved_blocked` → only #2690/#2691/#2701/#2735 (the implementing PRs).
- `nested sigsuspend`, `sigsuspend reentrant`, `signal mask overwrite`, `nested signal handler mask` → no matching bug report.

No issue/PR/CVE/advisory reports THIS mechanism (nested sigsuspend overwriting the single `saved_blocked` slot). Feature-implementation PRs and the umbrella feature tracker do **not** count as a filed report of this defect.

**Novelty: NEW.** **Source: MC.** No pre-filter drop (MC-sourced with a real counterexample). Proceed to Phase 2.

## Phase 2 — Reproduction (REPRODUCED, Level 2)

Technique: in-kernel test (`feature = test`) driving the REAL `ProcessManager` entry points on a
real `RunnableProcess` published to the ready list (create_process's product), booted via the
standalone UserVM — the same gold-standard harness prior PM findings used. The x86 kernel target
keeps the real signal paths active.

Wired into `src/kernel/src/pm/process/manager/test.rs` as
`test_nested_sigsuspend_overwrites_saved_mask`, registered in `pub(super) fn test()`.

Real-API call sequence (maps to CE MCSigSuspendInstall×2):
`sigprocmask(SET, {SIGUSR2}=orig)` → `install_sigsuspend_mask({})` [outer] →
`sigprocmask(SET, {SIGUSR1})` [handler-running mask; delivery never writes saved_blocked] →
`install_sigsuspend_mask({})` [nested → OVERWRITE, :734] →
`restore_sigsuspend_mask()` [inner return consumes the single slot] →
`restore_sigsuspend_mask()` [outer return: slot empty → cannot reinstate orig].

Observed serial (real kernel):
```
mc10a: saved_after_outer=Some(2048) saved_after_nested=Some(512) (orig=0x800)
       saved_after_inner=None final_blocked=0x200 usr2_still_blocked=false
       would_deliver_masked_usr2=true
mc10a REPRODUCED: ... outer sigsuspend restored blocked=0x200 instead of the pre-suspend
       mask 0x800 — SIGUSR2 is now UNBLOCKED though the application had blocked it
passed: test_nested_sigsuspend_overwrites_saved_mask
```
Decode: orig=0x800 (SIGUSR2). Outer install saved it (0x800); nested install overwrote with the
handler mask 0x200 (SIGUSR1); inner restore emptied the slot (None); outer restore left
blocked=0x200 — SIGUSR2 permanently unblocked. Consumer `try_deliver_signal` (signal.rs:242,
`(pending|thread_pending) & !blocked`) would now deliver the app-masked SIGUSR2
(`would_deliver_masked_usr2=true`).

Both restore variants lose orig: `restore_sigsuspend_mask` (used here) no-ops on an empty slot;
`sigreturn_restore` (signal.rs:607-610) falls back to `frame.blocked` = the empty temp mask — also
not orig. Destruction is permanent (no other copy of orig anywhere in kernel state); no downstream
mechanism reinstates it.

Repro artifacts:
- `repro/test_bugMC-10a_nested_sigsuspend_saved_mask.rs` (wired test copy + how-to + output)
- `repro/test_bugMC-10a_nested_sigsuspend_saved_mask.sh` (build+boot runner → `[PASS] REPRODUCED`)

Verdict: **REPRODUCED** (Level 2, real APIs on real kernel).
