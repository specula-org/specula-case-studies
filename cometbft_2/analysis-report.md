# CometBFT (Round 2) — Analysis Report

**Scope**: Byzantine-adversary actions on the consensus state machine (`consensus/`), vote tracking (`types/`), and evidence subsystem (`evidence/` + `light/`). Out of scope: ABCI execution semantics, mempool ordering, p2p transport, RPC, blocksync.

**System category**: Category A (distributed / message-passing), BFT — applies both `references/distributed-analysis.md` (6 fault families) and `references/bft-analysis.md` (9 Byzantine action categories).

**Why round 2**: the first CometBFT case study (sister directory `case-studies/cometbft/`) identified bugs via standard fault injection (crash / message loss / invalid VE) and surfaced #5204 (VE deadlock) and #1431 (nil-precommit advance). It **did not model an action that actually produces conflicting precommits**, so the equivocation-detection path is reactive but never exercised by an attacker action. This round focuses specifically on:

1. Equivocation (conflicting precommit production)
2. Lunatic (header conflicting with prior commitments)
3. Amnesia (LockedBlock/ValidBlock forgetting across crash)
4. Vote-extension reuse / replay
5. Evidence lifecycle (gossip suppression, invalid injection, race)
6. Round-state transitions under adversarial proposer interleaving

---

## 1. Reconnaissance

### 1.1 Codebase shape

| File | Lines | Role |
|------|-------|------|
| `consensus/state.go` | 2709 | Main state machine; `receiveRoutine`, `enterPropose/Prevote/Precommit/Commit`, `addVote`, `signVote`, `tryAddVote`, `repairWalFile` |
| `consensus/reactor.go` | 2015 | Gossip + per-peer goroutines; vote / proposal / block-part broadcast and receive |
| `consensus/replay.go` | 563 | WAL replay (`catchupReplay`); ABCI Handshake |
| `consensus/wal.go` | 435 | WAL `Write` (async) vs `WriteSync` (fsync); `WALDecoder.Decode` |
| `types/vote_set.go` | 725 | Vote tracking; `addVerifiedVote` conflict detection; `MakeExtendedCommit` |
| `types/vote.go` | 458 | `Vote.Verify` + `VerifyExtension` |
| `types/canonical.go` | 87 | What gets serialized in SignBytes — vote covers BlockID; VE does not |
| `types/validation.go` | ~700 | `VerifyCommit`/`VerifyCommitLight`/`VerifyCommitLightTrusting` for blocks and light client |
| `types/evidence.go` | 645 | `DuplicateVoteEvidence`, `LightClientAttackEvidence` |
| `evidence/pool.go` | 575 | `AddEvidence`, `CheckEvidence`, `ReportConflictingVotes`, `processConsensusBuffer`, expiry |
| `evidence/verify.go` | 317 | `VerifyDuplicateVote`, `VerifyLightClientAttack`, `IsEvidenceExpired` |
| `evidence/reactor.go` | ~260 | Evidence gossip, `prepareEvidenceMessage` filter |
| `light/verifier.go` | ~260 | `VerifyAdjacent`, `VerifyNonAdjacent`, `verifyNewHeaderAndVals` |
| `state/execution.go` | 822 | `ApplyBlock`, `BuildExtendedCommitInfo`, evidence pull/update |
| `privval/file.go` | ~470 | `FilePVLastSignState{Height,Round,Step,Sig,SignBytes}`, `CheckHRS` |

### 1.2 Concurrency model recap (carried forward from round 1)

- Single-writer state machine: `receiveRoutine` (state.go) owns `RoundState`; all input through channels (peer, internal, timeout)
- WAL: internal messages (own votes) use `WriteSync` (fsync); peer messages use buffered `Write`
- Evidence pool: per-node `consensusBuffer` (in-memory) → `addPendingEvidence` (DB + clist) → gossiped by `broadcastEvidenceRoutine`
- Privval: separate process or in-process, but stores `LastSignState` atomically via `tempfile.WriteFileAtomic` (privval/file.go:412)

### 1.3 BFT environment dimensions (Layer 1 per `bft-analysis.md`)

| Dimension | Value for CometBFT |
|---|---|
| Corruption type | **static** — `Faulty` set fixed; PoS slashing punishes after the fact |
| Network model | **partial-synchronous** (DLS) — timeouts grow each round |
| Computational power | **authenticated** — no signature forgery; honest sigs unforgeable |
| Threshold | **`f < n/3`** — voting-power weighted |

No deviations from default. Static-template adversary applies (not adaptive). Stake-weighted voting power, not flat n/3.

---

## 2. Bug Archaeology Coverage Statistics

| Metric | Count |
|---|---|
| GitHub issues / advisories deeply read (with full comment threads) | 33 |
| Confirmed Byzantine-relevant bugs | 25 |
| Confirmed OPEN | 12 |
| Confirmed FIXED / merged in last 24 months | 13 |
| Security advisories (ASA/CSA/GHSA) consulted | 6 |
| False positives explicitly excluded | 8 |
| Git commits analyzed | 1 commit on `main` (artifact is a shallow clone, single snapshot); GitHub history used in its place |

### 2.1 Confirmed bugs (organized by attack class)

#### A. Equivocation production / detection

| # | Severity | Status | Component | Mechanism |
|---|---|---|---|---|
| **#5435** | High | OPEN | consensus/state.go:2557 | `for i := int64(1); i < doubleSignCheckHeight; i++` — `DoubleSignCheckHeight=1` performs 0 iterations; operators believe protection enabled but aren't. **Verified by direct read at state.go:2557.** |
| **#2353** | High | OPEN | consensus/reactor + evidence | `TestByzantinePrevoteEquivocation` flaky: only 1 of 3 honest validators receives both equivocating Prevotes; consensus reactor drops byzantine Prevotes once peer past prevote step. Equivocation evidence silently not generated. |
| **#1917** | Medium | CLOSED | consensus tests | Pre-cursor of #2353 — flaky byzantine-prevote test indicates real gossip-suppression at prevote level. |
| **CSA-2026-001 "Tachyon"** | Critical | FIXED v0.38.21 / 0.37.18 | consensus state / BFT-Time | Commit-sig vs BFT-Time inconsistency lets ≤1/3 faulty arbitrarily move chain time. |
| **#1309** | Low | CLOSED (log only) | consensus state | Receiving Proposal with `POLRound == LockedRound` but different proposed value: only a log warning was added; no algorithmic guard. Cason: canonical sign of equivocation. |
| **ASA-2024-004** | Low | DOCS | evidence params | Default `EvidenceParams.MaxAgeNumBlocks` / `MaxAgeDuration` may be smaller than chain's unbonding period — equivocation can expire before slashing. |

#### B. Amnesia (lock forgetting across crash)

| # | Severity | Status | Component | Mechanism |
|---|---|---|---|---|
| **legacy tendermint#8739** | High | CLOSED | consensus WAL / PBTS | With PBTS, restart-replayed Prevote becomes "not timely" → privval is asked to sign both non-nil and nil for same (H,R), refuses ("conflicting data"). Caused by `ReceiveTime` not persisted to WAL. Cason acknowledged as amnesia risk. The PBTS path is not in the analyzed branch, but the WAL non-persistence of round state remains. |
| **#3570** | High | FIXED PR#3565 | consensus state / privval | v0.38.6 forgets to disable VE for nil precommit; calls `SignAndCheckVote(extEnabled=true)` after skipping ExtendVote. Privval panics: "extensions must be present IFF non-nil Precommit". |

(See Family 2 below for code-analysis findings: the WAL never persists `LockedRound`/`LockedBlock`/`ValidRound`/`ValidBlock` directly; the privval `CheckHRS` only enforces (H,R,S) monotonicity, not the locking rule.)

#### C. Lunatic / light-client header verification

| # | Severity | Status | Component | Mechanism |
|---|---|---|---|---|
| **#1749** | Med-High | FIXED #1750-1815 | evidence/verify + types/validation | `VerifyCommitLightTrusting` stopped counting signatures once 1/3 threshold reached; malicious >1/3-VP can construct LightClientAttackEvidence with valid sigs up front and unverifiable sigs after — innocent validators get slashed. |
| **#2252** | Medium | OPEN | light/verifier.go | `VerifyAdjacent` doesn't verify `untrustedHeader.LastBlockID == trustedHeader.Hash()`; `VerifyCommitLight` called with untrusted BlockID as "trusted" — check always passes. **Verified by direct read at light/verifier.go:92-131**: line 116 only checks `ValidatorsHash`, no LastBlockID cross-check. |
| **ASA-2024-009** | Medium | FIXED v0.38.12 | light / state-sync | State-sync didn't validate ProposerPriority — malicious snapshot causes proposer-selection split. |
| **legacy #5200** | Medium | CLOSED | evidence | Lunatic-validator evidence didn't take commit's round into account; attacker could forge lunatic evidence from honest validator's prior-round vote. |
| **#1826/#2625** | Low-Med | FIXED #1855 | types/validation | `verifyCommitSingle` / `VerifyCommitLightTrusting` panic on nil pubkey. |
| **#1830** | Medium | OPEN | blocksync/state | Triple signature verification — perf issue, but same code is header attestation surface. |

#### D. Vote extension reuse / replay

| # | Severity | Status | Component | Mechanism |
|---|---|---|---|---|
| **ASA-2024-011** | High | FIXED v0.38.15 | consensus/state | VE precommit-for-non-nil failed to validate `ValidatorIndex` before use; malicious peer panics any node receiving such precommit. |
| **#5204** | High | OPEN | ABCI++ VE | Proposer doesn't self-verify own VE; if proposer's VE fails `VerifyVoteExtension` at others, proposer advances but others loop. With >1/3 invalid VEs, validators re-use same extension across rounds (no re-extension on round change). |
| **#2523 / #2361** | Medium | OPEN (deferred to ABCI 3.0) | consensus state / execution | `PrepareProposal`'s `ExtendedCommitInfo` may contain VEs that were never verified — late precommits added to `LastCommit` after height delivered. |
| **#1253** | Medium | OPEN | consensus WAL | VE size not bounded; serialized vote can exceed 1 MB WAL message limit. |
| **ASA-2024-001** | High | FIXED v0.38.3 | ABCI / consensus param | `VoteExtensionsEnableHeight` governance change crashed v0.38.x. |

#### E. Evidence lifecycle (suppression / injection / race)

| # | Severity | Status | Component | Mechanism |
|---|---|---|---|---|
| **#4114** | High | CLOSED | evidence pool / blocksync | Same `DuplicateVoteEvidence` committed in two consecutive blocks; blocksync rejects second with "evidence was already committed" → permanently unsyncable chain. |
| **#1857** | Medium | OPEN | light/store/db | Single un-prefixed `size` DB key shared across light clients; corrupts counters. |
| **ASA-2024-004** | Low | DOCS | evidence params | (See A above — same evidence has expiry-before-slashing window.) |

#### F. Locking-vs-relock under adversarial proposer interleaving

| # | Severity | Status | Component | Mechanism |
|---|---|---|---|---|
| **ASA-2025-002** | High | FIXED v0.38.17 / v1.0.1 | consensus state / block-part gossip | Validator didn't check `Part.Index == Part.Proof.Index`; Byzantine proposer swaps proofs across parts; nodes re-gossip invalid part, mark correct as received → chain halts. Adjacent to locking — affects whether locked block can be reconstructed. |
| **#1551** | Design defect | UNFIXED | consensus state | Miss to lock/commit on conflicting votes (Tendermint legacy). |

### 2.2 False positives explicitly excluded

- **#1107**, **#773** — Namada / ICS test issues, not CometBFT
- **#4461** — misconfiguration (2 validators, 2/3-vs-1/3 power); Cason rejected
- **#1001** — user error with internal test helper
- **#1823** — different internal bug per reporter
- **#2711** — TMKMS bug, not Comet
- **#4021** — no reproducer; Cason couldn't reproduce
- **#2348** — doc-only
- **#5801** — disputed bypass of ASA-2024-008; vendor downgraded after review

---

## 3. Deep Analysis Findings

### 3.1 Equivocation production & detection lifecycle

**Lifecycle (verified file:line):**

1. **Sign**: `consensus/state.go:2495 signAddVote` → `sendInternalMessage` → `peerMsgQueue`
2. **Peer receive**: `consensus/reactor.go:362-368` `case *VoteMessage` enqueues `peerMsgQueue`. No signature verification at reactor (only `VoteMessage.ValidateBasic` at line 1879 = well-formedness)
3. **Dispatch**: `consensus/state.go:962-965` `tryAddVote`
4. **VoteSet add + sig verify**: `types/vote_set.go:166 voteSet.addVote` → 218-225 `vote.Verify(chainID, val.PubKey)` → 236 `addVerifiedVote` returns `conflicting` non-nil → 238 `NewConflictingVoteError`
5. **Report to evidence pool**: `consensus/state.go:2132-2149 tryAddVote` catches `*ErrVoteConflictingVotes` and calls `cs.evpool.ReportConflictingVotes(voteA, voteB)`
6. **Buffer**: `evidence/pool.go:172-188 ReportConflictingVotes` appends to in-memory `consensusBuffer` — note explicit comment line 180 "Votes are not verified"
7. **Flush at commit**: `evidence/pool.go:107-122 Update(state, ev)` called from `state/execution.go:353` after `ApplyBlock` → `evidence/pool.go:461 processConsensusBuffer` builds `DuplicateVoteEvidence` with the committed block's `LastBlockTime`
8. **Gossip**: `evidence/reactor.go:107-162 broadcastEvidenceRoutine`; `prepareEvidenceMessage` filters by `peerHeight - evHeight > MaxAgeNumBlocks` only (line 192) — **height alone, not the AND-of-both that local validation uses**
9. **Propose**: `consensus/state.go:1321 createProposalBlock` → `state/execution.go:114 CreateProposalBlock` → 129 `evpool.PendingEvidence(MaxBytes)`
10. **Validate proposed block**: `state/execution.go:234 evpool.CheckEvidence` → `evidence/pool.go:208 verify` → `evidence/verify.go:168 VerifyDuplicateVote` (full sig + membership + (h,r,s) match + distinct BlockIDs)
11. **Apply / slash**: `state/execution.go:281-290 proxyApp.FinalizeBlock` with `Misbehavior` — slashing fully delegated to application
12. **Commit**: `evidence/pool.go:330 markEvidenceAsCommitted` moves to committed prefix

**Gaps (verified):**

- **Selective dissemination** (G2): equivocation detection requires both votes to arrive at the *same* node. A Byzantine sending vote A to half, vote B to the other half, never triggers `NewConflictingVoteError` on any single node. `VoteSetBits` reconciliation (`consensus/reactor.go:1611`) exchanges bitmaps, not actual conflicting vote bytes. Cross-node detection is not implemented.
- **`processConsensusBuffer` doesn't re-verify** (G3, verified `pool.go:172-188` "Votes are not verified"): consensus is the local trust boundary. A future refactor that calls `ReportConflictingVotes` with unverified votes feeds them through without verification. Receivers will reject in gossip (V2) but the local-pool would still attempt to include in block.
- **`consensusBuffer` is in-memory only** (G5, `pool.go:49`): a crash between `ReportConflictingVotes` and `Update` loses the buffer entirely. The buffer is flushed only at the next `Update` call. Worse, `pool.go:502-509` *unconditionally drops* votes whose height is `> state.LastBlockHeight` — the comment acknowledges "perhaps consider keeping the votes in the buffer and retry in following heights", but it does not.
- **MaxBytes flood by a Byzantine** (G8): pool ordering is height-ASC, hash-ASC within height. A Byzantine validator can craft many distinct `DuplicateVoteEvidence` records at one height (one per distinct BlockID they sign for) and bias hashes to sort before honest evidence — pushing legitimate evidence past `MaxBytes` in `listEvidence` (line 383). Each piece is itself valid (validator did equivocate). Bounded but real.
- **Sender/receiver expiry disagreement** (G6/9, **verified by direct read**): `evidence/reactor.go:192` filter is *height-only* (`ageNumBlocks > params.MaxAgeNumBlocks`). `evidence/verify.go:309-317 IsEvidenceExpired` is **height AND time** (`ageDuration > MaxAgeDuration && ageNumBlocks > MaxAgeNumBlocks`). In the window where `ageDuration > MaxAgeDuration` but `ageNumBlocks ≤ MaxAgeNumBlocks` (height not expired, time expired), an honest sender broadcasts (the height check at the sender returns "not expired") but the receiver's expiry-and-time check fires → receiver returns error → `evidence/reactor.go:86 StopPeerForError` punishes the honest sender. Confirmed inconsistency.

**Safe paths (verified):**
- `vote.Verify` is called *before* `addVerifiedVote` (V1, vote_set.go:218-225) — fake-signed votes can't make us report another validator
- Gossiped evidence is re-verified in `evidence/pool.go:154` and `evidence/verify.go` (V2)
- Block-evidence-list re-verified at `state/execution.go:234` (V3)
- Committed blocks persist regardless of later evidence (V4)
- A Byzantine cannot suppress its own evidence indefinitely if at least one honest node sees both votes (V5; but G2 shows this premise can fail)

### 3.2 Amnesia / locking state across crashes

**WAL persistence schema (verified):**

The WAL has only four message types (`proto/tendermint/consensus/wal.proto:35-42`):
- `EventDataRoundState` — only `{Height, Round, Step}`
- `MsgInfo` — wraps proposals, votes, block parts
- `TimeoutInfo` — `{Duration, Height, Round, Step}`
- `EndHeight` — `{Height}`

**`LockedRound`, `LockedBlock`, `ValidRound`, `ValidBlock` are NEVER directly persisted.** They are reconstructed only as a side-effect of replaying votes/proposals through `handleMsg`/`handleTimeout` (`replay.go:39-90`).

**Privval state file (verified, `privval/file.go:75-83`):**
```go
type FilePVLastSignState struct {
    Height    int64
    Round     int32
    Step      int8       // 0=none, 1=propose, 2=prevote, 3=precommit
    Signature []byte
    SignBytes []byte
}
```

`CheckHRS` (file.go:100-131, verified): enforces only `(H, R, S)` monotonicity. **It does not track BlockID across rounds at the same height.**

**Amnesia attack scenario (full trace):**

1. At height H, round R1: validator signs precommit for block B. WAL state: `MsgInfo(VoteMessage)` written via `WriteSync` (state.go:851). Privval state: `LastSignState = (H, R1, stepPrecommit, sig_for_B, signBytes_for_B)`.
2. Crash. WAL is corrupted somewhere between EndHeight(H-1) and the precommit record — typical: torn fsync, power loss mid-write.
3. On restart, `State.OnStart` calls `catchupReplay` (replay.go:94-166). WAL decode hits the corrupted entry → `DataCorruptionError`. `state.go:340-374` logs "the WAL file is corrupted; attempting repair" and calls `repairWalFile`.
4. **`repairWalFile` (state.go:2675-2708, verified)** decodes until first error and writes that prefix to a fresh file (`os.Create` overwrites). **The tail after the first error is silently dropped** — even valid records past the corruption point.
5. After repair, replay proceeds on the truncated WAL. The precommit record is gone. `LockedRound` ends as `-1` (default after `updateToState`); `LockedBlock` is `nil`.
6. Validator re-enters round R1 (or moves to R2 > R1). Consensus advances to round R2.
7. `signVote` for precommit at (H, R2) → `CheckHRS(H, R2, stepPrecommit)`: `lss.Height==H`, `lss.Round=R1 < R2`. **Returns `(false, nil)` — no regression detected**. Privval signs new precommit for block B'.
8. Result: this validator has signed conflicting precommits B@R1 and B'@R2 at height H. Externally detectable as equivocation evidence; internally undetected by the privval.

**Verified inline citations:**
- `state.go:735-740`: `updateToState` clears `LockedRound=-1`, `LockedBlock=nil` on every new height (intended: lock is per-height)
- `state.go:851-859`: explicit `fail.Fail() // XXX` between `WriteSync(VoteMessage)` and `handleMsg`. Comment: "Equivalent would be to fail here and manually remove some bytes from the end of the wal."
- `state.go:881-905 writeInternalMsgToWAL`: `VoteMessage`/`ProposalMessage` use `WriteSync` (fsync); `BlockPartMessage` only `Write` (buffered)
- `state.go:2675-2708 repairWalFile`: confirmed silent tail truncation on first decode error
- `wal.go:185-219`: `Write` (buffered) vs `WriteSync` (fsync) split
- `wal.go:367-421 WALDecoder.Decode`: many `DataCorruptionError` paths
- `privval/file.go:100-131 CheckHRS`: only (H,R,S) monotonic, no per-block memory
- `privval/file.go:340-355 SignVote`: same-HRS replay reuses signature if `SignBytes` byte-equal; otherwise "conflicting data" error — but R2 > R1 is not same-HRS, so this defense doesn't apply
- `privval/file.go:412-421 saveSigned`: atomic via `tempfile.WriteFileAtomic`

**Cross-round unlock in `addVote` (state.go:2317-2333, verified):**
```go
if (cs.LockedBlock != nil) &&
    (cs.LockedRound < vote.Round) &&
    (vote.Round <= cs.Round) &&
    !cs.LockedBlock.HashesTo(blockID.Hash) {
    cs.LockedRound = -1
    cs.LockedBlock = nil
}
```
Correct protection — but only **as long as `LockedRound` is correct**. After amnesia (`LockedRound=-1`), the first guard `cs.LockedBlock != nil` is false, so unlock is a no-op (already nothing to unlock).

**`enterPrecommit` paths (state.go:1484-1603, verified):**

Three inlined transitions (not separate functions named "EnterPrecommitRelockPolka" / "EnterPrecommitNewLockPolka" as the brief task statement assumed; those are inline branches):
- **Relock** (1550-1561): `LockedBlock.HashesTo(blockID.Hash)` → bump `LockedRound = round`, precommit same block
- **NewLock** (1563-1582): `ProposalBlock.HashesTo(blockID.Hash)` → overwrite `LockedRound`, `LockedBlock`, precommit proposal
- **Unlock-and-nil** (1584-1602): polka for unknown block → clear lock, fetch block, precommit nil. **This branch unconditionally clears the lock based on a polka in the *current* round** without an explicit `polkaRound > LockedRound` check (relies on implicit semantics that the polka's round matches the current round). After amnesia, `LockedRound=-1` already; no defense.

### 3.3 Lunatic / light-client verifier surfaces

**Proposal signature coverage (`types/canonical.go:42-52`, verified):** signs `{Type, Height, Round, POLRound, BlockID, Timestamp, ChainID}`. The signed payload covers BlockID's hash (which embeds Merkle root of header). A Byzantine proposer chooses header contents (LastBlockID, AppHash, ValidatorsHash, etc.) freely; honest full nodes reject via `state/validation.go:21-170` cross-checks against local `State`. **Light clients do not have this cross-check.**

**`light/verifier.go:VerifyAdjacent` (verified, lines 92-131):**
- Checks `untrustedHeader.ValidatorsHash == trustedHeader.NextValidatorsHash` (line 116) ✓
- Checks 2/3+ of untrustedVals signed (line 125) ✓
- **Does NOT check `untrustedHeader.LastBlockID.Hash == trustedHeader.Hash()`** ✗

**`light/verifier.go:verifyNewHeaderAndVals` (verified, lines 152-191):**
- Only re-hashes `untrustedVals` against `untrustedHeader.ValidatorsHash` (line 182)
- **Does NOT cross-check `LastBlockID`, `LastCommitHash`, `ConsensusHash`, `AppHash`, `NextValidatorsHash` against the trusted header**

This is exactly the surface of issue #2252: a Byzantine majority of the new valset could sign a header at H+1 with `LastBlockID` pointing to a different prior block, and `VerifyAdjacent` would accept it. Documented design: light clients rely on the trust-level assumption (2/3+ honest signers).

**`VerifyCommitLightTrusting`**: previously bugged (#1749) — stopped counting after 1/3 threshold reached, allowing fake sigs past the cutoff. The current code (line 261-404 of `types/validation.go`) iterates the batch, breaks on `talliedVotingPower > votingPowerNeeded`, then calls `bv.Verify()` once at line 365 over the partial batch. Verified to be correct in the current snapshot (the partial batch only contains added sigs; tally is from those added sigs). #1749 is fixed.

**Trust level 1/3 in lunatic evidence verification (`evidence/verify.go:124`):**
`VerifyLightClientAttack`'s lunatic branch uses `light.DefaultTrustLevel = 1/3`. This is intentional per ADR-047 — lunatic evidence by definition has a Byzantine subset that signed a fake header outside the valid valset. Worth flagging in modeling: a lunatic attack requires only 1/3 corroborating signatures, not 2/3.

### 3.4 Vote-extension reuse / replay surfaces

**Signed payload (`types/canonical.go:71-78`, verified):** `CanonicalizeVoteExtension` covers only `{Extension, Height, Round, ChainId}`. **Does NOT include BlockID.**

**Consequence**: a Byzantine validator's VE signature at (H, R) is valid for any precommit they sign at (H, R) regardless of BlockID. Combined with the absence of BlockID binding, two precommits with different BlockIDs at (H, R) — i.e., equivocation — can carry the *same* VE signature. The honest validator's VE is bound to (H, R, ChainID, Ext); a Byzantine signs two votes at (H, R) for different BlockIDs and attaches the same VE to both.

**Verification context in `addVote`:** `consensus/state.go:2262`: `vote.VerifyExtension(cs.state.ChainID, val.PubKey)`. The VE verifier uses `vote.Height` and `vote.Round` from the carrying vote envelope — it cannot independently check that the VE bytes belong to a *different* (H, R) than claimed. Cross-(H,R) replay is blocked by the *vote signature* (which does cover BlockID, hence implicitly height/round), but not by the VE signature itself.

**ABCI `VerifyVoteExtension` round delivery (`proto/tendermint/abci/types.proto:196-203`, `state/execution.go:413-433`):** the ABCI app receives `{Hash, ValidatorAddress, Height, VoteExtension}`. **The round is NOT delivered to the app.** Consequence: an application can never reject a stale-round VE on its own — it must trust CometBFT's (H,R) binding via the vote signature, which is correct only in normal operation.

**`BuildExtendedCommitInfo` (`state/execution.go:609-665`, verified):**
- Per-signature rounds are NOT carried; only `ec.Round` is attached at line 662
- Signatures are NOT re-verified inside; only structural presence check via `ecs.EnsureExtension(extEnabled)` (line 649)
- Trust is inherited from the consensus reactor's prior verification
- Late precommits added to `LastCommit` after height delivered (issue #2361) bypass `VerifyVoteExtension` and surface unverified at the next height's `PrepareProposal`

### 3.5 Evidence lifecycle gaps (refined from §3.1)

**Pool unbounded growth (G2 in §3.1, verified):**
- Block-level cap: `state/validation.go:165` enforces `block.Evidence.ByteSize() ≤ MaxBytes` (default 1 MiB)
- Reactor message cap: `evidence/reactor.go:19 maxMsgSize = 1048576`
- **No in-memory pool cap.** `evidence/pool.go:297-316 addPendingEvidence` does `atomic.AddUint32(&evpool.evidenceSize, 1)` without checking a maximum
- Pruning only at `Update()` when `state.LastBlockHeight > evpool.pruningHeight` (pool.go:129-132)
- A Byzantine with many real conflicting votes from past heights, or many distinct `LightClientAttackEvidence` with different `CommonHeight`s, can push large numbers of *individually valid* records. Per-block iteration is O(n) in `listEvidence` (pool.go:362-403)

**Sender/receiver expiry disagreement (G6/9, **verified by direct reads**):**
- Sender broadcast filter: `evidence/reactor.go:192 if ageNumBlocks > params.MaxAgeNumBlocks` — height only
- Receiver `IsEvidenceExpired` (`evidence/verify.go:313`): `ageDuration > MaxAgeDuration && ageNumBlocks > MaxAgeNumBlocks` — AND of both
- Window: `ageDuration > MaxAgeDuration` but `ageNumBlocks ≤ MaxAgeNumBlocks` (slow chain) → sender broadcasts, receiver rejects, sender gets banned via `StopPeerForError`. **Honest peer punished.**

**Combined-AND expiry semantics (verified):** A halted chain (network partition, BFT stall) cannot expire evidence merely by waiting — both height and time must elapse. Conversely, a very fast chain can keep evidence valid through real-time even after `MaxAgeNumBlocks` blocks have produced, until `MaxAgeDuration` elapses.

**`ABCI Misbehavior` is application-defined slashing (state/execution.go:281-290):** CometBFT never reduces stake on its own. If the application's `FinalizeBlock` ignores `Misbehavior`, evidence is committed on-chain (via merkle root in `Block.Evidence`) but no slashing occurs.

**Cross-validator dissemination has no acknowledgment:** `evidence/reactor.go:107-162 broadcastEvidenceRoutine` gossips every 10s per peer with no QoS. A partitioned proposer with evidence still includes it; receivers pull via `CheckEvidence`. But if multiple consecutive proposers don't have the evidence (or are Byzantine and exclude it), it can expire silently.

### 3.6 Round-state transitions under adversarial proposer interleaving

Already covered in §3.2 (`enterPrecommit` three-branch analysis). Additional observation:

**`defaultDoPrevote` (state.go:1387-1444, verified):**
- If locked, prevotes the locked block regardless of proposer's offering (line 1422-1430)
- If `validBlock` exists, prevotes the validBlock (line 1432)
- Otherwise prevotes the proposal block (line 1440)

A Byzantine proposer can craft different proposals at adjacent rounds. The locking rule says: validator should prevote nil for any block ≠ locked at the current round, until a +2/3 polka for the proposal block is observed in a round > LockedRound. The implementation enforces this *if* `LockedBlock` is set — but after amnesia, `LockedBlock = nil`, and the validator simply prevotes whatever the Byzantine proposer offers.

**`POLRound` validation (proposal.go:59-61, verified in round 1):** `POLRound ≥ Round` passes `ValidateBasic`. This is a known weak validation; the protocol-level check is in `enterPrecommit` where `polkaRound = POLRound` is used to compute the polka set. A Byzantine proposer with `POLRound = Round` (same round) confuses the locking decision since the polka is supposedly in the current round.

---

## 4. Cross-Cutting Observations

### 4.1 Architectural seams that compose Byzantine attacks

| Seam | Composes |
|------|----------|
| WAL non-persistence of `LockedBlock/Round` × `repairWalFile` silent tail truncation × privval `CheckHRS` only (H,R,S) | Amnesia × Crash (2.6 × 5.1) |
| Selective dissemination of conflicting votes × evidence reactor only-after-local-detection | Equivocation × Selective Dissemination (2.1 × 2.4) |
| VE signed bytes lack BlockID × VE round not delivered to ABCI app × `BuildExtendedCommitInfo` doesn't re-verify VE sigs | VE Reuse × Invalid Content (2.5 × 2.2) |
| Light-client `VerifyAdjacent` lacks `LastBlockID` cross-check × Byzantine majority of new valset can sign forked header | Lunatic (2.2 + 2.7) |
| Sender broadcast filter height-only vs receiver expiry height-AND-time | Evidence Lifecycle (2.8) |
| `consensusBuffer` in-memory only × `processConsensusBuffer` drops votes for future heights × crash window | Evidence Lifecycle × Crash (2.8 × 5.1) |
| `EvidenceParams.MaxAgeNumBlocks` may be < unbonding period | Evidence expiry × Stake slashing (2.8) |

### 4.2 What the round-1 brief modeled vs. what this round adds

| Round 1 (already modeled) | Round 2 (new modeling targets) |
|---|---|
| Crash + WAL replay | Amnesia *as a Byzantine action*: validator chooses to forget LockedBlock and sign conflicting precommit |
| Invalid VE injection (#5204 narrow) | VE replay/reuse: cross-(H,R) reuse blocked by vote-sig binding, but ExtendedCommitInfo doesn't re-verify; unverified late precommits in `LastCommit` |
| Nil-precommit advance under timeout (#1431) | Locking-vs-relock transitions under Byzantine proposer interleaving + amnesia |
| `DetectEquivocation` as reactive sink | Equivocation as Byzantine action that *produces* conflicting precommits; selective dissemination evades detection |
| Evidence lifecycle (basic detect→pending→commit) | Byzantine withholds, injects invalid evidence, gossips with broadcast/verify expiry disagreement; lunatic LightClientAttack at 1/3 trust |
| n/a | Lunatic header at light-client verifier (LastBlockID/AppHash/NextValidatorsHash not cross-checked in `VerifyAdjacent`) |

---

## 5. Findings Summary

Detailed findings synthesized into Bug Families in the modeling brief. The key novel claims from this round:

1. **Privval `CheckHRS` does not enforce the locking rule across rounds at the same height.** A precommit at (H, R1) followed by a precommit at (H, R2 > R1) for a different BlockID passes the privval check. **Verified by direct read** at `privval/file.go:100-131`.

2. **WAL `repairWalFile` silently truncates the tail at the first decode error.** Combined with `LockedBlock`/`LockedRound` not being directly persisted, a corrupted WAL forces re-derivation that may drop locking state. **Verified** at `state.go:2675-2708`.

3. **Vote-extension signed bytes do not include BlockID.** A Byzantine can attach the same VE signature to two conflicting precommits at (H, R). **Verified** at `types/canonical.go:71-78`.

4. **Light-client `VerifyAdjacent` does not cross-check `LastBlockID` between trusted and untrusted headers.** Issue #2252; documented gap. **Verified** at `light/verifier.go:92-131`.

5. **Evidence broadcast filter and verification filter disagree.** Sender filters by height only; receiver filters by AND-of-height-and-time. Honest sender can be banned by receiver. **Verified** at `evidence/reactor.go:192` and `evidence/verify.go:313`.

6. **`consensusBuffer` is purely in-memory and is unconditionally dropped/reset at each Update.** Equivocation evidence has no durability guarantee across crashes. **Verified** at `evidence/pool.go:49,538`.

7. **`ABCI VerifyVoteExtension` does not receive the round.** The application cannot reject stale-round VEs even if it wanted to. **Verified** at `proto/tendermint/abci/types.proto:196-203`.

8. **`DoubleSignCheckHeight=1` produces zero iterations** (issue #5435). **Verified** at `state.go:2557` — `for i := int64(1); i < 1` is empty.

---

## 6. Coverage Statistics

| Phase | Activity | Count |
|---|---|---|
| Reconnaissance | Core files mapped | 14 |
| Bug Archaeology | GitHub issues / advisories deeply read (full comments) | 33 |
| Bug Archaeology | Confirmed Byzantine-relevant bugs | 25 |
| Bug Archaeology | OPEN (unfixed) | 12 |
| Bug Archaeology | FIXED (with merged PR) | 13 |
| Bug Archaeology | False positives explicitly excluded | 8 |
| Deep Analysis | Parallel subagents launched | 5 (1 issue-mining, 4 file-analysis) |
| Deep Analysis | Total findings (gaps + safe + suspect) | 32 across the 4 file-analysis agents |
| Deep Analysis | Spot-verified by direct re-read | 8 critical claims (broadcast gate, expiry semantics, repairWalFile, CheckHRS, canonical VE bytes, VerifyAdjacent, doubleSignCheck loop, enterPrecommit branches) |

---

## 7. References

- **Round 1 brief**: `case-studies/cometbft/modeling-brief.md` (sister directory)
- **CometBFT GitHub**: `cometbft/cometbft` (and legacy `tendermint/tendermint`)
- **Security advisories**: ASA-2024-001, -004, -008, -009, -011; ASA-2025-002; CSA-2026-001 (Tachyon)
- **Reference papers**:
  - Buchman, Kwon, Milosevic 2018 — Tendermint BFT (arXiv:1807.04938)
  - Cason, Milosevic 2022 — *Toward a unified theory of fork accountability for BFT consensus* (ADR-047 source)
  - Castro, Liskov 1999 — PBFT (authenticated computational model)
- **Reference TLA+ specs**: Informal Systems' Tendermint TLA+; existing `case-studies/cometbft/spec/base.tla` reactive `DetectEquivocation`
