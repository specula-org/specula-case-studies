# CR-5 investigation

## Scope and provenance

- Finding source: Code Review. The supplied finding has no model-checking counterexample or violated invariant.
- Parent checkout: `sonic-buildimage` `d5a2f4d1df9fdf71e48777905cd3f032b3d78a94`.
- Investigated submodule: `src/sonic-sairedis` `9bd6103824e4590b24fbce2bc014d8902b51eccb` (the pinned checkout does not contain upstream PR #2007).
- Finding mechanism audited: warm-reboot `APPLY_VIEW` identity matching, RID/VID map construction and validation, and the downstream execution of generated ASIC operations.

## Step 1 — code audit

### Relevant behavior

- `syncd/ComparisonLogic.cpp:67-71` seeds the process-global C PRNG with second-resolution wall-clock time in each `ComparisonLogic` constructor. `syncd/BestCandidateFinder.cpp:2024-2035` consumes that PRNG with `std::rand() % candidateCount`.
- `syncd/BestCandidateFinder.cpp:1629-1645` explicitly describes orchagent restart assigning new VIDs and acknowledges that a wrong tie choice can cause many ASIC removes/recreates. At `:1949-1999`, equal-scoring candidates fall through graph and usage-count heuristics; at `:1554-1606`, a non-unique usage-count result calls the random selector.
- `syncd/ComparisonLogic.cpp:2889-2897` describes `m_preMatchMap` as a prediction/hint, not an authoritative mapping. `syncd/BestCandidateFinder.cpp:1392-1409` honors a hint only when its current VID is still among the candidate objects.
- The supplied claim that candidate traversal itself is unordered is not supported by this checkout. `syncd/AsicView.h:22-24,356` defines the per-type object indexes as nested `std::map`s, and `syncd/AsicView.cpp:424-436` iterates those maps. The comments at `AsicView.h:154,169` and `AsicView.cpp:411,449` still call the returned order random, but the current container implementation is ordered. Independent nondeterminism remains because the tie is explicitly randomized.
- Ordinary generic matching is injective during one transition: candidates come from `getNotProcessedObjectsByObjectType()` (`BestCandidateFinder.cpp:1692-1713`), and a chosen current object is set to `FINAL` by `ComparisonLogic::updateObjectStatus()` (`ComparisonLogic.cpp:1069-1118`), so it cannot be selected again. A pre-match collision likewise cannot reuse a current object after it is final because the hint lookup is restricted to the current candidate vector.
- `ComparisonLogic.cpp:3901-3907` invokes detailed cross-map diagnostics only when RID/VID map sizes differ. Equal-size non-reciprocal maps would therefore escape this particular diagnostic. This is a validation gap, but it is not needed for the concrete virtual-router failure below.
- `SaiSwitch.cpp:1188-1241` accepts a newly discovered warm-boot RID by calling `VirtualOidTranslator::translateRidToVid()`. The translator validates the object type, allocates a fresh typed VID, and inserts both directions (`VirtualOidTranslator.cpp:118-148`). The surrounding comment explicitly allows genuinely new default objects after firmware updates (`SaiSwitch.cpp:1199-1214`). This path does not itself choose among identity candidates.

### Reachable call chain

The path is reached through normal warm-restart operations:

1. Orchagent sends normal Redis `NOTIFY` operations for `INIT_VIEW` and later `SAI_REDIS_NOTIFY_SYNCD_APPLY_VIEW`.
2. `Syncd::processSingleEvent()` dispatches `REDIS_ASIC_STATE_COMMAND_NOTIFY` to `processNotifySyncd()` (`syncd/Syncd.cpp:460-504`).
3. `Syncd::processNotifySyncd()` handles `APPLY_VIEW` and calls `Syncd::applyView()` (`syncd/Syncd.cpp:5557-5567`).
4. `Syncd::applyView()` reads the current and temporary ASIC views, constructs `ComparisonLogic`, and calls `compareViews()` (`syncd/Syncd.cpp:5716-5815`).
5. `ComparisonLogic::compareViews()` seeds the PRNG, creates hints, and calls `applyViewTransition()` (`syncd/ComparisonLogic.cpp:25-71,81-147`).
6. `processObjectForViewTransition()` calls `BestCandidateFinder::findCurrentBestMatch()` (`syncd/ComparisonLogic.cpp:1790-1818`). For tied, structurally identical virtual routers, the generic heuristic reaches `selectRandomCandidate()`.
7. A wrong virtual-router/RID binding makes unchanged VLAN router interfaces look moved. `ComparisonLogic` emits create/remove operations, and the real vendor-SAI consumer executes them in `ComparisonLogic::executeOperationsOnAsic()` / `asic_process_event()` (`syncd/ComparisonLogic.cpp:3816-3878`), called by `Syncd::applyView()` at `syncd/Syncd.cpp:5844-5849`.

### Concrete trigger and safeguards

Natural trigger: configure two VRFs; create two VLAN interfaces for each VRF with VLAN members; bind each VLAN interface to its intended VRF; save configuration; perform warm reboot. The temporary virtual-router VIDs differ from the current VIDs while the two virtual-router objects have identical SAI attributes and identical dependency counts. The existing special-case heuristics do not identify them by their attached VLAN interfaces, so the tie can use the PRNG.

Safeguards encountered:

- Exact VID matches and object-specific heuristics avoid many ambiguous cases, but they do not cover virtual routers in the pinned checkout.
- Marking a selected current object `FINAL` prevents duplicate ordinary selection, but does not prevent the wrong bijection between two virtual routers.
- The pre-match map is only a hint and has no virtual-router/VLAN discriminator here.
- First-stage comparison exceptions return failure without ASIC mutation (`syncd/Syncd.cpp:5794-5831`), but a bad plan that passes comparison is executed destructively at `:5834-5849`.
- Optional post-apply ASIC/database consistency checking occurs only after operations and is controlled by `m_enableConsistencyCheck` (`syncd/Syncd.cpp:5851-5861`); it does not guard the vendor create that can fail first.

## Step 2 — developer-knowledge evidence

- Source commentary acknowledges the behavior. `syncd/Syncd.cpp:5743-5751` asks whether selection should be deterministic for reproducibility and says Redis view results also need sorting. `syncd/BestCandidateFinder.cpp:1641-1645,1965-1977` says ties may be chosen randomly, a wrong choice can cause removes/recreates, and the logic is not perfect.
- Upstream issue [sonic-buildimage#28650](https://github.com/sonic-net/sonic-buildimage/issues/28650), opened 2026-07-28 and currently OPEN, reports this mechanism in production: identical virtual routers tie during warm-reboot APPLY_VIEW, random selection mismatches their VLAN RIF ownership, duplicate RIF creation returns `SAI_STATUS_ITEM_ALREADY_EXISTS`, syncd enters shutdown-wait, and orchagent exits. Its public trigger is the same two-VRF/two-VLAN-interface-per-VRF sequence above.
- Upstream fix PR [sonic-sairedis#2007](https://github.com/sonic-net/sonic-sairedis/pull/2007), opened 2026-07-29 and currently OPEN, is titled "[warm-reboot] Match virtual routers by VLAN interfaces during APPLY_VIEW." Commit `cd2799ef3d0872c976fbb881f26707059bc1a99f` adds `findCurrentBestMatchForVirtualRouter()` at the same `BestCandidateFinder` generic-heuristic site and a unit test with two identical current and temporary virtual routers in reversed identity order. The fix is not an ancestor of the pinned checkout.
- History/blame on the old matching code reaches the repository's available history boundary (`94d5545`, 2021-09-13) and supplies no additional intent beyond the in-code comments. The new PR's commit message and test directly state current developer intent: preserve VLAN-interface ownership when matching virtual routers.

## Step 3 — known status and pre-filter

Tracker searches covered issues and PRs (open and closed), including explicit closed/merged queries for `ComparisonLogic`, random candidates, deterministic APPLY_VIEW, warm reboot, and virtual-router matching. No closed/merged duplicate fix was found. The open issue and open PR above are nevertheless an exact prior report: same warm-reboot APPLY_VIEW tie, same random-candidate fallback site, same virtual-router ambiguity, and the same wrong create/remove consequence.

- Novelty: `KNOWN (cite: https://github.com/sonic-net/sonic-buildimage/issues/28650; fix-status: unfixed)`.
- Status: `DROPPED (code-review × known, cite: https://github.com/sonic-net/sonic-buildimage/issues/28650)`.
- Per the bug-confirmation Phase-1 pre-filter, Phase 2 is not run and no reproduction test is written for a dropped code-review duplicate.
