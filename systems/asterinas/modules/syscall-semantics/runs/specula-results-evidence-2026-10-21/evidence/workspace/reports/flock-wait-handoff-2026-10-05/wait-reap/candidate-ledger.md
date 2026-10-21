# Wait/reap proposed candidate ledger (as of pause, 2026-10-06)

No entry here is a confirmed Asterinas bug. No new AST ID is requested. The coordinator assigns
final IDs.

| Lane ID | Kind and source | Disposition | Evidence | Novelty |
| --- | --- | --- | --- | --- |
| WR-SQ | Source lead from preparation (`contracts.md`), kept by native analysis | NOT_RUN, ambiguous/requires investigation. Asterinas `sys_waitid` returns 0 on the WNOHANG no-event branch without writing siginfo (`kernel/core/src/syscall/waitid.rs:49-51`). Pinned Linux writes zeroed `si_signo`/`si_code`/`si_pid`/`si_uid`/`si_status` (`kernel/exit.c:1804-1825`). The harness prepares a poisoned-output control that has not run. | `contracts.md`, `analysis-report.md` (WR-SQ section) | Not established. Persistent lookup and catalog screen found no match. Historical lead, not a new finding. |
| WR-CF | Calibration from preparation | NOT_RUN. Both Linux and Asterinas consume before copyout, so EFAULT without rollback is a permitted outcome, not a defect. | `contracts.md`, `analysis-report.md` | Calibration, not a candidate |
| WR-LEAD-WEXITED | Controller source observation during gate 1, not in the native brief | Unverified, outside the lane's call matrix (stop/continue excluded). `try_wait_children` consumes a zombie without checking WEXITED (`kernel/core/src/process/wait.rs:310-319`). Linux `wait_task_zombie` returns 0 when WEXITED is absent (`kernel/exit.c:1167-1168`). By source reading, `waitid(P_PID, pid, WSTOPPED)` on Asterinas could reap an exited child that Linux leaves waitable. Linux comparison and runtime are NOT_RUN. | `execution/gates.md` (gate 1) | Unknown, needs a catalog and upstream search before any claim |
| Protocol properties (Q1 to Q4) | Model checking on accepted r2 | No counterexample. Publication complete. Restricted wakeup liveness complete. Other configurations time-limited without violation. | `spec-fix-2026-10-05/independent-verify/` | Negative result within bounds |

Rejected hypotheses recorded by the native analysis (duplicate wakes as double consumption, late
WNOWAIT output as post-reap recovery, map removal as object destruction, relaxed exit-code read as
stale status, blocked SIGCHLD as no wake, EFAULT rollback) are listed with reasons in
`analysis-report.md` ("False positives, unsupported conclusions, and scope exclusions").

## Proposed catalog text (for the coordinator to merge)

Run entry row:

```text
| Child wait/reap: `asterinas-child-wait-reap-20261004T160159Z` | `0c60537098f4c2949ad2d382aaf499de72263d76` | PAUSED 2026-10-06 before harness execution. Analysis PASS 35/35; spec accepted at r2 (PASS 40/40); bounded TLC found no violation (publication and restricted wakeup liveness complete, others time-limited). Harness v5 approved for CONSISTENCY_UNDER_SAMPLED_CLOCK_BOUND, not yet executed. WR-SQ and WR-CF remain NOT_RUN; WR-LEAD-WEXITED is an unverified out-of-scope source lead. No finding assigned. | [Lane result](../flock-wait-handoff-2026-10-05/wait-reap/result.md) |
```

Old-ID map rows:

```text
| `asterinas-child-wait-reap-20261004T160159Z` | WR-SQ | Unassigned | waitid WNOHANG no-event output clearing; NOT_RUN source lead. |
| `asterinas-child-wait-reap-20261004T160159Z` | WR-LEAD-WEXITED | Unassigned | waitid without WEXITED may reap a zombie (source reading only); outside lane scope, unverified. |
```

## Update 2026-10-10 (outcome run d8)

- **Linux controls**: 21/21 match the pinned Linux-source expectations. That includes WR-SQ,
  where Linux zeroes the selected siginfo fields on a no-event WNOHANG, and WR-LX, where Linux
  returns ECHILD for `waitid(P_PID, zombie, WSTOPPED|WNOHANG)` and then consumes with WEXITED.
- **Asterinas side of WR-SQ, WR-CF and WR-LX**: still NOT_RUN in effect. Every guest fixture
  aborted at the placement assertion before any wait syscall. WR-SQ and WR-LX remain source
  leads, now with a confirmed Linux baseline.
- **New out-of-scope observation, WR-OBS-AFFINITY** (runtime-observed, novelty not checked).
  On the pinned Asterinas, `sched_setaffinity` to a single other CPU returns 0, but the caller
  keeps running on its old CPU (`sched_getcpu()` unchanged). The source says migration is
  unsupported (`kernel/core/src/syscall/sched_affinity.rs:33`). Linux migrates before returning,
  and the same assertion passed in all 21 Linux controls. This is a Linux-compatibility
  difference outside the wait/reap protocol, with no security impact shown. Disposition:
  unsupported behavior, documented by a TODO in the source.

Proposed old-ID map row:

```text
| `asterinas-child-wait-reap-20261004T160159Z` | WR-OBS-AFFINITY | Unassigned | sched_setaffinity does not migrate the caller (documented TODO); observed in guest runs, out of lane scope. |
```

## Final dispositions (2026-10-10, outcome run d9)

Run d9's evidence is outcome-only, with no implementation trace. Trace validation is
BLOCKED_ENVIRONMENT. D9R5-S1 is an accepted residual, and review-v6j's verdict was NOT_APPROVED.
Native confirmation did not run because findings refused for `bug-report MISSING`.

| Lane ID | Disposition | Evidence |
| --- | --- | --- |
| WR-LX | **Runtime-observed Linux-compatibility defect, not natively confirmed.** In the Asterinas guest, `waitid(P_PID, zombie, WSTOPPED\|WNOHANG)` returned 0 with CLD_EXITED and status 37 and consumed the child. The next WEXITED wait got ECHILD. Linux returns ECHILD and keeps the child waitable, and the Linux control matched. Source: `process/wait.rs:310-319` has no WEXITED test. No security impact demonstrated. Sequential, so no SMP needed. | `evidence/20261010T074837Z-…/outcomes/guest-zombie-without-wexited.outcome.json` vs `linux-zombie-without-wexited.outcome.json` |
| WR-SQ | **Runtime-observed Linux-compatibility difference, not natively confirmed.** A no-event `waitid(WEXITED\|WNOHANG)` returned 0 and left the poisoned siginfo unchanged. Linux zeroes the selected fields, and the Linux control matched. Source: `syscall/waitid.rs:49-51`. No security impact demonstrated. | `outcomes/guest-siginfo-poison.outcome.json`, `linux-siginfo-poison.outcome.json` |
| WR-CF | Calibrated. Asterinas per-call outcomes match the Linux-source expectations for consuming wait4 and waitid faults and for the WNOWAIT fault. | `outcomes/guest-copyout-*.outcome.json` |
| WR-01 to WR-10 protocol | Per-call match (94/97 overall, with mismatches only in WR-SQ and WR-LX). Competing consumers: one success and one ECHILD in all 8 runs. **No concurrency claim**, because placement is not credible (`actual_cpu` 123). Model: bounded TLC with no violation. | `outcomes/guest-consumers*.outcome.json`, `spec-fix-2026-10-05/independent-verify/` |
| WR-OBS-AFFINITY | Out of scope. Unsupported behavior documented by a TODO. `sched_getcpu()` also reported CPU 123 on a 2-CPU guest (unverified). | gates.md, run v6d8 and d9 placement |

Novelty screen: the findings catalog has only the WR-SQ placeholder. Asterinas issues and PRs
about `waitid` (#1216, #1197, #2511) concern panics and pidfd errno. Nothing covers these
behaviours, so novelty is suggested but not established.

## Proposed catalog text (final, supersedes the PAUSED row above)

Run entry row:

```text
| Child wait/reap: `asterinas-child-wait-reap-20261004T160159Z` | `0c60537098f4c2949ad2d382aaf499de72263d76` | Analysis PASS 35/35; spec r2 PASS 40/40 with bounded TLC (no violation; publication and restricted wakeup liveness complete). Implementation-trace validation BLOCKED_ENVIRONMENT (AMD KVM, no invariant TSC); outcome-only runtime run 2026-10-10 under a user-overridden harness receipt (D9R5-S1 accepted residual). Linux 21/21 match; Asterinas per-call 94/97 match. Runtime-observed Linux-compat mismatches WR-LX (WSTOPPED-only waitid reaps a zombie) and WR-SQ (WNOHANG no-event leaves siginfo unwritten); not natively confirmed (findings refused: no bug-report). No concurrency claim (placement not credible). | [Lane result](../flock-wait-handoff-2026-10-05/wait-reap/result.md) |
```

Old-ID map rows:

```text
| `asterinas-child-wait-reap-20261004T160159Z` | WR-LX | Provisional AST-NEW-WR1 | waitid without WEXITED consumes a zombie child (runtime-observed vs Linux control; not natively confirmed). |
| `asterinas-child-wait-reap-20261004T160159Z` | WR-SQ | Provisional AST-NEW-WR2 | waitid WNOHANG no-event leaves siginfo unwritten (runtime-observed vs Linux control; not natively confirmed). |
| `asterinas-child-wait-reap-20261004T160159Z` | WR-OBS-AFFINITY | Unassigned | sched_setaffinity does not migrate the caller (documented TODO); out of lane scope. |
```
