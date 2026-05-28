# Modeling Brief: cometbft/cometbft (Round 3 — Sync-Boundary, Reactor-Freshness, Verification-Determinism)

## 1. System Overview

- **System**: CometBFT (fork of Tendermint) — Go BFT consensus engine. Round 3 expands scope to **sync-mode boundaries** (BlockSync / StateSync trust model, BlockSync→Consensus handoff) and **reactor freshness** post-PR #5411 architectural change. Rounds 1-2 covered consensus-mode safety/liveness and Byzantine adversary actions in consensus mode.
- **Language**: Go, ~16k LOC consensus core, ~3k LOC blocksync+statesync, ~12k LOC supporting types/state/evidence/light.
- **System category**: **Category A (Distributed / Message-Passing) with BFT overlay**. Safety/liveness depends on tolerating ≤ *f* deviating validators per `n ≥ 3f+1`. Apply both `distributed-analysis.md` (6 fault families) and `bft-analysis.md` (9 Byzantine action categories). Layer-1 environment: **static corruption + partial synchrony + authenticated + f < n/3**. Round 3 adds an **untrusted-peer-channel** dimension: nodes in BlockSync/StateSync receive bulk state from peers who are NOT bound by validator-set authentication; trust is anchored only in (a) light-client trust hash, (b) `VerifyCommit` chain.
- **Protocol**: Tendermint BFT (PBFT-family) with ABCI++ vote extensions; PBTS; evidence pool with `DuplicateVoteEvidence` + `LightClientAttackEvidence`; light-client verifier; **BlockSync mode** (`blocksync/pool.go`+`reactor.go`); **StateSync mode** (`statesync/syncer.go`+`reactor.go`).
- **Architectural changes relevant to round 3**:
  - **PR #5411 (Sept 2025 backport)** removed the `updateRoundStateRoutine` polling goroutine. Reactor's `conR.rs` is now refreshed ONLY on three events (`EventNewRoundStep`, `EventValidBlock`, `EventVote`) in `consensus/reactor.go:431-481`. `EventVote` listener broadcasts BEFORE updating `conR.rs` (lines 469 vs 475-476). `EventCompleteProposal` is NOT subscribed.
  - **ASA-2025-001 fix** (`blocksync/pool.go:413-428`): peer reporting decreased base/height is banned. But `bannedPeers` TTL is hard-coded 60s (`pool.go:513`), volatile across restart.
  - **#5629 fix** (Feb 2026): blocksync's `ExtendedCommit` is now cryptographically tied to the next block's `LastCommit` via light-client commit verification. The trust anchor for blocksync is therefore the `VerifyCommit` chain.
  - **#5613 fix** (Feb 2026): `ProposerPriorityHash` correctly advances buffer offset per validator. Used by light-client divergence detector at `light/detector.go:212`.
  - **#5570** (Sept 2025) added `TotalVotingPowerSafe` but production paths still call panicking `TotalVotingPower()` in 5+ sites (`consensus/state.go:1856, 2298, 2590, 2621, 2644`).
  - **#4977 fix** (Feb 2025): on statesync **failure**, must handshake with ABCI app before falling back to blocksync. **Does not cover statesync success + crash window between `Bootstrap` and `SaveSeenCommit`**.
- **Round-1/2 carry-forward**: keep `Crash`, `LoseMessage`, `Timeout`, BFT actions (Equivocation, Amnesia, VEReuse, LunaticForkHeader, EvidenceLifecycle, LockingTransitions). Round 3 ADDS sync-boundary, reactor-freshness, and verification-determinism families.

## 2. Bug Families

### Family 1: BlockSync Peer-Trust Boundary (HIGH)

**Mechanism**: The blocksync pool admits peer-reported `(base, height)` after only structural checks; cryptographic trust is established only LATER, when the next block's `LastCommit` arrives and verifies against the previously-fetched block's `Hash`. Byzantine peers can manipulate the pool's height accounting, the requester→peer assignment, and the order of block delivery to (a) stall catch-up, (b) cause honest peers to be banned as collateral, or (c) force a node-bricking transient app failure path.

**Evidence**:
- Historical: ASA-2025-001 / GHSA-22qq-3xwm-r5x4 FIXED — peer reporting lower height/base is banned (`pool.go:413-428`); #5801 OPEN claims the fix is incomplete (advertise high `base` to be skipped while poisoning `maxPeerHeight`)
- Historical: #5135 OPEN — empty-block runs cause peer kick due to byte-rate threshold (`pool.go:161-169`); affects Provenance mainnet quicksync
- Historical: #3398 OPEN — mempool floods catching-up node; `EnableInOutTxs` runs before `SwitchToConsensus`
- Historical: #5629 (PR merged Feb 2026) — blocksync now cryptographically verifies `ExtendedCommit` via next block's `LastCommit`; pre-fix Byzantine peer could feed forged extended commits
- Historical: #5592 (OPEN PR) — `redoCh` cap-1 silently drops concurrent redos for second peer
- Code analysis (verified): `pool.go:487-501 updateMaxPeerHeight` excludes peers with `base > pool.height` only when `pool.height > 0` — non-monotonic in `pool.height` at startup
- Code analysis (verified): `pool.go:732-753 setBlock` first-writer-wins — if a Byzantine peer delivers a malformed block first, the second peer's correct block is silently discarded
- Code analysis (verified): `pool.go:715, 822-825` redoCh cap-1 with non-blocking write; second redo silently dropped
- Code analysis (verified): `consensus/reactor.go:121-157 SwitchToConsensus` releases `cs.mtx` before `waitSync.Store(false)`; `StateChannel` is processed unguarded during the window (Receive at line 273-327 enters StateChannel case without WaitSync check)

**Affected code paths**:
- `blocksync/pool.go:397-445 SetPeerRange`, `pool.go:487-501 updateMaxPeerHeight`, `pool.go:524-547 pickIncrAvailablePeer`, `pool.go:732-753 setBlock`, `pool.go:715/822-825 redo`, `pool.go:511-513 isPeerBanned` (60s TTL, volatile)
- `blocksync/reactor.go` poolRoutine → `VerifyCommit` against next block's `LastCommit` (the trust anchor)
- `consensus/reactor.go:121-157 SwitchToConsensus`, `:273-327 Receive StateChannel`

**Suggested modeling approach**:
- Variables:
  - `peerClaims : [Server -> [Peer -> (base, height)]]` — peer-reported ranges
  - `poolHeight : [Server -> Nat]` — local fetch progress
  - `maxPeerHeight : [Server -> Nat]` — computed from peerClaims via the `updateMaxPeerHeight` predicate
  - `delivered : [Server -> [Height -> SetOf Block]]` — blocks delivered to requester from any peer
  - `firstDelivered : [Server -> [Height -> Block]]` — winner of first-writer-wins
  - `banned : [Server -> SUBSET Peer]` — local ban list (volatile per F1.3)
  - `redoBacklog : [Server -> [Requester -> Maybe Peer]]` — cap-1 channel
  - `waitSync : [Server -> BOOLEAN]`, `consensusStarted : [Server -> BOOLEAN]`
- Actions:
  - `ByzPeerAdvertiseRange(p, s, base, height)` (BFT 2.2 invalid content fabrication × non-validator peer) — Byzantine peer reports arbitrary `(base, height)` to honest server `s`; the SetPeerRange predicate determines acceptance
  - `ByzPeerDeliverBlock(p, s, h, block)` — peer delivers a block (correct or malformed) for height h
  - `ByzPeerDeliverFirstWrong(p1, p2, s, h, badBlock, goodBlock)` — composition: peer p1 delivers badBlock first, peer p2 delivers goodBlock second; verify the setBlock first-writer-wins discards goodBlock
  - `RedoCoalesce(s, requester, peerA, peerB)` — redo for peerA already pending; redo for peerB silently dropped
  - `SwitchToConsensusWindow(s)` — between `cs.mtx` release and `waitSync.Store(false)`, an honest peer's `VoteSetMaj23` arrives and mutates `votes` via the alias chain
  - `MempoolEnableBeforeConsensus(s)` — composes with #3398: mempool active while consensus not started
- Granularity: 
  - SetPeerRange = single atomic transition (predicate-rich)
  - block delivery = separate action per peer per height; first-writer = state predicate captured at delivery time
  - SwitchToConsensus = split into `ReleaseCSMtx`, `ClearWaitSync`, `StartConsensus`; allow peer messages in between
- Key invariants:
  - `MaxPeerHeightMonotone`: if all peers honest, `maxPeerHeight` is non-decreasing in time (CURRENTLY VIOLABLE via F1.2 with Byzantine high-base peers)
  - `HonestPeerNotPunishedForCorrectBlock`: a peer that delivers the canonical block for height h is not banned even if a different peer delivered a wrong block first (CURRENTLY VIOLABLE via F1.4 collateral)
  - `NoConsensusBeforeSwitchComplete`: while `waitSync == true`, no state-mutating peer message can reach consensus's `Votes` table (CURRENTLY VIOLABLE via F1.7 StateChannel unguarded path)

**Priority**: High
**Rationale**: BlockSync was deliberately excluded from rounds 1 & 2. ASA-2025-001 (Feb 2025) and #5629 (Feb 2026) prove the area is recently bug-rich. #5801 is OPEN and disputed but the maintainer's mitigation (F1.2) is verifiably non-monotonic. The first-writer-wins gap (F1.4) and the SwitchToConsensus window (F1.7) are both forward-looking and not directly covered by the #5629 anchor — that anchor protects block contents, not pool-state manipulation.

---

### Family 2: StateSync Trust Boundary (HIGH)

**Mechanism**: StateSync transfers bulk state from peers via snapshots and chunks. The trust anchor is the configured `TrustHash` (light-client). However, **`snapshot.Hash` is never cryptographically verified by CometBFT**; per-chunk integrity is delegated to the ABCI application; and the persistence sequence (`Bootstrap → SaveSeenCommit → enable`) is not atomic across crashes.

**Evidence**:
- Historical: #4977 FIXED Feb 2025 — on statesync **failure**, must run ABCI handshake before falling back to blocksync. Does NOT cover statesync success + mid-persistence crash.
- Historical: ASA-2024-009 FIXED — state-sync `ProposerPriority` not validated (covered round 1-2 reference).
- Code analysis (verified): `statesync/syncer.go:262-271, 335, 504` — `snapshot.trustedAppHash` from light-client is verified against `resp.LastBlockAppHash` post-apply, but `snapshot.Hash` itself appears only in logs, `OfferSnapshot`, and pool dedup `Key()`.
- Code analysis (verified): `statesync/chunks.go:63-101 chunkQueue.Add` — chunks accepted bytes-verbatim; no Merkle proof; integrity = ABCI app's `RejectSenders`/`RefetchChunks` response.
- Code analysis (verified): `node/setup.go:617-649 performStateSync` — `Bootstrap → SaveSeenCommit → Enable` sequence is non-atomic; crash between (2) and (3) leaves persisted `state.LastBlockHeight=H` with no `seenCommit` at H.
- Code analysis (verified): `node/node.go:432-463` — `stateStore.SetOfflineStateSyncHeight(0)` at line 460-463 clears the marker BEFORE statesync runs. Crash before Bootstrap → restart sees blockStore.Height==0 and no marker → blocksync from genesis.
- Code analysis (verified): `syncer.go:308, 314` — `ApplySnapshotChunk` mutates app state before `verifyApp` runs; if `verifyApp` fails, the app already has restored state but CometBFT has no rollback signal to send.
- Code analysis (verified): `statesync/snapshots.go:88` `recentSnapshots=10` per peer; no global cap; Byzantine flood inflates pool to O(Npeers × 10) and forces O(N log N) Ranked() per SyncAny iteration.

**Affected code paths**:
- `statesync/syncer.go:115-241 SyncAny`, `:246-323 Sync`, `:308-314 chunks-apply-then-verify`, `:490-521 verifyApp`
- `statesync/chunks.go:63-101 chunkQueue.Add`, `:147-170 Discard*`
- `statesync/snapshots.go:75-118 snapshotPool.Add`, `:158-187 Ranked`
- `node/node.go:368-463 maybeStateSync`, `node/setup.go:604-648 performStateSync`

**Suggested modeling approach**:
- Variables:
  - `snapshotPool : [Server -> SUBSET Snapshot]` — accepted snapshots
  - `trustedAppHash : [Server -> Hash]` — light-client-anchored
  - `appliedChunks : [Server -> [Snapshot -> Seq(Bytes)]]` — fed to app
  - `appState : [Server -> Hash]` — abstract ABCI state digest
  - `bootstrapped : [Server -> {NONE, STATE_ONLY, FULL}]` — persistence stage
  - `offlineMarkerCleared : [Server -> BOOLEAN]`
- Actions:
  - `ByzOfferBogusSnapshot(p, s, height, fakeHash, chunks)` (BFT 2.2) — Byzantine peer offers a snapshot with valid `height` (matching trust window) but arbitrary `fakeHash`/`chunks`. SyncAny tries; light-client succeeds; `OfferSnapshot` is sent to app with `fakeHash`.
  - `ByzCorruptChunk(p, s, snap, idx, bytes)` (BFT 2.2) — Byzantine peer delivers corrupted chunk bytes; CometBFT does not detect; app may.
  - `ByzWithholdChunk(p, s, snap, idx)` (BFT 2.3 omission)
  - `ByzSpamSnapshotPool(p, s)` — flood `recentSnapshots × Npeers` entries
  - `CrashBetweenBootstrapAndSeenCommit(s)` — crash between persistence steps; restart sees inconsistent (state, blockStore)
  - `CrashBetweenOfflineMarkerClearAndBootstrap(s)` — crash after marker clear; restart sees blockStore=0 and no marker
  - `VerifyAppFailsAfterChunksApplied(s, snap)` — chunks applied but `verifyApp` fails; app state is divergent until restart-time handshake
- Granularity:
  - Snapshot acceptance = one atomic predicate
  - Chunk apply = per-chunk action
  - Persistence sequence = split into 3 named actions (Bootstrap, SaveSeenCommit, Enable) with crash injection between each
- Key invariants:
  - `SnapshotIntegrityAnchored`: every accepted snapshot's content must be tied to the trusted `AppHash`, either by CometBFT verification OR by app-layer rejection of bad chunks
  - `PersistenceAtomicity`: after a crash anywhere in the statesync goroutine, on restart the persisted (state, blockStore, offline marker) tuple is either the genesis tuple or a fully consistent (state@H, commit@H, marker=∅) tuple
  - `AppCometStateConsistency`: after Sync returns and post-restart, `appState.LastBlockHeight == cometState.LastBlockHeight`
  - `NoDoSViaSnapshotFlood`: pool size bounded by a function of validator-set-size, not peer count

**Priority**: High
**Rationale**: StateSync was deliberately out of scope in rounds 1-2. The #4977 fix is partial (covers failure path, not success-crash). The `snapshot.Hash` non-verification is a real trust gap; the spec contract "CometBFT trusts ABCI to verify per-chunk integrity" should be made explicit and the failure-modes-under-malicious-app analyzed.

---

### Family 3: Reactor Round-State Freshness Post-Polling-Removal (MEDIUM-HIGH)

**Mechanism**: PR #5411 (Sept 2025 backport) removed the 100µs polling routine that refreshed `conR.rs` from `cs.GetRoundState()`. `conR.rs` is now refreshed event-only on three event types. The `EventVote` listener broadcasts `HasVote` BEFORE updating `conR.rs`. `EventCompleteProposal` is not subscribed. Gossip routines and `Receive` handlers read `conR.rs` and can see stale snapshots — opening a class of Byzantine-peer-driven gossip-starvation attacks and a state-mutation alias path.

**Evidence**:
- Historical: PR #5411 backport (Sept 2025) — the architectural change; CHANGELOG documents intent ("our view may be stale → get the updated round state")
- Historical: #5813 OPEN PR — `handleMsg` sends to `statsMsgQueue` while holding `cs.mtx`; 1000-slot buffer fills under load and stalls the consensus state machine (composes with reactor freshness)
- Historical: Oct 2025 commit `25dee2b05` added bitarray validation to NewValidBlock/ProposalPOL/VoteSetBits — pre-fix these messages could carry malformed bitmaps that affected peer-state bitmap tracking
- Historical: #5324 FIXED — reject oversized proposals (the `Receive` handler at consensus/reactor.go:335-345 now calls `ValidateBlockSize` against current `maxBytes`)
- Code analysis (verified): `consensus/reactor.go:431-481 subscribeToBroadcastEvents` — only NewRoundStep, ValidBlock, Vote, NewConsensusParams subscribed; no CompleteProposal
- Code analysis (verified): `consensus/reactor.go:465-481 EventVote` listener — `broadcastHasVoteMessage` at line 469 runs BEFORE `updateRoundState(&rs)` at lines 475-476
- Code analysis (verified): `consensus/reactor.go:289-324 VoteSetMaj23` handler — `rs := conR.getRoundState()` value-copy; `rs.Votes` is `*HeightVoteSet`; mutation via `votes.SetPeerMaj23(...)` writes through the alias to the live consensus `Votes` table, bypassing `cs.mtx`
- Code analysis (verified): `consensus/reactor.go:1599-1609 ApplyHasVoteMessage` — blindly trusts peer's HasVote claim
- Code analysis (verified): `consensus/reactor.go:1566-1580 ApplyNewValidBlockMessage` — `ps.PRS.ProposalBlockParts = msg.BlockParts` direct assignment from peer
- Code analysis (verified): `consensus/reactor.go:1611-1630 ApplyVoteSetBitsMessage` — `votes.Update(msg.Votes)` at line 1623 when `ourVotes == nil` (mismatched-height branch)

**Affected code paths**:
- `consensus/reactor.go:431-481 subscribeToBroadcastEvents`, `:504-509 updateRoundState`, `:602-606 getRoundState`
- `consensus/reactor.go:289-324 VoteSetMaj23 handler`, `:362-368 VoteMessage handler`, `:381-413 VoteSetBitsMessage handler`
- `consensus/reactor.go:617-704 gossipDataRoutine / gossipVotesRoutine / queryMaj23Routine`
- `consensus/reactor.go:1152-1175 SetHasProposal`, `:1566-1580 ApplyNewValidBlockMessage`, `:1599-1609 ApplyHasVoteMessage`, `:1611-1630 ApplyVoteSetBitsMessage`

**Suggested modeling approach**:
- Variables:
  - `cachedRS : [Server -> RoundState]` — `conR.rs` snapshot
  - `liveRS : [Server -> RoundState]` — `cs.GetRoundState()`
  - `peerKnowsVote : [Server -> [Peer -> SUBSET (h, r, type, idx)]]` — `ps.PRS.Prevotes`/`Precommits` bitmaps
  - `peerKnowsBlockPart : [Server -> [Peer -> SUBSET (h, r, partIdx)]]`
  - `peerKnowsProposal : [Server -> [Peer -> SUBSET (h, r)]]`
- Actions:
  - `EmitEventVote(s, vote)` — splits into (a) `BroadcastHasVote(s, vote, all_peers)`, then non-atomically (b) `UpdateCachedRS(s, newRS)`. Allow peer-Receive-VoteMessage between (a) and (b).
  - `ByzClaimHasVote(p, s, h, r, type, idx)` (BFT 2.5 stale-context misuse) — Byzantine peer sends `HasVoteMessage{Index=i}` for an index they don't actually have; the honest server marks `peerKnowsVote[s][p]` accordingly; the gossip routine then never sends vote `i` to peer `p` even when needed.
  - `ByzClaimHasAllBlockParts(p, s, h, r)` — Byzantine peer sends `NewValidBlockMessage` with all-ones BlockParts; honest server never gossips block parts to that peer.
  - `ByzVoteSetBitsCrossHeight(p, s, oldH, r)` — Byzantine peer sends a `VoteSetBitsMessage` for a height < cachedRS.Height; the mismatched-height branch unconditionally overwrites `peerKnowsVote[s][p]`.
  - `ByzVoteSetMaj23(p, s, h, r, type, blockID)` — Byzantine sets peer's claimed maj23; the aliased pointer write to `votes` mutates live consensus state without `cs.mtx`.
- Granularity: split each Receive handler into a "read cached state" + "mutate peer state" + "side-effect on consensus Votes" action. Allow state-machine progression to interleave between read and mutate.
- Key invariants:
  - `BroadcastBeforeStateUpdate ⇒ ConsumerSeesNewState`: when an honest peer reacts to `HasVoteMessage`, the originator's `cachedRS` already reflects the vote (CURRENTLY VIOLABLE in `EventVote` listener due to ordering)
  - `PeerKnowledgeWellFounded`: `peerKnowsVote[s][p][v]` implies the peer has actually sent us `v` or has seen `s` send it (CURRENTLY VIOLABLE via F3.4-F3.6 Byzantine lies)
  - `VotesTableMutatedOnlyByMainLoop`: `cs.Votes` is written only by the consensus main loop under `cs.mtx` (CURRENTLY VIOLABLE via F3.3 alias path through `VoteSetMaj23` handler)
  - `EventualGossipDelivery` (liveness): if honest server `s` has vote `v` and honest peer `p` does not, then eventually `s` sends `v` to `p` — bounded by stale-cache windows (CURRENTLY violable if Byzantine peer sets `peerKnowsVote[s][p][v] = true` via `HasVoteMessage` lie)

**Priority**: Medium-High
**Rationale**: The polling-removal architectural change (Sept 2025) is recent and the freshness contracts have not been re-audited. Byzantine `HasVoteMessage` / `NewValidBlockMessage` lying is a strong forward-looking gossip-starvation vector that does not require any validator-set membership. The `VoteSetMaj23` alias path is a verified mutation of consensus state outside `cs.mtx`.

---

### Family 4: Verification & Voting-Power Arithmetic Determinism (MEDIUM)

**Mechanism**: Voting-power arithmetic and commit-verification paths have several determinism / safety gaps: panicking unsafe variants in production paths, an early-exit in `VerifyCommitLightTrusting` that skips ~2/3 of signatures, silent saturation in proposer-priority arithmetic, and ordering ambiguity in `ProposerPriorityHash`. Most surface in the **light-client** trust chain that statesync and IBC depend on.

**Evidence**:
- Historical: #5609 / #5613 FIXED Feb 2026 — `ProposerPriorityHash` buffer-offset bug (different sets → same hash); used by light-client divergence detector at `light/detector.go:212`. Reference only.
- Historical: #5570 MERGED Sept 2025 — added `TotalVotingPowerSafe` to return error instead of panicking, but **production paths NOT migrated**.
- Historical: #1750 fixed (in `VerifyCommitLight*AllSignatures` variants only); the default-cached `VerifyCommitLightTrusting` still exits early at trust threshold.
- Historical: #3984 — light: cross-check proposer priorities in retrieved validator sets.
- Code analysis (verified by grep): `TotalVotingPower()` (panicking) called at `consensus/state.go:1856, 2298, 2590, 2621, 2644`, `blocksync/reactor.go:453`, `light/detector.go:429-433`, `types/vote_set.go:308`, `types/evidence.go:75`, `types/validation.go:40, 121, 216`. `TotalVotingPowerSafe()` called only at `types/validator_set.go:999` and tests.
- Code analysis (verified): `types/validation.go:148-194` — `VerifyCommitLightTrusting` (default) and `*WithCache` pass `countAllSignatures=false`; only `*AllSignatures` passes true.
- Code analysis (verified): `types/validation.go:196-239 verifyCommitLightTrustingInternal` — does NOT call `verifyBasicValsAndCommit`. `len(commit.Signatures)` is unbounded.
- Code analysis (verified): `types/validator_set.go:181-193 incrementProposerPriority` uses `safeAddClip`/`safeSubClip` — silent saturation.
- Code analysis (verified): `types/validator_set.go:400-412 ProposerPriorityHash` — comment requires sorted set; not enforced inside function.

**Affected code paths**:
- `types/validator_set.go:181-193 incrementProposerPriority`, `:354-361 TotalVotingPower (panicking)`, `:341-345 TotalVotingPowerSafe`, `:400-412 ProposerPriorityHash`
- `types/validation.go:140-194 VerifyCommitLightTrusting*` family, `:196-239 verifyCommitLightTrustingInternal`, `:291-321 verifyCommitBatch`, `:431-438 verifyCommitSingle` (notes `ValidateBasic` asymmetry)
- `light/detector.go:212 ProposerPriorityHash` cross-check, `:429-433 TotalVotingPower` call

**Suggested modeling approach**:
- Variables (small extension):
  - `commit : [H -> Commit]` with `commit.Signatures = Seq(CommitSig)` where some indices may be `forged`
  - `forgedSig : SUBSET (H, Index)` — Byzantine-forged signatures
  - `trustLevelNumer`, `trustLevelDenom : Nat`
  - `lightTrusted : [Client -> Header]`
  - `valPriorities : [Server -> [Validator -> Int64]]` — with explicit `Int64` semantics including saturation
- Actions:
  - `ByzCommitWithLateForgeries(p, c, h, validPrefix, forgedSuffix)` (BFT 2.7 certificate manipulation) — Byzantine ≥ 1/3 valid signatures at the start of the commit; rest forged. Light client `VerifyCommitLightTrusting` exits at trust threshold and accepts.
  - `LightClientVerify(c, h)` — split into `VerifyCommit_Strict` (countAllSignatures) and `VerifyCommit_TrustingEarly` (early-exit). Compose with `ByzCommitWithLateForgeries` to expose F4.2.
  - `ByzCommitFlood(p, c, h)` — `len(commit.Signatures)` arbitrarily large (no validation gate in trusting path); verifier consumes O(n) work.
  - `ByzValidatorSetCmtproto(p, s)` — Byzantine peer feeds a `cmtproto.ValidatorSet` whose summed voting power overflows `Int64`. Path: if reaches a panicking `TotalVotingPower()` call site (e.g., during light-block verification at the detector path, or during evidence ingestion at `types/evidence.go:75`), node panics.
  - `IncrementProposerPriority_Clipping(s)` — long-running chain reaches the saturation boundary; some validators stick at `MinInt64`/`MaxInt64`; proposer-rotation fairness violated.
- Granularity: split commit verification into `VerifyCommitEarlyExit` and `VerifyCommitAllSignatures` as separate actions; bind to the appropriate caller path via the trust-level parameter.
- Key invariants:
  - `LightClientCommitSoundness`: if `VerifyCommit*` (any variant) accepts a commit `c` at height `h`, then **for the variant's trust threshold**, an honest majority of that threshold's signers actually signed (CURRENTLY VIOLABLE for `VerifyCommitLightTrusting` w.r.t. the 2/3+ majority claim because only trust-fraction is checked)
  - `NoUnauthenticatedPanic`: no peer-supplied `cmtproto.ValidatorSet` reaching the consensus state machine, blocksync reactor, or light-client detector causes an `int64` overflow panic in `TotalVotingPower()` (CURRENTLY VIOLABLE per F4.1)
  - `ProposerPriorityHashIdentityImpliesEqualSets`: if two ValidatorSets produce equal `ProposerPriorityHash` AND equal `Hash`, then the sets are point-wise equal (sorted-set semantics; needed for light-client divergence detection to be sound) — model-checkable as a function-equality check
  - `ProposerFairness`: if all validators have voting power ≥ ε, then over an unbounded horizon, every validator is selected proposer infinitely often (CURRENTLY VIOLABLE if priorities saturate at `MinInt64`)

**Priority**: Medium
**Rationale**: The unfixed-in-production migration of `TotalVotingPower` → `TotalVotingPowerSafe` (F4.1) is a verified DoS surface. The `VerifyCommitLightTrusting` early-exit (F4.2) is a real safety surface for light-client / IBC users; though "trust 1/3" is the documented semantics, the silent acceptance of forged signatures past the 1/3 threshold should be model-explored.

---

### Family 5: Block-Execution Atomicity Crossing Sync Mode (LOW)

**Mechanism**: Sync→consensus transitions and consensus-params changes interact with the persistence sequence to create crash windows beyond those modeled in round 1's `applyBlock` atomicity family.

**Evidence**:
- Code analysis (verified): `state/execution.go:347-361` — evidence pool marked committed at line 353 before `state.Save` at line 359; crash window leaves replay rejecting the same block
- Code analysis (verified): `state/execution.go:649-650 buildExtendedCommitInfoFromStore` — `ap.VoteExtensionsEnabled(ec.Height)` uses current state's ABCI params, not params at `ec.Height`; if `VoteExtensionsEnableHeight` was updated between, panic at line 650 via `EnsureExtension`
- Code analysis (verified): `node/setup.go:617-649 performStateSync` and `node/node.go:432-463` — `Bootstrap → SaveSeenCommit → Enable` plus `SetOfflineStateSyncHeight(0)` happen non-atomically

**Priority**: Low for primary spec; informs Family 2 crash actions.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|---|---|---|
| BlockSync peer-trust state machine | Family 1: ASA-2025-001 + #5801 + #5135 + #3398; sync mode was excluded from rounds 1-2 | New variables `peerClaims`, `poolHeight`, `maxPeerHeight`, `banned`; actions for `ByzPeerAdvertiseRange`, `ByzPeerDeliverFirstWrong`, `RedoCoalesce` |
| BlockSync→Consensus handoff window | Family 1: F1.7 `cs.mtx` released before `waitSync` clear; F1.8 mempool enable order | Split `SwitchToConsensus` into 3 actions; allow `VoteSetMaj23` between them |
| StateSync trust chain | Family 2: snapshot.Hash unverified; per-chunk integrity = ABCI; F2.2-F2.6 are not covered by #4977 | New variables `snapshotPool`, `appliedChunks`, `appState`, `bootstrapped`; actions for `ByzOfferBogusSnapshot`, `ByzCorruptChunk`, `CrashBetweenBootstrapAndSeenCommit` |
| Reactor cached-RS freshness | Family 3: post-#5411 architecture; `EventVote` ordering; no `EventCompleteProposal` | Split RoundState into `cachedRS` (event-updated) vs `liveRS` (cs.mtx); allow Byzantine `HasVoteMessage` / `NewValidBlockMessage` / `VoteSetBitsMessage` with arbitrary bitmaps |
| `VoteSetMaj23` alias mutation | Family 3 F3.3 verified bypass of `cs.mtx` | Model `votes.SetPeerMaj23` as a write to live `Votes` table without acquiring `cs.mtx` |
| Light-client trusting verifier early-exit | Family 4 F4.2 unfixed in default variant | Two actions `VerifyCommit_TrustingEarly` vs `*AllSignatures`; explicit `forgedSig` set |
| Voting-power overflow in production paths | Family 4 F4.1 verified panic surface | `ByzValidatorSetCmtproto` action whose total power overflows `MaxInt64/8`; route through unprotected call sites |

### 3.2 Do Not Model (with rationale)

| What | Why |
|---|---|
| Already-modeled adversaries from rounds 1-2 (Equivocate, Amnesia, VEReuse, Lunatic, EvidenceLifecycle, LockingTransitions) | Carry these forward only to compose with round-3 actions; do not re-derive their consequences in isolation |
| #5609 ProposerPriorityHash fix | Already fixed (PR #5613); demoted to reference. Bug-prone-mechanism evidence only. |
| #5275 EC-prefix pruning | Already fixed; storage layer, not protocol |
| #5638 evidence pubkey-swap | Already fixed; reference only |
| ASA-2025-002 block-part proof index | Already covered round 2 |
| lp2p / dependency / typo / CI fixes | Not protocol layer |
| #4977 statesync failure path | Already fixed; only the SUCCESS + crash window is in scope |
| Cryptographic primitive breaks | Out of scope per Layer-1 default |
| Mempool transaction ordering | Not consensus safety scope (carries over from rounds 1-2) |
| PBTS detailed timing arithmetic | #4815/#4816 fixed; documented as reference |
| ABCI Misbehavior application semantics | Slashing is application-defined |
| Per-method Go-channel-implementation deadlocks (#5813, #5850, #2444) | Implementation-level concurrency; better caught by tests/race detector |
| Recreate already-fixed bugs as MC targets | Per `bug-archaeology.md` §1.4 — no value to re-derive |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|---|---|---|---|
| BlockSync peer pool | `peerClaims`, `poolHeight`, `maxPeerHeight`, `banned`, `firstDelivered`, `redoBacklog` | Model adversarial peer-range claims, first-writer-wins, redo coalescing | Family 1 |
| SwitchToConsensus handoff | `waitSync`, `consensusStarted`, `csMutex` (abstract) | Capture the window where StateChannel is unguarded | Family 1 |
| StateSync chunks | `snapshotPool`, `acceptedSnapshot`, `appliedChunks`, `appState`, `bootstrapped`, `offlineMarkerCleared` | Model snapshot/chunk trust delegation to ABCI and persistence atomicity | Family 2 |
| Reactor cached RS | `cachedRS`, `liveRS`, `peerKnowsVote`, `peerKnowsBlockPart`, `peerKnowsProposal` | Capture event-only refresh and Byzantine peer-state lies | Family 3 |
| Light-client verify modes | `commitSignatures : Seq(Sig)`, `forgedSig : SUBSET (h, idx)`, `verifyMode ∈ {Strict, TrustingEarly, TrustingAll}` | Probe early-exit's acceptance of forged-suffix commits | Family 4 |
| Validator-set ingestion path | `untrustedValSet : ValidatorSet`, `safetyChecked : BOOLEAN` | Route untrusted sets to either `TotalVotingPowerSafe` (returns err) or panicking call sites | Family 4 |
| Sync-mode persistence sequence | `persistStage ∈ {NONE, STATE_ONLY, COMMIT_SAVED, ENABLED}` | Crash injection between stages | Family 2/5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| `Agreement` | Safety | No two honest nodes commit different blocks at the same height under f < n/3 | All families (carry forward) |
| `ElectionSafety` | Safety | At most one block committed per height | All (carry forward) |
| `MaxPeerHeightMonotone` | Safety | Under honest peers, `maxPeerHeight` is non-decreasing | Family 1 (violable when Byzantine high-base peers compose with `pool.height` advance) |
| `HonestPeerNotPunishedForCorrectBlock` | Safety | A peer that delivers the canonical block for height h is not banned by validation, regardless of other peers' deliveries | Family 1 F1.4 |
| `NoConsensusBeforeSwitchComplete` | Safety | While `waitSync == true`, no peer message reaches consensus's mutable `Votes` table | Family 1 F1.7 |
| `MempoolFollowsConsensus` | Liveness | If mempool accepts txs, consensus is either running or actively starting | Family 1 F1.8 / #3398 |
| `SnapshotIntegrityAnchored` | Safety | Every accepted snapshot's content is tied to the trusted `AppHash` by either CometBFT or app-layer rejection | Family 2 F2.2 |
| `PersistenceAtomicity` | Safety | After any crash in the statesync goroutine, restart sees genesis OR fully-consistent (state, blockStore, marker) | Family 2 F2.4-F2.5 |
| `AppCometStateConsistency` | Safety | post-sync (state.LastBlockHeight == appState.LastBlockHeight) | Family 2 F2.6 |
| `EvidencePoolStateSaveAtomic` | Safety | evpool commit-mark and `state.Save` are atomically tied | Family 5 F5.2 |
| `BroadcastOrderingHonoredByListeners` | Safety | If listener L broadcasts message M and then updates cached state S, consumers reacting to M observe the updated S | Family 3 F3.1 (currently violable via EventVote ordering) |
| `PeerKnowledgeWellFounded` | Safety | `peerKnowsVote[s][p][v] = TRUE` implies s sent v to p or p sent v to s | Family 3 F3.4-F3.6 (currently violable) |
| `VotesTableMutatedOnlyByMainLoop` | Safety | The live `cs.Votes` is mutated only by the main loop under `cs.mtx` | Family 3 F3.3 (currently violable via VoteSetMaj23 alias) |
| `LightClientCommitSoundness` | Safety | If `VerifyCommit_*` accepts, the variant's voting-power threshold is met by signatures whose authenticity was verified | Family 4 F4.2 (currently violable for `VerifyCommitLightTrusting`) |
| `NoUnauthenticatedPanic` | Safety | No peer-supplied ValidatorSet causes int64 overflow panic in `TotalVotingPower()` | Family 4 F4.1 |
| `ProposerFairness` | Liveness | Over unbounded horizon, every validator with non-zero voting power is selected proposer infinitely often | Family 4 F4.4 |
| `ProposerPriorityHashSoundness` | Safety | `ProposerPriorityHash(S1) == ProposerPriorityHash(S2)` (after canonical sort) ⟺ priority-tuples equal | Family 4 F4.5 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected violation | Family |
|---|---|---|---|
| MC-1 | Byzantine peer advertises `base = poolHeight + Δ` for Δ > 0; after `poolHeight` advances by Δ, peer is suddenly counted in `maxPeerHeight`; honest server's `IsCaughtUp` regresses true→false | `MaxPeerHeightMonotone` violated | 1 |
| MC-2 | Byzantine peer p1 delivers malformed block for height h; honest peer p2 delivers correct block second; setBlock keeps p1's block; later `VerifyCommit` against h+1's `LastCommit` fails; both p1 AND p2 are banned | `HonestPeerNotPunishedForCorrectBlock` violated | 1 |
| MC-3 | RedoCoalesce: two peers fail to deliver in quick succession on a requester whose `redoCh` already has one entry; second redo dropped; requester sits for 30s | Liveness bound on catch-up violated | 1 |
| MC-4 | `SwitchToConsensus` releases `cs.mtx`, then before `waitSync.Store(false)`, an honest peer sends `VoteSetMaj23` → mutates `cs.Votes` via alias → potential vote-set corruption visible to subsequent consensus actions | `NoConsensusBeforeSwitchComplete` violated | 1, 3 |
| MC-5 | Byzantine peer offers snapshot at trusted height with crafted `Hash` and `Chunks`; permissive ABCI app accepts; `verifyApp` checks AppHash but not snapshot.Hash; chunks loaded reflect Byzantine bytes | `SnapshotIntegrityAnchored` holds only if app rejects (forced contract) | 2 |
| MC-6 | Crash between `stateStore.Bootstrap` and `blockStore.SaveSeenCommit`; restart sees state at H but no seenCommit; blocksync can't continue cleanly | `PersistenceAtomicity` violated | 2, 5 |
| MC-7 | `verifyApp` fails after chunks applied; CometBFT discards snapshot but app state is divergent; no rollback signal sent | `AppCometStateConsistency` violated | 2 |
| MC-8 | `EventVote` listener: broadcast at line 469 → peer receives `HasVote` → peer sends `VoteMessage` → consumer reads stale `cachedRS` because update at lines 475-476 has not run yet | `BroadcastOrderingHonoredByListeners` violated | 3 |
| MC-9 | Byzantine peer sends `HasVoteMessage{Index=i}` for every i; honest server marks `peerKnowsVote[s][p][i] = true`; gossip routines never send any vote to that peer | `PeerKnowledgeWellFounded` violated → eventually `EventualGossipDelivery` (liveness) | 3 |
| MC-10 | Byzantine peer sends `NewValidBlockMessage` with all-ones BlockParts; honest server never sends any block part to that peer | `PeerKnowledgeWellFounded` (block parts) violated | 3 |
| MC-11 | Byzantine peer sends `VoteSetBitsMessage` for height < cachedRS.Height with all-ones; honest server overwrites `peerKnowsVote[s][p]` for past height | `PeerKnowledgeWellFounded` violated | 3 |
| MC-12 | Byzantine peer sends `VoteSetMaj23` (StateChannel, unguarded during BlockSync); writes through alias to live `cs.Votes` table; happens during BlockSync→Consensus handoff window | `VotesTableMutatedOnlyByMainLoop` violated | 1, 3 |
| MC-13 | Byzantine commit at height h: first 1/3 signatures valid, remaining 2/3 forged; `VerifyCommitLightTrusting` accepts because countAllSignatures=false; later block at h+k inherits forged-signature acceptance through the light-client trust chain | `LightClientCommitSoundness` violated for `TrustingEarly` mode | 4 |
| MC-14 | Byzantine `cmtproto.ValidatorSet` whose summed voting power overflows; reaches `consensus/state.go:1856` (live state metrics) or `types/evidence.go:75` (evidence construction); honest validator panics | `NoUnauthenticatedPanic` violated | 4 |
| MC-15 | Long-running chain (high round counts) + concentrated voting power: `incrementProposerPriority` clips one validator's priority at `MinInt64`; validator never selected proposer thereafter | `ProposerFairness` violated | 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| TV-1 | `bannedPeers` is volatile across restart; banned peer rejoins immediately | Integration test: ban peer, restart node, verify peer can connect |
| TV-2 | `bannedPeers` TTL hard-coded 60s — no operator control | Configuration test: verify no exposed knob |
| TV-3 | `setBlock` discards correct second-arrival block | Unit test: deliver malformed block from p1, correct from p2; verify p2's block is unused |
| TV-4 | `redoCh` capacity-1 silently drops concurrent redos | Unit test: trigger two failures rapidly; verify only one redo fires |
| TV-5 | `verifyApp` failure leaves ABCI app at restored state with no rollback | E2E test: mock ABCI to accept chunks then fail Info hash check |
| TV-6 | `ProposerPriorityHash` ordering dependence | Unit test: same logical validator set in different orderings → different hashes |
| TV-7 | `VerifyCommitLightTrusting` accepts trailing forged signatures | Unit test: craft commit with valid first-1/3 + garbage second-2/3; verify default trusting variant accepts but `*AllSignatures` rejects |
| TV-8 | `TotalVotingPower()` panic from overflow `cmtproto.ValidatorSet` | Unit test: craft proto with summed power > MaxInt64/8; route through consensus/state.go:1856 path |
| TV-9 | `incrementProposerPriority` saturation lock-in | Long-running unit test: force `MinInt64` clip; verify the validator never elected |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR-1 | `bannedPeers` TTL of 60s is hard-coded; ban erased on restart | Discuss: should ban be persistent? Should TTL be configurable? |
| CR-2 | `pickIncrAvailablePeer` no fairness mechanism — HOL by curRate ordering | Discuss: should there be a peer-rotation or anti-starvation rule? |
| CR-3 | `ApplyVerifiedBlock` panics on transient app failure rather than rollback | Discuss: should there be a recovery path? |
| CR-4 | `Validator.Bytes()` excludes ProposerPriority; `Validator.ToProto()` includes it; proto-bytes-of-set is sometimes used as a key | Audit all proto-marshal-as-key uses; either canonicalize or document |
| CR-5 | `params.go:84-92 VoteExtensionsEnabled(h<1)` panics; `ValidateUpdate` rule comparisons use `<= h`/`<= 0` | Add documentation; verify genesis-update path |
| CR-6 | `verifyCommitBatch` does not call `commitSig.ValidateBasic` (compare with single path) | Add the check or document the asymmetry |
| CR-7 | `verifyCommitLightTrustingInternal` does not call `verifyBasicValsAndCommit`; `len(commit.Signatures)` unbounded | Add a bound or document the DoS surface for trusting light clients |
| CR-8 | `lastValidatedBlock` cache hit still runs `CheckEvidence` — idempotence relies on evidence-store `Has` check | Document the idempotence contract |
| CR-9 | `EventCompleteProposal` not subscribed by reactor; cached RS may miss proposal completion until next NewRoundStep | Add subscription or document the freshness contract |
| CR-10 | `Receive` StateChannel handler not WaitSync-gated; allows `VoteSetMaj23` during BlockSync handoff window | Either add WaitSync guard or document the intentional behavior |

## 7. Reference Pointers

- **Full analysis report**: `/home/ubuntu/Specula/case-studies/cometbft_3/.specula-output/analysis-report.md`
- **Round 1 brief** (consensus core safety): `/home/ubuntu/Specula/case-studies/cometbft/modeling-brief.md`
- **Round 2 brief** (BFT adversary actions): `/home/ubuntu/Specula/case-studies/cometbft_2/modeling-brief.md`
- **Key source files for round 3**:
  - `artifact/cometbft/blocksync/pool.go` (952 lines) — peer pool, SetPeerRange at 397-445, updateMaxPeerHeight at 487-501, pickIncrAvailablePeer at 524-547, setBlock at 732-753, redoCh at 715/822-825, isPeerBanned at 511-513 (60s TTL)
  - `artifact/cometbft/blocksync/reactor.go` (788 lines) — poolRoutine commit-verification anchor
  - `artifact/cometbft/statesync/syncer.go` (521 lines) — `Sync` at 246-323, `verifyApp` at 490-521, chunk-then-verify at 308/314
  - `artifact/cometbft/statesync/chunks.go` — `chunkQueue.Add` at 63-101
  - `artifact/cometbft/statesync/snapshots.go` — pool at 75-118 / 158-187
  - `artifact/cometbft/node/node.go` (1071 lines) — maybeStateSync at 368-463; `SetOfflineStateSyncHeight(0)` at 460-463
  - `artifact/cometbft/node/setup.go` — `performStateSync` at ~617-649
  - `artifact/cometbft/consensus/reactor.go` (2015 lines) — `SwitchToConsensus` at 121-157, subscribeToBroadcastEvents at 431-481 (EventVote ordering bug at 469 vs 475-476), VoteSetMaj23 handler at 289-324, Apply{HasVote,NewValidBlock,VoteSetBits}Message at 1566-1630
  - `artifact/cometbft/consensus/state.go` (2709 lines) — TotalVotingPower call sites at 1856, 2298, 2590, 2621, 2644
  - `artifact/cometbft/types/validator_set.go` (1118 lines) — TotalVotingPower (panicking) at 354-361, TotalVotingPowerSafe at 341-345 (used only at 999), incrementProposerPriority at 181-193, ProposerPriorityHash at 400-412
  - `artifact/cometbft/types/validation.go` (533 lines) — VerifyCommit family at 30-138, VerifyCommitLightTrusting* at 140-194, verifyCommitLightTrustingInternal at 196-239, verifyCommitBatch at 291-321, verifyCommitSingle at 431-505
  - `artifact/cometbft/state/execution.go` (889 lines) — buildExtendedCommitInfoFromStore at 595-665 (panics at 603/626/639/650); evpool.Update→state.Save crash window at 347-361
- **GitHub issues (round-3-relevant, NEW)**:
  - OPEN: #5801 (blocksync DoS, disputed), #5135 (peer kick on empty blocks), #3398 (mempool floods catching-up node), #5459 (privval), #5205 (BlockIDFlag), #3642 (privval VE signing)
  - OPEN PRs: #5864 (proposer self-verify VE), #5813 (statsMsgQueue cs.mtx), #5592 (redoCh cap), #5850 (ABCI client deadlock), #5867 (blocksync flake)
  - CLOSED (reference): #5613 (ProposerPriorityHash), #5638 (evidence pubkey-swap), #5629 (blocksync ExtendedCommit verify), #5324 (oversized proposal), #4978 (statesync→handshake), #4816 (PBTS overflow), #5276 (EC prune), #5570 (TotalVotingPowerSafe)
- **Security advisories**: ASA-2025-001 (blocksync stuck), ASA-2025-002 (block-part index — round 2)
- **Reference algorithm**: Tendermint BFT (Buchman, Kwon, Milosevic 2018, arXiv:1807.04938); ADR-047 (fork accountability)
- **BFT methodology**: `references/bft-analysis.md` (composed with round-1 distributed faults + round-2 Byzantine actions)
