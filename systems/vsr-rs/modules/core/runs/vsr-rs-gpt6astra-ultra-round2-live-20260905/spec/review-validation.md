# Validation Review: vsr-rs

## Status

- Syntax: PASS
- MC: TIMEOUT
- Ready for trace validation: YES

Reviewed on 2026-09-05 against source revision `3ac0104a567092139534c9022205d02281a2da41` with the existing instrumentation patch. The requested `validation-report.md` and optional `quick-mc.log` are absent. This review uses [validation.md](validation.md), the newer [validation results](output/validation-results.json), and their raw logs. The newer results supersede the generation report's statements that instrumentation and broader checking remain unperformed.

**Syntax:** All three delivered modules, `base.tla`, `MC.tla`, and `Trace.tla`, passed SANY parsing and semantic analysis through the recorded TLC runs. Current evidence includes the [MC log](output/MC_hunt_baseline_bfs.out) and [implementation replay log](output/trace-round1/normal_retry_duplicates.log); neither reports a syntax or semantic-analysis error.

**Model checking:** No unexpected invariant violation was reported.

| Run | Result | Evidence and limits |
|---|---|---|
| Generation smoke BFS and random simulation | PASS | Smoke exhausted 1,677 distinct states; simulation checked 200 traces / 20,911 states, seed `20260905`. These were TLC checks, not Rust simulator reproductions. [Smoke](validation/MC-smoke.log), [simulation](validation/MC-simulation.log). |
| Current `MC.cfg` BFS | TIMEOUT | The 30-minute watchdog returned 124. Last progress sample: 219,874,256 distinct states discovered, 160,519,720 queued, layer 14. These are not final totals or a completed search. [TLC log](output/MC_round1_bfs_retry.out), [watchdog log](output/MC_round1_bfs_retry.launcher.log). |
| `MC_hunt_baseline.cfg` BFS | PASS within its finite constraints | Exit 0; 74,772,829 distinct states, empty queue, depth 27. This narrower profile excludes crashes and does not replace the incomplete `MC.cfg` search. [Log](output/MC_hunt_baseline_bfs.out). |

The historical negative fixtures intentionally violate `TraceMatched`: a corrupted application snapshot, a changed emitted payload, and a removed Prepare event were correctly rejected. These are expected validator-test failures, not protocol findings. Their original `tag: "vsr"` differs from the current `tag: "trace"` filter; they require reconciliation before reuse. See [negative logs](validation/) and [harness validation notes](../harness/VALIDATION.md).

**Trace readiness:** Instrumentation is already implemented, and all four real-library traces passed the current full replay: normal retries/duplicates, reordered state transfer, view change after crash, and stale recovery responses—186 events total. [Results](output/trace-round1/result.json) and [per-trace evidence](bug-report.md) agree. `Trace.cfg` enables `TraceMatched` and seven invariants; all 19 transition wrappers enforce full post-state, network-multiset, and output equality. The [capture audit](../harness/validation/audit.json) covers all 20 event names including Init and checks completion records/native callback counts. Review-time hashing matched all 22 input-manifest entries, 37 harness entries, and 28 validation-artifact entries. This review inspected existing evidence; it did not rerun TLC or modify source/specs.

## Next Steps

- No additional instrumentation is required for the existing baseline traces. Reuse [the harness](../harness/INSTRUMENTATION.md); from `.specula-output/`, `bash harness/validate.sh` audits and replays captured traces.
- For new scenarios, retain one event per complete handler/client/timer call, including ignored calls; explicit crash/recovery/loss/duplication; independently observed application execution; full snapshots and both output queues; and completion/native-call counters. These boundaries are already implemented in the current harness.
- Extend trace coverage to combined recovery/view change and membership 2. Current event-type coverage does not establish complete branch or behavior coverage. Keep filesystem, socket, startup, nonce-allocation policy, and singleton handoffs on their separate verification routes.
- Preserve `MC.cfg` as TIMEOUT/LIMITED until further checking supports a stronger result. Before reusing historical fixtures, align their tags and rerun positive/negative controls; point future report consumers to the current validation results.

## Verdict: PASS

Ready to continue trace validation within the declared conforming-library baseline, with four successful implementation replays already available. The MC timeout limits safety assurance but does not block trace validation. No exhaustive protocol-safety, liveness, or production-bug conclusion follows from these results.
