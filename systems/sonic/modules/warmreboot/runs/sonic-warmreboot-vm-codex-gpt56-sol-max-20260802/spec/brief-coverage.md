# Modeling-brief coverage audit

This audit was filled from the actual `base.tla`, `MC.tla`, and
`MC_hunt_scenario*.cfg` files after the hunt configurations were written. The
brief is the only coverage source. Category-taxonomy checklists were not used.

## Brief §2 scenarios

| Brief scenario | Base-spec extension and principal actions | Targeting hunt cfg | Target checks enabled |
|---|---|---|---|
| 1. Reboot epoch admission and cancellation ownership | `RebootEpoch`; `FastReboot_Request`, `CheckWarmRestartInProgress_Admit`, `EnableWarmRestart`, `ClearBoot`, `FastReboot_ContinueAfterSignal`, `FastReboot_BeginIrreversibleWork` | `MC_hunt_scenario1.cfg` | `AtMostOneActiveEpoch`, `PhaseMonotonicity`; `EventualRecoveryDecision` |
| 2. Acknowledgement before a global quiescence fence | `ProducerFence`; producer enqueue/drain, `OrchDaemon_WarmRestartCheck`, each post-reply drain/FDB/flush/freeze step, and the MC-2 reordered reply | `MC_hunt_scenario2.cfg` | `FreezeAckImpliesQuiescence`, `CheckpointAfterQuiescence` |
| 3. Per-ASIC shutdown, mode choice, and checkpoint aggregation | `ParticipantSnapshot`; service stop success/failure, syncd warm/downgrade, Redis SAVE, dump copy, global decision, dump load | `MC_hunt_scenario3.cfg` | `SingleAuthoritativeView`, `CompleteSameEpochSnapshot`, `PhaseMonotonicity`; `EventualRecoveryDecision` |
| 4. Split hardware/APPLY and database commit | `ApplyJournal`; INIT, compare, one SAI op, ASIC_DB delete/write fragments, two-direction map fragments, crash, journal resume, dirty warm acceptance, cold fallback | `MC_hunt_scenario4.cfg` | `InitBeforeApply`, `SingleAuthoritativeView`, `ApplyCommitAgreement`, `NoWarmFromDirtyApply`; `EventualRecoveryDecision` |
| 5. Nondeterministic identity reconciliation | `IdentityGraph`; known-label candidate construction, one nondeterministic bind per transition, fragmented VID/RID publication | `MC_hunt_scenario5.cfg` | `IdentityMapBijective`, `ApplyCommitAgreement` |
| 6. Timeout reconciliation and premature completion publication | `CompletionBarrier`; restoration, early/late input, EOIU/timeout, reconcile/state publication, later pipeline flush, participant failure, finalizer timeout/clear | `MC_hunt_scenario6.cfg` | `ReconciledImpliesOutputsPublished`, `WarmFlagSafeToClear`; `EventualRecoveryDecision` |

No §2 scenario is merged or omitted; there is one hunt cfg per scenario.

## Brief §5 proposed invariants

`MC.cfg` enables only standard safety and structural convergence checks. Its
scenario-extension block is intentionally commented. Every brief safety
invariant is nevertheless enabled in at least one actual hunt cfg below.

| Brief invariant | Type | Defined in | Available to MC through | Enabled in actual cfg(s) |
|---|---|---|---|---|
| `InitBeforeApply` | Safety | `base.tla` | `MC.tla` extends/instances `base` | scenarios 2, 4, 5, 6 |
| `SingleAuthoritativeView` | Safety | `base.tla` | `MC.tla` extends/instances `base` | scenarios 3, 4 |
| `PhaseMonotonicity` | Safety | `base.tla` | `MC.tla` extends/instances `base` | scenarios 1, 3 |
| `EventualRecoveryDecision` | Liveness | `base.tla` | `MCSpec` behavior | scenarios 1, 3, 4, 6 (`PROPERTIES`) |
| `AtMostOneActiveEpoch` | Safety | `base.tla` | `MC.tla` extends/instances `base` | scenario 1 |
| `FreezeAckImpliesQuiescence` | Safety | `base.tla` | `MC.tla` extends/instances `base` | scenario 2 |
| `CheckpointAfterQuiescence` | Safety | `base.tla` | `MC.tla` extends/instances `base` | scenario 2 |
| `CompleteSameEpochSnapshot` | Safety | `base.tla` | `MC.tla` extends/instances `base` | scenario 3 |
| `ApplyCommitAgreement` | Safety | `base.tla` | `MC.tla` extends/instances `base` | scenarios 4, 5 |
| `NoWarmFromDirtyApply` | Safety | `base.tla` | `MC.tla` extends/instances `base` | scenario 4 |
| `IdentityMapBijective` | Safety | `base.tla` | `MC.tla` extends/instances `base` | scenario 5 |
| `ReconciledImpliesOutputsPublished` | Safety | `base.tla` | `MC.tla` extends/instances `base` | scenario 6 |
| `WarmFlagSafeToClear` | Safety | `base.tla` | `MC.tla` extends/instances `base` | scenario 6 |

Safety coverage result: 12/12 safety invariants are defined and enabled in at
least one hunt cfg. The one liveness obligation is also enabled selectively.

## Brief §6.1 model-checkable findings

| Finding | Reachable trigger in the actual hunt cfg | Expected check(s) enabled | Target cfg |
|---|---|---|---|
| MC-1: owner-scoped epoch plus stale cancellation/retry cleanup | `UseEpochCAS = TRUE`, two callers (`RequestLimit = 2`), and two cleanup firings (`CancellationLimit = 2`) allow owner 1 to release, owner 2 to acquire, then owner 1's unscoped stale cleanup to erase owner 2's flag/snapshot authority | `AtMostOneActiveEpoch`, `PhaseMonotonicity`; liveness property | `MC_hunt_scenario1.cfg` |
| MC-2: reply moved after local drain/flush but another producer crosses the fence | `ReplyAfterLocalDrain = TRUE`; one external enqueue and one optional suppressed freeze failure remain enabled after local check/drain/flush (`EnqueueLimit = 1`, `FreezeFailureLimit = 1`) | `FreezeAckImpliesQuiescence`, `CheckpointAfterQuiescence` | `MC_hunt_scenario2.cfg` |
| MC-3: every single APPLY crash cut with a durable journal | `UseDurableApplyJournal = TRUE`, two irreversible operations, a two-object identity map, and one apply crash (`MaxApplyOps = 2`, `IdentityChoiceLimit = 2`, `ApplyCrashLimit = 1`); unsafe warm recovery is disabled and reactive journal-resume/cold actions remain unbounded | `ApplyCommitAgreement`, `NoWarmFromDirtyApply`, `InitBeforeApply`, `SingleAuthoritativeView`; liveness property | `MC_hunt_scenario4.cfg` |
| MC-4: per-ASIC downgrade still yields one decision/same-epoch checkpoint | Two ASICs plus one local downgrade and one masked stop failure (`ModeDowngradeLimit = 1`, `StopFailureLimit = 1`) while warm aggregation deliberately does not test participant-local mode/status | `CompleteSameEpochSnapshot`, `SingleAuthoritativeView` | `MC_hunt_scenario3.cfg` |
| MC-5: explicit failure and late input with safe/eventual flag clear | Route timeout, EOIU, early/late input, terminal failure, and finalizer timeout each have a one-shot bound; the later flush and flag-clear reactions remain unbounded | `WarmFlagSafeToClear`, `ReconciledImpliesOutputsPublished`; liveness property | `MC_hunt_scenario6.cfg` |
| MC-6: known labels leave graph automorphisms | `UseKnownIdentityLabels = TRUE` with three VIDs/RIDs: one distinguished known pair and two remaining unlabeled symmetric pairs; three candidate choices and one map-publication crash are enabled (`IdentityChoiceLimit = 3`, `ApplyCrashLimit = 1`) | `IdentityMapBijective`, `ApplyCommitAgreement` | `MC_hunt_scenario5.cfg` |

All six §6.1 findings have a hunt cfg whose constants and nonzero bounds make
the stated mechanism reachable. Brief §§6.2 and 6.3 are intentionally not
modeled, as directed by the brief and the coverage checklist.
