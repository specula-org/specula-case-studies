# Bug report — etcd-raft V00

## Summary

All ten Scenario configurations completed their prescribed BFS and simulation checks. One simulation counterexample was classified as a model caller-precondition error (Case B), repaired, and trace-regressed. The ten subsequent simulations reported no invariant violations before their planned deadlines. No implementation bug was established; exploration remains incomplete.

Six Scenario groups and all ten supplied configurations were exercised. The run retained every invariant and bound. The single new counterexample was Case B, not a confirmed implementation defect; `findings.json` therefore contains an empty findings array. No confirmation or operational reproduction was run.

## Not reproduced within the explored work

| Configuration | BFS depth | BFS distinct | Simulation states checked | Simulation traces generated |
|---|---:|---:|---:|---:|
| MC_hunt_1_durability.cfg | 4 | 5,751,426 | 6,822,626 | 10,257 |
| MC_hunt_1_parallel.cfg | 4 | 5,503,525 | 8,892,960 | 8,176 |
| MC_hunt_1_same_batch.cfg | 4 | 5,145,688 | 7,575,325 | 9,180 |
| MC_hunt_2_election_transfer.cfg | 3 | 19,730,092 | 6,862,224 | 7,891 |
| MC_hunt_3_configuration_application.cfg | 3 | 18,276,401 | 7,066,573 | 7,658 |
| MC_hunt_3_node.cfg | 3 | 19,803,444 | 5,952,565 | 9,694 |
| MC_hunt_4_replication_snapshot.cfg | 3 | 21,208,013 | 8,385,536 | 11,019 |
| MC_hunt_5_reads.cfg | 3 | 22,538,999 | 7,286,663 | 7,889 |
| MC_hunt_5_singleton.cfg | 4 | 105,960,938 | 21,874,302 | 94,779 |
| MC_hunt_6_outcomes.cfg | 3 | 20,436,713 | 7,190,459 | 8,148 |

All tabled checks ended at their ordinary 30-minute budgets with no unclassified violation. BFS used the pre-repair reference and reached only depths 3–4; simulations used the repaired reference with depth cap 100. Counters are last reported samples. Neither deadlines nor unvisited behavior are counted as exhaustive passing results. Parallel persistence interpretation remains unresolved.

## Model repair and evidence

CreateSnapshot's legal-caller precondition omitted the MemoryStorage lastIndex bound (`storage.go:198–200`). The retained 30-state durability counterexample attempts index 1 against lastIndex 0. The model now requires the local storage argument to be in bounds while retaining independent application/visibility schedules. Five real traces and six invalid prefixes were regressed successfully. Every invariant remains enabled in its original configuration.

See `validation-report.md`, `output/scenario-campaign-20260913-043418/case-b-create-snapshot.json`, and `output/scenario-campaign-20260913-043418/campaign.json` for source evidence, per-job receipts and exact input versions. The repair-driven MC.cfg check also reached its ordinary deadline without a reported violation. No exhaustive safety or progress proof is established. Remaining substantive initialization gaps are recorded in `remaining-validation-work.md`.

## Small quality round — diagnostic results

No unexpected counterexample or implementation finding was established. Eleven deliberately invalid observational fixtures failed their intended new invariants. The management check without caller fairness exhibited an expected unfinished-job stuttering cycle; the same finite graph with fair callback/job service passed. These controls are not implementation bugs or confirmations. Prior classifications/verdicts are unchanged. Evidence and open scope: `quality-improvement.md`.
