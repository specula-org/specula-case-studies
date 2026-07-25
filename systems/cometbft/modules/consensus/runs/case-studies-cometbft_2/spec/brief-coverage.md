# Brief Coverage Self-Audit — CometBFT Round 2

Maps modeling-brief.md §2 (Bug Families), §5 (Proposed Invariants), §6.1
(Model-Checkable Findings) to the spec/MC artifacts produced in this run.

Spec module: `base.tla` (defines invariants), `MC.tla` (wires fault wrappers),
seven hunt cfgs:
`MC.cfg` (convergence), `MC_hunt_family{1..6}_*.cfg`, `MC_hunt_combined.cfg`.

## Table 1: Bug Families (from brief §2)

| Brief Family | Hunt cfg file | Family-relevant invariants enabled in that cfg | If skipped, why? |
|---|---|---|---|
| 1. Equivocation production + detection-evasion | `MC_hunt_family1_equivocation.cfg` | ElectionSafety, EventualAccountabilityStrong; PROPERTY EventualAccountability | — |
| 2. Amnesia as a Byzantine action (lock-forgetting) | `MC_hunt_family2_amnesia.cfg` | ElectionSafety, LockSafety, PrivvalAmnesiaDetection | — |
| 3. Vote-extension reuse + late-commit | `MC_hunt_family3_vereuse.cfg` | ElectionSafety, VEContextBound, LastCommitVECoverage; PROPERTY VELiveness | — |
| 4. Light-client lunatic — missing header self-consistency | `MC_hunt_family4_lunatic.cfg` | LightClientFollowsCanonicalChain, LunaticEvidenceVerifies (ElectionSafety intentionally omitted — Family 4 probes f ≥ n/3 light-client threshold; Agreement is not expected to hold at this faulty cardinality) | — |
| 5. Evidence-lifecycle adversarial races | `MC_hunt_family5_evidence.cfg` | ElectionSafety, EventualAccountabilityStrong, HonestPeerNotPunished, EvidenceConsistency, EvidencePoolBounded; PROPERTY EventualAccountability | — |
| 6. Locking-vs-relock transitions under Byzantine proposer | `MC_hunt_family6_locking.cfg` | ElectionSafety, LockSafety, Round1ProposalValidation | — |
| (Cross-family compositions: MC-4, MC-13) | `MC_hunt_combined.cfg` | ElectionSafety, LockSafety, PrivvalAmnesiaDetection, EventualAccountabilityStrong | — |

All six families have a dedicated hunt cfg; an extra `MC_hunt_combined.cfg`
covers the compositional findings MC-4 and MC-13 from §6.1.

## Table 2: Proposed Invariants (from brief §5)

Read directly from each hunt cfg's INVARIANTS / PROPERTIES section.

| Brief invariant | Defined at (file:line) | Wired in MC.tla? | Enabled in which hunt cfg(s)? | If skipped, why? |
|---|---|---|---|---|
| Agreement (Safety) | `base.tla:1566` (alias of ElectionSafety) | yes (pass-through) | family1, family2, family3, family5, family6, combined (via ElectionSafety) | — |
| ElectionSafety (Safety) | `base.tla:1560` | yes | family1, family2, family3, family5, family6, combined | not in family4 — Family 4 probes the lunatic security threshold (f ≥ n/3) where Agreement is intentionally outside the safety boundary; this is documented inline in `MC_hunt_family4_lunatic.cfg` |
| LockSafety (Safety) | `base.tla:1578` | yes | family2, family6, combined | — |
| EventualAccountability (Eventual-Safety) | `base.tla:1738` (temporal) + `base.tla:1599` EventualAccountabilityStrong (instant) | yes | family1, family5 as PROPERTY (temporal); family1, family5, combined as invariant (Strong) | — |
| PrivvalAmnesiaDetection (Safety) | `base.tla:1612` | yes | family2, combined | — |
| VEContextBound (Safety) | `base.tla:1626` | yes | family3 | — |
| LastCommitVECoverage (Safety) | `base.tla:1639` | yes | family3 | — |
| VELiveness (Liveness) | `base.tla:1746` | yes | family3 as PROPERTY | — |
| LightClientFollowsCanonicalChain (Safety) | `base.tla:1650` | yes | family4 | — |
| LunaticEvidenceVerifies (Safety) | `base.tla:1660` | yes | family4 | — |
| HonestPeerNotPunished (Safety) | `base.tla:1672` | yes | family5 | — |
| EvidenceConsistency (Safety) | `base.tla:1683` | yes | family5 | — |
| EvidencePoolBounded (Safety) | `base.tla:1691` | yes | family5 | — |
| Round1ProposalValidation (Safety) | `base.tla:1698` | yes | family6 | — |

Every Safety invariant in brief §5 is enabled in at least one hunt cfg.
ElectionSafety is omitted from family4 only because that cfg probes the
documented security boundary (f ≥ n/3 light-client trust threshold), outside
the BFT bound where Agreement holds — this is the brief's design choice in
§2 Family 4 and §3.2.

## Table 3: Model-Checkable Findings (from brief §6.1)

| Finding ID | Trigger mechanism (action / fault) | Expected violated invariant | Hunt cfg targeting it |
|---|---|---|---|
| MC-1 | `ByzEquivocate(s, h, r)` + delivery to ≥1 honest | `EventualAccountabilityStrong` (or temporal `EventualAccountability`) — should hold under partial sync | `MC_hunt_family1_equivocation.cfg` |
| MC-2 | `ByzEquivocate` + `ByzSelectiveDisseminate` with disjoint partition | `EventualAccountabilityStrong` violated when split | `MC_hunt_family1_equivocation.cfg`; `MC_hunt_family5_evidence.cfg` |
| MC-3 | `Crash` + `WALTailTruncate` + `ByzAmnesia` (precommit at r2 for b' != prior b) | `LockSafety`, `PrivvalAmnesiaDetection` | `MC_hunt_family2_amnesia.cfg` |
| MC-4 | `ByzEquivocate` + `ByzAmnesia` (composition) | `LockSafety` + `EventualAccountabilityStrong` (layered) | `MC_hunt_combined.cfg` |
| MC-5 | `ByzAttachSameVEToBoth(s, h, r)` + `ByzEquivocate` | `VEContextBound` (expected to hold structurally; composes with equivocation) | `MC_hunt_family3_vereuse.cfg` |
| MC-6 | `ByzLateAddPrecommitWithBadVE(s, h, r)` — late LastCommit precommit reaches PrepareProposal at h+1 | `LastCommitVECoverage` violated | `MC_hunt_family3_vereuse.cfg` |
| MC-7 | `ByzLunaticForkHeader(h)` + `LightClientVerify` | `LightClientFollowsCanonicalChain` violated | `MC_hunt_family4_lunatic.cfg` |
| MC-8 | `EvidenceExpiryRace(s1, s2, ev)` with `AdvanceClock` driving skew | `HonestPeerNotPunished` violated | `MC_hunt_family5_evidence.cfg` |
| MC-9 | `CrashDuringConsensusBuffer(s)` — buffer flushed at Crash, evidence lost | `EventualAccountabilityStrong` violated (single-witness loss) | `MC_hunt_family5_evidence.cfg` |
| MC-10 | `ByzProposeAlternating(s, blockA)` then `ByzProposeAlternating(s, blockB)` at adjacent rounds | `LockSafety` must hold under interleaving | `MC_hunt_family6_locking.cfg` |
| MC-11 | `ByzPOLRoundGtRound(s)` — proposer with POLRound ≥ Round | `Round1ProposalValidation` violated | `MC_hunt_family6_locking.cfg` |
| MC-12 | `ByzFloodEvidence(s)` — many distinct DuplicateVoteEvidence | `EvidencePoolBounded` violated (pool unbounded) | `MC_hunt_family5_evidence.cfg` |
| MC-13 | `ByzEquivocate` + `ByzSelectiveDisseminate` + `WALTailTruncate` on detector | `EventualAccountabilityStrong` + `LockSafety` (worst-case detection-evasion) | `MC_hunt_combined.cfg` |

Every §6.1 finding has a hunt cfg whose fault-counter setup enables the
trigger. Counter bounds in `MC_hunt_combined.cfg` and the individual family
cfgs were checked against the brief: each required mechanism's counter is ≥ 1.

## Coverage Summary

```
Families: 6 / 6 implemented + 1 cross-family combined cfg (skipped: none)
Proposed Safety Invariants: 13 / 13 enabled in ≥1 hunt cfg
  (ElectionSafety omitted from family4 only — documented design boundary)
Model-Checkable Findings: 13 / 13 targeted by a hunt cfg
Hunt cfg files: 7 (family1..family6 + combined)
```
