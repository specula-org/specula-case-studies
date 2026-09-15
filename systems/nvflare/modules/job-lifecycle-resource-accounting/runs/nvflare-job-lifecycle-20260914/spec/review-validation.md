# Validation Review: nvflare-job-lifecycle

## Status

- Syntax: PASS
- MC: FAIL
- Ready for trace validation: YES

Readiness applies to the existing instrumented workload and trace projection. Four implementation traces already pass; the MC status includes three safety violations from targeted hunts.

**Evidence reviewed.** The requested `validation-report.md` and optional `quick-mc.log` are absent. This review instead uses the final [validation check receipt](output/check-generated-validation-r5.log), [MC coverage](output/run-coverage.json), [replay receipts](output/traces-r5/summary.json), and [finding classifications](validation/candidates.json). NVFlare HEAD is `53ba7ee567468ea7971dad4faccef13c6cb35dc2`; Specula HEAD is `fd46677315454ae9b011f8a85a7e65fa91c67459`. All 20 [final artifact hashes](validation-artifact-hashes.json), seven replay-input hashes, and 23 harness-artifact hashes match current files. Saved standard-MC and all eight BFS-hunt inputs also match current specs/configs. No new SANY, TLC, or implementation run was performed during this review.

**Syntax.** `base.tla`, `MC.tla`, and `Trace.tla` all passed SANY. The final receipt also records 11/11 configuration initialization/first-successor checks and consistent identities for 125 actions/wrappers/hooks. These checks establish syntax and initial-expression validity, not full behavioral coverage.

**Model checking.** Standard `MC.cfg` reached its normal 30-minute budget without reported violations: depth 28, 85,219,049 generated states, 16,008,119 distinct, and 6,158,119 queued. Its individual status is **TIMEOUT**, representing bounded coverage rather than exhaustive completion or an execution failure. All eight hunt configurations ran; three produced invariant violations:

| Finding | Violated invariant | Recorded interpretation |
|---|---|---|
| MC-2 | `NoFreeWhileInUse` | Startup rollback can release capacity while a spawned child remains live. |
| MC-3 | `AcceptedPreRunAbortPersists` | A stale deployment status write can undo a pre-run abort. |
| MC-4 | `NoTerminalResurrection` | A delayed startup write can overwrite terminal status with `RUNNING`. |

These are violations of intended safety contracts, classified as source-supported Case C model findings; they are not benign expected failures. Their violating implementation interleavings remain unconfirmed. No recorded counterexample is left unclassified. Five follow-up simulations reached their budgets without reported violations. An earlier progress simulation suffered a TLC worker exception and is excluded from successful coverage; its bounded retry used the documented [eager-evaluation workaround](validation/eager-execution.md), with four passing control replays.

**Trace readiness.** Final replay completed for `abort_completion`, `admission_exception`, `competition`, and `delayed_start`: **4/4 traces, 1,353 semantic events, 94/125 action types**. Each raw replay log reports completed temporal checking and zero queued states. `Trace.cfg` enables `TraceMatched`; `Trace.tla` checks exact action-specific post fields and normalized state, rejects unknown semantic events, and has no silent actions that invent missing execution. The earlier observed mismatches have recorded [model/capture repairs](validation/review-resolution.md) and passing final regression receipts.

## Next Steps

- Reuse the existing [harness and instrumentation](../harness/INSTRUMENTATION.md); no initial instrumentation remains necessary for the four validated scenarios. Keep source/configuration provenance, actual job/token/request identities, allocation/free observations, and distinct spawn/attachment/waiter/exit boundaries.
- Before expanding coverage, extend or exercise observations for two simultaneous resource bindings, waiter-install failure, explicit deployment errors, accepted ABORTED outcomes, and zero-grace server cleanup. Preserve real lock/capture boundaries and validate every added post field. The [coverage inventory](../harness/coverage.json) identifies the 31 unobserved actions.
- Retain the [coverage limits](validation/priority-coverage.md): delayed heartbeat snapshots, full notification retry, and TV-2/TV-3 service-death behavior are not established by these traces. Broader readiness requires corresponding model/capture support and passing replays.
- Keep MC-2/MC-3/MC-4 pending implementation confirmation; passing conformance traces do not reproduce those counterexamples. After any model or capture change, refresh hashes and rerun the affected checks and full trace regression.
- Supply `validation-report.md` as an index to the retained final evidence so later reviews can locate the intended handoff report directly.

## Verdict: PASS

The spec is ready for continued trace validation within the documented harness scope. This readiness verdict preserves **MC: FAIL**, bounded search coverage, and the outstanding implementation-confirmation boundaries.
