# Analysis Report: cometbft/cometbft (Round 3 — Sync-Boundary, Reactor-Freshness, Verification-Determinism)

## Scope and prior-rounds delta

Round 1 (`case-studies/cometbft/modeling-brief.md`) covered:
- VE lifecycle defects, state-machine liveness, WAL/crash recovery, evidence handling, locking transitions, block-execution atomicity.

Round 2 (`case-studies/cometbft_2/modeling-brief.md`) added BFT adversary actions:
- Equivocation + selective dissemination, amnesia × crash, VE reuse/late-commit, light-client lunatic header, evidence-lifecycle races, locking transitions under Byzantine proposer interleaving.

**Round 3 scope** — areas explicitly excluded or under-covered in prior rounds:
1. **BlockSync and StateSync trust model** (rounds 1-2 excluded blocksync/statesync as "separate protocol"; recent fixes ASA-2025-001, #5629, #4977 prove this is bug-rich).
2. **Reactor round-state freshness after PR #5411** (Sept 2025 backport removed `updateRoundStateRoutine` polling; reactor now reads event-only `conR.rs`).
3. **Determinism gaps in verification/voting-power arithmetic** (#5609 `ProposerPriorityHash`, #5570 `TotalVotingPowerSafe`, #1750-residual in `VerifyCommitLightTrusting`).
4. **Block-execution atomicity boundaries** that crossed sync mode (statesync-handshake gap, offlineStateSyncHeight clear ordering).

This report records the audit trail; the modeling brief synthesizes families and modeling actions.

---

## Phase 1: Reconnaissance

### Repository structure (cometbft_3 artifact)

- Go consensus engine ~16k LOC in `consensus/` alone; ~12k LOC in supporting types/state/evidence/light.
- Core files (verified line counts):
  - `consensus/state.go` (2709), `consensus/reactor.go` (2015), `consensus/replay.go` (563), `consensus/wal.go` (435)
  - `state/execution.go` (889), `state/state.go` (365), `state/validation.go` (170)
  - `types/validator_set.go` (1118), `types/validation.go` (533), `types/vote_set.go` (725), `types/canonical.go` (86)
  - `evidence/pool.go` (575), `evidence/verify.go` (317), `evidence/reactor.go` (253)
  - `light/verifier.go` (246), `light/detector.go` (~430)
  - `blocksync/pool.go` (952), `blocksync/reactor.go` (788)
  - `statesync/syncer.go` (521), `statesync/reactor.go` (296), `statesync/chunks.go`, `statesync/snapshots.go`
  - `privval/file.go` (465)
  - `node/node.go` (1071), `node/setup.go` (~700)

### System category

**Category A (Distributed / Message-Passing) with BFT overlay.** The protocol's safety/liveness depends on tolerating ≤ *f* deviating validators per `n ≥ 3f+1`. Apply `distributed-analysis.md` + `bft-analysis.md`.

Layer-1 environment for round 3 (carry forward from round 2):
- Static corruption · partial synchrony · authenticated · f < n/3.

Round 3 extends the model **outside the consensus mode** (sync boundary): nodes in BlockSync/StateSync are receiving data over an unauthenticated peer channel, with trust anchored in: (a) the configured light-client trust hash (statesync), (b) the `VerifyCommit` chain of next-block `LastCommit` (blocksync). Byzantine peers can lie freely subject to those anchors.

---

## Phase 2: Bug Archaeology

### Coverage statistics

- **Git history mined**: ~250 bug-fix commits across consensus/, types/, state/, evidence/, light/, privval/, blocksync/, statesync/, node/, internal/ since 2023. Round 3 focused on **commits since round-2 cutoff (mid-2025)** plus older items under-explored by rounds 1-2.
- **Issues deeply read (full comment threads)**: ~30 new issues in round 3 (parallel batches via Task subagents). Includes both `gh issue view --comments` reads of specific numbers and `gh issue list` label/keyword searches.
- **OPEN PRs reviewed**: ~10 (#5864, #5861, #5850, #5813, #5592, #5867, etc.)
- **Total new findings excluded as false-positive / already covered**: ~12 — see explicit exclusions below.

### Key new findings (NOT in prior rounds)

| Bug | Status | Component | Round 3 placement |
|---|---|---|---|
| #5801 | OPEN, disputed CVE | blocksync/pool.go peer trust | F1 (BlockSync trust) — forward-looking |
| #5275 / #5276 | CLOSED fixed | store/store.go `EC` prune | reference only (already fixed) |
| #5609 / #5613 | CLOSED fixed | types/validator_set.go ProposerPriorityHash | F4 reference; not modeling target |
| #5638 (PR merged) | CLOSED | evidence/verify.go pubkey-swap | reference (covered) |
| #5629 (PR merged) | CLOSED | blocksync ExtendedCommit verify | F1 (BlockSync trust) — anchor mechanism |
| #5324 | CLOSED fixed | consensus/reactor.go oversized proposal | F3 (Reactor freshness) reference |
| #5135 | OPEN | blocksync/pool.go rate timeout | F1 (BlockSync trust) — forward-looking |
| #3398 | OPEN | mempool ↔ consensus catch-up | F1 (BlockSync trust) — forward-looking |
| #4977 / #4978 | CLOSED partial fix | statesync→blocksync handshake | F2 (StateSync trust) — partial fix |
| #4815 / #4816 | CLOSED fixed | PBTS MessageDelay overflow | reference (covered) |
| #5570 | MERGED (test only) | types/validator_set.go TotalVotingPowerSafe | F4 — production paths NOT migrated |
| #5205 | OPEN | LastCommit BlockIDFlag | reference |
| #3642 | OPEN | privval VE signing rules | reference |
| #5813 (PR) | OPEN | state.go `statsMsgQueue` cs.mtx stall | F3 (Reactor freshness) — composes |
| #5592 (PR) | OPEN | blocksync redoCh cap-1 | F1 (BlockSync trust) — verified at pool.go:715, 822 |
| #5850 (PR) | OPEN | ABCI client deadlock resCb re-entry | code-review only |
| #25dee2b05 | CLOSED fixed | reactor bitarray validation | F3 reference |
| #5411 (backport) | MERGED Sept 2025 | reactor polling-routine removal | F3 — architectural change, freshness gaps |
| #5459 | OPEN | privval remote signer error | code-review only |
| #5028 / #5029 | CLOSED | e2e catch-up test | test-only, excluded |
| #5594, #5584, #5577, #5570, #5541, #5419, #5326 | mostly merged | lp2p / docs / cleanup | excluded as non-protocol |
| #5147 | MERGED revert | DB-backend revert | excluded (policy) |
| #653 | OPEN | data race logging consensus.State | code-review only |
| #5858 | OPEN | SecretConnection AEAD race on Rosetta | code-review only |
| #2444 | OPEN | CListMempool.CheckTx RLock-misuse | code-review / test-verifiable |
| #4054 | OPEN | consensus panic doesn't stop p2p/RPC | code-review only |
| #5672 | OPEN | PebbleDB 1.x 32-bit key limit | code-review (dependency) |
| #1857 | OPEN | light-client store global `size` key | code-review only (covered in round 1 brief as P5 area) |

### Explicit exclusions (Round 3 will NOT focus on)

- Items already deeply modeled in rounds 1-2: VE asymmetry, equivocation, amnesia, lunatic header, evidence pipeline, locking transitions.
- Pure resource leaks: #5275 (EC pruning), #5433 (privval port exhaustion), #5275-class storage bugs.
- Test-only fixes: #5028, #5570 (test scaffolding for the new Safe helper).
- Dependency/CI/docs: ~20 of the recent commits.
- libp2p (lp2p) port bugs (#5594, #5584): the `lp2p/` package is a transport-layer reimplementation that is not on the consensus safety path.

---

## Phase 3: Deep Analysis findings

Each finding cites file:line in the current `cometbft_3` artifact tree.

### Family F1. BlockSync Trust Boundary — peers' (base, height) and block contents

**F1.1** `pool.SetPeerRange` at `blocksync/pool.go:397-445` admits arbitrary peer-reported `(base, height)` after only structural checks (`base > height` → ban at 402-408; monotonic-decrease → ban at 413-428). No cross-validation against the local view or against other peers. **Forward-looking**: a sybil set of peers can advertise huge `height` to extend `maxPeerHeight` and stall `IsCaughtUp`.

**F1.2** `updateMaxPeerHeight` at `blocksync/pool.go:487-501` excludes peers with `peer.base > pool.height` only **when `pool.height > 0`** (line 490). At node startup `pool.height == 0` so all peers' heights contribute to `maxPeerHeight`. After even one block fetched, peers whose `base > pool.height` are silently dropped from the max calc. This means `maxPeerHeight` is **non-monotonic** in `pool.height`: an attacker who first poisons `maxPeerHeight` with a high `base=10^18, height=10^18` peer creates an apparent "ahead" cluster; once `pool.height` exceeds genesis, that peer is suddenly dropped from the max, so `maxPeerHeight` can decrease and `IsCaughtUp` can flip true→false→true. **Verified at pool.go:243** (`IsCaughtUp` reads `maxPeerHeight - 1`).

**F1.3** `bannedPeers` TTL is hard-coded `time.Second*60` at `pool.go:513`. `bannedPeers` is **volatile** across restart (`NewBlockPool` initializes from empty at `pool.go:102-116`). Combined with F1.1, an attacker can churn peer IDs every 60s with no persistent cost.

**F1.4** `bpRequester.setBlock` at `pool.go:732-753` implements "first-writer-wins". If peer A delivers a malformed block first and peer B delivers the correct block second, B's block is **silently discarded** (`return true` at line 740) and validation will later reject A's block (in `reactor.go` poolRoutine via `VerifyCommit` against the next height's `firstID`). Both peers are then removed by `handleValidationFailure`. **Verified at pool.go:738-741; rejection path at reactor.go:614-635**.

**F1.5** Redo-channel coalescing: `bpr.redo()` writes to a `redoCh` of capacity 1 (`pool.go:715, 822-825`). If a redo for peer X is already pending and a redo for peer Y arrives, Y is **silently dropped** (`default:` branch at line 823-825). The requester reset loop at `pool.go:919-930` then resets only the first peer; the second remains "outstanding" and the requester sits on the 30s `requestRetrySeconds` retry timer (`pool.go:35, 900`). This is **PR #5592**'s known gap.

**F1.6** `pickIncrAvailablePeer` at `pool.go:524-547` has no fairness — peers are ordered by `curRate` descending (`pool.go:553-555`). Combined with `incrPending` resetting the timer at `pool.go:656-662`, an HOL attacker with above-`minRecvRate` throughput keeps its head position by accumulating new requests faster than `peerTimeout` (15s).

**F1.7** `SwitchToConsensus` at `consensus/reactor.go:121-157` holds `conS.mtx` only across `reconstructLastCommit` + `updateToState`, **releases the lock**, then runs `conR.waitSync.Store(false)` and `conS.Start()`. Between the lock release at line 137 and `waitSync.Store(false)` at line 140, peer messages arriving on `StateChannel` are **not** WaitSync-gated (`Receive` at line 273-327 enters the `StateChannel` case without checking `WaitSync()`); the `VoteSetMaj23` handler at line 289-324 then calls `votes.SetPeerMaj23` on the live `HeightVoteSet`, **writing to consensus state via a pointer aliased through the value-copy `rs := conR.getRoundState()`**. The other channels (DataChannel, VoteChannel, VoteSetBitsChannel) ARE gated (lines 330, 357, 376).

**F1.8** BlockSync→Consensus handoff at `blocksync/reactor.go` calls `memR.EnableInOutTxs()` **before** `conR.SwitchToConsensus()` (the order is "stop pool → enable mempool → switch reactor"). Between these calls the mempool is accepting peer txs while consensus has not yet started. If `SwitchToConsensus` itself blocks on WAL replay (`conS.Start()` at consensus/reactor.go:147), the window widens. **Forward-looking**: model the existence of a state `mempool.enabled && !consensus.running && !blocksync.running`.

**F1.9** ApplyVerifiedBlock failure handling in `blocksync/reactor.go:687-691` (per round 3 subagent reading; spec: panics on error rather than rolling back `SaveBlock`). Transient app failures brick the node; no recovery path. Combined with F1.3 (bans volatile), restart restores attack surface.

### Family F2. StateSync Trust Boundary — snapshot Hash, chunk integrity, atomicity

**F2.1** `statesync/syncer.go:262-271`: the trust anchor is `stateProvider.AppHash(snapshot.Height)`, which uses the light-client trust hash. `snapshot.trustedAppHash = appHash` is set at line 271. After all chunks are applied, `verifyApp` at `syncer.go:490-521` checks `resp.LastBlockAppHash == snapshot.trustedAppHash` (line 504). **Good**: the `AppHash` chain is anchored.

**F2.2** **`snapshot.Hash` is NEVER cryptographically verified** by CometBFT against any trusted value. `snapshot.Hash` is only:
- Logged for operator messages (`syncer.go:119, 201, 207, 212, 220, 320, 329, 346, 474`)
- Forwarded to ABCI in `OfferSnapshot` (`syncer.go:335`)
- Used as part of `Key()` for pool dedup (`snapshots.go:30-39`)

A Byzantine peer can offer a snapshot with `Height = trustHeight`, `Format = anything`, `Hash = bogus bytes`, `Chunks = 1`; the pool accepts; `SyncAny` calls `stateProvider.AppHash(trustHeight)` (succeeds), then `OfferSnapshot` is sent to the app with bogus `Hash`. The app may reject or accept based on its own logic; CometBFT does no Merkle-root check.

**F2.3** **No per-chunk integrity verification in CometBFT.** `chunkQueue.Add` at `statesync/chunks.go:63-101` only checks `Height`, `Format`, `Index < snapshot.Chunks` (line 78). Bytes are written to disk verbatim (line 86). `applyChunks` at `syncer.go:363-416` hands them straight to `ApplySnapshotChunk` without computing any digest. The protocol delegates *all* per-chunk integrity to the ABCI application's `RejectSenders`/`RefetchChunks` response (`syncer.go:383-400`).

**F2.4** Crash atomicity in `node/setup.go:617-649`:
1. `Sync()` returns `(state, commit)`
2. `stateStore.Bootstrap(state)` (~line 624) — persists state
3. `blockStore.SaveSeenCommit(state.LastBlockHeight, commit)` (~line 630) — persists commit
4. `consensusReactor.SwitchToConsensus(state, ...)` or `blockSyncReactor.Enable()`

**Crash between (2) and (3)** leaves persisted `sm.State` at `LastBlockHeight = H` but **no seenCommit at H** in the block store. On restart, `state.LastBlockHeight > 0` so statesync is bypassed (`node.go:368-371`). Consensus / blocksync resumes without proof for height H. **Forward-looking** — the #4977 fix addresses statesync **failure**, not statesync **success** + crash between bootstrap and commit save.

**F2.5** **`offlineStateSyncHeight` cleared BEFORE statesync runs**: `node/node.go:432-463`.
1. Line 432-438: read `offlineStateSyncHeight` from store iff `blockStore.Height() == 0`
2. Line 440-450: create `bcReactor` with that height
3. Line 460-463: `stateStore.SetOfflineStateSyncHeight(0)` — **clears the persisted marker unconditionally**, even though the goroutine that actually performs statesync hasn't run yet.

If the node crashes between line 460 (clearing the marker) and `stateStore.Bootstrap(state)` in the `performStateSync` goroutine, restart will see `blockStore.Height() == 0` and no offline statesync marker → blocksync from genesis. This is **forward-looking**.

**F2.6** **ApplySnapshotChunk applied before verifyApp** at `syncer.go:308` (chunks apply) → `:314` (verifyApp). If `verifyApp` returns `errVerifyFailed`, CometBFT discards the snapshot and retries — but the ABCI app already has the restored state. Nothing tells the app to roll back. On restart, app's `LastBlockHeight` will mismatch CometBFT's; this is the exact failure mode #4977 tried to address, **but in the success-then-verifyApp-fails path** it remains.

**F2.7** Snapshot DoS via Byzantine flooding: per-peer cap is `recentSnapshots = 10` (`snapshots.go:88`, `reactor.go:25`). No global cap. Many Byzantine peers → tens of thousands of pool entries. Each `Ranked()` call re-sorts under lock. `SyncAny` retries every 30s per attempt; Byzantine peers can delay legitimate snapshots by 30s × N.

**F2.8** Late chunk from rejected sender can still enter `chunkQueue.Add`: after `RejectPeer` at `syncer.go:394-395`, the **pool** updates but `chunkQueue` does not consult the pool's reject list (`chunks.go:63-101`). A race window between pool rejection and `DiscardSender` propagation allows a chunk to slip through.

### Family F3. Reactor Round-State Freshness After Polling-Removal

PR #5411 (Sept 2025) removed `updateRoundStateRoutine` (which ticked every 100µs polling `cs.GetRoundState()` into `conR.rs`) and replaced it with event-driven `updateRoundState(rs)` callbacks on `EventNewRoundStep`, `EventValidBlock`, `EventVote` (see `consensus/reactor.go:431-481`).

**F3.1** **`EventVote` listener at `consensus/reactor.go:465-481`** broadcasts FIRST (line 469: `conR.broadcastHasVoteMessage(data.(*types.Vote))`), THEN updates `conR.rs` (lines 475-476). A peer receiving the broadcast `HasVote` may immediately reply with a `VoteMessage`; the `Receive` handler at `reactor.go:362-368` then reads a potentially-stale `conR.rs` height via `conR.getRoundState()` (line 363). The comment at lines 472-474 justifies this with "eventBus is synchronous" — but that only ensures the listener runs synchronously w.r.t. the publisher, NOT that `conR.rs` is updated before *consumers* of the broadcast act.

**F3.2** **No `EventCompleteProposal` subscription.** The reactor's `subscribeToBroadcastEvents` (lines 431-496) only listens for `EventNewRoundStep`, `EventValidBlock`, `EventVote`, `EventNewConsensusParams`. After a proposal completes, `conR.rs` may not reflect the new `ProposalBlock`/`Proposal` until a subsequent `EventNewRoundStep` fires (when `RoundStepPrevote` is entered). Gossip routines (`gossipDataRoutine` at line 620, `gossipVotesRoutine` at line 669) read `conR.getRoundState()` and gossip based on a possibly-stale snapshot.

**F3.3** **`VoteSetMaj23` writes through value-copy with pointer aliasing.** `Receive` at line 289-324 does `rs := conR.getRoundState(); votes := rs.Votes`. `RoundState.Votes` is a `*HeightVoteSet`, so the value copy aliases the live consensus `Votes` table. Line 296 then calls `votes.SetPeerMaj23(...)` which **mutates the live consensus state** through the reactor path — bypassing `cs.mtx` (held by the state machine's main loop). Lines 306-308 then build `ourVotes` from the same aliased pointer. If the state machine concurrently advances height between `Receive` entry and line 306, `votes` references the prior height's `HeightVoteSet` — `votes.Prevotes(msg.Round)` may return nil or stale data.

**F3.4** **`HasVoteMessage` blindly trusts peer claims**: `PeerState.ApplyHasVoteMessage` at `reactor.go:1599-1609` sets `ps.setHasVote(...)` from the peer's bit. There is NO cross-check that the local vote table actually contains the vote at the claimed index. A Byzantine peer can claim `HasVote{Index=i}` for every `i ∈ [0, ValSize)`, and our `pickVoteToSend` will then never gossip votes to them (because `BitArray.Sub(prs.Prevotes)` returns no candidates). **Forward-looking gossip starvation** — a Byzantine peer can isolate honest peers from vote gossip without sending any vote of their own.

**F3.5** **`NewValidBlockMessage` blindly trusts peer's block-parts bitmap**: `ApplyNewValidBlockMessage` at `reactor.go:1566-1580` sets `ps.PRS.ProposalBlockParts = msg.BlockParts` directly. A Byzantine peer can send `NewValidBlock{Height=ours, Round=ours, BlockPartSetHeader=ours, BlockParts=<all-ones>}` and we will **never send them block parts** because `pickPartToSend` at `reactor.go:818` does `rs.ProposalBlockParts.BitArray().Sub(prs.ProposalBlockParts.Copy()).PickRandom()` which returns no index. **Forward-looking block-data gossip starvation.**

**F3.6** **`VoteSetBitsMessage` mismatched-height overwrites peer state**: `ApplyVoteSetBitsMessage` at `reactor.go:1611-1630`. When `ourVotes == nil` (msg.Height ≠ rs.Height path), the function does `votes.Update(msg.Votes)` (line 1623) — **the peer's claimed bitmap directly overwrites our local view of their `ps.PRS.Prevotes`/`Precommits` for the mismatched-height branch**. Combined with F3.4, a peer can mark `ps.PRS.Prevotes[i] = true` for any `i` even at past heights. **Verified at reactor.go:1622-1623**.

**F3.7** **`NewRoundStepMessage.Round` unbounded**: `ValidateBasic` at `reactor.go:1685-...` only checks `Round >= 0`. An adversary setting `Round = math.MaxInt32` triggers bitmap reallocation in `ApplyNewRoundStepMessage` (line 1512+). DoS amplification.

### Family F4. Verification / Voting-Power Arithmetic Determinism

**F4.1** **`TotalVotingPower()` panics on overflow in production paths.** The `Safe` variant added by #5570 is called only in `validator_set.go:999` (proto validation) and the test file. Unsafe `TotalVotingPower()` is called from at least:
- `validator_set.go:142, 190, 505, 701` (internal — invariants assume safe input)
- `validation.go:40, 121, 216` (VerifyCommit, VerifyCommitLight, VerifyCommitLightTrustingInternal)
- `consensus/state.go:1856, 2298, 2590, 2621, 2644` — 5 sites in the live consensus state machine
- `blocksync/reactor.go:453`
- `light/detector.go:429-433`
- `types/vote_set.go:308`
- `types/evidence.go:75`

If a maliciously-crafted `cmtproto.ValidatorSet` reaches one of these via evidence ingestion, light-block import, or state-sync (post-snapshot), the node panics rather than returning an error. **Forward-looking DoS.** **Verified by grep** at the listed lines.

**F4.2** **`VerifyCommitLightTrusting` exits early at the trust threshold (typically 1/3) and does NOT check remaining signatures** — the residual #1750 in the default trusting variant. `verifyCommitLightTrustingInternal` at `types/validation.go:196-239` passes `countAllSignatures=false` from `VerifyCommitLightTrusting` (line 154) and `VerifyCommitLightTrustingWithCache` (line 177). Only the explicit `VerifyCommitLightTrustingAllSignatures` (line 193) sets `true`. The early-exit at line 348-350 and 498-500 then short-circuits once `talliedVotingPower > votingPowerNeeded`. **With trustLevel=1/3, this means only ~1/3 of signatures are checked**, and the rest are silently trusted. A Byzantine witness can submit a commit where the first ~1/3 of signatures are valid and the rest are garbage; trusting verification accepts.

**F4.3** **`verifyCommitLightTrustingInternal` does NOT call `verifyBasicValsAndCommit`** (no equivalent of the `vals.Size() == len(commit.Signatures)` check from validation.go:510-533). `len(commit.Signatures)` can be unbounded relative to `vals.Size()`. A malicious witness can flood verification work with huge `Signatures` slices.

**F4.4** **`IncrementProposerPriority` silent saturation**: `validator_set.go:181-193`. `safeAddClip`/`safeSubClip` clip to `MaxInt64`/`MinInt64` rather than overflowing. A validator with `ProposerPriority` clipped to `MinInt64` will never be chosen as proposer regardless of voting power. Subsequent rounds compound the clipping. **Fairness invariant violation** — the documented `PriorityWindowSizeFactor * TotalVotingPower` bound is a soft guideline, not enforced.

**F4.5** **`ProposerPriorityHash` ordering** (`validator_set.go:400-412`): comment says "Validator set must be sorted to get the same hash" but the function does NOT sort. Callers must ensure identical iteration order. The light-client detector at `light/detector.go:212` compares hashes assuming identical ordering — if peer A and peer B reconstructed the same logical set from different `cmtproto.ValidatorSet` orderings (e.g., one sorted by `ValidatorsByVotingPower`, another by address), hashes diverge → spurious divergence detection. **Forward-looking**, model-checkable.

**F4.6** **`verifyCommitBatch` does not call `commitSig.ValidateBasic`** (compare validation.go:431-438 single vs. validation.go:291-321 batch). Degenerate signatures (e.g., empty bytes with BlockIDFlag=Commit) may pass batch verifier where they would fail single.

**F4.7** Evidence age filter asymmetry — round 2 noted (`evidence/reactor.go:192` block-only, `evidence/verify.go:313` AND-of-both). Round 3 confirms this is still present at the cited lines.

### Family F5. Block-Execution Atomicity Crossing Sync Mode

**F5.1** **`buildExtendedCommitInfoFromStore` panics on params boundary**: `state/execution.go:649-650` calls `ap.VoteExtensionsEnabled(ec.Height)` using **current state's** ABCI params, not the params at `ec.Height`. If `VoteExtensionsEnableHeight` was raised via consensus params update between `ec.Height` and the current proposal height, the historical ExtendedCommit storage may not match the current predicate. Specifically:
- If a chain reduced `VoteExtensionsEnableHeight` from `h_high` to `h_low` (forbidden by `params.go:271-279` once enabled, but the validation rule may have gaps for the "raise after disable" path), the historical block at `h_low ≤ height < h_high` may have stored extensions that the predicate now expects, or not stored extensions that the predicate now expects.
- `panic` at line 650 if `EnsureExtension` fails — direct DoS via consensus-params-update interleaving.

**F5.2** **Evidence-pool commit-mark vs. state.Save crash window**: `state/execution.go:347-361`. Order is `Commit → evpool.Update → fail.Fail() → store.Save`. Crash between `evpool.Update` (line 353) and `store.Save` (line 359) leaves evidence marked committed in the pool but `state.LastBlockHeight` still at H-1. On replay, `CheckEvidence` at line 234 will reject the same block because evidence is "already committed". **Forward-looking** — distinct from round 1's general `applyBlock` atomicity in identifying the specific evpool commit-mark interaction.

**F5.3** **`lastValidatedBlock` cache hit still runs `CheckEvidence`**: `state/execution.go:217-235`. Cache hits skip validation but evpool side-effects (`addPendingEvidence`) re-run via `pool.go:290` `evidenceStore.Has` check (idempotent in steady state). Model-checkable: cache-hit idempotence under arbitrary interleavings.

### Other findings

**F6.1** Validator-update `Bytes()`/`ToProto()` inconsistency: `Validator.Bytes()` excludes `ProposerPriority` (validator_set.go:957-963), `Validator.ToProto()` includes it. Two ValidatorSets with identical validators but different proposer-priority histories serialize to different proto bytes (`marshal(set)`) while `Hash()` returns identical bytes. Callers using proto-bytes-of-set as a key diverge from callers using `Hash()`. Code-review-only.

**F6.2** `VoteExtensionsEnabled(h)` panics on `h < 1` (`params.go:84-92`). `ValidateUpdate` at line 282 uses `<= h` comparisons. Off-by-one in genesis-update path. Code-review-only.

**F6.3** `SwitchToConsensus` `StateChannel` unguarded (covered in F1.7 / F3.3).

---

## Phase 4 hand-off

The modeling brief in `modeling-brief.md` selects Families F1-F4 as round-3 modeling targets. F5 informs spec extensions for the crash window. F6 entries are demoted to code-review-only.

Key forward-looking modeling questions (the test the brief must justify):
- **Q1 (F1)**: Can a Byzantine subset of blocksync peers cause `IsCaughtUp` to oscillate, or cause the honest pool to silently discard the correct block (F1.4) while banning the honest peer (F1.4 collateral)?
- **Q2 (F2)**: If a Byzantine peer offers a snapshot at a valid height with crafted `Hash`/`Chunks`/`Metadata` that the app accepts blindly, can the post-`verifyApp` state diverge from the chain canonical state until the next block? Can the F2.4 crash window cause permanent state-store/blockstore divergence?
- **Q3 (F3)**: Under partial-synchronous Byzantine peers, can `HasVoteMessage`/`NewValidBlockMessage` lying isolate an honest validator from vote/proposal gossip enough to violate liveness?
- **Q4 (F4)**: Can the `VerifyCommitLightTrusting` early-exit (F4.2) accept a commit where the last 2/3 of signatures are forgeries that would have failed in `VerifyCommit`? What is the light-client safety implication?

These all compose with the round-1 and round-2 adversary actions, but they all probe surfaces that prior rounds explicitly scoped out.
