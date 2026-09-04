# MC-6 Investigation — Nested signal delivery during sigsuspend corrupts the saved mask

Source: MC (real counterexample `spec/output/MC_hunt_scenario4_mc6_final.out`, invariant
`SigsuspendMaskRestored`).

## Step 1 — Code audit

Cited sites (worktree paths; finding's `sync/signal.rs:607` is actually `process/manager/signal.rs:607`):

- `thread/state.rs:93,105` — `ThreadState { blocked: u64, saved_blocked: Option<u64> }`. A SINGLE
  per-thread saved-mask slot. `take_saved_blocked()` (452-453) is `self.saved_blocked.take()`.
- `process/manager/mod.rs:730-735` — `install_sigsuspend_mask`: `previous = blocked; set_saved_blocked(Some(previous)); set_blocked(installed)`.
- `process/manager/signal.rs:294-303,495` — `try_deliver_signal` commit: `build_frame(cpu, blocked, ...)`
  saves the pre-delivery mask INTO the frame, then `set_blocked(next_blocked(...))`. Does NOT touch
  `saved_blocked`.
- `process/manager/signal.rs:604-612` — `sigreturn_restore` mask precedence (the defect):
  `match take_saved_blocked() { Some(saved) => saved, None => frame.blocked }`.

Mechanism: the single `saved_blocked` slot is written only by `sigsuspend` but CONSUMED by the first
`sigreturn` that runs. If a caught signal is delivered while a `sigsuspend()` is in progress, the
nested handler's `sigreturn` calls `take_saved_blocked()` → gets the sigsuspend-saved mask and clears
the slot. When the `sigsuspend()` interruption itself later unwinds, the slot is `None`, so
`frame.blocked` (the wrong, temporary mask) is restored. The pre-suspend mask is lost.

Call chain / reachability: `kcall/sigsuspend.rs` → `install_sigsuspend_mask`; caught-signal delivery
at the return-to-user checkpoint → `try_deliver_signal`; `kcall/sigreturn.rs` → `sigreturn_restore`.
All are real syscalls. Calling `sigsuspend()` from inside a signal handler and taking a second caught
signal during it are legal POSIX usage → reachable.

Real consumer of the corrupted state: `try_deliver_signal` reads `state.blocked()` (signal.rs:221)
and computes `deliverable = (pending | thread_pending) & !blocked` (signal.rs:242). After the
corruption the thread's `blocked` is empty, so a signal it had blocked before `sigsuspend()` becomes
wrongly deliverable. `sigpending` (mod.rs:690) and future `sigprocmask` reads are similarly affected.

Safeguards: none. Nothing re-derives or repairs `blocked` afterward; the slot is `None` and both
frames are gone. The corruption is permanent for the thread.

## Step 2 — Developer-knowledge search

- `git log` on signal.rs / mod.rs / state.rs: signal support is freshly implemented
  (`c7cb73b66 F: Deliver Caught Signals`, `094b4cd3d F: Deliver Signals To Blocked Threads`,
  `3fcdf9a3c F: Map CPU Exceptions to Signals`, `9c727ee21 F: Implement sigaction and sigprocmask`).
  No commit message acknowledges the nested-sigsuspend mask-restore issue.
- Doc comments (mod.rs:704-710, signal.rs:600-603) state the design intent: "sigsuspend() must leave
  the mask unchanged on return"; sigreturn "reinstate the mask it saved ... instead of the frame's
  saved mask". This confirms the DESIGN promises the property the CE violates — evidence the
  consequence is real, not intended.
- No `TODO`/`FIXME`/"known issue" near the sites.

## Step 3 — Known-status / precedent

Upstream tracker search (issues + PRs): only umbrella/feature-tracking issues found —
`#2690 [signals] Enable POSIX Signal Support`, `#2694 [signals] Asynchronous Signal Delivery
(frame build/sigreturn)`. These describe IMPLEMENTING async delivery + per-frame `frame.blocked`
(which the code does). Neither is a bug report of the single-`saved_blocked`-slot nested-sigsuspend
corruption at this site. The worktree code still uses a single slot (unfixed). No CVE/advisory.
→ Novelty: NEW (looked at issues + recent PRs; nothing reports THIS mechanism at THIS site).

Source is MC (real counterexample) → proceeds to Phase 2 regardless.
