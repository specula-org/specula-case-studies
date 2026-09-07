# Validation Review: vsr-rs

## Status

- Syntax: PASS
- MC: TIMEOUT
- Ready for trace validation: YES

Reviewed the retained artifacts for source revision `3ac0104a567092139534c9022205d02281a2da41`. The requested `validation-report.md` and optional `quick-mc.log` are absent. This review instead uses [validation-results.md](validation-results.md), [validation-status.json](validation-status.json), and their raw logs. All 47 file hashes and seven trace hashes in [output/final-manifest.json](output/final-manifest.json) match the current files; the validation input spec/config hashes also remain unchanged. No checks or simulator experiments were rerun for this review.

**Syntax.** All three specs (`base.tla`, `MC.tla`, `Trace.tla`) passed standalone SANY parsing and semantic resolution, including Json/IOUtils dependencies; see [assembly-results.json](validation/assembly-results.json) and `validation/*-sany.log`. The later implementation replay logs also show successful semantic processing of the current Trace module. All nine MC configurations passed initialization checks, which establish configuration wiring only.

**MC results.** The small normal-case smoke model completed with 409 generated / 237 distinct states, depth 18 and an empty queue ([MC-smoke.log](validation/MC-smoke.log)). The S3 and S5 finite simulation checks reported no violations, but do not establish exhaustive coverage or liveness. The subsequent full `MC.cfg` run hit its 30-minute limit with no invariant violation observed. Its last periodic observation was 1,260,140,453 generated / 216,199,137 distinct states, depth 22, and 96,919,949 queued states ([raw log](output/MC_round1b.out), [driver log](output/MC_round1b.driver.log)). These are last reported counts, not final completion counts. MC convergence remains incomplete; none of the seven scenario hunts ran in the subsequent hunting phase.

The generation-time bad-state, bad-reply and missing-persist fixtures intentionally produced temporal-property violations: these are **expected negative-control rejections**, not unexpected protocol failures. No unexpected invariant counterexample was reported by the reviewed model-checking runs.

**Trace readiness.** Instrumentation is already present, and implementation trace validation has already passed **7/7 traces, 884 records, 33 event types** ([trace-round1.json](output/trace-round1.json)). [Trace.cfg](Trace.cfg) enables `TraceMatched`; [Trace.tla](Trace.tla) requires full consumption and compares complete normalized post-state snapshots at each event. The existing hooks capture replica/client state, actual application results, recovery/view-change response provenance, persistence, individual output publication, crash/recovery, and socket outcomes ([instrumentation notes](../harness/INSTRUMENTATION.md)). No further instrumentation is required to replay this existing scope.

The EOF trace successfully matching the model is expected: it follows the known integration corruption behavior. Trace replay intentionally excludes agreement/linearizability properties, so its success does not establish those properties or negate the retained defect. Event-type coverage also does not establish every branch, failure schedule, or deployment behavior.

## Next Steps

- Continue using the existing harness and seven implementation traces, retaining `TraceMatched`, full post-state checks, pinned inputs and per-trace results. The MC timeout does not block trace replay.
- Resolve the full MC convergence gap before advancing to the seven hunting configurations. Any revised search scope must be explicit; preserve the original timeout result and do not substitute the tiny smoke pass for convergence.
- Before expanding trace coverage, add instrumentation and model refinement for forwarded replies, log-carrying frame variants, and client-owner/connection failures. Broader process-level traces need causal ordering and atomic snapshots; other EOF cut positions/frame types remain outside current coverage. See [instrumentation-spec.md](instrumentation-spec.md) and [brief-coverage.md](brief-coverage.md).
- Align the review input paths with the actual report/log filenames, and update the older generation handoff wording that still describes implementation traces as future work.

## Verdict: NEEDS_IMPROVEMENT

The spec is ready for trace validation within its declared scope, with seven passing implementation replays already available. Overall validation remains incomplete because the full MC run timed out and convergence has not been established.
