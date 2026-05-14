# Modeling Brief: cometbft/cometbft (Round 2 — Byzantine adversary actions)

## 1. System Overview

- **System**: CometBFT (fork of Tendermint) — Go BFT consensus engine. This round 2 brief is scoped to **Byzantine adversary actions** that compose with the round-1 distributed-fault model.
- **Language**: Go, ~6200 LOC consensus core + ~6600 LOC supporting types (same as round 1)
- **System category**: **Category A (Distributed / Message-Passing)** with **BFT overlay**. The protocol's safety/liveness depends on tolerating ≤ *f* deviating validators per `n ≥ 3f+1`; safety argument is purely BFT, not crash-fault-tolerant. Apply both `distributed-analysis.md` (6 fault families) and `bft-analysis.md` (9 Byzantine action categories). Layer-1 environment: **static corruption + partial synchrony + authenticated + f < n/3**.
- **Protocol**: Tendermint BFT (PBFT-family) with: ABCI++ vote extensions; PBTS (in newer branches, not in analyzed snapshot); evidence pool with `DuplicateVoteEvidence` + `LightClientAttackEvidence`; light-client verifier.
- **Key architectural choices relevant to Byzantine analysis**:
  - **`LockedBlock`/`LockedRound`/`ValidBlock`/`ValidRound` are NOT persisted to WAL.** They are reconstructed only as a side-effect of replaying votes/proposals (`replay.go:39-90`). `repairWalFile` silently truncates the tail at the first decode error (`state.go:2675-2708`).
  - **Privval `CheckHRS` only enforces (H,R,S) monotonicity** (`privval/file.go:100-131`). It does **not** memoize the BlockID across rounds at the same height.
  - **`consensusBuffer` for conflicting-vote evidence is purely in-memory** and unconditionally reset on `Update` (`pool.go:49, 538`).
  - **VE signed bytes do not include BlockID** (`types/canonical.go:71-78`). ABCI `VerifyVoteExtension` does not receive the round.
  - **`evidence/reactor.go:192`** broadcast filter is height-only; **`evidence/verify.go:313 IsEvidenceExpired`** is height-AND-time. Sender and receiver disagree at the window edge.
  - **`light/verifier.go:VerifyAdjacent`** only cross-checks `ValidatorsHash` against `NextValidatorsHash`; does NOT cross-check `LastBlockID` / `LastCommitHash` / `AppHash` / `NextValidatorsHash` / `ConsensusHash` against the trusted header.
- **Round-1 carry-forward**: round-1 modeled `Crash`, `LoseMessage`, `Timeout`, `InvalidVE` (narrow), `WAL replay`, `enterPrecommit` paths. Round 2 adds the **Byzantine production-side actions** for the equivocation / lunatic / amnesia attack classes named in CometBFT's own accountability documentation, plus VE-reuse and evidence-lifecycle attacks.

## 2. Bug Families

### Family 1: Equivocation production with detection-evasion (HIGH)

**Mechanism**: A Byzantine validator signs two precommits at the same `(height, round)` for different `BlockID`s, then *selectively disseminates* the conflicting votes (one half to subset A of honest nodes, the other half to subset B) so that no single honest node observes both votes and `vote_set.go:NewConflictingVoteError` never fires. The reactive `DetectEquivocation` path is correct but the *trigger* is split across the network.

**Evidence**:
- Historical: #2353 OPEN — `TestByzantinePrevoteEquivocation` confirmed real evidence loss: byzantine prevotes dropped when peer past prevote step
- Historical: #1917 CLOSED — pre-cursor flaky test indicating gossip-suppression
- Historical: CSA-2026-001 "Tachyon" — commit-sig vs BFT-Time inconsistency lets ≤1/3 faulty move chain time
- Historical: #5435 OPEN — `DoubleSignCheckHeight=1` performs 0 iterations (state.go:2557)
- Historical: #1309 CLOSED-as-log-only — Proposal with `POLRound == LockedRound` but different proposed value: canonical sign of equivocation; only log added
- Code analysis: `evidence/reactor.go:1611 VoteSetBits` reconciliation exchanges bitmaps, not actual conflicting vote bytes — selective dissemination is undetectable cross-node
- Code analysis: `vote_set.go:267-283` conflicting vote silently dropped from `voteSet.votes` (only first vote retained for `maj23` computation)

**Affected code paths**:
- `types/vote_set.go:218-238` — `vote.Verify` + `addVerifiedVote` + `NewConflictingVoteError`
- `consensus/state.go:2132-2149` — `tryAddVote` catches `*ErrVoteConflictingVotes` and reports
- `evidence/pool.go:172-188` — `ReportConflictingVotes` (buffer is in-memory only)
- `consensus/reactor.go:1611` — `VoteSetBits` reconciliation

**Suggested modeling approach**:
- Variables: `signedVotes : [Server -> SUBSET Vote]` per validator; `seenConflicting : [Server -> SUBSET (Vote × Vote)]`
- Actions:
  - `ByzEquivocate(s, h, r, blockA, blockB)` (BFT category **2.1**) — Byzantine produces two signed precommits at same (h, r) for different blocks, both added to message bag
  - `ByzSelectiveDisseminate(s, voteA, voteB, partA, partB)` (BFT category **2.4**, requires directed message bag) — Byzantine sends `voteA` only to `partA ⊆ Server\{s}` and `voteB` only to `partB` with `partA ∩ partB = ∅`
  - The existing `DetectEquivocation` sink fires only when a server has both votes in its local pool
- Granularity: production = single atomic step; dissemination = per-recipient
- Key invariant: `EventualAccountability`: if a Byzantine validator equivocates and at least one honest node sees both votes, evidence eventually applies (composes with liveness conditions)

**Priority**: High
**Rationale**: This is the central Byzantine action that round 1 explicitly noted as missing. Selective dissemination is a known evidence-loss vector confirmed by #2353. Required to validate that the *reactive* `DetectEquivocation` is actually exercised.

---

### Family 2: Amnesia as a Byzantine action (lock forgetting across crash + cross-round signing) (HIGH)

**Mechanism**: A Byzantine validator (or an honest validator after WAL corruption / `repairWalFile` truncation) signs a precommit for block `B` at `(H, R1)`, then in a later round at the same height signs a precommit for a different block `B'` at `(H, R2 > R1)`. The privval's `CheckHRS` permits this because R2 > R1 is not a regression; the WAL never persisted `LockedBlock`/`LockedRound` directly.

**Evidence**:
- Historical: legacy tendermint#8739 — WAL non-persistence of PBTS `ReceiveTime` causes restart-replay to refuse signing ("conflicting data"). Cason: amnesia risk acknowledged.
- Historical: #3570 — v0.38.6 path that mis-asserts VE-enabled for nil precommit caused privval panic
- Code analysis: `consensus/state.go:2675-2708 repairWalFile` decodes until first error and writes prefix only; tail silently truncated
- Code analysis: `consensus/state.go:735-740 updateToState` clears `LockedRound=-1`, `LockedBlock=nil` on every new height
- Code analysis: `privval/file.go:100-131 CheckHRS` enforces only (H,R,S) monotonicity — no per-block memory
- Code analysis: `consensus/state.go:851-859` — explicit `fail.Fail() // XXX` between WAL WriteSync of internal VoteMessage and `handleMsg`; comment acknowledges "Equivalent would be to fail here and manually remove some bytes from the end of the wal"
- Code analysis: `proto/tendermint/consensus/wal.proto:35-42` — WAL has only 4 message types, none of them store `LockedBlock`/`ValidBlock`

**Affected code paths**:
- `consensus/state.go:1484-1603 enterPrecommit` (3 inlined branches: relock / new-lock / unlock-and-nil)
- `consensus/state.go:2317-2333 addVote` prevote handler unlock logic (`LockedRound < vote.Round`)
- `consensus/state.go:2422-2470 signVote` and `state.go:881-905 writeInternalMsgToWAL`
- `consensus/state.go:2675-2708 repairWalFile`
- `consensus/replay.go:94-166 catchupReplay`
- `privval/file.go:100-131 CheckHRS`, `file.go:340-355 SignVote` (same-HRS replay logic), `file.go:412-421 saveSigned`

**Suggested modeling approach**:
- Variables (new):
  - `walPersisted : [Server -> Seq(WALMessage)]` — fsync'd suffix
  - `walPending : [Server -> Seq(WALMessage)]` — buffered, lost on crash
  - `pvLastSign : [Server -> [Height, Round, Step, BlockID]]` — privval last-sign state
  - `lockedRound`, `lockedBlock`, `validRound`, `validBlock` (already in round-1 base)
- Actions:
  - `ByzAmnesia(s, h, r2, b2)` (BFT category **2.6**) with precondition: `s ∈ Faulty` and `∃ r1 < r2 : PriorPrecommit[s][h][r1].block ≠ b2`. Wrapper signs a fresh precommit at `(h, r2)` for `b2`. Composes with `Crash(s) × Recover(s)` to model the honest-but-amnesiac case.
  - `Crash(s)` discards `walPending[s]` and resets `lockedRound[s] = -1`
  - `WALTailTruncate(s, k)` (modeling `repairWalFile`'s silent truncation): drops the last `k` records of `walPersisted[s]` and re-derives `lockedRound` from the remaining replay
  - `Recover(s)` replays remaining WAL through `handleMsg`/`handleTimeout` to reconstruct `lockedRound[s]`, `lockedBlock[s]`
- Granularity: split `signVote` into `PrivvalSign` (updates `pvLastSign`) and `WALRecordWrite` (extends `walPersisted`); allow `Crash` between them; the `fail.Fail()` site at state.go:858 marks the explicit window
- Key invariants:
  - `LockSafety`: if validator `v` precommits block `b` at `(h, r1)`, it does not precommit `b' ≠ b` at `(h, r2 > r1)` unless it observed a polka for `b'` at some round `r ∈ (r1, r2]`
  - `PrivvalAmnesiaDetection`: if `pvLastSign[s].height == h && pvLastSign[s].step == precommit`, signing another precommit at `(h, r' > pvLastSign[s].round)` for a different BlockID should fail — currently it succeeds

**Priority**: High
**Rationale**: This is the canonical "Tendermint family" amnesia composition (2.6 × 5.1) explicitly called out in `bft-analysis.md` § 2.6. Round 1 modeled crash + WAL but did not model the Byzantine variant where the validator chooses to claim amnesia.

---

### Family 3: Vote-Extension Reuse and Late-Commit Surfacing (MEDIUM-HIGH)

**Mechanism**: The VE signature payload (`CanonicalizeVoteExtension`) does **not** include BlockID, so the same VE signature is valid for two conflicting precommits at the same (H, R). Cross-(H, R) replay is blocked by the carrying vote signature's BlockID/Timestamp/Round coverage, but `BuildExtendedCommitInfo` does not re-verify VE sigs and the ABCI app `VerifyVoteExtension` does not receive the round — closing the loop on the *next* proposer at height H+1.

**Evidence**:
- Historical: #5204 OPEN — proposer doesn't self-verify own VE; >1/3 invalid VEs cause indefinite re-extension loop
- Historical: ASA-2024-011 FIXED v0.38.15 — VE precommit `ValidatorIndex` not validated → panic
- Historical: #2523 / #2361 OPEN (spec-deferred) — `PrepareProposal`'s `ExtendedCommitInfo` may contain VEs that were never verified (late precommits added to LastCommit after height delivered)
- Historical: #1253 OPEN — VE size not bounded; serialized vote can exceed WAL 1 MB limit
- Historical: ASA-2024-001 FIXED v0.38.3 — `VoteExtensionsEnableHeight` governance change crashed nodes
- Code analysis: `types/canonical.go:71-78 CanonicalizeVoteExtension` — covers only {Extension, Height, Round, ChainId}; BlockID absent
- Code analysis: `proto/tendermint/abci/types.proto:196-203` — ABCI `RequestVerifyVoteExtension` has {Hash, ValidatorAddress, Height, VoteExtension} — **no Round**
- Code analysis: `state/execution.go:609-665 BuildExtendedCommitInfo` — per-signature rounds dropped; signatures not re-verified; only structural `EnsureExtension` check

**Affected code paths**:
- `consensus/state.go:2455-2462 signVote` (VE extension creation)
- `consensus/state.go:2262 addVote` (VE verify on receive)
- `types/vote.go:267-277 VerifyExtension`
- `state/execution.go:413-433 VerifyVoteExtension` (ABCI call)
- `state/execution.go:609-665 BuildExtendedCommitInfo`
- `consensus/state.go:2193-2222 addVote` LastCommit late-arrival path

**Suggested modeling approach**:
- Variables: `voteExtension : [Server -> [H, R] -> Bytes]`, `extSigVerified : [Server -> SUBSET [H, R, Validator]]`, `lastCommitExtensions : [Server -> SUBSET (Validator, Bytes)]`
- Actions:
  - `ByzAttachSameVEToBoth(s, h, r, blockA, blockB)` (BFT category **2.5** + **2.1** composition) — Byzantine attaches the same VE-sig to two conflicting precommits at (h, r). The receiver's `vote.VerifyExtension` accepts both because signature was over (Extension, H, R, ChainID).
  - `ByzLateAddPrecommitWithBadVE(s, h, r)` — Byzantine adds a precommit to `LastCommit` after height `h+1` has begun; the VE on this vote was never `VerifyVoteExtension`-checked. Trace through to `BuildExtendedCommitInfo` at height `h+1` `PrepareProposal`.
  - `ByzReplaySelfVE(s, h, oldR, newR)` — Byzantine replays its own previously-signed VE bytes onto a freshly-signed vote at (h, newR). Should be blocked by VoteSet's `vote.Round == voteSet.round` check; verify in model.
- Granularity: split precommit-with-extension into `ExtendVote` + `SignVoteEnvelope` + `BroadcastVote`
- Key invariants:
  - `VEContextBound`: every VE accepted by `addVote` has its `(H, R)` matching the carrying vote envelope (provable from current code; verify it holds under Byzantine)
  - `LastCommitVECoverage`: every extension in `ExtendedCommitInfo` was `VerifyVoteExtension`-passed at its origin height (currently violated for late-arrived precommits per #2361)
  - `VELiveness` (from round 1): consensus terminates even when ≤ f validators emit invalid VEs

**Priority**: Medium-High (round 1 already modeled the basic `InvalidVE` flow; this round adds the reuse/replay/late-commit dimensions and the structural ABCI-round-missing gap)
**Rationale**: 5 confirmed bugs (1 critical OPEN deadlock, 1 high-fixed sec advisory, 2 OPEN spec-deferred). The signed-bytes-vs-BlockID asymmetry is a real surface that wasn't exercised in round 1. Composition with 2.1 equivocation is novel.

---

### Family 4: Light-client Lunatic — Missing Header Self-Consistency (MEDIUM)

**Mechanism**: `light/verifier.go:VerifyAdjacent` only checks `ValidatorsHash == NextValidatorsHash` between the trusted and untrusted headers; it does **not** cross-check `LastBlockID`, `LastCommitHash`, `AppHash`, `NextValidatorsHash` against the trusted header. A Byzantine majority of the new validator set (whose voting power was committed to in the trusted header's `NextValidatorsHash`) can sign a header at H+1 with `LastBlockID` pointing to a different prior block — creating a fork that passes adjacency verification.

**Evidence**:
- Historical: #2252 OPEN — Josef Widder identified that `VerifyAdjacent` doesn't verify `untrustedHeader.LastBlockID == trustedHeader.Commit.BlockID`; calls `VerifyCommitLight` with untrusted BlockID as the "trusted" param → BlockID-vs-BlockID check always passes
- Historical: #1749 FIXED — `VerifyCommitLightTrusting` previously stopped counting sigs after 1/3, allowing fake sigs past the cutoff
- Historical: legacy tendermint#5200 — lunatic-validator evidence didn't account for commit's round (precursor design issue)
- Historical: ASA-2024-009 FIXED v0.38.12 — state-sync `ProposerPriority` not validated
- Historical: #1826/#2625 FIXED #1855 — nil pubkey panic in `verifyCommitSingle`
- Code analysis: `light/verifier.go:92-131 VerifyAdjacent` — only line 116 `ValidatorsHash` check; no LastBlockID cross-check
- Code analysis: `light/verifier.go:152-191 verifyNewHeaderAndVals` — only `untrustedVals.Hash() == ValidatorsHash` (line 182); no other header cross-checks
- Code analysis: `evidence/verify.go:124 VerifyLightClientAttack` lunatic branch uses `light.DefaultTrustLevel = 1/3` (intentional per ADR-047, but worth noting in model)

**Affected code paths**:
- `light/verifier.go:92-131 VerifyAdjacent`
- `light/verifier.go:30-78 VerifyNonAdjacent`
- `light/verifier.go:152-191 verifyNewHeaderAndVals`
- `types/validation.go:30-138 VerifyCommit` / `VerifyCommitLight`
- `evidence/verify.go:111-160 VerifyLightClientAttack`
- `evidence/verify.go:232-291 validateABCIEvidence` (PubKey.Address() check)

**Suggested modeling approach**:
- Variables: `chainHistory : Seq(Header)`, `lightClientTrusted : [Client -> Header]`, `forkBranches : SUBSET Seq(Header)`
- Actions:
  - `ByzLunaticForkHeader(s, h, fakeLastBlockID)` (BFT category **2.2** + **2.7**) — Byzantine ≥ 1/3 of `nextValidators(h-1)` (where 1/3 is per `DefaultTrustLevel`) signs a header at h with `LastBlockID = fakeLastBlockID ≠ chainHistory[h-1].Hash`. Place into directed bag toward light clients.
  - `LightClientVerify(c, h)` — light client receives header at h; runs `VerifyAdjacent` against `lightClientTrusted[c]`
  - `ByzCommitWithMixedValSet(s, h, fakeValSet)` — Byzantine signs commit with `untrustedVals` whose Hash matches header's `ValidatorsHash` but whose membership differs from `chainHistory[h-1].NextValidators`
- Granularity: explicit `VerifyAdjacent` action with all the checks decomposed
- Key invariants:
  - `LightClientFollowsCanonicalChain`: for every light client `c`, `lightClientTrusted[c]` is on the canonical chain (only fails if `≥ 1/3` of `nextValidators` are Byzantine, which IS the documented security boundary)
  - `LunaticEvidenceVerifies`: when a Byzantine ≥ 1/3 signs a lunatic header, `VerifyLightClientAttack` produces evidence with `ByzantineValidators` correctly identifying the signers

**Priority**: Medium
**Rationale**: Light-client safety is a real production concern (IBC, Cosmos relayers). Issue #2252 is OPEN and is exactly this surface. CometBFT's accountability documentation names lunatic as one of three primary attack classes; round 1 didn't model the light-client verifier.

---

### Family 5: Evidence-Lifecycle Adversarial Races (MEDIUM)

**Mechanism**: Five distinct Byzantine and architectural surfaces in the evidence pipeline:
1. Broadcast filter (`reactor.go:192` height-only) vs verification filter (`verify.go:313` height-AND-time) — honest sender can be banned by receiver at the window edge
2. `consensusBuffer` is purely in-memory and reset every `Update` — crash loses evidence; future-height votes unconditionally dropped
3. Pool has no in-memory cap — Byzantine can flood many distinct valid `DuplicateVoteEvidence` records
4. `ABCI Misbehavior` is application-defined slashing — CometBFT itself does nothing if app ignores it
5. Cross-validator dissemination has no acknowledgment — silent evidence loss if next proposer doesn't have it

**Evidence**:
- Historical: #4114 CLOSED — same `DuplicateVoteEvidence` committed in two consecutive blocks → blocksync permanently broken
- Historical: ASA-2024-004 — default `MaxAgeNumBlocks`/`MaxAgeDuration` may be < unbonding period
- Historical: #2942 wontfix — even with PBTS, 1/3+ cabal can delay commits arbitrarily → expiry attack surface remains
- Historical: #2353 — see Family 1; same evidence-loss mechanism
- Code analysis (**verified**): `evidence/reactor.go:192` filters by `peerHeight - evHeight > MaxAgeNumBlocks` only
- Code analysis (**verified**): `evidence/verify.go:313 IsEvidenceExpired` uses `ageDuration > MaxAgeDuration && ageNumBlocks > MaxAgeNumBlocks`
- Code analysis: `evidence/pool.go:49,538` — `consensusBuffer` in-memory, reset every Update
- Code analysis: `evidence/pool.go:502-509` — votes for height > LastBlockHeight unconditionally dropped
- Code analysis: `evidence/pool.go:297-316 addPendingEvidence` — no MaxNum check
- Code analysis: `state/execution.go:281-290 FinalizeBlock` — Misbehavior delegated to app, no CometBFT-side slashing

**Affected code paths**:
- `evidence/reactor.go:107-209 broadcastEvidenceRoutine` / `prepareEvidenceMessage`
- `evidence/verify.go:309-317 IsEvidenceExpired`
- `evidence/pool.go:172-188 ReportConflictingVotes` / `461-538 processConsensusBuffer`
- `evidence/pool.go:267-275 isExpired` / `405-436 removeExpiredPendingEvidence`
- `evidence/pool.go:194-232 CheckEvidence`
- `state/execution.go:114-181 CreateProposalBlock` (evidence pull)

**Suggested modeling approach**:
- Variables: `evidencePool : [Server -> SUBSET Evidence]`, `committedEvidence : SUBSET Evidence`, `gossipQueue : [(Server, Server) -> Seq(Evidence)]`, `validatorClock : [Server -> Time]`
- Actions:
  - `ByzInjectInvalidEvidence(s, ev)` (BFT category **2.8**) — Byzantine gossips evidence with bad sig or fake conflict; receivers verify via `evidence/verify.go` and call `StopPeerForError`
  - `ByzFloodEvidence(s, manyEv)` — Byzantine sends many valid `DuplicateVoteEvidence` records at distinct heights (all signed by some past Byzantine)
  - `ByzWithholdEvidence(s, ev)` — Byzantine refuses to gossip own pending evidence (implicit via honest-send guard)
  - `EvidenceExpiryRace(s1, s2, ev)` — `s1.validatorClock < s2.validatorClock`; `s1` thinks `ev` not expired (sender height-only), `s2` thinks expired (AND-with-time at receiver clock); `s1` broadcasts; `s2` punishes `s1`
  - `CrashDuringConsensusBuffer(s)` — Byzantine or honest crash between `ReportConflictingVotes` and `Update` loses the buffer
  - `ProposerExcludeEvidence(s, h, ev)` — at proposal of height `h`, proposer `s` (possibly Byzantine) does not include `ev` in block evidence list
- Granularity: split evidence lifecycle into Detect → Buffer → Flush → Pending → Gossip → Propose → Commit → Apply (slashing)
- Key invariants:
  - `EventualSlashing`: if Byzantine equivocates and ≥ 1 honest sees both votes, evidence is eventually included in some block within `min(MaxAgeNumBlocks, MaxAgeDuration / avgBlockTime)`
  - `HonestPeerNotPunished`: an honest sender broadcasting evidence per `reactor.go:192` filter is not banned by a correct receiver
  - `EvidenceConsistency`: if `ev` is committed in block `B`, no honest validator's pool retains `ev` as pending
  - `EvidencePoolBounded`: pool size is bounded above by a function of validator-set-size × MaxAgeNumBlocks (currently unbounded)

**Priority**: Medium
**Rationale**: The broadcast/verify expiry disagreement is a verified inconsistency in the current code. Equivocation slashing's correctness depends on this pipeline working end-to-end; multiple confirmed bugs (#4114, #2353, ASA-2024-004) and unfixed surfaces (#2942, the broadcast/verify mismatch) make this a strong modeling target.

---

### Family 6: Locking-vs-Relock Transitions under Byzantine Proposer Interleaving (MEDIUM)

**Mechanism**: `enterPrecommit`'s three inlined branches (relock / new-lock / unlock-and-nil) can be exercised in adversarial order by a Byzantine proposer who alternates between proposing block `B` and block `B'` at adjacent rounds, in combination with prevote messages that produce polkas. The unlock branch (state.go:1584-1602) doesn't have an explicit `polkaRound > LockedRound` check — it relies on the polka being for the *current* round, which is implicit semantics.

**Evidence**:
- Historical: legacy #1551 — miss to lock/commit on conflicting votes (design defect, unfixed)
- Historical: legacy #9251 — discussion of unlock-on-polka correctness
- Historical: ASA-2025-002 FIXED v0.38.17 — block-part proof index swap by Byzantine proposer; nodes re-gossip invalid part
- Historical: #1309 — Proposal with `POLRound == LockedRound` but different block (Cason: canonical sign of equivocation; only log added)
- Code analysis: `consensus/state.go:1484-1603 enterPrecommit` — 3 branches inlined, no explicit `polkaRound > LockedRound` guard on unlock
- Code analysis: `consensus/state.go:1535-1545` — unconditional lock clear on +2/3 prevotes nil
- Code analysis: `types/proposal.go:59-61` — `POLRound >= Round` passes `ValidateBasic`
- Code analysis: `consensus/state.go:2317-2333` — `addVote` unlock with `LockedRound < vote.Round <= cs.Round` guard (the explicit version)

**Affected code paths**:
- `consensus/state.go:1484-1603 enterPrecommit`
- `consensus/state.go:2317-2333 addVote` prevote handler (cross-round unlock)
- `consensus/state.go:1387-1444 defaultDoPrevote`
- `types/proposal.go:53-61 Proposal.ValidateBasic`

**Suggested modeling approach**:
- Variables: standard `lockedRound`, `lockedBlock`, `validRound`, `validBlock`; add `polkaSetByBlock : [H, R, BlockID] -> SUBSET Validator`
- Actions:
  - `ByzProposeAlternating(s, h, rEven, rOdd, blockA, blockB)` — Byzantine proposer offers `blockA` at even rounds and `blockB` at odd rounds; combine with Byzantine prevotes to force unlock/relock cycles
  - `ByzPolkaForUnknownBlock(s, h, r, blockX)` — Byzantine subset sends prevotes for `blockX` that the validator does not have, triggering the unlock-and-nil branch
  - `ByzPOLRoundGtRound(s, h, r)` — Byzantine proposer with `POLRound >= Round` (passes ValidateBasic per proposal.go:59-61); test whether `enterPrecommit` does the right thing
- Granularity: model all 3 `enterPrecommit` branches as separate actions
- Key invariants:
  - `LockSafety`: a locked validator only precommits its locked block unless it observed a polka in a round > LockedRound for a different block
  - `LockedNeverAcceptsNonProposalProposal`: in `defaultDoPrevote`, a locked validator prevotes nil for any proposal whose block differs from `lockedBlock`
  - `Round1ProposalValidation`: `POLRound < Round` (currently `POLRound >= Round` is accepted)
  - `Agreement` (standard): no two honest validators commit different blocks at the same height under f < n/3

**Priority**: Medium
**Rationale**: Locking is the core safety mechanism; 3 inlined branches × Byzantine proposer interleaving × Byzantine prevote subset is a high-state-space target. Round 1 modeled the paths but didn't compose with the Byzantine proposer alternating between blocks.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|---|---|---|
| `ByzEquivocate` action (BFT 2.1) | Family 1: round 1 explicitly missing; required to exercise `DetectEquivocation` | Byzantine adds two conflicting signed precommits at (h, r) for different BlockIDs to the message bag |
| `ByzSelectiveDisseminate` (BFT 2.4) | Family 1: confirmed evidence-loss vector (#2353) | Requires directed message bag; Byzantine sends voteA to partA, voteB to partB |
| `ByzAmnesia` × `Crash` × `WALTailTruncate` (BFT 2.6 × 5.1) | Family 2: WAL doesn't persist locking state; repairWalFile silently truncates | Per-validator persistent WAL var; truncate-tail action; recovery rebuilds `lockedRound` from the surviving prefix |
| `ByzAttachSameVEToBoth` + `ByzLateAddPrecommitWithBadVE` (BFT 2.5 + 2.1) | Family 3: VE bytes don't bind to BlockID; late LastCommit precommits unverified | Split precommit-with-extension; explicit VE verify action; LastCommit late-arrival path |
| `ByzLunaticForkHeader` (BFT 2.2 + 2.7) | Family 4: light-client `VerifyAdjacent` lacks LastBlockID cross-check (#2252) | Explicit light-client verify action; verify against trusted header |
| `EvidenceExpiryRace` + `CrashDuringConsensusBuffer` + `ByzInjectInvalidEvidence` (BFT 2.8) | Family 5: 5 verified surfaces in evidence pipeline | Per-validator clock; in-memory buffer var; split pipeline into Buffer → Pending → Gossip → Propose → Commit |
| `ByzProposeAlternating` + `ByzPolkaForUnknownBlock` (BFT 2.1 + 2.7 composition) | Family 6: 3 inlined branches × Byzantine proposer interleaving | Model all 3 enterPrecommit branches as separate actions; compose with alternating proposal action |
| `Faulty` as CONSTANT (static corruption) | Layer-1 default; no dynamic committees in CometBFT | `ASSUME 3 * Cardinality(Faulty) < Cardinality(Server)` |
| Per-category counters in MC.tla | Standard BFT pattern; bound TLC search budget | `MaxByzEquivocate`, `MaxByzAmnesia`, `MaxByzVEReuse`, `MaxByzLunatic`, `MaxByzEvidenceInject`, `MaxByzProposeAlternating` |

### 3.2 Do Not Model (with rationale)

| What | Why |
|---|---|
| Adaptive corruption (BFT 2.9) | CometBFT is static-corruption permissioned; PoS slashing punishes after the fact but the *protocol* model is static |
| Cryptographic signature forgery | Out of scope per Layer-1 default; honest sigs unforgeable |
| Block-part proof index swap (ASA-2025-002) detailed model | Implementation-level; the protocol consequence is captured by `ByzEquivocate` + `LockSafety` invariant |
| Mempool transaction ordering | Not in consensus safety scope (round-1 exclusion still applies) |
| PBTS timeliness (not in analyzed branch) | Carry over round-1 exclusion |
| ABCI Misbehavior application semantics | Slashing is application-defined; model as abstract "evidence applied" event |
| RPC / state-sync / blocksync paths | Round-1 exclusion; Family 4 LunaticForkHeader covers the lunatic surface at light client without full blocksync model |
| Gossip TOCTOU race details | Round-1 exclusion; model message delivery as nondeterministic |
| Metrics, logging, debug code | Code-review level (e.g., #1309's "only a log added") |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|---|---|---|---|
| Static Faulty subset | `Faulty ∈ SUBSET Server` (CONSTANT) | BFT environment, `f < n/3` | All BFT families |
| Conflicting precommit production | `precommitBag : SUBSET Vote` (already in round 1; ensure two conflicting votes by same `s ∈ Faulty` at (h, r) can coexist) | Family 1 equivocation |
| Directed message bag | `messages : SUBSET [sender, to: SUBSET Server, type, ...]` (replaces global bag) | Family 1 selective dissemination |
| Per-validator WAL persistence model | `walPersisted[s]`, `walPending[s]` | Family 2 amnesia |
| Privval last-sign state | `pvLastSign[s] : [h, r, step, blockID]` | Family 2 amnesia detection |
| WAL tail truncation | `WALTailTruncate(s, k)` action | Family 2 repairWalFile model |
| Vote extension binding | `voteExtension[s][h][r] : Bytes`, `extSigVerified[s] : SUBSET (h, r, validator)` | Family 3 VE reuse |
| Light-client trusted header | `lightClientTrusted[c] : Header` | Family 4 lunatic |
| Fork branches | `forkBranches : SUBSET Seq(Header)` | Family 4 lunatic |
| Per-validator clock | `validatorClock[s] : Nat` | Family 5 expiry race |
| Evidence pool | `pendingEvidence[s]`, `committedEvidence : SUBSET Evidence` | Family 5 evidence lifecycle |
| Consensus buffer | `consensusBuffer[s] : Seq(VotePair)` (volatile, lost on crash) | Family 5 consensusBuffer crash window |
| Three enterPrecommit branches | (no new vars; split action) | Family 6 locking transitions |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| `Agreement` | Safety | No two honest nodes commit different blocks at the same height under f < n/3 | All families |
| `ElectionSafety` | Safety | At most one block committed per height | All families |
| `LockSafety` | Safety | Locked honest validator only precommits its locked block unless polka in higher round for different block | Family 2, 6 |
| `EventualAccountability` | Eventual-Safety | If a Byzantine validator equivocates and ≥1 honest node sees both votes, evidence eventually applies (in some committed block) | Family 1, 5 |
| `PrivvalAmnesiaDetection` | Safety | Privval refuses to sign a precommit at (h, r2) for B' if it previously signed a precommit at (h, r1<r2) for B≠B' | Family 2 |
| `VEContextBound` | Safety | Every accepted VE has (H, R) matching its carrying vote envelope | Family 3 |
| `LastCommitVECoverage` | Safety | Every extension in `ExtendedCommitInfo` was VerifyVoteExtension-passed at its origin height | Family 3, #2361 |
| `VELiveness` | Liveness | Consensus terminates even when ≤ f validators emit invalid VEs | Family 3, #5204 |
| `LightClientFollowsCanonicalChain` | Safety | A light client's trusted header is always on the canonical chain unless ≥ 1/3 of nextValidators are Byzantine | Family 4, #2252 |
| `LunaticEvidenceVerifies` | Safety | LightClientAttackEvidence created from a lunatic fork correctly identifies the Byzantine signers | Family 4 |
| `HonestPeerNotPunished` | Safety | An honest sender broadcasting per reactor's filter is not banned by a correct receiver | Family 5 (broadcast/verify mismatch) |
| `EvidenceConsistency` | Safety | If `ev` is committed in block B, no honest validator retains `ev` as pending | Family 5 |
| `EvidencePoolBounded` | Safety | `|pendingEvidence[s]|` bounded by validator-set-size × MaxAgeNumBlocks | Family 5 (currently violated) |
| `Round1ProposalValidation` | Safety | Honest validator rejects proposal with `POLRound >= Round` | Family 6 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected violation | Family |
|---|---|---|---|
| MC-1 | Byzantine equivocates at (h, r); both votes reach ≥1 honest; evidence eventually committed | `EventualAccountability` should hold (under partial sync + f < n/3) | 1 |
| MC-2 | Byzantine selectively disseminates; no honest sees both votes | `EventualAccountability` violated when topology splits | 1, 5 |
| MC-3 | Byzantine amnesia: crash + WAL tail truncated + privval signs at (h, r2) for different block | `LockSafety` violated; `PrivvalAmnesiaDetection` violated | 2 |
| MC-4 | Same as MC-3 but composed with `ByzEquivocate` — Byzantine equivocates and *also* claims amnesia | Layered: `LockSafety` + `EventualAccountability` | 1, 2 |
| MC-5 | Byzantine attaches same VE signature to two conflicting precommits at (h, r) | `VEContextBound` holds (signature is over Extension, H, R) but composes with `ByzEquivocate` | 3 |
| MC-6 | Late precommit added to LastCommit; VE never `VerifyVoteExtension`-passed; reaches PrepareProposal at h+1 | `LastCommitVECoverage` violated | 3, #2361 |
| MC-7 | Byzantine ≥ 1/3 of `nextVals(h)` sign header at h+1 with `LastBlockID ≠ trustedHeader.Hash` | `VerifyAdjacent` accepts (no LastBlockID check) → `LightClientFollowsCanonicalChain` violated | 4, #2252 |
| MC-8 | Sender clock at edge: ageDuration > MaxAgeDuration but ageNumBlocks ≤ MaxAgeNumBlocks | Sender broadcasts, receiver rejects + `StopPeerForError` → `HonestPeerNotPunished` violated | 5 |
| MC-9 | Crash between `ReportConflictingVotes` and `Update` → consensusBuffer lost | If only one honest sees, evidence is lost — `EventualAccountability` violated | 2, 5 |
| MC-10 | Byzantine proposes blockA at round R, blockB at round R+1; combined with Byzantine prevotes | All 3 enterPrecommit branches exercised; `LockSafety` must hold | 6 |
| MC-11 | Byzantine proposer with `POLRound >= Round` (passes ValidateBasic) | `Round1ProposalValidation`: violated by current ValidateBasic; check whether enterPrecommit recovers | 6 |
| MC-12 | Byzantine floods evidence pool with N distinct valid `DuplicateVoteEvidence` records | `EvidencePoolBounded` violated (pool is currently unbounded) | 5 |
| MC-13 | Combined: `ByzEquivocate` + selective dissemination + WALTailTruncate on detector | Worst-case detection-evasion | 1, 2, 5 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| TV-1 | `DoubleSignCheckHeight=1` performs 0 iterations (#5435) | Unit test: configure DoubleSignCheckHeight=1, sign a precommit, restart, verify no double-sign check runs |
| TV-2 | `processConsensusBuffer` drops votes for height > LastBlockHeight unconditionally (pool.go:502-509) | Unit test: feed a conflict-vote-pair for height H+1 while state is at H; verify buffer is cleared without producing evidence |
| TV-3 | VE signature stays valid when only Extension bytes change but (H, R, ChainID) same | Unit test: sign VE for (h, r, ext1); construct vote with ext2 same bytes but different precommit BlockID; verify signature check |
| TV-4 | Light-client `VerifyAdjacent` accepts header with mismatched `LastBlockID` (#2252) | Unit test: create trusted at h, untrusted at h+1 with same NextValidators but different LastBlockID; verify accepts |
| TV-5 | Evidence broadcast: peer's local time-expired evidence accepted from sender's height-not-expired filter | Integration test: two validators with skewed clocks; verify expiry-race punishment |
| TV-6 | Pool unbounded growth: addPendingEvidence has no cap | Integration test: feed N distinct `DuplicateVoteEvidence` records; observe pool growth and per-block iteration cost |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR-1 | `repairWalFile` silently truncates tail at first decode error (state.go:2675-2708) | Discuss with maintainers: should it attempt resync past the corruption point? Or fail-fast and require manual recovery? |
| CR-2 | `ABCI VerifyVoteExtension` doesn't deliver Round to app (proto/tendermint/abci/types.proto:196-203) | Spec discussion: should ABCI++ include Round? Currently apps cannot enforce round-binding semantics |
| CR-3 | `consensusBuffer` for evidence is in-memory only and reset every Update (pool.go:49,538) | Discuss: should buffer be persisted, or should the reset be conditional on successful flush? |
| CR-4 | `evidence/reactor.go:192` filter (height-only) vs `verify.go:313` filter (height-AND-time) | Make filters consistent or document the intentional asymmetry |
| CR-5 | Evidence pool has no in-memory cap (pool.go:297-316) | Add per-validator-per-height cap on pending evidence; bound pool size |
| CR-6 | Lunatic evidence trust level 1/3 (verify.go:124 `DefaultTrustLevel`) — intentional per ADR-047 | Document inline; ensure modeling reflects the design choice |
| CR-7 | `POLRound >= Round` passes `Proposal.ValidateBasic` (proposal.go:59-61) | Add `POLRound < Round` check OR document that enterPrecommit is the gate |
| CR-8 | `enterPrecommit` unlock-and-nil branch (state.go:1584-1602) lacks explicit `polkaRound > LockedRound` check | Discuss whether the implicit "polka is for current round" is robust against Byzantine round-skip |

## 7. Reference Pointers

- **Full analysis report**: `/home/ubuntu/Specula/case-studies/cometbft_2/.specula-output/analysis-report.md`
- **Round 1 brief**: `/home/ubuntu/Specula/case-studies/cometbft/modeling-brief.md`
- **Key source files**:
  - `artifact/cometbft/consensus/state.go` (2709 lines) — state machine, `enterPrecommit` 3 branches at 1484-1603; `repairWalFile` at 2675-2708; `signVote`/`writeInternalMsgToWAL` at 2422-2470 / 881-905
  - `artifact/cometbft/consensus/replay.go` (563 lines) — `catchupReplay` at 94-166
  - `artifact/cometbft/consensus/wal.go` (435 lines) — Write vs WriteSync at 185-219; WALDecoder at 367-421
  - `artifact/cometbft/types/vote_set.go` (725 lines) — conflict detection at 218-238; `MakeExtendedCommit` at 631-672
  - `artifact/cometbft/types/canonical.go` (87 lines) — `CanonicalizeVoteExtension` at 71-78 (no BlockID)
  - `artifact/cometbft/types/validation.go` — `VerifyCommit*` family
  - `artifact/cometbft/types/evidence.go` (645 lines) — DuplicateVoteEvidence, LightClientAttackEvidence
  - `artifact/cometbft/evidence/pool.go` (575 lines) — pool lifecycle; in-memory buffer at 49; broadcast filter wires
  - `artifact/cometbft/evidence/verify.go` (317 lines) — VerifyDuplicateVote/LightClientAttack; `IsEvidenceExpired` AND-of-both at 313
  - `artifact/cometbft/evidence/reactor.go` — broadcast routine; filter at 192
  - `artifact/cometbft/light/verifier.go` — `VerifyAdjacent` at 92-131 (no LastBlockID cross-check)
  - `artifact/cometbft/state/execution.go` (822 lines) — `BuildExtendedCommitInfo` at 609-665; `CreateProposalBlock` at 114-181
  - `artifact/cometbft/privval/file.go` (~470 lines) — `CheckHRS` at 100-131
- **GitHub issues (CometBFT)**: #5204, #5435, #4114, #3570, #2523, #2361, #2353, #2252, #1917, #1857, #1830, #1749, #1309, #1253
- **GitHub issues (Tendermint legacy)**: #8739, #5200, #1551
- **Security advisories**: ASA-2024-001 (VE param), ASA-2024-004 (evidence params), ASA-2024-009 (state-sync prop priority), ASA-2024-011 (VE ValidatorIndex), ASA-2025-002 (block-part proof index), CSA-2026-001 "Tachyon" (BFT-Time)
- **Reference algorithm**: Tendermint BFT (Buchman, Kwon, Milosevic 2018, arXiv:1807.04938); Cason, Milosevic 2022 (fork accountability, ADR-047)
- **BFT methodology**: `references/bft-analysis.md` (9 Byzantine action categories) + `references/distributed-analysis.md` (6 fault families)
