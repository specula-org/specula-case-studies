# Remaining validation work — incremental V02

This file records assurance limits after the completed incremental workflow. It
does not mark a required CI phase as pending and does not weaken the retained
properties or scope.

| Area | Current evidence and limit | Future evidence that would strengthen it |
|---|---|---|
| Exhaustive safety | Standard, full-update, and focused BFS checks reached 50.7–99.8 million distinct states before their planned budgets; all retained nonempty frontiers. | Exhaust smaller bounds or allocate a larger campaign for deeper frontier coverage while preserving all properties. |
| Update-scenario BFS storage | The joint, outgoing-snapshot, learner-vote, recovery, and Ready-output hunts ended on run-local state-storage exhaustion. Exact tasks and last counters are in `../incremental-validation.md` and `verification-results.json`. | Use a larger state volume or a sound state-reduction refinement; do not treat the partial queues as completed checks. |
| Scenario reachability | Six complete source-backed traces reached every intended update canary. Six random simulations did not independently reach those negated canaries before their budgets. | Add targeted non-trace state constraints or proven symmetry/reduction so unconstrained checking reaches the same scenarios without embedding the witness path. |
| Liveness | The campaign checks safety invariants and finite reachability. It does not establish general election, replication, membership, recovery, or ReadIndex liveness under fairness assumptions. | Add separately justified temporal properties and fairness assumptions, then run temporal checking within explicit fault bounds. |
| MC-2 repair validation | MC-2 is reproduced and recorded; the target source was not modified to force a passing result. | After an authorized source fix, rerun the outgoing-snapshot trace, public RawNode confirmation as a negative control, and affected broad checks. |
| Persistent CR-2 | The earlier private-harness scenario is not re-established on the current public interface. | Build a public-interface control for transfer during unapplied self-removal without assuming the result. |
| Persistent CR-5 | The prior delayed-read consequence is not re-established on the current public bootstrap/joint APIs. | Build a public-interface ReadIndex control after leader self-removal, including observable completion or timeout. |
| Retained V01 limits | The prior model's stated abstraction, state-bound, caller-scheduling, and progress limits remain applicable outside the changed interactions. | Extend coverage only with independently justified source correspondence and preserve the original evidence labels. |

The exclusions remain KV/MVCC, gRPC, physical WAL/OS details, serialization
bytes without protocol significance, clock-based lease reads, and Byzantine
behavior. No claim is made about later revisions or external issue histories.

