# dash-ha brief coverage audit

This is the mandatory Phase 2.5 self-audit from the `spec-generation` skill.
It was filled by reading the final `base.tla`, `MC.tla`, `MC.cfg`, and each
actual `MC_hunt_*.cfg`. The modeling brief, rather than a generic fault
taxonomy, is the source of the rows below.

## Brief §2 scenarios

| Brief scenario | Modeled mechanism and principal actions | Targeting hunt config | Enabled scenario invariants |
|---|---|---|---|
| 1. Non-atomic acceptance/dependency/hardware-ACK pipeline | `ActorDriverHandleSwbusMessage` → `ActorDriverHandleActorMessage` → `ActorDriverCommitChanges`; independent HA-set write/state sends; producer apply; scope apply; `DpuAsicAcknowledgeRole` | `MC_hunt_scenario1_pipeline.cfg`; supplementary `MC_hunt_scenario1_role_pair.cfg` prevents strict CP/ASIC checking from masking the pipeline hunt | `ParentBeforeScope`, `AckedTransitionSafety`, `RouteMatchesAckedOwner`; `LegalRolePair` in the supplementary cfg |
| 2. Unversioned at-least-once replay | Distinct retained IDs in `OutgoingSendHaScopeState`; separate `IncomingHandleRequest`, `NetworkLoseAck`, retry, callback, response, and expiry; arrival-ordered overwrite in `NpuHandleHaStateChange` | `MC_hunt_scenario2_replay.cfg` | `TermNonRegression`, `RouteMatchesAckedOwner` |
| 3. Re-pair without protocol epoch | Resolved/unresolved `NpuHandleHaSetStateUpdateRePair*` branches increment a ghost provenance epoch while preserving old messages/caches; handlers ignore source/epoch | `MC_hunt_scenario3_repair.cfg` | `CurrentPeerIsolation`, `AckedTransitionSafety`, `SingleDecisionMaker` |
| 4. Persist-before-send recovery gap | Phase side effects are queued by `NpuDriveStateMachine`, phase is committed separately, `Crash` clears volatile intent, and `NpuApplyRehydrationSideEffects` rebuilds only the implemented subset; pending-edge UUID regeneration is separate | `MC_hunt_scenario4_recovery.cfg` | `PendingOperationBijective`, `SingleDecisionMaker` |
| 5. Actor deletion/recreation across epochs | Config SET/DEL, exact-route creation, deleting-actor ACK/ignore, cleanup sends/applies, registration, timeout, and recreation are all separate | `MC_hunt_scenario5_lifecycle.cfg` | `ParentBeforeScope` |
| 6. Independent route writers | Scope-state, config-preference, and replay computations are separate actions and all race through `ProducerBridgeApplyRoute` | `MC_hunt_scenario6_route.cfg` | `RouteMatchesAckedOwner`, `SingleDecisionMaker` |
| 7. Shared retry counter | Vote retry/final, switchover RST/FIN, and connection retry/lost/reset each update the implementation counter and an operation-local comparison model | `MC_hunt_scenario7_retry.cfg` | `RetryIsolation` |

No Scenario was merged or omitted. There is at least one targeting cfg for
each of the seven scenarios; Scenario 1 has a supplementary focused cfg so a
strict role-pair violation cannot mask the dependency-pipeline targets.

## Brief §5 proposed invariants

`MC.tla` extends `base`, so every base invariant below is directly in scope of
the MC module. “Enabled” was verified from the `INVARIANTS` stanza of the named
cfg, not inferred from comments or operator definitions.

| Brief invariant | Type | Definition / MC wiring | Enabled hunt config(s) | Audit result |
|---|---|---|---|---|
| `SingleDecisionMaker` | Safety | Defined in `base.tla`; inherited by `MC.tla` | scenarios 1, 3, 4, 6 | Covered |
| `LegalRolePair` | Safety | Defined in `base.tla`; inherited by `MC.tla` | scenario 1 supplementary role-pair cfg | Covered |
| `TermNonRegression` | Safety | Defined in `base.tla`; inherited by `MC.tla` | scenario 2 | Covered |
| `AckedTransitionSafety` | Safety | Defined in `base.tla`; inherited by `MC.tla` | scenarios 1, 3 | Covered |
| `ParentBeforeScope` | Safety | Defined in `base.tla`; inherited by `MC.tla` | scenarios 1, 5 | Covered |
| `RouteMatchesAckedOwner` | Safety | Defined in `base.tla`; inherited by `MC.tla` | scenarios 1, 2, 6 | Covered |
| `CurrentPeerIsolation` | Safety | Defined in `base.tla`; inherited by `MC.tla` | scenario 3 | Covered |
| `PendingOperationBijective` | Safety | Defined in `base.tla`; inherited by `MC.tla` | scenario 4 | Covered |
| `DurableActionProgress` | Liveness | Defined as a temporal operator in `base.tla`; inherited by `MC.tla` | — | Intentionally not enabled in safety hunts: it needs explicit fairness/eventual-delivery assumptions |
| `ConfiguredActorProgress` | Liveness | Defined as a temporal operator in `base.tla`; inherited by `MC.tla` | — | Intentionally not enabled in safety hunts: stable-config and delivery fairness are environment assumptions |
| `PairConvergence` | Liveness | Defined as a temporal operator in `base.tla`; inherited by `MC.tla` | — | Intentionally not enabled in safety hunts: pair stability/eventual delivery must be supplied by a dedicated liveness run |
| `RetryIsolation` | Safety/Liveness | Safety component defined in `base.tla`; operation-local counters retain the comparison history | scenario 7 | Safety component covered; nontermination requires a fair liveness run |

All §5 invariants with a Safety component are enabled in at least one actual
hunt config. `MC.cfg` lists every scenario invariant but comments it out, as
required for standard convergence.

## Brief §6.1 model-checkable findings

| Finding | Reachable trigger in the hunt cfg | Expected violation checked | Targeting hunt config |
|---|---|---|---|
| MC1 | `ConfigSetLimit=1` opens epoch 2; independently scheduled state/write/producer/ASIC actions can expose the dependent scope or route first; one peer send/transition permits stale ACK authorization | `ParentBeforeScope`, `AckedTransitionSafety`, `RouteMatchesAckedOwner` (plus role/decision safety) | `MC_hunt_scenario1_pipeline.cfg` |
| MC2 | `PeerSendLimit=2` permits old/new distinct IDs; `AckLossLimit=1` and `MaintenanceLimit=1` retain/retry old content; delivery order is unconstrained; one replay route compute is enabled | `TermNonRegression`, `RouteMatchesAckedOwner` | `MC_hunt_scenario2_replay.cfg` |
| MC3 | A message can be sent under epoch 1, `RePairLimit=1` advances the relationship, then the retained old message is delivered; one transition enables control-state use of the stale ACK | `CurrentPeerIsolation`, `AckedTransitionSafety`, `SingleDecisionMaker` | `MC_hunt_scenario3_repair.cfg` |
| MC4 | `PendingEdgeLimit=2` allows one UUID before and another after `CrashLimit=1` clears the cached edge; `TransitionLimit=1` opens a persist/send cut and rehydration path | `PendingOperationBijective`, `LegalRolePair`, `SingleDecisionMaker`; `DurableActionProgress` is defined for a separate fair run | `MC_hunt_scenario4_recovery.cfg` |
| MC5 | One DEL, one rapid replacement SET, one cleanup timeout, and one transition allow a dying actor to ACK/discard the replacement while a child retains its old parent cache | `ParentBeforeScope`; progress operators are defined for a separate fair run | `MC_hunt_scenario5_lifecycle.cfg` |
| MC6 | One peer state can install an unacknowledged/stale cached owner; two independent route computations let replay/scope and config writers race before producer apply | `RouteMatchesAckedOwner`, `SingleDecisionMaker`; `PairConvergence` is defined for a separate fair run | `MC_hunt_scenario6_route.cfg` |
| MC7 | `RetryEventLimit=3` is enough for one workflow to consume the shared count and another to make a premature terminal decision or reset it | `RetryIsolation`; `PairConvergence` is defined for a separate fair run | `MC_hunt_scenario7_retry.cfg` |

## Result

The audit found no silent cfg-coverage gap: every brief §2 Scenario has a hunt
cfg, every §5 Safety invariant is defined and enabled in at least one hunt cfg,
and every §6.1 finding has nonzero bounds for its triggering mechanism. The
three pure liveness properties remain explicit operators rather than being
quietly weakened into state predicates; their required fairness assumptions
are documented above.
