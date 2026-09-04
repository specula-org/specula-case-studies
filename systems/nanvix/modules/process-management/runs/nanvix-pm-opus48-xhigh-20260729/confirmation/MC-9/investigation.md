# MC-9 Investigation — Immortal pending signal after a disposition change

Invariant: `NoImmortalPending` (`MCNoImmortalPending`), scenario 6, config `MC_hunt_scenario6.cfg`.
Counterexample: `spec/output/MC_hunt_MC-9.out` (trace length 5).
Source: **MC** (real counterexample trace).

## Step 1 — Code audit (facts)

CE trace actions: `Initial -> MCCreateProcess -> MCSetDisposition -> MCPostSignalHandler -> MCSetDisposition`.
Per-state (`disposition[p1][1]`, `pending[p1]`, `immortalPending`):
- s3 `MCSetDisposition`: disposition[p1][1] = handler
- s4 `MCPostSignalHandler`: pending[p1] = {1}
- s5 `MCSetDisposition`: disposition[p1][1] = default; pending[p1] still {1}; **immortalPending = TRUE**

Cited code (worktree == upstream `nanvix/nanvix` `dev` HEAD, verified byte-identical):
- `state/signal.rs:364` `SignalControl::set_disposition` — `core::mem::replace` on the slot only; **never clears pending**.
- `manager/mod.rs:583-614` `ProcessManager::sigaction` — captures `oldact`, calls `set_disposition` (:605); never touches pending.
- `manager/mod.rs:849-882` `ProcessManager::kill` — adds to the process pending set **only** on the `Handler` arm (`signals.post(signum)`, :854-855). `Default` resolves the default action immediately at post time; `Ignore` -> nothing. So the process pending set is populated *only* by a signal posted while its disposition is a Handler.
- `manager/signal.rs:240-253` `try_deliver_signal` — `deliverable = (pending | thread_pending) & !blocked`, then delivers **only** `Handler` dispositions; every other pending signal is skipped and left pending (never cleared).

Consequence: a signal posted while caught (Handler), then re-dispositioned via `sigaction` to `SIG_IGN` or `SIG_DFL`, is (a) not discarded (set_disposition leaves the bit) and (b) not delivered (try_deliver only handles Handler). It is **stuck pending forever**.

Reachability: fully reachable through the real kcall interface — `Sigaction` (kcall 41) and `Kill` (kcall 43) are normal user operations (e.g., install SIGINT handler; raise; temporarily `SIG_IGN` during a critical section; restore handler).

Permanence (no downstream mask): audited every `clear_pending` call site — delivery of a Handler frame (`manager/signal.rs:264,301,306,424,429`, all gated on selecting a Handler), stop clears SIGCONT (`mod.rs:962`), continue clears stop-signals (`mod.rs:985`), `reset_for_exec`/`inherited_for_fork` on exec/fork. **None** clears a process-pending non-handler signal. The state is permanent until exec/exit.

## Step 2 — Developer knowledge

- `git blame` `set_disposition` -> commit `9c727ee21` "[kernel] F: Implement sigaction and sigprocmask" (P. Penna, 2026-06-25). Signals subsystem built incrementally (`F: Deliver Caught Signals`, `F: Add SIGCHLD and Stop/Cont`). WIP, but no filed bug on this gap.
- Umbrella design issue `nanvix/nanvix#2690` ("[signals] Enable POSIX Signal Support"), a **Feature** epic, closed 2026-06-29 with all 7 sub-issues complete. Its design table explicitly documents intended disposition semantics: **`SIG_IGN` (discard)**. This is *evidence of intent* that the current behavior deviates from the promised semantics — it is not a bug report of this defect.
- The `try_deliver_signal` comment (`manager/signal.rs:236-239`) says non-handler pending signals are "left pending and skipped … job-control stop/continue that kill() records for a later phase." But `kill()` does **not** record stop/continue as pending (it applies them directly and clears them), so the only real producer of a non-handler pending signal is exactly this re-disposition path — which the comment does not acknowledge.

## Step 3 — Known-status / precedent

Searched `nanvix/nanvix` issues/PRs (`pending discard`, `signal ignore pending`, code search on `set_disposition`) and upstream `dev` HEAD. Results: only the signal **feature** sub-issues (#2690–#2697, all Feature type) and unrelated bugs (#2908 bulk-pull). **No** issue/PR/CVE reports "set_disposition/sigaction fails to discard a pending signal" or "immortal pending after disposition change". Upstream `dev` `sigaction`/`set_disposition` are byte-identical to the worktree — **unfixed**.

Novelty: **NEW**. Not a code-review × known drop (MC-sourced with a real counterexample anyway).

## Reproduction summary

In-kernel test `test_mc9_disposition_change_leaves_signal_immortally_pending`
(`src/kernel/src/pm/process/state/signal_test.rs`, wired into the boot test aggregator), driving the
real `SignalControl::set_disposition`/`post`/`pending`/`disposition` and a verbatim replica of the
`try_deliver_signal` selection loop, booted in the standalone UserVM. Level 0/1 (normal real-API
sequence, no fault injection). Observed (`repro/test_bugMC-9_immortal_pending.run.log`):
- CASE-A (SIG_IGN): `still_pending_after_SIG_IGN=true`; after reinstalling a handler `try_deliver selects=Some(1)` -> spurious delivery of a signal POSIX discarded.
- CASE-B (SIG_DFL, exact CE trace): `still_pending_after_SIG_DFL=true`, `try_deliver_selects=None` -> immortal pending (NoImmortalPending violated).
- CONTROL: a caught signal never re-dispositioned is delivered (`Some(1)`), isolating the defect to the re-disposition path.

Verdict: **REPRODUCED** (Level 0/1). Consumer = `try_deliver_signal` (`manager/signal.rs:242,248`); state is permanent (no clearing path).

---

## Fresh reproduction (this run) — EXECUTED

Reproduction driver: `src/kernel/src/pm/process/manager/mc9_test.rs`
(`test_mc9_immortal_pending_after_disposition_change`), wired into the process-manager test
aggregator (`manager/test.rs::test()` -> `mc9_test::test()`), built with
`make all-test-kernel all-uservm` and booted in the standalone UserVM
(`./bin/uservm.elf -kernel bin/kernel-test.elf -kernel-args test_magic=0xDEADBEEF`).

The driver uses the REAL process-manager entry points `ProcessManager::sigaction` (kcall 41) and
`ProcessManager::kill` (kcall 43). The target is the exact product of process creation (a
`RunnableProcess` with one ready thread on the ready list, == `create_process` product,
manager/mod.rs:1208). Level 0 signal ops; the only setup is a Level-2 construction of the
create_process product (CE step `MCCreateProcess`).

Observed console (repro/test_bugMC-9_immortal_pending.run.log), harness exit 0, kernel booted to
`hello, world!` with all in-kernel tests passing:
- precondition: SIG 1 caught (Handler) and pending — established via real sigaction+kill.
- [B][SIG_DFL] after sigaction(SIG_DFL): pending=0x1, disposition_is_handler=false ->
  try_deliver_signal selects None (never) — immortal=true  (EXACT CE State 5).
- [B][PERMANENCE] after a query sigaction(None) + null-signal kill: pending=0x1 -> still immortal=true.
- [A][SIG_IGN] after sigaction(SIG_IGN): pending=0x1 — POSIX requires discard; still_pending=true.
- [A][SIG_IGN] after reinstalling a handler: pending=0x1, disposition_is_handler=true ->
  try_deliver_signal would SPURIOUSLY deliver a signal SIG_IGN should have discarded — spurious=true.
- [CONTROL] never re-dispositioned: pending=0x1, disposition_is_handler=true -> deliverable=true
  (isolates the defect to the re-disposition path).
- VERDICT: REPRODUCED.

Novelty re-check (this run): `git log --all` on signal.rs shows `set_disposition` introduced by the
feature commit `9c727ee21` (2026-06-25) and never modified by any fix; no bug-fix commit for
discard-on-IGN. Upstream `nanvix/nanvix` HEAD (code search, ref f3eeb4e...) has the identical
swap-only `set_disposition`; the only tracker reference is the Feature epic #2690 documenting the
INTENDED `SIG_IGN (discard)` semantics (design intent, not a filed bug of this defect). The existing
`test_set_disposition_swaps_and_returns_previous` asserts only the swap, not discard. Novelty: NEW.

Verdict: REPRODUCED (Level 0 signal ops + Level-2 create_process-product setup). Consumer =
`try_deliver_signal` (manager/signal.rs:242,248); permanent (no clear path; demonstrated at runtime).

---

## Fresh reproduction (turn01_A, this run) — EXECUTED, REPRODUCED

Driver `repro/test_bugMC-9_immortal_pending.{rs,sh}`: an in-kernel `feature="test"` module
(`mc9_repro.rs`, wired into `manager/test.rs::test()`), built with `make all-test-kernel all-uservm`
and booted in the standalone UserVM. It drives an ISOLATED `ProcessManager` through the REAL entry
points `sigaction` (kcall 41), `kill` (kcall 43, caller granted `ProcessManagement` via real
`capctl`), and observes the consequence through the REAL `sigsuspend()` deliverability oracle
`install_sigsuspend_mask` (mod.rs:722) plus the real pending set `signals().pending()` — the delivery
selection loop is NOT replicated. Worktree reverted to clean afterward.

Observed console (`repro/test_bugMC-9_immortal_pending.run.log`; harness exit 0; clean boot to
`hello, world!`, all in-kernel tests passed):
- CONTROL (handler, never re-dispositioned): pending=0b0100000000000000, sigsuspend_deliverable=true.
- CASE B (handler->post->SIG_DFL, EXACT CE): pending_posted / pending_after_dfl /
  pending_after_query+nullkill all = 0b0100000000000000 (bit 14 = SIGTERM 15); sigsuspend_deliverable
  = FALSE. == CE State 5 (pending={sig}, disposition=default, immortalPending=TRUE). Permanent.
- CASE A (handler->post->SIG_IGN->reinstall handler): pending_after_ign=0b0100000000000000 (NOT
  discarded — POSIX violation); spurious_deliverable_after_reinstall=TRUE.

Real consumer observing the wrong outcome: `install_sigsuspend_mask` (mod.rs:722, the real
`sigsuspend()` path) returns false for the immortal SIG_DFL signal (sigsuspend sleeps forever) and
true after a SIG_IGN->handler reinstall (spurious delivery); the same pending set is what
`try_deliver_signal` (signal.rs:242,248) consumes. Novelty re-checked via git history: only feature
commit 9c727ee21 ever touched set_disposition; no discard/ignore-pending fix commit -> NEW.

Verdict: REPRODUCED (Level 0 real signal ops + Level-2 admissible create-product construction).
