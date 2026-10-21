# Wait/reap validation status

Phase 3 is **INCOMPLETE**, blocked during the validation workflow's Phase 0 on 2026-10-10. There are no implementation traces in `../traces/`. No trace validation, convergence model checking, or bug hunting ran in this invocation. No model-checking bug verdict is available.

The controller can resume this campaign after it provides admitted implementation trace collection. [validation-status.json](validation-status.json) records the machine-readable disposition. [The preflight record](output/validation-preflight-20261010T082734Z/preflight.json) binds the inspected files, source installation, receipt checks, resource ownership, and existing outcome records by hash.

## Initialization evidence

The source HEAD is `0c60537098f4c2949ad2d382aaf499de72263d76`, with tree `4693fdec88cd7da14bed4f1541eba593f123059c`. The working tree contains the existing Phase 2.5 instrumentation. All 20 files in `harness/evidence/applied.json` match their installed hashes. This invocation changed no source, model, configuration, instrumentation, oracle, or harness semantics.

All base, MC, trace, and instrumentation files exist, together with six hunting configurations. The model and trace format are Category B. `Trace.cfg` has uncommented `PROPERTIES TraceMatched`. `Trace.tla:378` defines `ValidatePostState(e) == e.post = ExpectedPost(e)`, and `MatchEvent` invokes it after the base action and argument check. This static prerequisite inspection does not establish that an implementation execution matches the model.

The controller's PID 3823656 holds `heavy.lock`, verified through its file-descriptor lock record. The worker did not reacquire the lock or start heavy work. The configured TLC allowance remains 4 GiB and two workers.

## Trace collection cannot proceed under the current receipt

The live [review receipt](../harness/review-gate.json) passes `review_gate.py --outcome`, including the bound input and frozen-snapshot hashes. It authorizes only `OUTCOME_ONLY`. Running the read-only admission check with `--consistency` exits 78:

```text
INCOMPLETE_REVIEW_GATE: clock diagnostics and grouped consistency mode are not approved
```

The current receipt preserves the independent review verdict **NOT_APPROVED** and the recorded user override for exact D9 revision 5. D9R5-S1 remains an accepted residual: an invalid UTF-8 placement record can discard completed calls when the collector decodes the whole log. Such records must remain inconclusive. The override permits outcome collection only. It neither supplies implementation traces nor closes the clock/order obligations for grouped collection.

The harness also records that its existing consistency method requires GenuineIntel and invariant TSC, while the available environment reports AuthenticAMD under KVM with invariant TSC absent. Changing the vendor check alone would not establish the missing clock/order evidence. A changed collection method or trace interpretation must pass the supplied `corrective_review_gate` before dependent verification.

The candidate-era text in `harness/STATUS.md`, `INSTRUMENTATION.md`, and `evidence/worker-result.json` predates the live receipt and latest outcome attempt. Their earlier NOT_RUN statements are historical. This report uses the current receipt and actual outcome files below, without rewriting those hash-bound inputs.

## Existing runtime evidence and its limits

The latest attempt is `harness/evidence/20261010T074837Z-3806790-84036f8bfadd4196ad238dc7bfb7161a`. Its [status](../harness/evidence/20261010T074837Z-3806790-84036f8bfadd4196ad238dc7bfb7161a/status.json) records 42 reports. All 42 raw-log hashes and their receipt binding were rechecked during this preflight.

| Evidence | Observed disposition | Limit |
| --- | --- | --- |
| 21 Linux outcome reports | All report `match` and complete fixtures. | They are syscall controls, not implementation traces. The recorded running kernel is Linux 7.2.8, distinct from the pinned Linux v6.16.5 source oracle. |
| 21 Asterinas outcome reports | All report `inconclusive` and incomplete fixtures. Completed per-call records remain available. | The reports identify a truncated final log line and missing completion or CPU/boot evidence. A zero supervisor exit code does not close those gaps. |
| Asterinas competing and observer cases | All ten relevant reports record `actors_on_distinct_cpus: false`. | Guest SMP=2 alone does not satisfy the recorded user condition requiring the two waiters on different CPUs. No runtime concurrency conclusion is accepted. |
| Every outcome report | `OUTCOME_ONLY_NO_IMPLEMENTATION_TRACE`, `implementation_trace: NONE`, and `trace_validation: BLOCKED_ENVIRONMENT`. | The recorder was not armed. These records cannot supply the internal events required by `Trace.tla`. |

Both systems record glibc 2.39. The guest uname string is `Linux 5.13.0 x86_64` for compatibility. Its Asterinas attribution comes from the runner, pinned source, kernel/build, boot, and outcome evidence, not that string. The preflight record includes each report's CPU, identity, per-call result, diagnostic, and raw-log hash.

The retained synthetic fixtures and prior spec-generation TLC results remain checker-development evidence. They were not rerun or substituted for implementation traces. The earlier [spec-generation review](review-specgen.md) accepts that stage's design, not completion of this validation phase.

## Disposition of the five priority questions

All five questions remain unvalidated by the required trace-validation and invariant-checking loop. The table preserves what the existing outcome records can support without promoting their incomplete runs.

| Priority question | Existing evidence | Required work still outstanding |
| --- | --- | --- |
| 1. Unique consumption and fresh post-reap calls | The latest guest consumer records contain one successful consumer and one ECHILD, followed by ECHILD in the post-reap calls. Their overall reports remain inconclusive, with no distinct-waiter-CPU evidence. | Collect the protected selection/removal/output events across both interfaces. Validate them, then check `UniqueConsume` and `NoFreshSelectionAfterRemoval` in convergence and `MC_hunt_1_unique_consume.cfg`. |
| 2. Repeated WNOWAIT and late retained observations | `observe-consume4` and `observe-consumeid` retain two successful observations followed by one consumer. The overlap cases contain no internal selection/removal order. | Validate repeated observations and a witnessed selection-before-removal/late-output execution. Check availability and retained-reference properties with `MC_hunt_2_observation.cfg`. Return order alone is insufficient. |
| 3. Registration, recheck, notification, and parking | Outcome-only calls do not establish any scan/register/recheck/park window or either internal notification channel. No lost wakeup is demonstrated. | Collect both notification paths and the scheduler handoff. Run `MC_hunt_3_blocking.cfg` and `MC_hunt_3_wakeup.cfg` after convergence, including the second consumer's ECHILD completion. |
| 4. Publication and lifetime through output | Recorded exit outputs agree with the expected status in the inspected per-call records, including exit values 0, 37, and 255. They cannot establish the release/acquire bridge or retained Arc lifetime. | Validate store/publication/acquire/read/drop events and run `MC_hunt_4_publication.cfg`. A protocol result will still depend on the source-backed atomic and lifetime assumptions. |
| 5. API-specific no-result and post-reap behavior | Guest no-event and post-reap call records preserve the expected return distinctions. The poisoned WR-SQ call retains nonzero siginfo fields, while the Linux control clears them. | Validate primary no-event/error traces and run `MC_hunt_5_api_results.cfg`. Keep WR-SQ separate, preserve its partial runtime evidence, and do not treat prezeroed output as a clearing test. |

WR-SQ's latest guest report contains a per-call mismatch but remains overall inconclusive. This invocation assigns no novelty, AST ID, severity, or Case C verdict. The preparation document's NOT_RUN rows remain preparation history.

WR-CF stays a separate calibration. The retained guest calls report EFAULT followed by ECHILD after consuming wait4 and waitid faults. WNOWAIT faults leave an exit available to the next valid wait. The Linux reports match those expectations. All three guest reports remain overall inconclusive, so the records do not complete the calibration or justify a rollback-on-EFAULT invariant.

The latest harness also contains WR-LX outcome records using waitid without WEXITED. Those are outside this task's primary supported call matrix. Their per-call mismatches are preserved in the audit without adding a model obligation or finding.

Completion remains conditional on eventual child publication and notification, a live parent, lock acquisition/release progress, pending unpark completion, and runnable waiter execution under finite client activity. No FIFO order, spontaneous notification, or untimed-wait timeout is assumed.

## Controller handoff

The validation workflow requires: "Always start with trace validation" and "Complete each phase fully before switching." An empty trace set cannot satisfy those requirements. No Case A/B/C counterexample was produced, and no correction was proposed or self-approved.

The controller must provide a compatible environment and an exact-version receipt admitting implementation trace collection, or arrange a bounded correction of the collection method with independent source/model/harness review. Preserve prior/proposed versions, diff, rationale, triggering evidence, hashes, reviewer identity, and disposition before any semantic correction is rerun. Outcome-only approval does not admit grouped collection.

After actual implementation traces exist, resume Phase 0 and Phase 1 in this same campaign. Preserve the reviewed Category B acceptance distinction: `TraceSearch.cfg` requires a complete matching witness, while `Trace.cfg` has the stricter universal `TraceMatched` diagnostic. Do not accept a synthetic witness or an outcome summary as an implementation execution. Only after the implementation trace round passes should `MC.cfg` run, followed by convergence and all six hunting configurations with the skill's 30-minute BFS/simulation rules.

`bug-report.md` and `findings.json` are not emitted for this blocked attempt because the workflow produces them after convergence and bug hunting. In particular, an empty findings array would incorrectly suggest that Phase 3 ran and found no model-checking defects. [validation-status.json](validation-status.json) explicitly records that the phase is incomplete and is not a no-bugs result. The controller must not advance to confirmation or mark validation accepted from the process exit status or the existence of `changelog.md`.
