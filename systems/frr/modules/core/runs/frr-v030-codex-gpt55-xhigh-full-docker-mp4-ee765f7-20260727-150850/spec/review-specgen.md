# Spec Generation Review: frr

## Scores
| Criterion | Score | Notes |
|-----------|-------|-------|
| Scenario Coverage | 4/5 | All five brief Scenarios have modeled variables/actions and targeted `MC_hunt_*` cfgs. Coverage is weaker for some suggested details such as explicit `earlyRouteQ`, coalesced NHT delete/add behavior, and richer provider/multi-provider paths. |
| Action Design | 4/5 | Most actions are named after implementation functions and important boundaries are split: BGP pending vs ZAPI send, RIB process vs install, dataplane ctx/init/enqueue/provider/result, owner notify send/apply, and NHT resolve/send. Some divergent paths remain collapsed, especially `rib_process_result` success/failure/stale handling and `rib_addnode`/`rib_link` trace consumption. |
| Source Annotations | 3/5 | The spec has useful action-level `file:line` citations, but not every condition, branch, and state update block is individually annotated. Several fault/harness actions have scenario descriptions instead of concrete source locations, and large actions rely on broad line ranges. |
| Invariant Coverage | 4/5 | Brief section 5 invariants are defined and enabled in at least one hunt cfg; Scenario 5 also has `ProviderSuccessImpliesRealizedAttrs`. The liveness properties are present, but their meaning is limited without fairness/progress assumptions. |
| MC Spec Structure | 4/5 | Counter wrappers are mostly limited to external/fault/nondeterministic actions, while reactive actions pass through with unchanged counters. `MCStateConstraint` and symmetry are present. A view operator excluding counters is missing, so state-space reduction is incomplete relative to the pattern. |
| Trace Spec Design | 4/5 | `Trace.tla` calls base actions directly, implements post-state validation, defaults `JsonFile` correctly, and `Trace.cfg` enables `TraceMatched`. There are no silent actions, which is fine if every step is instrumented. Validation remains optional-field based, so weak traces can pass if instrumentation omits key state fields. |
| Instrumentation Mapping | 4/5 | The mapping covers nearly every spec action with code locations, trigger points, and field categories. It is not strictly 1:1 because `rib_link` is listed as a non-consumed debug/action source, several fields are described generically, and a few fault/harness actions do not have concrete C insertion points. |
| Logical Correctness | 3/5 | SANY syntax passed for base/MC/Trace and all hunt cfgs; base VAV passed; base and MC smoke simulations ran without runtime errors. Main risks are temporal properties without fairness/progress, broad nondeterministic guards such as arbitrary MetaQ `q` selection, and optional trace validation fields that can make checks vacuous. |

## Overall: 30/40

## Issues Found
- `base.tla:1278` and `base.tla:1284` define liveness properties, and `MC_hunt_scenario3_nht.cfg` / `MC_hunt_scenario4_metaq_reconnect.cfg` enable them, but `MCSpec` has no fairness or progress assumptions. Infinite stuttering can produce liveness violations unrelated to the modeled FRR bug.
- `Trace.tla:428` defines `TraceMatched` as eventual trace consumption under `TraceSpec == TraceInit /\ [][TraceNext]_traceAllVars`. As with the MC liveness properties, this relies on progress despite the stuttering closure; trace validation should add an explicit progress/fairness convention or use a validation pattern that cannot fail only because TLC stutters.
- `Trace.tla:81-139` validates only fields that appear in the event state. `instrumentation-spec.md` says fields are validated if present, but does not give per-action required field lists, so an incomplete harness could omit key modified fields and still satisfy post-state validation.
- `MC.tla` has `Symmetry == Permutations(Prefix)` and `MC.cfg` enables it, but there is no `VIEW` operator excluding `constraintCounters`. Counter values therefore remain part of the explored state identity, weakening the intended MC structure.
- `base.tla` source annotations are too coarse for the stated generation standard. For example, `rib_process_result` has broad citations at `base.tla:790-794`, but the individual state updates and stale/matching branches at `base.tla:804-823` are not independently tied to source lines.
- `rib_meta_queue_add` allows any `q \in QueueKind` without tying qindex to route type or actual implementation queue selection. This can intentionally expose `AnyQueuedMask` issues, but it can also create impossible states and make `MetaQSingleVisibleMembership` violations less diagnostic.
- `instrumentation-spec.md` includes `rib_link` as a mapped row while `Trace.tla` consumes only `rib_addnode` for that path. The note explains the exception, but it means the action-to-event mapping is not strictly 1:1.

## Verdict: NEEDS_IMPROVEMENT
