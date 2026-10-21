# Spec Generation Review: asterinas-fd-epoll

## Scores

| Criterion | Score | Notes |
|-----------|-------|-------|
| Scenario Coverage | 5/5 | All six scenarios have source-backed state, split actions, scenario oracles, focused MC configs, Trace dispatches, and instrumentation rows. Every brief section 6.1 candidate has a reachable targeted hunt. |
| Action Design | 5/5 | The 74 production actions use implementation-function names or function-qualified semantic boundaries. Capture/use, replace/cleanup, enqueue/notify/return, register/check/cache, prepare/copyout, wait/terminal/restore, and callback lock hops remain separate where the implementation can interleave. |
| Source Annotations | 5/5 | Every production action has local `file:line` evidence. The machine-readable 74-row source index is consumed by MC and Trace dispatch, and all 214 generated source references resolve against the pinned checkout. |
| Invariant Coverage | 5/5 | All standard structural properties and all 17 brief section 5 safety/liveness properties are defined, wrapped, and enabled in at least one non-vacuous focused config. Reach and mutation controls independently exercise the added lifetime, exec, wait, callback, and identity oracles. |
| MC Spec Structure | 5/5 | Only nondeterministic request, producer, timeout, signal, and fault introductions consume counters; reactive completions are unbounded. The model provides a projected view, state constraint, and thread symmetry for safety-only runs, while all temporal configs omit symmetry. |
| Trace Spec Design | 5/5 | The Category B timebox uses per-thread cursors and `ViablePIDs`, invokes exactly one full base action per event, has no unconstrained silent production actions, validates action-specific post-state, and requires full consumption plus operation/callback quiescence. |
| Instrumentation Mapping | 5/5 | Base actions, MC wrappers, Trace validation branches, Trace match branches, and instrumentation rows form the same 74-name set. Each row gives pinned code locations, trigger timing, arguments, and exact post-state fields. |
| Logical Correctness | 5/5 | SANY accepts all three modules. No tautological scenario oracle, impossible targeted guard, or malformed temporal property was found; reach/control configs demonstrate non-vacuity and mutation sensitivity. Neutral MC, base simulation, and the positive Trace complete cleanly. |

## Overall: 40/40

## Issues Found

- No correctness or completeness defect was found within the declared bound of two actors, three FD slots, three OFDs, and two epoll instances.
- The seven candidate hunt violations are intended model-checking outputs for brief section 6.1, not specification failures or confirmed Asterinas bugs. They still require minimized counterexamples and source-level regression confirmation.
- Current validation: `audit-spec.py` passes with 74/74 action mappings, 69 MC configs, 13 Trace configs, zero liveness-plus-symmetry configs, and a clean pinned checkout. SANY passes for `base.tla`, `MC.tla`, and `Trace.tla`; `base.cfg` simulation generated 1,760 states, `MC.cfg` completed 519/296 states at depth 7, and `Trace.cfg` completed 37/36 states at depth 36.

## Verdict: PASS
