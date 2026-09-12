# Validation Review: temporal-history-queue

## Status

- Syntax: PASS
- MC: TIMEOUT
- Ready for trace validation: YES

Readiness applies to the existing instrumented scenarios and continued trace validation. Overall verification remains **INCOMPLETE / NOT CONVERGED**.

**Syntax.** A fresh SANY check of all five current modules (`base.tla`, `MC.tla`, `Trace.tla`, `Witness.tla`, and `CfgCheck.tla`) passed with exit code 0 and no errors or warnings. Commands, module hashes, and logs are recorded in [syntax-results.json](output/review-validation-20260911T195623Z/syntax-results.json).

**MC evidence.** `quick-mc.log` is absent. The actual baseline evidence is [MC-round2.log](output/validation-20260911/MC-round2.log), with [exit code 124](output/validation-20260911/MC-round2.exit) after the 1,800-second limit. Last progress: **130,208,773 generated; 40,246,046 distinct; 36,081,667 queued; depth 13**. No invariant violation was observed, but the search did not complete. Current base/MC/Trace modules and MC/Trace configurations match the frozen Round 2 inputs. `MC.cfg` enables five structural/disposition invariants; scenario-specific properties and temporal hunts are separate. All nine post-convergence hunt configurations remain unexecuted. Earlier one-task exhaustive results and finite diagnostic schedules do not establish convergence of this baseline.

**Violations and repairs.** The [validation report](validation-report.md) records earlier unexpected model, capture, and fixture failures as repaired, including stopped-owner acquisition, batch order, fairness assignments, multi-slice Clear, detached-cursor capture, and late-DLQ fixture choreography. The final implementation replays have no unexpected failures. Seven deliberately corrupted traces violate `TraceMatched`; the missing-Endpoint control fails an assertion. These eight rejections are expected. The reported CR-1 reader stall is source-discovered adverse behavior accepted by the model, not a new baseline MC finding or evidence of physical task loss.

**Trace readiness.** [Recorded replay results](../harness/evidence/run-20260911T193533Z-m3XQAh/validation/validation.json) confirm six passing implementation traces, **534 records including Init/Endpoint**, and eight rejected negative controls. Coverage is **46/65 named model actions**, excluding Init/Endpoint from the action denominator. `Trace.cfg` enables `TraceMatched`; each transition requires full post-state equality. No additional instrumentation is needed to replay these six scenarios. Passing adverse traces establishes agreement with measured behavior, not system correctness. This review reran SANY and inspected existing MC/replay evidence; it did not rerun the implementation harness or baseline MC.

## Next Steps

- Continue using the existing harness: from `.specula-output`, run `timeout 900 bash harness/run.sh`. Preserve full state capture, independent SQLite Endpoint readback, and all eight negative controls.
- Before extending publication/ownership traces, add controlled outstanding-request schedules and observations for uncertain publication, pending-key retention, fenced writes/renewals, closed-shard responses, and late old-owner callbacks across takeover. Distinguish durable commits from caller receipts.
- Before extending checkpoint traces, capture multiple simultaneous shard snapshots, copied metadata, commit order, failures/fencing, and lost replies; verify reconstruction against independently read durable queue state.
- Before extending responsibility/progress traces, add executor/downstream fixtures and hooks for durable DLQ commit/lost-reply/reply, terminal and unexpected errors, terminal discard, justified obsolescence, task start, and worker completion. Matching acceptance alone does not establish completion.
- For partial page failures, prefetched-read/DELETE races, and production mitigation decisions, first extend the model/adapter and observation hooks for read admission/buffers, actual group counters, and predicate bytes. The current projection does not cover these paths. See [instrumentation-spec.md](instrumentation-spec.md) and [harness coverage limits](../harness/REPORT.md).
- Complete baseline convergence on the current model before starting the nine gated hunts. Preserve the current TIMEOUT result; report any narrower diagnostic separately rather than substituting it for the unfinished baseline.

## Verdict: NEEDS_IMPROVEMENT

Syntax and the existing trace adapter are ready. Baseline MC completion and broader implementation-trace coverage remain outstanding.
