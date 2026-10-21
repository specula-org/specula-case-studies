# Wait/reap lane result (final, 2026-10-10 17:15 +08:00)

Run `asterinas-child-wait-reap-20261004T160159Z`, target `asterinas-child-wait-reap`, Asterinas
pin `0c60537098f4c2949ad2d382aaf499de72263d76`, engine Specula 1.2.0 at `aa93be67…`, routing Codex
gpt-6-astra max (pi GLM-5.3 for confirm, never reached).

The lane ended with an accepted model and runtime outcome evidence on Linux and Asterinas.
Implementation-trace validation is **BLOCKED_ENVIRONMENT**. Native validation stopped
**INCOMPLETE** at Phase 0 for lack of traces, and native findings refused for lack of
`spec/bug-report.md`. Two Linux-compatibility mismatches were observed at runtime, WR-LX and
WR-SQ. Neither has demonstrated security impact. Every timestamp, hash and decision is in
[execution/gates.md](execution/gates.md). The pre-final version of this file is
[execution/result.pre-final-20261010.md](execution/result.pre-final-20261010.md).

The 2026-10-12 catalog audit keeps WR-LX / AST-92 and WR-SQ / AST-93 in the
[outcome-only section of the reproduction index](../../asterinas-bug-findings-2026-08/reproduced.md#outcome-only-runtime-observations-2).
They have no native confirmation, implementation-trace validation or supported
concurrency conclusion. Validation exited 1 at Phase 0; findings exited 1
before any agent started. Closing the lane did not complete its pipeline.

## Phase exits

| Stage | Exit and time (local) | Review verdict and the version it binds |
| --- | --- | --- |
| Analysis | exit 0, 10-05 01:22 to 01:56 | `review-analysis.md` PASS 35/35, brief `617152b6…` |
| Spec generation | exit 0, 10-05 13:23 to 13:47 | v0 NEEDS_IMPROVEMENT 33/40 (base `44831dac…`) |
| Spec revision r1 (Codex) and review | r1 exit 0, 13:48 to 15:04; review 20:28 to 20:37 | NEEDS_IMPROVEMENT 39/40 (base `abe074fc…`) |
| Spec revision r2 (Codex) and review | r2 exit 0, 10-06 00:37 to 00:51; review 00:55 to 01:03 | **PASS 40/40**, accepted model r2 (`execution/model-accepted-r2.sha256`) |
| Harness (native Phase 2.5) | exit 0, 10-06 01:32 to 02:18, worker INCOMPLETE, 0 traces | in-phase reviews v1 to v3 left the clock finding R2 open |
| Harness corrections | v4 to v6 and amendments C1, D1 to D9 (static Codex or controller) | v5 approved (C1, D1, D4, D5), the memory gate reviewed by the coordinator, v6 approved (D6, D7, D8 with earlycon), D9 rev 5 **NOT_APPROVED** (review-v6j) and installed under the user override |
| Outcome run d9 | exit 0, 10-10 15:48 to 15:50 under heavy lock | runs under receipt `4d759ae1…` (user override, D9R5-S1 an accepted residual) |
| Validation | exit 1, 10-10 16:23 to 16:30 | worker INCOMPLETE at Phase 0, no review produced |
| Findings | exit 1, 10-10 17:07 | prerequisite `bug-report MISSING`, no agent started |

Earlier outcome runs did not produce usable Asterinas evidence. Their failures and fixes are
logged in gates.md:
- d4 refused on memory.
- d4m was killed by the reaper.
- d5 found the AMD clock unsupported.
- v6-outcome failed the offline kernel build.
- v6d6 failed on Linux pinning and std dependencies.
- v6d7 failed to compile the kernel.
- v6d8 had all guests abort on the placement assertion.

## Decisions and ratifications

- 2026-10-09: the user ratified the weaker trace claim `CONSISTENCY_UNDER_SAMPLED_CLOCK_BOUND`
  ([execution/user-ratification-2026-10-09.md](execution/user-ratification-2026-10-09.md)). This
  host could not use it.
- 2026-10-09: the memory gate measure became MemFree + Inactive(file). I rebound the receipt
  before any review, which was wrong. The coordinator then reviewed the exact files
  (`harness-fix-2026-10-06/review-v5-memgate-coordinator.md`). From then on, every receipt was
  rebound only after its review or user record existed.
- 2026-10-10: outcome-only mode
  ([execution/user-decision-2026-10-10-outcome-only.md](execution/user-decision-2026-10-10-outcome-only.md)).
  Clock environment: AMD Ryzen 9 9950X KVM guest, `kvm-clock`, CPUID 80000007 EDX[8] = 0.
- 2026-10-10: the user accepted D9 revision 5 despite review-v6j's **NOT_APPROVED** verdict
  ([execution/user-decision-2026-10-10-accept-d9r5.md](execution/user-decision-2026-10-10-accept-d9r5.md)).
  **D9R5-S1 is an accepted residual.** The collector decodes the whole log before validating
  calls, so invalid UTF-8 in a placement line would discard that run's completed calls. No
  log in run d9 failed UTF-8 decoding.

## Model evidence (accepted r2, bounded TLC; controller rerun in `spec-fix-2026-10-05/independent-verify/`)

| Configuration | Result |
| --- | --- |
| MC_hunt_4_publication | complete, 1,005,898 distinct states, no violation |
| MC_hunt_3_wakeup, both liveness properties, restricted two-consumer fixture | complete, 474,133 distinct states, no violation |
| MC.cfg | TIME-LIMITED at 1,200 s (818,081 distinct), no violation |
| MC_hunt_3_blocking (general completion), hunts 1, 2, 5 | TIME-LIMITED at 600 s, no violation |
| Synthetic traces through TraceSearch.cfg | 4 accepted with complete witnesses, 1 corrupted fixture rejected |

Time-limited runs are bounded explorations, not passes. Native validation ran no TLC.

## Runtime outcome evidence (run d9)

Evidence directory:
`.specula-output/harness/evidence/20261010T074837Z-3806790-84036f8bfadd4196ad238dc7bfb7161a/`.
The evidence class is `OUTCOME_ONLY_NO_IMPLEMENTATION_TRACE`, and trace validation is
BLOCKED_ENVIRONMENT. D9R5-S1 applies as an accepted residual, and review-v6j's verdict was
NOT_APPROVED.

- **Linux controls: 21/21 `match`** against the pinned Linux v6.16.5 source expectations. They ran
  in containers on the host kernel 7.2.8, pinned with taskset to two CPUs. The running kernel is
  not the v6.16.5 oracle.
- **Asterinas guests:** all 21 booted with `-smp 2` and `WR_GUEST_NPROC 2`, and the boot
  supervisor recorded `fixture_complete: true`.
  - **Run-level verdict: 21/21 `inconclusive`.** This is a harness artifact. `boot.py` stops
    reading at the `WR_OUTCOME_COMPLETE` marker before its newline, and D9 revision 4's
    truncated-line rule then drops that line. No output was edited.
  - **Per-call comparisons, as computed by the collector: 97 calls, 94 `match`, 3 `mismatch`.**
    - WR-SQ, `siginfo-poison` / `live-siginfo` (1 mismatch, see the candidates below).
    - WR-LX, `zombie-without-wexited` (2 mismatches, see the candidates below).
    - Competing consumers, WR-06/07 (8 runs): exactly one consumer received the exit status and
      the other received ECHILD, with no hang, for wait4/wait4, waitid/waitid and both mixed
      orders.
    - WR-01 to WR-05 and WR-08 sequential observation and consume calls, plus WR-CF (copyout
      faults on wait4, waitid and WNOWAIT), all `match`.
  - **Placement:** every actor reported `actual_cpu` 123 on a 2-CPU guest, so Asterinas
    `sched_getcpu()` output is not credible. No run qualifies as distinct-CPU. Under the user's
    condition, **no concurrency conclusion is drawn for WR-06 to WR-10**. WR-09/10 internal windows
    were not established.

## Priority questions

1. Unique consume across APIs. The model has no violation (bounded or complete hunts). Runtime
   per-call outcomes for sequential and competing consumers match Linux, but without
   distinct-CPU evidence. **Exception:** a WSTOPPED-only waitid consumes the zombie (WR-LX).
2. Repeated WNOWAIT and consume. Model: no violation. Runtime per-call: match.
3. Registration and wake windows, no stranded waiter. Model: the restricted liveness check is
   complete with no violation, and the general check is time-limited. Runtime: no hang in any
   run, but the internal windows are not established and there is no concurrency claim.
4. Exit-code publication. Model: complete, no violation. Runtime: statuses 0, 37 and 255 match.
5. No-event and post-reap results. Post-reap ECHILD matches. **WR-SQ mismatch.**

## Candidates (details in [candidate-ledger.md](candidate-ledger.md))

- **WR-LX: waitid without WEXITED reaps a zombie.** Runtime-observed. Linux-compatibility
  defect in the consuming-reap protocol.
  - Repro: `waitid(P_PID, pid, &info, WSTOPPED|WNOHANG)` on a zombie child returned 0 with
    CLD_EXITED, status 37, and consumed the child. The next `waitid(..., WEXITED|WNOHANG)`
    returned ECHILD.
  - Linux returns ECHILD for the first call (`kernel/exit.c:1167-1168,1494,1689`) and lets the
    WEXITED call consume. The Linux control matched that.
  - Source: `try_wait_children` (`kernel/core/src/process/wait.rs:310-319`) never tests WEXITED.
  - Effect: a caller that asked only for stop events silently steals the exit status. There is
    no demonstrated security impact; it is a same-process API misbehaviour.
  - Evidence is sequential, so SMP is not required.
  - Not natively confirmed, because the findings stage refused.
- **WR-SQ: waitid WNOHANG with no event leaves siginfo unwritten.** Runtime-observed
  Linux-compatibility difference.
  - A poisoned siginfo stayed `a5a5…` after a 0 return. Linux zeroes `si_signo`, `si_code`,
    `si_pid`, `si_uid` and `si_status` (`kernel/exit.c:1804-1825`), and the Linux control
    matched that.
  - Source: `syscall/waitid.rs:49-51`.
  - No security impact demonstrated. Callers that do not prezero siginfo may misread garbage
    as an event.
- **WR-CF:** calibrated. Asterinas matches Linux: consuming copyout faults consume, and WNOWAIT
  faults leave the child waitable.
- **WR-OBS-AFFINITY (out of scope):** `sched_setaffinity` does not migrate the caller. This is a
  documented TODO (`sched_affinity.rs:33`). Also, `sched_getcpu()` reported CPU 123 on a 2-CPU
  guest, which is unverified and out of scope.
- Novelty: the catalog holds only the WR-SQ placeholder. Asterinas issues and PRs about
  `waitid` (#1216, #1197, #2511) concern panics and pidfd errno, not these behaviours. That is
  suggestive, not proof.

## Usage

Known Specula phase costs: analysis $59.24, analysis review $5.69, specgen $6.36, spec reviews
$4.38 and $3.33, harness $20.41, validation $3.20.
- **Known total: $102.61.**
- The r1 spec review reported $0.00, treated as unknown.
- Auxiliary Codex runs (spec fixes r1 and r2, harness H1 to H3, about 20 harness reviews) report
  tokens only, so their cost is unknown.
- Claude controller usage is unknown. It included two session-limit interruptions and one
  memory-reaper kill.

## Remaining work and options

- Native confirmation and classification did not run (no `bug-report.md`). WR-LX and WR-SQ need
  confirmation outside the native pipeline, or an explicitly authorized bug-report input.
- A one-line collector fix would turn the 21 guest runs into run-level verdicts: treat
  `WR_OUTCOME_COMPLETE` as a complete final line, or have `boot.py` keep reading to the newline.
  It needs review and a rerun.
- Concurrency evidence for WR-06 to WR-10 needs credible placement. Asterinas `getcpu` reports
  123 in the guest, and migration is unsupported.
- The recorded collector requires an Intel invariant-TSC setup. Before a
  future run, establish a supported clock or causal-order collector and
  credible actor placement with a bounded pilot. This failed setup does not
  prove that every AMD platform is unsuitable.
- Lane resource left: the Docker volume `specula-wait-reap-20261005-rustup` (cache, safe to
  remove).
