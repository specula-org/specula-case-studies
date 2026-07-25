# Modeling Brief: babylonlabs-io/babylon (x/finality, x/btcstaking, x/btccheckpoint, x/checkpointing)

## 1. System Overview

- **System**: `babylonlabs-io/babylon` — Bitcoin-secured Proof-of-Stake chain built on Cosmos-SDK + CometBFT. Mainnet launched April 2025 with BTC staking activated.
- **Language**: Go, **~22,500 LOC** of core (non-generated, non-test) code across the four target modules: `x/finality` (6.6k), `x/btcstaking` (9.0k), `x/btccheckpoint` (2.9k), `x/checkpointing` (4.1k). Repo head analyzed: commit `d96cd9d` (v4.x).
- **System Category**: **Category A (Distributed / Message-Passing) + BFT overlay + cross-chain trust boundary**.
  - Babylon validator set runs Tendermint/CometBFT consensus (`n ≥ 3f+1`, partial synchrony, authenticated). Threat model: Byzantine adversary controls up to `f` Babylon validators.
  - BTC chain is modeled as a **slow trusted external oracle** delivering `(height, header)` tuples eventually; reorgs ≤ `BtcConfirmationDepth` (k = 10) are expected, reorgs ≥ `CheckpointFinalizationTimeout` (w = 100) halt the chain by design.
  - Cosmos SDK base + CometBFT consensus itself are treated as abstract — scope is only the layers Babylon introduces.
- **Protocols implemented (Babylon-introduced layers)**:
  - **EOTS finality**: finality providers (FPs) sign blocks with Extractable One-Time Signatures over per-height pre-committed pub-randomness. Double-signing two distinct `(height, hash)` pairs under the same pub-rand mathematically reveals the FP's BTC secret key.
  - **Schnorr adaptor signatures for BTC slashing**: covenant committee pre-signs a "slashing tx" adapted to each FP's pub-rand; on detected double-sign, the revealed SK decrypts the adaptor signature, allowing anyone to spend the staking UTXO to the slashing address.
  - **BTC-timestamping checkpoints**: per-epoch BLS multi-sig sealing of validator set + last block hash, embedded into BTC via OP_RETURN; `Submitted → Confirmed (k-deep) → Finalized (w-deep)` lifecycle, with `Forgotten` rollback when ancestry breaks.
- **Concurrency model**: Single-threaded Cosmos-SDK tx execution per block; `BeginBlocker`/`EndBlocker` runs sequentially. The interesting parallelism is **between modules within the same block** (one tx can mutate state read by a later tx) and **across blocks** (event-deferred processing in `x/finality/keeper/power_dist_change.go`).
- **Key architectural choices that matter for modeling**:
  - **Three concurrent state machines** for a BTC delegation: the on-Babylon `BTCDelegationStatus` (PENDING/VERIFIED/ACTIVE/UNBONDED/EXPIRED), the FP's `IsSlashed`/`Jailed`/`HighestVotedHeight` flags, and the on-BTC tx state (mempool/confirmed/reorged). Power-distribution events are buffered per BTC-tip height and applied in `EndBlock` only after BTC light client tip advances.
  - **Evidence is keyed by `(FpBtcPk, height)`** — at most one evidence record per (FP, height); a second fork vote overwrites the first.
  - **Intent-based undelegation** (`x/btcstaking/keeper/msg_server.go:521-681`): once staker signals unbonding, the delegation is permanently UNBONDED on Babylon regardless of BTC reorgs shallower than `k`.
  - **Vote extension BLS aggregation** (`x/checkpointing/prepare/proposal.go`): proposer aggregates per-validator BLS signatures from CometBFT vote extensions of the *last block of an epoch* into a `MsgInjectedCheckpoint` placed at `txs[0]` of the *first block of the next epoch*; the proposer also *prunes* invalid extensions from the committed `ExtendedCommitInfo`.
  - **Hard-coded `CheckpointFinalizationTimeout` immutability** (`x/btccheckpoint/keeper/msg_server.go:127-131`) — even governance cannot change `w`.

## 2. Bug Families

### Family 1: EOTS evidence lifecycle and retroactive pub-rand commits (HIGH)

**Mechanism**: The slashing primitive depends on a *strict precommitment* property: an FP must commit pub-randomness *before* the block heights it will vote on are produced. The implementation enforces strict-monotonicity between commits (`StartHeight > lastCommit.EndHeight()`), but **does not enforce that `StartHeight > currentBlockHeight`**. An FP can therefore commit pub-rand for already-produced heights, then vote on them with full knowledge of the canonical block hash — a free reward with no slashing risk. Secondary issue: `(FpBtcPk, height)`-keyed evidence silently overwrites a prior fork vote with a newer fork vote, losing the original `ForkFinalitySig`.

**Evidence**:
- Historical: PR #1994 (open) "fix(finality): reject retroactive public randomness commitments" — exact patch for issue #1984 (still unmerged in `d96cd9d`).
- Historical: Issue #1253 closed — `MsgEquivocationEvidence` lacked validation; PR #1271 added it.
- Historical: PR #186 (#174) — `MsgAddFinalityVote` panicked on nil proof; fixed with nil guard.
- Code analysis: `x/finality/keeper/msg_server.go:251-253` — only upper bound `StartHeight < currentHeight + MaxPubRandCommitOffset` is checked; lower bound is missing.
- Code analysis: `x/finality/keeper/msg_server.go:152-218` — fork branch never writes to vote DB (`SetSig`), only to evidence; second fork vote at same height overwrites first evidence in `x/finality/keeper/evidence.go:13-16`. Verdict: safe (latest fork sig is still slashable with later canonical sig) but **the evidence DB loses historical fork sigs**.
- Code analysis: `x/finality/types/finality.go:226-250` — `IsSlashable()` requires `CanonicalFinalitySig != nil`; half-evidence (fork-only) is never auto-slashable, even though two distinct fork sigs at the same height already mathematically reveal the SK.

**Affected code paths**:
- `CommitPubRandList` (`msg_server.go:242-321`)
- `AddFinalitySig` (`msg_server.go:62-227`)
- `SetEvidence`/`GetFirstSlashableEvidence` (`x/finality/keeper/evidence.go`)
- `Evidence.IsSlashable` / `Evidence.ExtractBTCSK` (`x/finality/types/finality.go:226-250`)

**Suggested modeling approach**:
- Variables: `pubRandCommits[fp] : Seq([startHeight, endHeight, commitment])`, `evidenceMap[(fp, height)] : Evidence`, `sigStore[(height, fp)] : finalitySig`, `currentHeight`.
- Actions: `CommitPubRand(fp, startHeight, num)` with guard `startHeight > lastCommit.endHeight ∧ startHeight > currentHeight`; introduce a *broken* variant `CommitPubRandRetroactive` with only the first guard to exhibit the bug. Split `AddFinalitySig` into `VoteCanonical`, `VoteFork`, `VoteForkOverridingPriorEvidence` to expose evidence overwriting.
- Granularity: evidence write + slash attempt must be atomic within a single action; do NOT split.

**Priority**: **HIGH**.
**Rationale**: Issue #1984 (still unfixed in mainline) directly breaks the precommitment property the entire scheme rests on. Modeling captures both #1984 and the closed-but-illustrative #1253 / #174 evidence-validation family.

---

### Family 2: Liveness/jailing bypass via active-status toggling (HIGH)

**Mechanism**: When an FP transitions from inactive → active, `HandleActivatedFinalityProvider` resets `signInfo.StartHeight` to the current Babylon height but does **NOT** reset `MissedBlocksCounter` or clear the missed-block bitmap. Jailing requires `height > StartHeight + signedBlocksWindow` AND `MissedBlocksCounter > maxMissed`. After re-activation, the first condition is false for a full window. Worse, the modular index `(height - StartHeight) % signedBlocksWindow` reuses the OLD bitmap slots — old miss bits silently shield the FP from new counter increments at the same modular positions. An FP that can briefly toggle active state at sliding-window boundaries (e.g., via delegator churn) gets indefinite jail-shield.

**Evidence**:
- Historical: Issue #1852 (open, security label, Immunefi #56201) — exact issue.
- Historical: PR #324 "Decrementing jailed fp counter" — earlier fix for adjacent counter logic; bug-prone area.
- Historical: PR #620 "JailUntil is not reset after unjailing" — additional liveness-state-machine bug history.
- Code analysis: `x/finality/keeper/liveness.go:79-104, 149-186` and `x/finality/keeper/power_dist_change.go:186-203` (`HandleActivatedFinalityProvider` does not call `ResetMissedBlocksCounter`).
- Code analysis: `x/finality/types/signing_info.go:39-41` — `ResetMissedBlocksCounter` exists but is never invoked from any keeper code (verified by grep).
- Code analysis: `x/finality/keeper/liveness_test.go:230-294` — test deliberately documents the non-reset behavior, asserting `MissedBlocksCounter` stays at 1 after `HandleActivatedFinalityProvider`.

**Affected code paths**:
- `HandleLiveness` / `HandleFinalityProviderLiveness` / `UpdateSigningInfo` (`liveness.go`)
- `HandleActivatedFinalityProvider` (`power_dist_change.go:186-203`)
- `ProcessAllPowerDistUpdateEvents` (`power_dist_change.go:241-...`)

**Suggested modeling approach**:
- Variables: `signingInfo[fp] : {startHeight, missedCounter, jailedUntil}`, `missedBitmap[fp] : BitSet`, `vpActive[height, fp] : Bool` (whether FP is in active set at that height).
- Actions: `ActivateFp(fp)`, `DeactivateFp(fp)`, `RecordVote(fp, height, didSign)`, `JailIfThresholdReached(fp, height)`. The bug is exhibited by an FP that alternates `ActivateFp`/`DeactivateFp` around the jailing-window boundary.
- Invariant: *eventually any persistently non-voting FP is jailed* (liveness property).

**Priority**: **HIGH**.
**Rationale**: Open security-label issue with no fix yet; the mechanism is a clean state-machine invariant; FP economic accountability depends on this primitive.

---

### Family 3: Checkpoint lifecycle FSM + BTC reorg coupling (HIGH)

**Mechanism**: Two interacting FSMs share state without a single source of truth:
- `x/btccheckpoint`: per-epoch `EpochData.Status` ∈ {Submitted, Confirmed, Finalized}; transitions driven by `OnTipChange` → `checkCheckpoints`.
- `x/checkpointing`: per-epoch `RawCheckpointWithMeta.Status` ∈ {Accumulating, Sealed, Submitted, Confirmed, Finalized, Forgotten}; transitions driven by the BTC module via hook callbacks (`SetCheckpointSubmitted`, …, `SetCheckpointForgotten`).
The cleanup cascade for an epoch whose BTC parent loses ancestry depends on the iteration "single-pass parent-then-child" property: `clearEpochData(parent)` writes empty `Keys`, then the next iteration step visits the child with `parentEpochInfo.bestSubmission == nil` and clears the child. If iteration *breaks* (line 327-331 `if len(currentEpoch.Keys) == 0 { break }`) before the child, the child sits as `Submitted` forever with no recovery path. Reorgs deeper than `CheckpointFinalizationTimeout = w` invalidate previously-Finalized epochs and trigger the deterministic panic at `x/btccheckpoint/keeper/keeper.go:343` — chain halt by design.

**Evidence**:
- Historical: PR #1908 "fix: call AfterRawCheckpointForgotten in all hooks, instead of early return" (commit `c5e5a5b3`) — multi-hook bug where Monitor.removeCheckpointRecord was silently dropped during checkpoint forget.
- Historical: PR #1136 / #1159 "fix(btccheckpoint): update submission dup validation".
- Historical: PR #287 "Fix vulnerability when processing bls sig transactions" — added LastCommitHash binding for BLS sigs (legacy pre-vote-extension flow; not directly relevant to current architecture but illustrative).
- Historical: PR #842 "Properly wire btclightclient hook for btcstaking to panic in case of a BTC reorg larger than BtcConfirmationDepth" — confirms the chain-halt path on large reorg.
- Historical: PR #695 / #715 "Improve checkpoint panicking behavior".
- Code analysis: `x/btccheckpoint/keeper/keeper.go:304-426` (`checkCheckpoints`) — iteration logic.
- Code analysis: `x/btccheckpoint/keeper/keeper.go:333-351` — `Finalized` epoch losing main-chain ancestry panics with `"Finalized epoch submission must be on main chain"`.
- Code analysis: `x/checkpointing/keeper/keeper.go:296-381` — five-state FSM with `validateCheckpointStatus` gate.

**Affected code paths**:
- `checkCheckpoints` (`x/btccheckpoint/keeper/keeper.go:304-426`)
- `getEpochChanges` / `addEpochSubmission` / `clearEpochData` (`submissions.go`)
- `setCheckpointStatus` and the `SetCheckpoint{Submitted,Confirmed,Finalized,Forgotten}` callers (`x/checkpointing/keeper/keeper.go:296-410`)
- `HaltIfBtcReorgLargerThanConfirmationDepth` (`x/btcstaking/keeper/btc_reorg.go:13-29`)

**Suggested modeling approach**:
- Variables: `epochs[e] : {status, keys : Seq(SubmissionKey)}`, `ckpt[e] : LocalStatus`, `btcChain : Seq(Header)`, `btcLightClientTip : Height`, `lastFinalizedEpoch : Nat`.
- Actions: `SubmitBTCProof(e, key)`, `BtcLightClientAdvance(newTip)`, `BtcReorg(rollbackTo, newTip)` (depth ≤ k vs > k branches), `CheckCheckpointsLoop` as one atomic EndBlock action that walks epochs and emits hook calls.
- Invariants: (a) `ckpt[e].status = Finalized` ⇒ epoch `e` has exactly one submission key, and that submission's BTC headers are on main chain (else panic = halt). (b) Hook firing order matches state transitions: `Submitted → Confirmed → Finalized` monotonically per epoch. (c) `LastFinalizedEpoch` is monotonically non-decreasing. (d) After `Forgotten`, the child epoch is also Forgotten within bounded delay.

**Priority**: **HIGH**.
**Rationale**: Cross-chain trust boundary lives here; the entire safety argument for BTC-timestamping rests on correct lifecycle transitions plus the `w`-depth assumption. Multiple historical bugs in hook ordering (#1908) and reorg wiring (#842). The chain-halt-on-conflict primitive is a strong but blunt instrument worth verifying.

---

### Family 4: Vote-extension aggregation and proposer trust (MEDIUM-HIGH)

**Mechanism**: The BLS multi-sig sealing a Babylon epoch is assembled by the *proposer of the first block of the next epoch* from CometBFT vote extensions of the *last block of the previous epoch*. Two trust gradients coexist:
- **CometBFT layer** (`x/checkpointing/vote_extensions/vote_ext.go::VerifyVoteExtension`): runs on every validator during gossip, decides whether to accept a peer's vote extension into precommit.
- **Proposer layer** (`x/checkpointing/prepare/proposal.go::VerifyVoteExtension`): runs only on the proposer when building the injected checkpoint tx, and on validators when re-verifying the proposal.

Historically the proposer layer has been the locus of multiple security advisories: GHSA-m6wq-66p2-c8pc (nil block hash), GHSA-2fcv-qww3-9v6h (unknown protobuf fields), and PR #1923 (#1923 → `dead25d5`, `MaxVoteExtensionSize = 1024`). The CometBFT layer **still lacks** the size cap / `RejectUnknownFieldsStrict` / round-trip-marshal checks that the proposer layer applies — a malicious validator can broadcast oversized vote extensions during gossip even if they ultimately get pruned by the proposer. A separate developer TODO at `proposal.go:459-461` notes "this indicates the existence of a fork (>1/3 malicious voting power) and we should probably send an alarm and stall the blockchain" but the current code only rejects the proposal (next-round proposer retries).

**Evidence**:
- Historical: PR `9c52e24a` (Dec 2025) "nil block hash check in vote extension" — `ve.Validate()` added in both layers; `bytes.Equal` replaced `*BlockHash.Equal`.
- Historical: PR `953724e5` (Nov 2025) "unknown fields check on vote extension validation" — `unknownproto.RejectUnknownFieldsStrict` added in proposer layer only.
- Historical: PR `d0b75cfe` (Jul 2025) — major refactor splitting `getValidBlsSigs` (read-only) from `getValidBlsSigsAndPruneCommitInfo` (proposer-mutating); ProcessProposal validators see pre-pruned commit info.
- Historical: PR #1911 (commit `97d56bc6`) "avoid panic in ProcessProposal when injected checkpoint tx contains a wrong message type".
- Historical: PR `dead25d5` (Mar 2026) "vote extension max size" — proposer-layer 1KB cap.
- Code analysis: `x/checkpointing/vote_extensions/vote_ext.go:108-185` — receiver-side validation is shorter than `x/checkpointing/prepare/proposal.go:222-284`; comparison shows the missing defenses.
- Code analysis: `x/checkpointing/prepare/proposal.go:459-467` — TODO and reject-only behavior.

**Affected code paths**:
- `VoteExtensionHandler.VerifyVoteExtension` (`vote_ext.go:108-185`)
- `ProposalHandler.VerifyVoteExtension` / `PrepareProposal` / `ProcessProposal` / `PreBlocker` (`proposal.go`)
- `buildCheckpointFromVoteExtensions` + `findLastBlockHash` (`proposal.go`)

**Suggested modeling approach**:
- Variables: `voteExt[h, v] : VoteExtension ∪ {Invalid}`, `injectedCkpt[h] : Checkpoint ∪ ⊥`, `localCkpt[e] : Checkpoint`, `Faulty ⊆ Validators` (Byzantine identity set).
- Actions: `ExtendVote(v, h)` (honest), `ByzantineExtendVote(v, h, payload)` (with selectable variants: wrong epoch, wrong block hash, oversize payload, bad signer), `Propose(p, h)` (combines vote extensions into injected tx, applies pruning if proposer is honest), `ByzantinePropose(p, h)` (proposer drops valid sigs or inserts invalid ones), `ProcessProposal(v, h)` (rebuilds and compares).
- Invariants: (a) If `injectedCkpt[h]` is committed, then `localCkpt[epoch(h)]` equals it. (b) No two distinct injected checkpoints for the same epoch ever both reach `Sealed` (modulo the documented "conflict halt" path). (c) If `≥ 2f+1` honest validators see the same `BlockHash` in their `findLastBlockHash` tally, the proposer's choice matches.

**Priority**: **MEDIUM-HIGH**.
**Rationale**: 4+ security advisories in the past year; the cross-validator BLS aggregation is a unique Babylon extension to standard BFT and not covered by upstream CometBFT specs. Receiver-side gap (CometBFT layer missing defenses) is a clear hardening item, not a model-checking target — but the *consistency* between PrepareProposal and ProcessProposal under Byzantine proposer **is** a model-checking target.

---

### Family 5: Power-distribution event ordering and slash-vs-jail composition (MEDIUM)

**Mechanism**: BTC delegation lifecycle events (`ACTIVE`, `EXPIRED`, `UNBONDED`) and FP state events (`SLASHED`, `JAILED`, `UNJAILED`) are buffered per BTC-tip-height in `EventPowerDistUpdate` records, then consumed in `ProcessAllPowerDistUpdateEvents` per `BeginBlock`. Within one BTC height, JAILED/UNJAILED events apply *immediately* during the per-height pass, while SLASHED events are deferred into `state.SlashedEvents` and applied *after* all per-height events in `processSlashedEvents`. This explicit ordering ensures SLASHED dominates: a slashed-jailed FP correctly has zero voting power. The mechanism is correct as long as:
- No code path calls `SlashFinalityProvider` twice in one block on the same FP (would panic — `slashFinalityProvider` wrapper in `x/finality/keeper/msg_server.go:373-384` panics on any error).
- No code path calls `JailFinalityProvider` after `SlashFinalityProvider` (would `ErrFpAlreadySlashed` — the guard at `x/btcstaking/keeper/finality_providers.go:193-200` blocks it).
- Multi-level stake expansion + same-block slashing: caught by `validateStakedFPs` rereading FP from store before each `CreateBTCDelegation`.

**Evidence**:
- Historical: PR #1813 commit `18f69ed1` "fix: add error and panic if there is any issue on removing delta sats" (Audit V4-CORE-008) — `ChangeDeltaSats` was silently producing wrong totals; now panics on negative-going-below-zero.
- Historical: PR #1805 commit `3eefafe9` "fix: nondeterminism incentives IterateBTCDelegationSatsUpdated" — sort.Strings added for deterministic iteration.
- Historical: PR #342 commit `ccc00b73` "Non-determinism while jailing" — map-iteration → `GetVotingPowerTableOrdered`.
- Historical: PR #180 commit `58e13f06` "Non-determinism in sorting finality providers in the voting power table".
- Historical: PR #1875 commit `292b5d49` "ensure soft-deleted FPs cannot receive new/extended BTC stake, or commit pub rand".
- Code analysis: `x/finality/keeper/power_dist_change.go:241-...` (consumer), `:464-478` (`processSlashedEvents`).
- Code analysis: `x/btcstaking/keeper/finality_providers.go:151-218` (slash/jail/unjail).
- Code analysis: `x/finality/keeper/msg_server.go:373-384` — `panic`-on-error wrapper.

**Affected code paths**:
- `ProcessAllPowerDistUpdateEvents` (`x/finality/keeper/power_dist_change.go`)
- `processInactiveFp` / `processSlashedEvents`
- `BTCStakingKeeper.{Slash,Jail,Unjail}FinalityProvider` (`x/btcstaking/keeper/finality_providers.go`)
- `CreateBTCDelegation` / `BtcStakeExpand` / `validateStakedFPs` (`x/btcstaking/keeper/{btc_delegations,msg_server}.go`)

**Suggested modeling approach**:
- Variables: `fpFlags[fp] : {slashed, jailed}`, `pendingEvents[btcHeight] : Seq(Event)`, `delegations[txHash] : {fp, status, params, sats}`, `votingPowerCache[height, fp] : Nat`.
- Actions: `EmitEvent(btcHeight, evt)`, `ProcessHeight(h)` — applies all pendingEvents[h] in order: ACTIVE/EXPIRED/UNBONDED first, JAILED/UNJAILED next, SLASHED last.
- Invariants: (a) Slashed FP always has voting power 0 in cache. (b) JAILED then UNJAILED in same block is a no-op for voting power (after consumer runs). (c) Stake expansion never activates an expansion of a slashed FP within the same block where the slash occurs.

**Priority**: **MEDIUM**.
**Rationale**: Determinism class is well-stocked with historical bugs (#342, #180, #1805); the SLASHED-dominates ordering is correctly implemented but the panic-on-error wrapper could mask a latent regression. Modeling this clarifies the event-deferral semantics that are hard to follow in the imperative code.

---

### Family 6: Governance and rewarding catch-up liveness (LOW for safety, MEDIUM for completeness)

**Mechanism**: Several adjacent gov / rewarding flows have known liveness issues:
- `MsgResumeFinalityProposal` (Issue #1979) compares user-supplied raw hex against `BIP340PubKey.MarshalHex()` results without case normalization — mixed-case hex bypasses voter cleanup.
- `MsgResumeFinalityProposal` listing all active FPs (Issue #950) zeroes the voting-power table at halting-height, producing a chain that cannot meet quorum.
- `HandleRewarding` (Issue #938) gets permanently stuck if `MaxFinalizedRewardedBlocksPerEndBlock = 10000` finalized-but-not-rewarded blocks accumulate (e.g., after a zero-VP episode); the per-EndBlock processing bound never catches up.

**Evidence**:
- Historical: Issue #1979 (open, Cantina BABY-2).
- Historical: Issue #950 (open, originally closed and reopened).
- Historical: Issue #938 (open, no fix yet).
- Historical: PR #992 (commit `6681f30e`) "fix: resume fp halt height" — earlier patch in same area.
- Historical: PR #829 (`9da1dfea`) "add checks for slashed fp in gov resume finality".
- Code analysis: `x/finality/keeper/gov.go:37-157` and `x/finality/keeper/rewarding.go:35`.

**Affected code paths**:
- `HandleResumeFinalityProposal` (`gov.go`)
- `HandleRewarding` (`rewarding.go`)
- `tally` / `TallyBlocks` (`tallying.go`)

**Priority**: **LOW for TLA+ modeling** (these are mostly liveness/parameter-space concerns and hex normalization is implementation-only).
**Rationale**: Worth a fairness assumption in the spec ("if FPs have power and submit votes, blocks finalize within bounded time") but not the core target.

---

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Pub-rand commit lifecycle with `currentHeight` lower bound | Family 1 (#1984 open bug) | `pubRandCommits[fp] : Seq`; `CommitPubRand` guard includes `startHeight > currentHeight`; provide a "broken" variant `CommitPubRandRetroactive` that omits this guard, to exhibit the bug |
| EOTS evidence FSM with overwrite | Family 1 (closed #1253 and current behaviour) | `evidenceMap[(fp, h)] : Evidence`; actions `VoteCanonical`, `VoteFork`; second fork at same (fp, h) overwrites; `Slash` triggered iff `IsSlashable` (canonical+fork both set) |
| Liveness/jailing FSM with bitmap | Family 2 (#1852 open bug) | `signingInfo[fp]`, `missedBitmap[fp]`; transitions on `ActivateFp`/`DeactivateFp`/`RecordVote`; jailing rule with `StartHeight + window` |
| Checkpoint lifecycle FSM (both modules) | Family 3 | `epochs[e].status` (BTC-side) + `ckpt[e].status` (local) with hook actions linking them; `BtcReorg` action with two depth tiers |
| Vote-extension aggregation + proposer pruning | Family 4 | `voteExt[h,v]`, `injectedCkpt[h]`; `Propose` (honest), `ByzantinePropose` (drops/inserts sigs); ProcessProposal rebuilds and compares; conflict-halt invariant |
| Power-dist event ordering | Family 5 | `pendingEvents[btcHeight]`; `ProcessHeight` applies ACTIVE/UNBONDED/JAILED first, SLASHED last; multi-tx-per-block scenarios for slash-vs-expand race |
| Cross-chain BTC oracle | All families | `btcChain` as a sequence with `BtcLightClientAdvance` and `BtcReorg(depth)`; reorgs deeper than `w` trigger fail-stop action |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| **CometBFT block-production** | Mature, abstract it: assume CometBFT delivers (height, hash) tuples |
| **Stock Cosmos SDK modules** (`x/staking`, `x/distribution`, `x/gov`) | Not in scope; treat as oracles invoked via hooks |
| **BLS-12-381 cryptographic primitive details** | Authentication axiom: honest signatures unforgeable; aggregations correct over correctly-bitmapped signers |
| **Schnorr/EOTS cryptographic primitive details** | Authentication axiom: two distinct messages signed under same nonce reveal SK (model as a `MathExtract(sigs)` operator); do not model curve arithmetic |
| **Adaptor signature cryptographic primitive details** | Treat as: `EncSign(msg, encKey)` produces sig such that `Decrypt(sig, sk) = ValidSchnorrSig(msg)` iff `pk(sk) = encKey`. Receiver-side verification predicate is the bug surface, not the math. |
| **BIP-322 / BIP-340 signature parsing canonicality** | Issue #1853 — implementation/parsing-level, no protocol effect at the abstraction level we want |
| **Hex normalization in gov proposals** | Issue #1979 — string-handling bug, not state-machine bug |
| **Refund-tx accounting** | Refunds are economic, do not affect safety |
| **Wasm / IBC / zoneconcierge / EVM** | Out of scope; large surface, separate analysis |
| **`MaxVoteExtensionSize` at CometBFT layer** | Hardening / bandwidth concern, no protocol state effect |
| **Concrete BLS bitmap size (104 bits)** | Protocol-imposed constant; model with abstract `Signers ⊆ Validators` set |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Pub-rand commits | `pubRandCommits[fp] : Seq([start, end, commitment])` | Capture retroactive-commit bug | 1 |
| Evidence map | `evidenceMap[(fp,h)] : Evidence ∪ ⊥` | Capture fork-vote overwrite | 1 |
| Signing-info + bitmap | `signingInfo[fp] : Record`, `missedBitmap[fp] : Func` | Capture jailing bypass | 2 |
| Two-FSM checkpoint state | `epochStatusBTC[e]`, `ckptStatusLocal[e]` plus `forgottenCascade : Pending` | Capture cross-module FSM | 3 |
| Per-validator vote extensions | `voteExt[h, v] : ExtPayload ∪ Invalid` | Capture proposer trust gradient | 4 |
| Deferred power-dist events | `pendingEvents[btcHeight] : Seq(Event)` | Capture event-ordering semantics | 5 |
| BTC oracle with reorg | `btcChain : Seq(Header)`, `btcTip`, action `BtcReorg(depth)` | Captures the cross-chain coupling | 1,3,5 |
| Byzantine set | `Faulty ⊆ Validators` (CONSTANT for static model) | Permit Byzantine proposers / FPs | 4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| **PubRandPrecommitment** | Safety | For any `(fp, h)` voted, the pub-rand commit covering `h` was created at a Babylon height `< h` (broken if retroactive commits are allowed) | 1 |
| **EvidenceExtractableIfDoubleSign** | Safety | If FP signs two distinct `(h, hash)` with the same pub-rand, then `Slash(fp)` is eventually invoked (broken if only fork votes are seen without a canonical) | 1 |
| **NoSelfFalseSlashing** | Safety | An honest FP (signs only canonical, commits pub-rand correctly) is never `Slashed` | 1 |
| **JailingMonotonicity** | Liveness | If FP is non-voting for ≥ `signedBlocksWindow * 2` blocks (with bounded fairness for active/inactive churn), eventually `Jailed[fp]` | 2 |
| **FinalizedImpliesAncestor** | Safety | `ckpt[e].status = Finalized` ⇒ there exists `BTCInfo` for the kept submission on main chain (else fail-stop) | 3 |
| **MonotonicLastFinalizedEpoch** | Safety | `lastFinalizedEpoch` is monotonic non-decreasing | 3 |
| **NoTwoFinalizedSameEpoch** | Safety | No two distinct local checkpoints for the same epoch both reach `Finalized` | 3 |
| **CkptForgottenCascade** | Liveness | If parent epoch `Forgotten`, child epoch is `Forgotten` within bounded BTC tip advances | 3 |
| **CkptAgreementOrHalt** | Safety | Either all honest validators produce identical injected checkpoints for an epoch, or `ConflictingCheckpointReceived` is eventually set (triggering halt) | 4 |
| **ProposerCannotForge** | Safety | A Byzantine proposer cannot produce an injected checkpoint that differs from what any 2/3 honest set of vote extensions would produce | 4 |
| **SlashedDominatesJailed** | Safety | Eventually `votingPower[fp] = 0` when `Slashed[fp]`, regardless of `Jailed[fp]` | 5 |
| **SingleSlashEvent** | Safety | `SlashFinalityProvider` invocation is idempotent (second call no-op or rejected, not double-counted) | 5 |
| **UnbondingIntentSticky** | Safety | Once `DelegatorUnbondingInfo ≠ ⊥`, status stays `UNBONDED` even if the BTC unbonding tx is reorged out (depth < k) | 5 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|------------------------------|------------|
| MC1 | Can an FP commit pub-rand retroactively (with `lastCommit` ending below `currentHeight`) and then vote on already-produced canonical blocks with full reward, no slashing risk? | `PubRandPrecommitment` violated by `CommitPubRand` action under current guards | 1 |
| MC2 | Can two distinct fork votes for the same `(fp, h)` produce a state where only the second is recorded as `Evidence`, but the first's pub-rand-revealed SK is mathematically extractable from gossip-level data? | `EvidenceExtractableIfDoubleSign` violated unless the model also tracks gossip-level message bag and forces extraction by anyone with the data | 1 |
| MC3 | Can an FP that toggles active→inactive→active across the jailing window keep its `MissedBlocksCounter` non-reset, evading `Jailed` indefinitely under bounded oscillation? | `JailingMonotonicity` violated under a churn schedule | 2 |
| MC4 | Can a BTC reorg that removes a Confirmed-but-not-Finalized epoch's main-chain submission, *and* simultaneously an alternative submission becomes deepest, cause the local checkpoint to go `Confirmed → Sealed → Submitted → Confirmed → Finalized` with a *different* `BlockHash` than the original? | `NoTwoFinalizedSameEpoch` or the conflict-halt invariant — verify the cascade single-pass property | 3 |
| MC5 | Can a Byzantine proposer drop valid BLS signatures from `ExtendedCommitInfo` such that ProcessProposal validators rebuild a checkpoint that still has 2/3 power but a different signer subset, and have it accepted? | `ProposerCannotForge` — check whether checkpoint equality is by content (epoch, hash, multi-sig bytes) or by signer set | 4 |
| MC6 | When two MsgInsertBTCSpvProof for the same epoch arrive at consecutive heights with different signer subsets (both pass BLS verify against the local sealed checkpoint), does the multi-submission tracking + `getEpochChanges` always select a consistent "best" across nodes, even under same-block ordering nondeterminism? | Determinism invariant on `ed.Keys` ordering after `addEpochSubmission` and `getEpochChanges` | 3, 5 |
| MC7 | Under SLASHED + JAILED + EXPIRED events for the same FP in the same BTC-tip batch, is the resulting `votingPowerCache` always 0 regardless of buffered-event order? | `SlashedDominatesJailed` | 5 |
| MC8 | If a stake-expansion message is included in the same block as the slashing of its FP (via `AddFinalitySig` with a double-sign), does `validateStakedFPs` correctly reject the expansion? | Safety: an expansion of a slashed-this-block FP must not commit | 5 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| T1 | `IsFinalityProviderDeleted` returns true on transient KV error — silently fails closed | Unit test injecting KV error in `finalityProvidersDeleted.Has` |
| T2 | `slashFinalityProvider` panics on error from `BTCStakingKeeper.SlashFinalityProvider` — regression risk if a new caller emerges | Integration test with mocked SlashFinalityProvider returning an error; chain-halt check |
| T3 | `CommitPubRandList` has no refund + no slashed/jailed FP check — slashed FP can keep wasting gas | Integration test: slash FP, submit pub-rand commit, observe gas consumed |
| T4 | Multi-vote-extension de-dup at gossip layer — verify `MaxVoteExtensionSize` is checked at CometBFT layer too | Network-level test injecting oversize vote extensions |
| T5 | `BtcStakeExpand` chained N-levels deep (A→A'→A''→…) — each expansion uses prior `ACTIVE` delegation as input | Integration test creating multi-level chain, then slashing the root FP |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR1 | `vote_ext.go::VerifyVoteExtension` lacks `MaxVoteExtensionSize`, `RejectUnknownFieldsStrict`, and round-trip marshal check that `proposal.go::VerifyVoteExtension` has — gossip-layer bandwidth amplification | File issue: apply size cap and round-trip checks at the CometBFT layer too |
| CR2 | TODO at `proposal.go:459-461` ("send an alarm and stall the blockchain") is misleading — current reject-only behaviour is correct; halting would be a DoS primitive | Update comment, document the design choice |
| CR3 | `validateActivationHeight` comment "TODO: remove it after Phase-2 launch" (msg_server.go:389) is stale (mainnet launched April 2025) | Audit/remove if obsolete |
| CR4 | `slashFinalityProvider` wrapper (`x/finality/keeper/msg_server.go:373-384`) panics on any error — hardening: log+ignore `ErrFpAlreadySlashed` to avoid chain halt on future regression | Make idempotent in the wrapper |
| CR5 | `pubRandFpStore` set on every `AddFinalitySig` (`msg_server.go:149`) but never read — dead storage | Remove or use for liveness/freshness check |
| CR6 | `IsFinalityProviderDeleted` swallows KV errors → fail-closed (treats FP as deleted) — silent | Distinguish "deleted" from "lookup failed", log/halt on the latter |
| CR7 | `BTCDelegation.GetStatus` does not consult FP `Slashed` flag — a slashed-FP's delegation still reports `ACTIVE` (filtering happens at finality power-dist consumer) | Document the convention, or add `WithFPStatus(status)` wrapper |
| CR8 | `AddCovenantSigs` quorum check is `len(d.CovenantSigs) >= quorum`; depends on `AddCovenantSigs` schema requiring both staking + unbonding sigs together. A future schema change could break this. | Add an explicit dedup-by-PK guard in `BTCDelegation.AddCovenantSigs` |
| CR9 | `validateStakeExpansionAmt` has no maximum amount cap — relies on params-level checks elsewhere | Add explicit upper bound or document the chain-of-validation |
| CR10 | `checkCheckpoints` iterator break at `len(currentEpoch.Keys) == 0` (line 327-331) — single-pass cleanup is correct but subtle; an assertion on the underlying invariant would help future maintainers | Add `panic`-on-violation or comment with the invariant |

## 7. Reference Pointers

- **Full analysis report**: `analysis-report.md` in same directory
- **Key source files**:
  - `x/finality/keeper/msg_server.go` (399 lines) — `AddFinalitySig`, `CommitPubRandList`, `slashFinalityProvider`
  - `x/finality/keeper/evidence.go` (74 lines) — evidence storage keyed by (FpBtcPk, height)
  - `x/finality/keeper/liveness.go` (205 lines) — jailing FSM
  - `x/finality/keeper/power_dist_change.go` (629 lines) — power-dist event consumer
  - `x/finality/keeper/tallying.go` (134 lines) — block finalization
  - `x/finality/types/finality.go` (around line 220-250) — `Evidence.IsSlashable`, `Evidence.ExtractBTCSK`
  - `x/btcstaking/keeper/msg_server.go` (812 lines) — delegation lifecycle messages
  - `x/btcstaking/keeper/btc_delegations.go` (540 lines) — status FSM + creation
  - `x/btcstaking/keeper/inclusion_proof.go` (206 lines)
  - `x/btcstaking/keeper/btc_reorg.go` (73 lines) — chain-halt on deep reorg
  - `x/btcstaking/keeper/finality_providers.go` (312 lines) — Slash/Jail/Unjail
  - `x/btccheckpoint/keeper/keeper.go` (431 lines) — `checkCheckpoints` cross-module FSM
  - `x/btccheckpoint/keeper/submissions.go` (237 lines) — submission lifecycle
  - `x/checkpointing/keeper/keeper.go` (529 lines) — local checkpoint FSM + BLS verify
  - `x/checkpointing/vote_extensions/vote_ext.go` (185 lines) — CometBFT-level vote-ext handler
  - `x/checkpointing/prepare/proposal.go` (589 lines) — proposer-level vote-ext aggregator
  - `x/checkpointing/abci.go` (35 lines) — conflict-halt EndBlock
- **GitHub issues** (open, relevant):
  - #1984 — Retroactive pub-rand commits (PR #1994 pending merge) [Family 1]
  - #1852 — FPs bypass jailing via active toggle (Immunefi #56201, security label) [Family 2]
  - #1853 — BIP-340 signature parsing (Immunefi #54049, security label) [out of scope per § 3.2]
  - #1979 — Hex normalization in `ResumeFinalityProposal` (Cantina BABY-2) [Family 6, out of MC scope]
  - #950 — Bad `MsgResumeFinalityProposal` halts chain [Family 6]
  - #938 — `HandleRewarding` stuck after VP-zero gap [Family 6]
- **GitHub security advisories** (fixed):
  - GHSA-m6wq-66p2-c8pc — Nil block hash in vote extension (commit `9c52e24a`)
  - GHSA-2fcv-qww3-9v6h — Unknown protobuf fields in vote extension (commit `953724e5`)
  - GHSA-4rmq-mc2c-r495 — `AfterBtcDelegationUnbonded` hook conditional logic (commit `b833baeda`)
  - GHSA-xq4h-wqm2-668w — BIP-322 signatures `SIGHASH_ALL`/`SIGHASH_DEFAULT` (commit `0b35b185`)
  - GHSA-56j4-446m-qrf6 — Bank restriction for fee collector
  - GHSA-h598-3g3g-c67c — CometBFT bump
- **Notable closed PRs** (mechanism evidence, see § 1.4 of bug-archaeology.md):
  - PR #342 (`ccc00b73`) Non-determinism while jailing → `GetVotingPowerTableOrdered`
  - PR #180 (`58e13f06`) Non-determinism in sorting FPs in VP table
  - PR #1805 (`3eefafe9`) Non-determinism in `IterateBTCDelegationSatsUpdated`
  - PR #1813 (`18f69ed1`) Audit V4-CORE-008: panic on invalid sats
  - PR #1908 (`c5e5a5b3`) `AfterRawCheckpointForgotten` hook propagation
  - PR #218 (`0caa9bed`) Remove VP `max(w, minUnbondingTime)` before timelock ends
  - PR #1271 Validate `MsgEquivocationEvidence` (was #1253)
  - PR #186 (`c4c25b69`) Don't panic on nil proof when handling votes (was #174)
  - PR `d0b75cfe` (Jul 2025) Major refactor of proposer-vs-validator vote-extension validation
  - PR #1994 (open) `fix(finality): reject retroactive public randomness commitments` — the open patch for #1984
- **Reference algorithms / papers**:
  - "Bitcoin Staking: Secure Proof-of-Stake using Bitcoin" (Babylon whitepaper)
  - Aumayr et al., "Generalized Channels from Limited Blockchain Scripts and Adaptor Signatures"
  - Babylon's own EOTS construction paper
  - DLS 1988 (partial-synchrony BFT model); Castro-Liskov 1999 (PBFT)
- **Coverage statistics**:
  - Git history: 163 bug-fix commits across the 4 target modules (`git log --oneline --grep="fix"`), all 6 "Merge commit from fork" private-fork security advisories reviewed, ~25 of the highest-relevance commits read in full
  - GitHub issues: 60+ collected via `gh issue list`, 12 deeply read (full thread via `--comments`), all 6 GHSA advisories reviewed
  - Files: 22 core production files (~22,500 LOC) read completely across 4 parallel Task subagents + the lead context
