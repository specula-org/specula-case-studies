# Flock lane result: `asterinas-local-flock-ownership-20261004T160159Z`

Pipeline status: all five stages completed with the recorded review decisions:
analysis, spec generation (with one reviewed revision), harness, validation,
and findings (confirmation plus classification). Two model-checking
candidates were reproduced on real Asterinas. Four code-review candidates were
dismissed. General `MC.cfg` exploration is time-limited. Only the four-event
C00 open trace meets the overlap criterion, so the accepted traces do not
establish campaign-wide critical-interleaving coverage. AST-85's separately
recorded ungated race with observers supports that specific defect. The
2026-10-12 documentation audit preserves these bounded results and makes no
claim of complete concurrency protocol verification.

The per-stage records hold the details and evidence paths:
[analysis](execution/gate-1-analysis.md),
[spec generation](execution/gate-2-specgen.md),
[spec revision](execution/gate-2b-spec-revision.md),
[harness](execution/gate-3-harness.md),
[validation](execution/gate-4-validation.md) and
[findings](execution/gate-5-findings.md). The candidate ledger and the
proposed catalog text are in [candidate-ledger.md](candidate-ledger.md).

## Identity

- Source: `/home/chin39/Documents/play/specula-profile-local-artifacts/flock-wait-2026-10-05/flock/source`
  at `0c60537098f4c2949ad2d382aaf499de72263d76`, tree `4693fdec88cd…`, clean,
  4,715 commits. The run used its private `--keep-original` copy.
- Guidance `6bbe86b4…`, config `8058e175…`, commands `195f034a…` and contracts
  `e79b4509…` were unchanged after every material phase, through the final
  check at 23:04 on 10-09. `resources.json` changed only in its memory-gate
  measure (user decision of 2026-10-09). Its original is kept as
  `resources.before-memory-gate-2026-10-09.json`.
- Engine: Specula 1.2.0 at `aa93be678b95…`, with its three known untracked
  files. Routing was codex gpt-6-astra max for every phase except confirmation,
  which used pi `tlaic/sophnet/GLM-5.3`. The route never changed, and there
  were no policy blocks or quota stops.
- The authoritative checkout `/home/chin39/Documents/asterinas-dev` stayed
  clean at `74d5631c57e6…` throughout.
- Container: `specula-flock-harness-20261005` (the harness worker chose this
  name instead of the planned `specula-flock-20261005`). It is stopped and
  kept.

## Stage exits and review verdicts

Times are local (+08:00).

| Stage / attempt | Lock held | Exit | Review verdict and model version |
|---|---|---|---|
| Analysis | 10-05 00:43–01:22 (analysis lock) | 0 | PASS 34/35 on brief `6b937de7…` |
| Spec generation | 10-05 08:27–09:06 | 0 | NEEDS_IMPROVEMENT 27/40 on the original suite (`base.tla` `3e1715f0…`) |
| Codex spec fix | 10-05 15:29–16:09 | 0 | Author run only |
| Independent verify, attempt 1 | 10-05 19:06–19:07 | 3 | False SANY failure in the controller's grep. Nothing installed. |
| Verify, install, re-review | 10-05 19:08–19:17 | 0 | 28/28 checks. Spec review **PASS 40/40** on revision 1 (`base.tla` `5114e9f4…`, `MC.tla` `f11ba301…`, `Trace.tla` `918b7c4a…`) |
| Harness | 10-05 20:37–22:52 | 0 | Worker INCOMPLETE because memory was below the gate. Model unchanged. |
| Harness continuation (`run.sh` v12) | 10-06 00:51–00:54 | 0 | 18 traces, 49 actions, zero drops |
| Validation, attempt 1 | 10-06 04:11–04:18 | 1 | Phase 0 asked for an acceptance-contract decision |
| Validation, attempt 2 (resume) | 10-06 04:19–05:17 | 0 | Validation review **PASS** on revision 1 |
| Findings, attempt 1 | 10-06 07:01–10:15 | 1 | MC-1 REPRODUCED. MC-2 proposal rejected. CR-2 hit the deadline. |
| Findings, attempt 2 | never acquired | -15 | Cancelled while queued for the user's pause |
| Wrapper, 10-09 (old measure) | never queued | — | Stopped for the measure change |
| Wrapper, 10-09 (new measure) | never queued | — | Reaped by Claude Code's memory guard |
| Findings, attempt 3 (resume) | 10-09 20:07–20:54 | 1 | MC-2 REPRODUCED. CR-2 upstream stream failure. |
| Findings, attempt 4 (resume) | 10-09 22:49–23:03 | 0 | CR-2 FALSE POSITIVE. Classification wrote `bug-severity.md`. |

Every failed or interrupted attempt keeps its log, receipt and archive.

## Controller decisions

1. **Spec revision under the corrective gate.** The original suite and
   review are in `spec-fix-2026-10-05/before/`. Codex revised an isolated
   copy. The controller verified it independently with raw TLC and two
   mutations of its own, then installed it. The native re-review passed it.
2. **Harness continuation.** The run had no saved harness conversation. The
   controller ran the worker's documented `bash harness/run.sh` on the
   independently reviewed v12 harness. It did not edit the stale
   `harness/STATUS.md` or `status.json`.
3. **Validation acceptance contract.** The installed method contradicts
   itself on trace acceptance. The controller authorized the exact reviewed
   `TraceNoWitness` existential adapter, with no input change
   ([decision](execution/validation-controller-decision.md)). The validation
   review accepted it, and **the user ratified it on 2026-10-09**
   ([execution/user-ratification-2026-10-09.md](execution/user-ratification-2026-10-09.md)).
4. **Memory measure.** Following the user's 2026-10-09 decision, the
   controller scripts measure memory as MemFree + Inactive(file), with the
   thresholds unchanged. The edit is minimal, preserved and independently
   reviewed ([execution/memory-measure-change-2026-10-09.md](execution/memory-measure-change-2026-10-09.md)).
5. **Leftover guests.** Twice (after findings attempts 1 and 3), a CR-2 guest
   kept running in the lane container after the stage had released the heavy
   lock. Each time the controller preserved the guest's files
   (`findings-attempt1-leftover-guest/` and `findings-attempt3-leftover-guest/`
   under the lane's local artifacts) and stopped the container.

## Bounded verification results (model revision 1)

- **Traces.** 18 real Asterinas traces (1,481 events, all 49 actions, zero
  drops, SMP 2, ramfs) were accepted with complete witnesses. C00, C06 and
  C11 are runtime prefixes. The 20 percent interval-overlap criterion is met
  only by the 4-event C00 trace.
- **Model checking.** 13 of 16 hunts were exhausted with no violation. C05
  violates `ConversionOracle` (80 states), C06 `ConvertersDrain` (57 states)
  and C11 `NoRecursiveListWait` (34 states). `MC.cfg` timed out at 30 minutes
  (20.1M distinct states, depth 13, no violation), and it enables only four
  safety invariants. **General convergence is not established.**
- **Linux controls.** C01–C05 passed on host Linux 7.2.8 tmpfs. No Linux
  v6.16.5 kernel was booted.

## Findings

`confirmed-bugs.md` (sha256 `a89d49ac…`) reports 2 reproduced (both NEW), 4
false positives and 0 incomplete. `bug-severity.md` (sha256 `9e9aa99d…`)
rates both reproduced findings Critical.

- **MC-1 / FL-SQ-1, conversion retention.** Confirmed implementation bug,
  reproduced at Level 0 (black-box, SMP 2).
  - After A's SH→EX|NB conversion fails and B unlocks, C's EX|NB returns
    EAGAIN on Asterinas and succeeds on Linux 7.2.8.
  - Two blocking SH→EX converters both stayed parked on Asterinas, while on
    Linux one completes.
  - Specula rates it Critical. The workspace assessment is a Linux
    compatibility bug with a local denial of progress among the caller's own
    or cooperating lock holders. No privilege boundary is crossed and no
    security impact is shown.
- **MC-2 / FL-SQ-2, temporary-reference cleanup self-deadlock.** Confirmed
  implementation bug.
  - It reproduced in a pure syscall race with trace observers enabled but no
    gate or injection (MC2-L0: hit after 3 unlock crossings, SMP 2, zero
    drops, the full reference chain captured). The `LOCK_NB` probe then
    blocked, showing that the list Mutex stayed held.
  - It also reproduced deterministically with the reviewed timing gate
    (MC2-L1). The extra-alias negative control did not deadlock.
  - The fully plain Level 0 run did not hit it in 128 crossings, because the
    unobserved window is a few tens of nanoseconds.
  - The fixed Linux source has no corresponding upgrade under the list lock.
  - Specula rates it Critical. In the workspace assessment, an unprivileged
    process can hang the flock path of a shared inode until reboot, so it is
    a local denial of service on files the attacker can open. Cross-user
    reachability and exploit reliability without observers were not
    demonstrated.
- **CR-1, CR-2, CR-3, CR-4: FALSE POSITIVE.** CR-2 needed three runs. Its
  intermediate hangs came from its own test-gate fixtures and are not
  production evidence.
- **FL-CR-1** (request-clone Drop draining re-enqueued waiters) is an alias of
  native CR-4 / AST-89. The source site and scheduling-impact hypothesis match
  the final FALSE POSITIVE record. Its earlier code-review-only status and
  C09's lack of a completion claim remain historical; no extra open finding
  is counted.
- **Separate observation, not a finding.** The plain Level 0 MC-2 run froze
  in unrelated waits while the flock Mutex was free. The agent attributes
  this to the lost-wakeup / stale-waker family of upstream issue #3283. It is
  outside this lane's signal-free contract, was not reproduced or analyzed
  further, and has no AST entry. It is retained as an unverified lead in
  `confirmation/MC-2/investigation.md`.

The coordinator assigned AST-84 and AST-85 on 2026-10-11. They preserve the
FL-SQ-1/2 source-lead provenance and are not blind discoveries. The
[reproduction index](../../asterinas-bug-findings-2026-08/reproduced.md) lists
their evidence limits and the [ID map](../../asterinas-bug-findings-2026-08/id-map.md)
resolves the provisional names.

## Usage

| Item | Cost | Tokens |
|---|---:|---:|
| Analysis + review | $56.57 | 39.4M |
| Spec generation + review | $10.21 | 3.83M |
| Codex spec fix | unknown | unknown (none reported in its JSON stream) |
| Spec re-review | $4.19 | 2.11M |
| Code review of the memory-measure edit (Sonnet subagent) | unknown | about 33K |
| Harness | $61.98 | 46.0M |
| Validation (both attempts, cumulative) + review | $32.91 | 25.4M |
| Confirmation (pi GLM-5.3, all attempts) | unknown (pi reports $0.00) | 88.4M |
| Classification | $1.58 | 0.51M |

The known total is $167.44. The true total is higher by the three unknown
items. Controller (Claude) usage is not included.

## Interruptions

- 2026-10-06 10:36:17: the queued findings waiter (PID 3048386) was cancelled
  for the user's pause. Specula never started, and the receipt records exit -15.
- 2026-10-09 14:43: the first resume wrapper, which still used MemAvailable,
  was stopped before queuing because of the user's memory-measure change.
- 2026-10-09, between 14:45:05 and 15:18:51 (around 15:1x): Claude Code's
  background-shell memory guard killed the re-queued wrapper while it was
  still waiting before queuing. The guard probably reads MemAvailable, which
  the host's `watermark_scale_factor=2000` understated. Free plus
  Inactive(file) was about 39 GiB. The work resumed after the user reset the
  sysctl to 10.

## Retained artifacts

- Run: `/home/chin39/Documents/play/Specula/runs/asterinas-local-flock-ownership-20261004T160159Z/`.
  It holds `confirmed-bugs.md`, `bug-severity.md`, the `spec/` round
  outputs, `harness/evidence/`, `confirmation/*/` and `repro/`.
- Checkpoints: `specula-profile-local-artifacts/flock-wait-2026-10-05/flock/checkpoints/`
  (eight archives, one before each stage change).
- Spec revision: `spec-fix-2026-10-05/`. The workspace and its 8.4 GiB of TLC
  metadata are in `…/flock/spec-fix-ws/`.
- Leftover-guest evidence: `…/flock/findings-attempt1-leftover-guest/` and
  `…/flock/findings-attempt3-leftover-guest/`.
- Console logs and receipts: `reports/runs/asterinas-local-flock-ownership-20261004T160159Z.*`.
