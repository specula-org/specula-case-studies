# arc-swap_4 — Spec Validation Changelog

## Round 1 - Trace Validation
- All 8 traces passed validation on first run (basic_read_write, concurrent_readers_writer, family_2_cas_arc, family_2_cas_raw_stale, family_2_guard_clone, family_2_into_inner, family_2_send_guard, family_5_fallback_path).

## Round 1 - Model Checking (MC.cfg)
- MC.cfg passed: 6,255,337 states generated, 1,425,406 distinct, diameter=131, completed in 28s.

## Result
Converged in 1 round. No spec changes needed during convergence. Proceeding to bug hunting.

---

## Bug Hunting (post-convergence)

### Family 1 — Memory Ordering (sensitivity / robustness check)
- [sensitivity] BFS hit `MCNoUseAfterFree` at depth 15 in 5s under `MCPickRelaxSite("DebtPayFailure")` (counter-factual to PR #195 / `bd5d327`). Output: `output/MC_family1_bfs.out`.
- [sensitivity] Simulation reproduces the same `DebtPayFailure` UAF; output: `output/MC_family1_sim.out`. Confirms spec faithfulness against past upstream fix.

### Family 2 — Caller Misuse (priority area)
- [no-violation] BFS 30 min: 1.34B states generated, 198M distinct, depth 44. No violations under SC ordering with `GuardClone × SendGuard × DropArcSwap × CASRawStale × CASOps`. Output: `output/MC_family2_bfs.out`.
- [no-violation] Simulation: 489M states / 1.84M traces / sim depth 100. No violations. Output: `output/MC_family2_sim.out`.

### Family 3 — Stale Snapshot (priority area for round 4)
- [sensitivity] BFS first hit at depth 15 in 5s under `DebtPayFailure` relaxation (same shape as F1 finding). Output: `output/MC_family3_bfs.out`.
- [sensitivity] Continued simulation: 80,430 violations across `MCStaleSnapshotSafety` (59,444), `MCPayAllCompleteness` (19,671), `MCNoUseAfterFree` (1,315). Per-site breakdown: FallbackLoad (79,179), ListHeadLoad (801), DebtPaySuccess (185), DebtPayFailure (203), FastConfirmLoad (62). **Every violation requires a relaxation site; NO SC-only violation.** Output: `output/MC_family3_sim.out`.

### Family 4 — Cooldown ABA
- [bug] BFS hit `MCCooldownDrainSafety` at depth 33 in 6s under SC. Writer reserves an UNUSED node during pay_all. Documented as MC4 precondition; downstream ABA needs ≥3 threads to exhibit. Classified as Case A (invariant steady-state form too strong vs. impl semantics) but precondition is genuinely reachable. Output: `output/MC_family4_bfs.out`. See bug-report.md Bug 2.

### Family 5 — Action Granularity (NEW round 4)
- [bug] BFS hit `MCNoDanglingTransaction` at depth 28 in 6s. Confirms expected MC5 panic in `LocalNode::confirm_helping`'s `node.get().expect()` after wrap-discard. Real Case-C bug; reachable on 32-bit after 2^30 fallback calls. Output: `output/MC_family5_bfs.out`. See bug-report.md Bug 1.

## Final Bug Hunting Result
- 1 real Case-C implementation defect: F5 panic on generation wrap (`bug-report.md` Bug 1).
- 1 design-pattern reachability finding: F4 cooldown / writer-reservation (`bug-report.md` Bug 2 — precondition only under 2-thread SC; downstream ABA needs more threads).
- 4 expected sensitivity findings (counter-factual to PR #195, #203, #204, #76, #164).
- 0 SC-only violations for F2 (caller misuse — the explicit gap from prior round).
- 0 SC-only violations for F3 (stale snapshot — the round-4 priority).
