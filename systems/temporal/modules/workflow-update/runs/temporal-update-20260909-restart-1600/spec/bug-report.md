# Bug report — temporal-update

## Summary

**INCOMPLETE: trace validation has not converged.** No full implementation trace passes. Model-checking bug hunting has not started, so this report does not assert that any scenario is bug-free.

- New model-checking implementation findings: **0**.
- Convergence runs with `MC.cfg`: **0**; hunting configs run: **0/8**.
- Complete implementation traces passed: **0/9**.
- Real functional scenarios rerun: **9/9 pass**; eight admission prefixes pass, three transitions each, covering three distinct model actions.
- Three synthetic model regression fixtures and six rejecting negative controls are separate test evidence, not implementation trace coverage.

See [validation-handoff.md](validation-handoff.md) for exact commands, source-backed repairs, priority-question/CR coverage, upstream refresh, and remaining capture/model defects. [findings.json](findings.json) contains an empty MC findings list with explicit incomplete status; it does not contain prior code-review findings.

## Not reproduced / not executed

| Scenario | Config | States explored in this phase | Diameter | Result |
|---|---|---:|---|---|
| Convergence | `MC.cfg` | Not run | Not measured | Gated by incomplete implementation trace validation |
| Persistence and caller outcomes | `MC_hunt_scenario_1.cfg` | Not run | Not measured | No hunt verdict |
| Stale work identity | `MC_hunt_scenario_2.cfg` | Not run | Not measured | No hunt verdict; independent identity oracle unresolved |
| Recovery progress | `MC_hunt_scenario_2_progress.cfg` | Not run | Not measured | No hunt verdict; timer budget/fairness defect unresolved |
| Effects and closure | `MC_hunt_scenario_3.cfg` | Not run | Not measured | No hunt verdict |
| Direct dispatch/retry | `MC_hunt_scenario_4.cfg` | Not run | Not measured | No hunt verdict; Matching acceptance/return separation unresolved |
| Dispatch progress | `MC_hunt_scenario_4_progress.cfg` | Not run | Not measured | No hunt verdict; timer budget/fairness defect unresolved |
| Host cache aliasing | `MC_hunt_MC_4_cache.cfg` | Not run | Not measured | Earlier generation witness is unvalidated and stale after model changes |
| Forced termination contract | `MC_hunt_CR_5_limit.cfg` | Not run | Not measured | Prior code/test observation remains separate from MC discovery |

No Case C implementation counterexample was classified in this phase. No invariant was weakened. Source/trace inconsistencies and the append-timeout guard repair are recorded in [changelog.md](changelog.md); none is counted as a Temporal bug.
