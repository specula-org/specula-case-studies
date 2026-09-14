# Validation changelog: nvflare-transfer

## Phase 0

- Source pin: `53ba7ee567468ea7971dad4faccef13c6cb35dc2`; existing observation patch preserved. All Phase 2.5 provenance hashes match current files.
- Read validation, trace and checking guides, instrumentation mapping, harness instructions and modeling brief. Experiment `.agents/skills` entrypoints/guides match the supplied installed skills byte for byte.
- Found 16 raw/normalized traces, 94 mapped actions, all required modules/configs and four hunts. `TraceMatched` is enabled; every wrapper checks exact required post-state fields.
- Fresh full-corpus replay follows through the installed `run_trace_validation_parallel` handler, with its TLC execution transported through the experiment task API to honor resource caps and preserve logs.

## Round 1 - Trace Validation

- All 16 normalized implementation traces passed the installed parallel handler with original invariants, exact post-state matching and complete cursors (3,029 events). No spec/invariant/instrumentation changes. Evidence: `output/round1-traces/results.json`.

## Round 1 - Model Checking

- Started original `MC.cfg`, 30-minute budget, 16 GiB heap + 48 GiB direct memory, 40 workers; no bounds reduced.

- Budget ended normally (task exit 124), no TLC errors or invariant violations. Last reported: 726,661,713 generated, 188,559,267 distinct, 103,310,511 queued, depth 21. Search not exhaustive. Evidence: `output/MC_round1.out`, `output/MC_round1_summary.json`.

## Round 1 - Convergence

- All traces pass; the 30-minute standard check found no violation; no spec or invariant changes were needed. Converged within the prescribed exploration budget, not an exhaustive proof. Proceed to all four unchanged hunting cfgs.

## Bug Hunting

- Executed all four original BFS hunts with 30-minute budgets; three stopped on violations. S4, the no-violation depth-21 hunt, received the required same-cfg depth-100 simulation follow-up.

- [bug] S1 / MC-2 / Case C: a 35-state counterexample commits receiver FAILED, then an admitted EOF without a new nonce publishes and latches COMPLETED progress. Source mapping confirms the callback gap and terminal branch. No spec/invariant change. `output/MC_hunt_s1_progress_bfs.out`.
- [bug] S3+S5 / MC-1 / Case C: post-enqueue submission RuntimeError permits inline and worker settlement. Independent 77-state duplicate-effect and 94-state after-receipt counterexamples map to the unguarded settlement entry; receipt ownership remains single-write. Existing controlled-injection trace supports the mechanism, not natural production triggering. `output/MC_hunt_s3_settlement_bfs.out`, `output/MC_hunt_s3_after_receipt_bfs.out`.

- S4 BFS: 30-minute budget completed with no violation (exit 124), last reported 646,515,586 generated / 163,706,943 distinct / 86,654,088 queued states, depth 21. Search not exhaustive. Started mandatory same-cfg simulation with depth 100, 999999999 trace limit, 30 minutes, 16 GiB heap + 16 GiB direct memory and 40 workers.

- S4 simulation: full 30-minute budget completed with no violation (exit 124); last reported 624,958,988 states checked and 4,664,773 random model traces generated, configured depth limit 100. Evidence: `output/MC_hunt_s4_budgets_sim.out`. No liveness or exhaustive-completion claim.

## Result

Converged in 1 budgeted round without spec, invariant, cfg or instrumentation changes. Bug hunting: 2 Case C root findings, supported by 3 counterexamples; no Case A/B repairs. All 4 hunting cfgs and the required S4 simulation were executed and observed to termination. Wide BFS coverage remains incomplete; exact MC-2 runtime confirmation and natural MC-1 production triggering are not established by this phase.
