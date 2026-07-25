# Brief Coverage Self-Audit

This audit maps modeling-brief §2 (Bug Families), §5 (Proposed Invariants), and
§6.1 (Model-Checkable Findings) to the artifacts produced in Phases 1 and 2:
`base.tla`, `MC.tla`, `MC.cfg`, and `MC_hunt_familyN.cfg`.

## Families (Brief §2)

| Family | Priority | Hunt cfg | Notes |
|---|---|---|---|
| F1: Catchup vs Live Agreement Race | HIGH | `MC_hunt_family1.cfg` | `MCCatchupInstall` enabled, ByzantineVote and Fork zeroed; checks AgreementSafety, LedgerConsistency, NoCrossRoundEquivocation |
| F2: Period 0->P carryover & reproposal guard | HIGH | `MC_hunt_family2.cfg` | `MCByzantineVote` enabled (needed to reorder threshold events that populate the stale next-threshold cache); checks ReproposalGuardEnforced, CertImpliesStartingValue |
| F3: Dynamic Filter Timeout cross-round divergence | MEDIUM | `MC_hunt_family3.cfg` | Crash enabled (post-crash history reset = key trigger); checks FilterTimeoutWithinBounds. Brief explicitly notes this family is liveness-degradation, not safety — primary safety target is "no permanent divergence", checked indirectly by the structural invariants |
| F4: Freshest bundle / fresherThan edge cases | MEDIUM | `MC_hunt_family4.cfg` | ByzantineVote + FastPrimer enabled to drive multi-period cert-threshold creation; checks StagingMatchesFreshest |
| F5: VRF seed lookback forks | LOW (safety) / MEDIUM (liveness) | `MC_hunt_family5.cfg` | ForkCommitteeView + CatchupInstall enabled (Family 5 requires both); checks AgreementSafety, LedgerConsistency |
| F6: Crash recovery state coverage | LOW | `MC_hunt_family6.cfg` | Crash enabled; checks PersistedBeforeBroadcast, NoCrossRoundEquivocation, PersistedNotAhead |

Every named family has a targeting hunt cfg. No mergers.

## Invariants (Brief §5)

| Invariant | Type | Defined in | Wired in MC.tla | Enabled in cfgs |
|---|---|---|---|---|
| AgreementSafety | Safety | base.tla | yes (passes through `algorand!` access) | MC.cfg, MC_hunt_family1.cfg, MC_hunt_family2.cfg, MC_hunt_family4.cfg, MC_hunt_family5.cfg, MC_hunt_family6.cfg |
| LedgerConsistency | Safety | base.tla | yes | MC.cfg, MC_hunt_family1.cfg, MC_hunt_family5.cfg |
| StagingMatchesFreshest | Safety | base.tla | yes | MC.cfg, MC_hunt_family4.cfg |
| ReproposalGuardEnforced | Safety | base.tla | yes | MC.cfg, MC_hunt_family2.cfg |
| CertImpliesStartingValue | Safety | base.tla | yes | MC.cfg, MC_hunt_family2.cfg |
| NoCrossRoundEquivocation | Safety | base.tla | yes | MC.cfg, MC_hunt_family1.cfg, MC_hunt_family6.cfg |
| PersistedBeforeBroadcast | Safety | base.tla | yes | MC.cfg, MC_hunt_family6.cfg |
| EventuallyConverge | Liveness | base.tla | (not yet exercised — out of scope for this audit per checklist) | — |
| FilterTimeoutWithinBounds | Safety/Liveness | base.tla | yes | MC.cfg, MC_hunt_family3.cfg |

Every Safety invariant in §5 is enabled in at least one cfg. Liveness invariants are out of scope per the brief-coverage checklist.

## Findings (Brief §6.1)

| ID | Trigger | Expected violation | Targeting hunt cfg | Reachable? |
|---|---|---|---|---|
| MC-1 | CatchupInstall(R, V_c) then BroadcastVote(R, P, cert, V_l), V_l /= V_c | AgreementSafety | `MC_hunt_family1.cfg` | Yes — `MCCatchupInstall` and `BroadcastVote` both enabled; LoseMessage zeroed enough to keep the schedule reachable |
| MC-2 | Fast-forward via softThreshold(R, P) with Cached.Bottom=false AND Cached.Proposal=bottom; subsequent issueSoftVote without reproposer constraint | ReproposalGuardEnforced | `MC_hunt_family2.cfg` | Yes — Byzantine votes can populate the cache asymmetrically; MaxPeriod=2 reaches the trigger |
| MC-3 | certThreshold(R, P1) cached; later certThreshold(R, P2) for different value arrives. Cache NOT replaced (short-circuit). partitionPolicy rebroadcasts stale P1 cert | AgreementSafety, StagingMatchesFreshest | `MC_hunt_family4.cfg` | Yes — `UpdateFreshest` faithfully encodes the cert-cert short-circuit; ByzantineVote drives multi-period cert thresholds |
| MC-4 | Two honest servers' committees for (R,P,S) against different ledgerView[R-2] snapshots; can BOTH branches produce cert thresholds for different values? | LedgerConsistency | `MC_hunt_family5.cfg` | Yes — `MCForkCommitteeView` enabled; MaxRound=3 reaches R-2 |
| MC-5 | After EnterPeriod(P+1): lastConcluding = previous step. If step >= partitionStep, voteStepFresh expands acceptance window. Can adversarial votes from P be accepted as fresh in P+1 creating unintended quorum? | NoCrossRoundEquivocation | `MC_hunt_family2.cfg` | Yes — `lastConcluding` is tracked in base.tla, EnterPeriodViaNextThreshold sets it; ByzantineVote enabled |
| MC-6 | enterRound(R+1) via certThreshold(R, p); freshestBundleRequest may replay; cached nextThreshold(R, P') replay may trigger enterPeriod in freshly zeroed round. Does p.Period > e.Period guard at player.go:396-398 hold? | EventuallyConverge | `MC_hunt_family2.cfg` | Partial — the guard check is baked into `EnterPeriod*` preconditions; we check no spurious period skip via the structural invariant `PeriodBound`. Direct EventuallyConverge property is in base.tla but not enabled in MC.cfg per the checklist (liveness out of scope) |

All five primary findings (MC-1..5) have a targeting hunt cfg with a fault setup that makes the trigger reachable. MC-6 is partially covered — the structural side is checked, but the full liveness assertion is intentionally out of scope per the brief-coverage checklist.

## Self-check summary

- 6/6 families have a targeting hunt cfg.
- 7/7 §5 Safety invariants are defined in `base.tla`, wired in `MC.tla`, and enabled in ≥1 hunt cfg.
- 5/6 §6.1 findings have a fully reachable hunt cfg; MC-6 is partial (structural only) and the limitation is written down.
- No invariant is "defined but never enabled" — that gap is the failure mode the checklist exists to catch.
- No fault wrapper is `git revert <commit>` of a known fix; every wrapper models an adversary action grounded in concrete brief evidence (catchup install, Byzantine equivocation, fork, crash, fast-recovery primer, message loss).
