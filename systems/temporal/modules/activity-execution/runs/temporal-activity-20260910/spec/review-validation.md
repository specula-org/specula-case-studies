# Validation Review: temporal-activity

## Status

- Syntax: PASS
- MC: PASS
- Ready for trace validation: YES

Reviewed on 2026-09-11 against source revision `0c010ce5fe8c0180aa7573c72fe8fc87c6df7025`. This replaces the earlier review of incomplete inputs. [validation-report.md](validation-report.md) now exists; the optional `quick-mc.log` is absent, so this review uses the retained checking outputs. All 35 files in the [final manifest](output/continuation-20260911/final-manifest.json), all 20 model/config files in the final acceptance snapshot, and all 21 MC output hashes match their recorded evidence.

**Syntax:** Independently reran SANY on all seven current top-level modules: `base.tla`, `MC.tla`, `Trace.tla`, `MCProgress.tla`, `SpecControls.tla`, `SyntheticTraceControls.tla`, and `OracleControls.tla`. All passed parsing and semantic processing with exit 0 and no reported errors. Commands, input hashes and logs are retained in the [review syntax evidence](/home/ubuntu/temporal-investigation-20260909/parallel-20260910/scratch/activity/tmp/temporal-activity-validation-review-20260911-yftwqkof/sany-results.json).

**MC:** PASS applies to the completed bounded `MC.cfg` safety baseline: **116,828,979 generated / 29,188,066 distinct states, empty queue, depth 87, 6m40s**, with no errors in the [TLC log](output/continuation-20260911/mc-baseline/MC-r4.out). This configuration has one Activity, two attempts, a finite clock, and no injected recovery/storage/response-loss faults. It uses the documented [clock reduction](clock-reduction.md). The baseline configuration is unchanged; verified snapshot diffs contain only an invariant inactive in this baseline and additions used by progress/simulation.

The unreduced clock reference, all seven larger hunting BFS runs, and the healthy progress runs remain **TIMEOUT / INCOMPLETE**. Each hunt received a 30-minute BFS run and a 30-minute simulation; completed budgets and sampled runs do not establish exhaustive success. The final-only healthy progress run never reached its final temporal check. See [checking outcomes](output/continuation-20260911/checks-summary.json).

Violations were found during development: both S2 searches exposed an overly strict timer/dispatch invariant (Case A), while progress checks exposed missing notification fairness and then a finite clock stopping before a pending physical timer (Case B). These were classified as oracle/model/configuration issues, not implementation defects. The S2 oracle was corrected with positive and negative controls; healthy progress remains unproved. No confirmed Temporal implementation violation is established by this evidence.

**Trace readiness:** The ordinary Activity core is already instrumented and has **21/21 successful complete real replays**, covering 2,414 events. The [current-file replay results](output/continuation-20260911/final-real-current/result.json) and all 21 scenario logs record success. Independent inspection found 45 state fields in every event, complete implementation-provenance envelopes, sequential event numbers, and Bootstrap/FinishTrace endpoints. `Trace.cfg` enables `TraceMatched`; wrappers compare the full decoded post-state, and FinishTrace requires terminal WFT consumption and independent readback. The 84 deliberate wrong-attempt, wrong-durable-state, missing-field and missing-endpoint rejections are expected controls. Five synthetic controls are separate from real execution evidence. This review reran SANY and audited retained artifacts; it did not rerun the functional suite or TLC exploration.

## Next Steps

- No prerequisite instrumentation remains for the validated ordinary core. Reuse [harness/INSTRUMENTATION.md](../harness/INSTRUMENTATION.md) and [instrumentation-spec.md](instrumentation-spec.md): immutable lease snapshots, separate submission/append/SQL commit observations, task identities and timing, Matching/worker receipts, shard readiness, and independent terminal readback are already implemented.
- Before extending trace coverage, add controlled scenarios and verify capture at the nine unobserved interfaces in [COVERAGE.md](../harness/COVERAGE.md), including obsolete-task disposal, child-start expiry, AddTask response loss, definite non-timeout persistence rejection, and Workflow close branches. Current coverage is 52/61 model actions, not product coverage.
- After model or hook changes, recollect affected real scenarios, replay complete traces, and repeat selective corruption controls against the same file hashes. Preserve full-state and endpoint checks.
- Keep larger safety searches and conditional progress explicitly INCOMPLETE until they finish. Process/database restart, power-loss durability, administrative APIs and replication/routing need separate instrumentation and validation before extending the claims.

## Verdict: PASS

Ready for trace validation within the documented ordinary Activity scope; this verdict does not certify unfinished searches or conditional liveness.
