# Bug Report — Algorand BA*

## Summary

- Bug families tested: 6
- Bugs found: **0** (no Case C real-bug violations observed within the 30-minute BFS budget for any family)
- Configs run: `MC_hunt_family1.cfg` … `MC_hunt_family6.cfg`, plus `MC.cfg`

The converged spec was checked against all six bug-family hunting configs from the modeling brief. None of the BFS runs produced an invariant violation within the 30-minute budget. This is a partial — not exhaustive — verification: each run hit its `-t 30` time budget with millions of states still queued, so the search depth (8–17) only covers a small fraction of the reachable state space. The diameters are below the 25-step recommended threshold; a simulation follow-up is recommended for any future iteration with more compute (see "Coverage Gaps" below).

## Per-Family Coverage

| Family | Title | Priority | Config | Diameter | Distinct States | States Generated | Verdict |
|--------|-------|----------|--------|----------|-----------------|------------------|---------|
| 1 | Catchup vs Live Agreement race | HIGH | `MC_hunt_family1.cfg` | 12 | 14,547,528 | 90,305,152 | No violation in 30 m |
| 2 | Reproposal guard asymmetry (period 0 → P) | HIGH | `MC_hunt_family2.cfg` | 8 | 23,519,935 | 75,219,397 | No violation in 30 m |
| 3 | Dynamic filter timeout cross-round divergence | MEDIUM | `MC_hunt_family3.cfg` | 17 | 23,043,598 | 227,417,789 | No violation in 30 m |
| 4 | Freshest bundle / `fresherThan` cert-cert short-circuit | MEDIUM | `MC_hunt_family4.cfg` | 8 | 19,476,139 | 61,484,012 | No violation in 30 m |
| 5 | VRF seed lookback forks | LOW (safety) | `MC_hunt_family5.cfg` | 9 | 12,127,887 | 35,563,285 | No violation in 30 m |
| 6 | Crash recovery state coverage | LOW | `MC_hunt_family6.cfg` | 13 | 14,690,585 | 105,253,351 | No violation in 30 m |

Total: **107.4 M distinct states / 595.2 M generated states explored.** Raw outputs: `spec/output/MC_hunt_family{1..6}_bfs.out`.

The base MC.cfg run (`spec/output/MC_run1.out`) also reached the 30 min budget cleanly at diameter 7 with 16.78 M distinct states across the full fault-injection model.

## Findings

### Case C — Real bugs

None observed. **No new safety-violating behavior was reachable within the BFS coverage of any hunting config.** The IACR 2023/1344 audit (Benhamouda et al., CCS'23) similarly proved no exploitable safety/liveness flaw, and the TestNet 2022-07-08 stall (~5 h) was traced to a `ledger/internal/prefetcher/prefetcher.go` validation-cache bug **outside** `agreement/` (forum.algorand.co/t/7416). The agreement protocol itself has no known safety bug in production history.

### Case A / Case B — Spec corrections during convergence

The only spec modifications during validation were trace-replay accommodations:
- Stripped the `IssueCertVote` post-step transition (Case B fix; `issueCertVote` in `agreement/player.go:209-212` is dispatched from the soft-threshold handler at `player.go:405` and does **not** transition `p.Step`).
- Made `PersistState` idempotent (Case B fix; matches `Service.persistState` at `agreement/service.go:281-284`).
- Inlined `pinnedLowest` mutation in `ProposeBlock` / `ReceiveProposal` (Case B fix; the original sub-action call into `UpdatePinnedLowest` conflicted with the same actions' UNCHANGED clauses).
- Started rounds at 1 (matches `testLedger.nextRound = 1`).
- Fixed two TLC parse failures: nested multi-binding quantifiers in `PersistedBeforeBroadcast` (base.tla) and `HonestVoteInCommittee` (MC.tla).

Full detail in `spec/changelog.md`.

## Coverage Gaps

The 30-min BFS runs do **not** exhaustively explore Algorand's reachable state space for these bug families. To strengthen this result we recommend, in priority order:

1. **Simulation follow-up for every family** — `-S -n 999999999 -p 100` for 30 min each. The workflow guidance is that diameters ≤ 25 warrant simulation; all six families hit this threshold. Simulation reaches deeper traces (depth 100+) that BFS will not in the 30 min budget.
2. **Larger fault counters** — every hunt cfg already raises a different counter (catchup × 2, byz × 4-5, crash × 2, fork × 2). The current MC.cfg permits one of each. For deeper hunts, consider Multi-fault combinations (e.g., catchup × 2 + byz × 2 in one cfg).
3. **Period ≥ 3 partition recovery** — most cfgs cap `MaxPeriod = 1` to fit BFS in the 30-min window. Modeling brief §2 Family 1/2 specifically calls out `partitionPolicy` (player.go:512-568) and the period-3+ recovery rules; running with `MaxPeriod = 3` and `MaxStep = 9` (so `PartitionStepNum = 6` is reachable) is the primary unexplored regime.
4. **Modeling the `cert ↔ catchup` interleaving on a real fork** — Family 1's MC-1 finding (Brief §6.1) requires `CatchupInstall(R, V_c)` followed by `BroadcastVote(R, P, cert, V_l)` with `V_c /= V_l`; the converged spec models this, but the precise schedule of `inFlight` → `Send` → `ReceiveVote` aggregation across two values may need extra depth to land an honest `CertCommitteeThreshold` for `V_l`.

## Implementation Findings to Re-Check Manually (Code Review, not MC)

Per the modeling brief §6.3 these are flagged but not model-checkable in their current form:

- **CR-1**: `catchup/service.go:819-840` fork-detection branch is log-only — no halt or operator alert.
- **CR-2**: `voteTracker.go:189` `Panicf("too many equivocators for step %d: %d", ...)` is a DoS surface under coordinated equivocation.
- **CR-3**: `voteAggregator.go:128` `Panicf("bad round ...")` reachable on a late-vote race.
- **CR-5**: `lowestCredentialArrivals` not persisted (`persistence.go:246,262`) — known degradation, undocumented.
- **CR-10**: PR #5286's "Blocks attached to next-vote bundles are not correctly processed" TODO was deleted without follow-up; the underlying concern was never re-investigated.
- **Open PR #5341**: `AsyncVoteVerifier.Quit` shutdown panic — outside `agreement/` proper but adjacent.

None of these are protocol-level safety issues that the converged spec would catch; they are reliability / DoS / process-lifecycle concerns to address in code review.

## Conclusion

The TLA+ spec converged after the Phase 1 / Phase 2 fixes documented in `changelog.md`. Across **107 M distinct states explored**, six bug-family hunts ran for 30 min each without finding a Case C real bug. This is consistent with the existing external audit (CCS'23) and production history of no mainnet halt attributed to `agreement/`. To raise confidence further, run simulation follow-ups for every family and re-run with the larger fault-counter / partition-recovery regimes described in "Coverage Gaps".
