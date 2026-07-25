# Sui Mysticeti — Validation Changelog

Tracking spec modifications across iterative trace validation and model checking
rounds. See `validation-workflow/guide.md` for the workflow.

## Round 1 - Trace Validation

- [fix-spec] IsVote: replaced `Nil`-returning `FindSupportedBlock` with
  set-returning `FindSupportedBlockRefs`; use set membership for the vote
  check. Avoids TLC's strict record-vs-string equality. (Trace: normal,
  equivocation)
- [fix-spec] GetBlocksAtRef: replaced `GetBlockIn` (returns Nil or block)
  with set-returning version; propagated through AncestorRefsAbove,
  FindSupportedBlockReachable, IsCertificate, TryIndirectDecide, Linearize.
  Removes all Nil/record heterogeneous comparisons. (Trace: normal)
- [fix-spec] ByzPropose: add Byzantine block to `dag[s]` for the producer s.
  Matches the harness's `accept_block` call on the Byzantine validator's own
  block. Required for clockRound math to advance correctly. (Trace:
  equivocation)
- [fix-spec] DeliverBlockIfLogged: added idempotent branch — when block is
  already in dag (from ByzPropose self-add), DeliverBlock event treated as
  no-op stuttering on protocol state. Required because the harness emits a
  separate DeliverBlock for s4's own round-2 byz block. (Trace: equivocation)
- [fix-spec] DeliverBlock: removed ancestor presence check. The harness uses
  `dag_state.accept_block` directly, bypassing block_manager's
  suspended-blocks logic; traces show blocks accepted with missing
  high-round ancestors. CommitRecursionDecidable still catches recursion
  bugs at decide time. (Trace: equivocation)
- [fix-spec] ByzProposeIfLogged: bypass base.tla::ByzPropose's
  `\E ancRefs \in SUBSET ...` and `\E ts` existentials; construct the post-
  state directly from the trace block. Avoids 2^|Messages| * MaxTimestamp
  enumeration that timed out at depth 37. (Trace: equivocation)
- [fix-spec] ServerSeq: hardcoded as `<<"s1","s2","s3","s4">>` to match the
  harness's authority-index → "s{i+1}" convention. The previous CHOOSE-based
  permutation was non-deterministic across TLC runs. (Trace: equivocation)
- [fix-spec] FindSupportedBlockRefs: pass `leaderSlot.round - 1` to
  AncestorRefsAbove (instead of `leaderSlot.round`) so the recursion
  includes refs at exactly `leaderSlot.round`, matching impl's `>=
  leader_slot.round` recursion bound. Required for EnoughLeaderSupport to
  return TRUE at decide time. (Trace: equivocation)
- [fix-spec] FindSupportedBlockReachable: use `>=` instead of `>` in the
  strict ancestor filter; mirror the impl's recursion semantics. (Trace:
  equivocation)
- [fix-cfg] Trace.cfg / TraceByz.cfg: bumped `GCDepth` from 2 to 10 so the
  spec's `leader.round - GCDepth` saturates to 0 within the trace's max
  round of 6. Matches the impl's default gc_depth (≈ 50) where commits at
  low rounds don't advance gcRound past 0. (Trace: equivocation,
  crash_recover)
- [fix-spec] TraceSpec: added `WF_allVars(TraceNext)` (weak fairness) so
  TLC's temporal property `TraceMatched` actually rules out the stuttering
  behaviour at every cursor. Without fairness, `[][TraceNext]_allVars`
  allows infinite stuttering and `<>(l > Len)` would fail trivially. (Trace:
  equivocation)
- [fix-spec] Removed SilentDeliverBlock from TraceNext: with DeliverBlock no
  longer gated on ancestor presence, silent pre-delivery isn't needed and
  was creating alternative stuttering paths. (Trace: equivocation)
- [fix-spec] RecoverAmnesiaIfLogged (Trace wrapper only): bypass
  base.tla::RecoverAmnesia's peer-report aggregation; directly set
  `lastKnownProposed` to the trace's value. Models the harness's
  unconditional `emit_recover_amnesia(0)` simulation of the F2 underreport
  bug. Base RecoverAmnesia (with the strict f+1 quorum model) is unchanged
  for MC bug hunting. (Trace: crash_recover)

**Result**: All 4 traces pass — normal, force_propose, crash_recover,
equivocation.

## Round 2 - Model Checking (MC.cfg)

- 30-min BFS at depth 12 with 401 M states / 79 M distinct. No
  invariant violations of `TypeOK`, `ClockGCConsistency`,
  `CommittedBlocksRoundOK`, `DecisionPermanence`, or
  `MonotonicCommitSeq`.
- [fix-cfg] `Server` set to strings `{"s1", "s2", "s3", "s4"}` so the
  hardcoded `ServerSeq` matches the trace harness convention. Lost
  TLC's honest-permutation `SYMMETRY` as a result (cannot use
  `Permutations` on strings); tightened `MaxRound = 4`,
  `MaxTimestamp = 1`, `MaxDagSizeLimit = 10` to compensate.
- No spec changes.

**Result**: Phase 2 passes. Converged in one round.

## Round 3 - Bug Hunting

- [info] Updated all `MC_hunt_*.cfg` to use string `Server` and
  remove `SYMMETRY Symmetry`.
- [bug] F3 / `CommitRecursionDecidable`: 4-state counterexample
  with two consecutive `MCByzPropose` then a `DeliverBlock` leaves
  an honest validator with a block whose `round > gc_round` ancestor
  is missing from `dag[s]`. Matches CR1 — `find_supported_block` and
  `ancestors_at_round` lack the defensive guard that `is_certificate`
  has. Output: `spec/output/MC_hunt_family3_bfs.out`.
- [bug] F4 / `ForcePropose2f1Parents`: 3-state counterexample
  (`MCAddCertifiedCommit("s2", 2)` then `MCForcePropose("s2")`) with
  the validator force-proposing at round 2 against an empty round-1
  parent set. Matches MC4 — `proposer.rs:352-354` `assert!` fires in
  production. Output: `spec/output/MC_hunt_family4_bfs.out`.
- F1 BFS hit depth 12 / 45 M distinct in 30 min; no violation of
  CommitAgreement / CommitDigestAgreement / LeaderCommitMonotonic.
- F2 BFS hit depth 10 / 2.5 M distinct (run squeezed by shared-host
  TLC contention); no violation of `NoOwnEquivocation`.
- F4 multileader: depth 13 / 858 K distinct, no violation (multi-leader
  path not active in current spec).

**Result**: 2 bugs found and recorded in `spec/bug-report.md`.
