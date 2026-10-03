# Bug Report — CometBFT

## Summary

- Scenarios tested: 3
- Bugs found: 0
- Configs run: `MC_hunt_scenario1_params.cfg`, `MC_hunt_scenario2_durability.cfg`, `MC_hunt_scenario3_recovery.cfg`
- Convergence: all six retained traces passed, then `MC.cfg` completed with no invariant or deadlock violation

No model-checking bug was found within the supplied consensus-parameter execution, persistence, and startup-recovery scope.

## Convergence Evidence

| Check | Coverage | Result |
|---|---:|---|
| Retained trace validation | 6/6 traces; 4-11 generated states per trace | Fully matched, including `TraceMatched` and post-state checks |
| `MC.cfg` BFS | 6,921 generated; 5,126 distinct; 0 queued; diameter 33 | Complete bounded state graph, no violation |

## Not Reproduced

| Scenario | Config | States Explored | Result |
|---|---|---:|---|
| Parameter update validation and installation | `MC_hunt_scenario1_params.cfg` | BFS: 224 generated / 183 distinct, 0 queued, diameter 18; simulation: 4,381,164,075 checked across 87,623,286 traces, depth 50, 30 minutes | No violation |
| Ordered durable boundaries during block application | `MC_hunt_scenario2_durability.cfg` | BFS: 2,277 generated / 1,719 distinct, 0 queued, diameter 27 | No violation |
| Height-matrix startup replay | `MC_hunt_scenario3_recovery.cfg` | BFS: 5,147 generated / 3,892 distinct, 0 queued, diameter 33 | No violation |

Scenario 1 received the workflow-required simulation follow-up because its BFS diameter was at most 25. Scenarios 2 and 3 exceeded that threshold, so no simulation follow-up was required.

## Reachability Witnesses

Each auxiliary config intentionally violates a `NeverReached*` invariant. All seven expected violations occurred, confirming that the checks exercise accepted and rejected updates, crash, app-only replay, real replay, mock replay, and successful handshake completion.

| Config | Expected witness | States generated |
|---|---|---:|
| `MC_reach_accepted.cfg` | `NeverReachedAcceptedUpdate` | 12 |
| `MC_reach_rejected.cfg` | `NeverReachedRejectedUpdate` | 14 |
| `MC_reach_crash.cfg` | `NeverReachedCrash` | 3 |
| `MC_reach_app_replay.cfg` | `NeverReachedAppOnlyReplay` | 175 |
| `MC_reach_real_replay.cfg` | `NeverReachedRealReplay` | 20 |
| `MC_reach_mock_replay.cfg` | `NeverReachedMockReplay` | 93 |
| `MC_reach_handshake_complete.cfg` | `NeverReachedHandshakeComplete` | 12 |

## Assurance Limits

The BFS results are exhaustive only for the finite constants in each supplied config. The Scenario 1 simulation is time-bounded and sampled, not exhaustive. The suite intentionally excludes `InitChain`, historical parameter-index lookup, partial storage-write effects or corruption, retry/liveness after deterministic failures, transactions, validator-set transitions, Byzantine consensus behavior, evidence, cryptography, and state sync. Passing these checks is bounded evidence for the supplied model and source correspondence, not a proof that CometBFT is safe.
