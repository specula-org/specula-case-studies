# Code Analysis Report: babylonlabs-io/babylon

**Target**: Babylon — Bitcoin-secured Cosmos-SDK + CometBFT chain (mainnet April 2025).
**Scope**: `x/finality`, `x/btcstaking`, `x/btccheckpoint`, `x/checkpointing` only. Stock Cosmos SDK + CometBFT treated as abstract.
**Commit analyzed**: `d96cd9d` (HEAD of `main`, late Feb 2026; corresponds to v4.x mainline).
**System category**: Category A (distributed/message-passing) + BFT consensus overlay + cross-chain trust boundary.

## 0. Coverage Statistics

| Phase | Statistic |
|-------|-----------|
| Git history mining | 163 fix-keyword commits across the 4 target modules; ~25 highest-relevance commits read in full (security advisories, audit fixes, non-determinism fixes) |
| Security advisories | 6 GHSA "Merge commit from fork" private-fork advisories reviewed |
| GitHub issues collected | 60+ via `gh issue list` (open + closed, multiple keyword searches) |
| GitHub issues deeply read | 12 (full `--comments` thread) |
| Core files read in full | 22 files across `x/{finality,btcstaking,btccheckpoint,checkpointing}` totalling ~22,500 LOC |
| Parallel subagents | 4 (1× issue verification + 3× file analysis) plus the lead context |

---

## 1. Reconnaissance (Phase 1)

### 1.1 Module structure

| Module | Core LOC | Role |
|--------|----------|------|
| `x/finality` | 6,583 | Finality-provider votes, slashing on EOTS double-sign, pub-rand commitments, jailing, tallying |
| `x/btcstaking` | 8,980 | BTC delegation lifecycle, covenant signatures, adaptor-signature handling, FP registration & slashing |
| `x/btccheckpoint` | 2,884 | Receives BTC SPV proofs of OP_RETURN checkpoints, FSM Submitted→Confirmed→Finalized, BTC reorg handling |
| `x/checkpointing` | 4,050 | Builds BLS multi-sig sealing of validator set + tip; CometBFT vote-extension handler + proposer aggregation |

Total: ~22,500 LOC of non-generated, non-test core code.

### 1.2 Message types and entry points

| Module | MsgServer entry | Role |
|--------|-----------------|------|
| `x/finality` | `AddFinalitySig` | Receives a finality signature; detects fork-vote / equivocation; slashes on double-sign |
| `x/finality` | `CommitPubRandList` | FP commits a Merkle root over `NumPubRand` pub-rand values starting at `StartHeight` |
| `x/finality` | `UnjailFinalityProvider` | FP self-unjails after jail period elapses |
| `x/finality` | `ResumeFinalityProposal` | Gov-only: reset voting power on halt recovery |
| `x/btcstaking` | `CreateBTCDelegation` | Register a new delegation (PENDING) |
| `x/btcstaking` | `AddCovenantSigs` | Covenant member submits adaptor-sigs + Schnorr; on quorum, becomes VERIFIED/ACTIVE |
| `x/btcstaking` | `AddBTCDelegationInclusionProof` | Submits BTC SPV proof; activates delegation |
| `x/btcstaking` | `BTCUndelegate` | Intent-based unbonding; permanent on Babylon side |
| `x/btcstaking` | `BtcStakeExpand` | Expand a previous active delegation to a larger amount |
| `x/btcstaking` | `SelectiveSlashingEvidence` | Anyone with a recovered FP BTC SK can slash that FP |
| `x/btcstaking` | `CreateFinalityProvider` / `EditFinalityProvider` | FP registration / mutation |
| `x/btccheckpoint` | `InsertBTCSpvProof` | Submits a pair of BTC txs with OP_RETURN halves of a raw checkpoint |
| `x/checkpointing` | `WrappedCreateValidator` | Registers validator's BLS key alongside Cosmos validator creation |
| `x/checkpointing` | `MsgInjectedCheckpoint` (special tx) | Proposer injects aggregated BLS-signed checkpoint into the *first block of next epoch* |

### 1.3 State machines

**FP lifecycle** (managed by `x/btcstaking`, read by `x/finality`):
```
              ┌──── Slashed ────┐  (terminal-ish; can be unjailed-from-non-slashed but not from-slashed)
Active ────┬──┤                  │
           ├──┤── Jailed ── Unjailed ── Active
           └──┘
```
Plus a `SoftDeleted` flag set only at upgrades/migrations/genesis.

**BTC delegation lifecycle** (computed by `BTCDelegation.GetStatus` based on flags + BTC tip):
```
PENDING ──covenant quorum──→ VERIFIED ──inclusion proof──→ ACTIVE
                                                          │
                                                ┌─ EXPIRED  (btcHeight + UnbondingTime ≥ EndHeight)
                                                ├─ UNBONDED  (DelegatorUnbondingInfo set, sticky)
                                                └─ (slashed FP → power=0 but status stays as above)
```

**Checkpoint lifecycle (local, x/checkpointing)**:
```
Accumulating ──seal──→ Sealed ──BTC OP_RETURN seen──→ Submitted
                       │                                │
                       └────────── Forgotten ◄──────────┘ (parent epoch lost ancestry)
                                                        ↓ k-deep
                                                    Confirmed
                                                        ↓ w-deep
                                                    Finalized
```

**Epoch BTC-side (x/btccheckpoint)** carries `EpochData.Status` ∈ {Submitted, Confirmed, Finalized} that drives the local FSM via hooks.

### 1.4 Concurrency model

- Single-threaded per-block execution (Cosmos SDK).
- `BeginBlock` order: `epoching` → `btclightclient` → `btcstaking.HaltIfBtcReorgLargerThanConfirmationDepth` → `btccheckpoint.OnTipChange` (if light client updated) → `checkpointing.PreBlocker` (for inject ckpt) → `finality.BeginBlock` (processes power-dist events buffered per BTC height) → app msgs.
- `EndBlock` order: `finality.EndBlock` (TallyBlocks + HandleLiveness + HandleRewarding) → `checkpointing.EndBlock` (`panic` on conflict flag).
- Vote extensions and prepare/process proposal hooks run at the CometBFT layer, *one step ahead* of normal Begin/EndBlock.
- Events deferred via `addPowerDistUpdateEvent(btcHeight, evt)` are stored under a (btcHeight, idx) key and consumed in `ProcessAllPowerDistUpdateEvents` only after `btclightclient` tip advances.

---

## 2. Bug Archaeology (Phase 2)

### 2.1 Git history mining

Total bug-fix-keyword commits across `x/finality,btcstaking,btccheckpoint,checkpointing`: **163**.

#### High-value commits (categorised)

**Non-determinism (4 confirmed bugs in this area)**:
- `ccc00b73` (PR #342, Dec 2024) "Non-determinism while jailing" — map iteration over `fpSet` → ordered iteration via `GetVotingPowerTableOrdered`.
- `58e13f06` (PR #180, Oct 2024) "Non-determinism in sorting finality providers in the voting power table" — sort tiebreak by BTC PK hex on both-jailed/both-non-timestamped and equal-power cases.
- `3eefafe9` (PR #1805, Oct 2025) "nondeterminism incentives IterateBTCDelegationSatsUpdated" — sort.Strings added for deterministic iteration.
- `8d76979e` (PR #597) "fix non-determinism in voting power rotation".

**Crypto fixes (multiple)**:
- `7d8ca32f` (PR #657) "crypto: fix adaptor sig timing side channels"
- `2290bd86` (PR #656) "crypto: fix adaptor sig validity and typos"
- `dc36df00` (PR #691) "crypto: fix EOTS missing normalization in use of secp256k1.FieldVal"
- `3d6da873` (PR #680) "crypto: fix bls rogue attack"
- `4588c996` (PR #671) "crypto: align adaptor sig impl with Blockstream spec"
- `a2065668` (PR #667) "crypto: Enable group check in BLS"
- `0b35b185` (PR #1876) BIP-322 non-compliance fix
- `94791888` (PR #287) "Fix vulnerability when processing bls sig transactions" — added LastCommitHash binding (pre-vote-extension era)

**Vote-extension / proposer-layer security advisories (4)**:
- `9c52e24a` (Dec 2025, GHSA-m6wq-66p2-c8pc) "nil check of block hash in vote extension" — `ve.Validate()` added at both `vote_ext.go` and `proposal.go`; `bytes.Equal` replaces broken `*BlockHash.Equal`.
- `953724e5` (Nov 2025, GHSA-2fcv-qww3-9v6h) "unknown fields check on vote extension validation" — `unknownproto.RejectUnknownFieldsStrict` at proposer layer.
- `d0b75cfe` (Jul 2025) — major refactor splitting `getValidBlsSigs` (read-only) from `getValidBlsSigsAndPruneCommitInfo` (proposer-mutating); ~139 lines changed.
- `dead25d5` (Mar 2026, PR #1923) "vote extension max size" — `MaxVoteExtensionSize = 1024` at proposer layer.
- `97d56bc6` (PR #1911) "avoid panic in ProcessProposal when injected checkpoint tx contains a wrong message type".

**Checkpoint/checkpointing hooks**:
- `c5e5a5b3` (PR #1908) "fix: call AfterRawCheckpointForgotten in all hooks, instead of early return" — multi-hook iteration bug.
- `b25cf6af` (PR #163, Oct 2022) "Fix handling duplicated submissions".

**Finality slashing / equivocation / refund**:
- PR #1271 "rollup: equivocation e2e test for rollup BSN" closed Issue #1253 (MsgEquivocationEvidence lacked validation).
- `828ec9ab` (PR #592/#593) "avoid refunding finality signatures over forks".
- `c4c25b69` (PR #186) "Do not panic on nil proof when handling votes" (closed #174).
- `9da1dfea` (PR #829) "add checks for slashed fp in gov resume finality".
- `6681f30e` (PR #992) "fix: resume fp halt height".
- `d166d40b` (PR #449) "Do not return errors for duplicated signatures" — covenant sig dedup design.

**Delegation FSM / power-dist**:
- `18f69ed1` (PR #1813, Audit V4-CORE-008) "panic if there is an invalid amount of sats in fp distribution info".
- `c1c2abe1` (PR #1953) "refresh fp commission of active fps in voting power dst cache" — stale-cache bug in reward distribution.
- `292b5d49` (PR #1875) "ensure soft-deleted FPs cannot receive new/extended BTC stake, or commit pub rand".
- `0caa9bed` (PR #218) "Fix removing voting power during expiry" — `max(w, minUnbondingTime)` rule (closed #176).
- `a26bba41` (PR #620) "JailUntil is not reset after unjailing".
- `213b1ae9` (PR #324) "Decrementing jailed fp counter".

**Costaking GHSA (Dec 2025)**:
- `b833baeda` (GHSA-4rmq-mc2c-r495) "fix: update conditional logic in `AfterBtcDelegationUnbonded` hook" — incorrect double-subtraction guard fixed; new rule: substract iff `isFpActiveInPrevSet`.

### 2.2 GitHub issue verification (12 deeply read)

| # | Title | State | Verdict | Bug Family |
|---|-------|-------|---------|------------|
| #1852 | FPs bypass jailing via active toggle | OPEN, security label | **Confirmed** (Immunefi #56201). HandleActivatedFinalityProvider resets StartHeight but not bitmap/counter (liveness.go:79-104; power_dist_change.go:186-203). Test at liveness_test.go:230-294 documents the non-reset behavior. | 2 |
| #1853 | BIP-340 schnorr.ParseSignature accepts non-canonical sigs | OPEN, security label | **Confirmed but low practical impact** (Immunefi #54049). Upstream issue in btcsuite/btcd. Reporter notes deterministic signing + need for naturally low S limit exploitability. | Out of scope |
| #1984 | CommitPubRandList allows retroactive randomness commits | OPEN | **Confirmed**. PR #1994 pending merge. msg_server.go:251 only checks upper bound `< currentHeight + MaxPubRandCommitOffset`; no lower bound. **Verified directly: not fixed in `d96cd9d`.** | 1 |
| #1979 | Hex normalization in ResumeFinalityProposal | OPEN | **Confirmed** (Cantina BABY-2). gov.go compares mixed-case hex against `MarshalHex()` canonical lowercase. | 6 |
| #950 | bad MsgResumeFinalityProposal with all active FPs halts chain | OPEN | **Confirmed** (reopened). Listing all active FPs zeroes the voting power table at halting-height. | 6 |
| #938 | HandleRewarding stuck with big gap of unfinalized blocks | OPEN | **Confirmed** with detailed reproduction (rewarding.go:35; per-EndBlock bound never catches up after 10k+ zero-VP block gap). | 6 |
| #1346 | Decouple unbonding time from finalization timeout | OPEN | **Refactor request, not a bug.** | Out of scope |
| #176 | Remove VP `max(w, minUnbondingTime)` before timelock ends | CLOSED | **Confirmed historical**. Fixed by PR #218 (`0caa9bed`). | Family-1 evidence |
| #1253 | finality: validation of MsgEquivocationEvidence | CLOSED | **Confirmed historical**. Fixed by PR #1271 — added full evidence validations. | Family-1 evidence |
| #1830 | HAL-06 Delegation tx OP_RETURN is not verified | CLOSED | **Closed by spec clarification** — OP_RETURN is phase-1 only, no on-chain verify needed for phase-2 model. | Out of scope |
| #174 | Passing nil proof in MsgAddFinality vote leads to Panic | CLOSED | **Confirmed historical**. Fixed by PR #186 (`c4c25b69`). | Family-1 evidence |
| #322 | Missing params validation of unbondingTime < minStakingTime | CLOSED | **Closed as dup of #296** (still open). Parameter-space well-formedness; not a runtime invariant. | Out of scope |

### 2.3 Open security-labeled bugs at time of analysis

- **#1852** (Family 2) — model-checkable
- **#1853** — implementation-only, not model-checkable
- **#1984** (Family 1) — model-checkable
- **#1979** (Family 6) — borderline (hex normalization is implementation; gov state machine could be modeled)
- **#950** (Family 6) — model-checkable
- **#938** (Family 6) — liveness, model-checkable

---

## 3. Deep Analysis (Phase 3)

### 3.1 x/finality findings

**3.1.1 EOTS evidence overwrite (msg_server.go:151-219, evidence.go:13-16)**

The evidence store is keyed by `(FpBtcPk, height)`. When a second fork vote arrives at the same height (before any canonical sig), the new evidence replaces the old one, losing the original `ForkFinalitySig` and `ForkAppHash`.

```go
// msg_server.go:152-181 — fork branch (excerpt)
if !bytes.Equal(indexedBlock.AppHash, req.BlockAppHash) {
    evidence := &types.Evidence{...}
    canonicalSig, err := ms.GetSig(ctx, req.BlockHeight, fpPK)
    if err == nil { evidence.CanonicalFinalitySig = canonicalSig; ms.slashFinalityProvider(...) }
    ms.SetEvidence(ctx, evidence); return nil, nil
}
```

```go
// evidence.go:13-16 — SetEvidence
func (k Keeper) SetEvidence(ctx context.Context, evidence *types.Evidence) {
    store := k.evidenceFpStore(ctx, evidence.FpBtcPk)
    store.Set(sdk.Uint64ToBigEndian(evidence.BlockHeight), k.cdc.MustMarshal(evidence))
}
```

**Verdict**: by-design. The protocol's slashing trigger requires both canonical-and-fork sigs to be present in evidence (`IsSlashable` at finality.go:226-234 requires `CanonicalFinalitySig != nil`). Since a later canonical vote completes evidence with whatever fork sig is currently stored, security holds. **Curiosity worth modeling**: the LATEST fork sig is the one used for SK extraction, not the first — and if FP only ever votes for forks (no canonical), Babylon never extracts the SK. Mathematically, anyone observing two distinct fork sigs at the same (FP, height) could extract the SK off-chain; the chain itself does not.

**3.1.2 Retroactive pub-rand commits (msg_server.go:242-321) — Issue #1984**

```go
// 250-253 — only an UPPER bound, no lower bound
if req.StartHeight >= uint64(ctx.BlockHeader().Height)+types.MaxPubRandCommitOffset {
    return nil, types.ErrInvalidPubRand.Wrapf("start height %d is too far into the future...")
}
// ... no `req.StartHeight > currentBlockHeight` check ...
// 310-314 — only enforces no overlap with PRIOR commit
if req.StartHeight <= lastPrCommit.EndHeight() {
    return nil, types.ErrInvalidPubRand.Wrapf("the start height has overlap with the highest committed")
}
```

Sequence to exploit:
1. FP has `lastPrCommit = [1, 100]`. Chain runs to height 500.
2. FP submits `CommitPubRandList(StartHeight=101, NumPubRand=400)`. Both checks pass (line 251 allows it; line 312 allows it). **Commit succeeds.**
3. FP now can submit `AddFinalitySig` for any height in [101, 500] with full knowledge of canonical block hashes. Vote always matches canonical → no slashing risk, full reward.

**PR #1994** (open, not in `d96cd9d`) adds `req.StartHeight > uint64(ctx.BlockHeader().Height)` to fix this.

**3.1.3 Liveness/jailing bypass (Issue #1852)**

`HandleActivatedFinalityProvider` (`power_dist_change.go:186-203`) — on FP transitioning from inactive → active:

```go
if err == nil {  // signing info exists
    signingInfo.StartHeight = sdkCtx.HeaderInfo().Height
    signingInfo.JailedUntil = time.Unix(0, 0).UTC()
}
```

`MissedBlocksCounter` and the missed-block bitmap are NOT reset. The jailing rule (`liveness.go:79-104`) requires:
1. `height > StartHeight + signedBlocksWindow` (post-reset: false for `signedBlocksWindow` blocks)
2. `MissedBlocksCounter > maxMissed`

Plus the bitmap-index calculation `index := (height - StartHeight) % signedBlocksWindow` re-uses the old bitmap slots. `UpdateSigningInfo` (line 149-186) reads `previous, _ := GetMissedBlockBitmapValue(fp, index)` and only updates on transition:
- `previous=false ∧ missed=true`: set bit, ++counter
- `previous=true ∧ missed=false`: clear bit, --counter
- `previous=true ∧ missed=true`: no-op
- default (`previous=false ∧ missed=false`): no-op

If old bitmap had `previous=true` at the new index because of past misses, and the FP now SIGNS (`missed=false`), the bit is cleared and counter decremented. If FP now MISSES (`missed=true`), no-op (since previous was already true).

Test `liveness_test.go:230-294` explicitly asserts `Equal(int64(1), counter)` after `HandleActivatedFinalityProvider`, confirming the non-reset behaviour is INTENTIONAL in current code (even though arguably wrong per Issue #1852).

**3.1.4 Slash idempotency**

`SlashFinalityProvider` (btcstaking/keeper/finality_providers.go:153-180) checks `fp.IsSlashed()` and returns `ErrFpAlreadySlashed` on second call. `slashFinalityProvider` wrapper in finality/keeper/msg_server.go:373-384 `panic`s on any error. So a double-call would halt the chain.

Within a single `AddFinalitySig` call, the two slashing branches (line 173 fork-finds-canonical; line 214 canonical-finds-evidence) are mutually exclusive (different branches of the same `if/else`). Across `AddFinalitySig` calls, the FP being slashed is rejected at line 116-118 before reaching either branch. So practical double-call is unreachable today.

**Hardening note**: if a future code change introduces a path that calls `slashFinalityProvider` without first checking `IsSlashed()`, the chain halts. Consider making the wrapper log+ignore `ErrFpAlreadySlashed`.

**3.1.5 Tallying determinism**

`tally()` (tallying.go:99-111) sums over a `map[string]uint64`. Sum is order-independent, so the boolean result `votedPower*3 > totalPower*2` is deterministic across nodes regardless of map iteration order.

`finalizeBlock` and `setNextHeightToFinalize` are linear sequential writes — deterministic.

`HandleLiveness` iterates `GetVotingPowerTableOrdered` (sorted by VP desc with BTC-PK-hex tiebreak — see power_table.go:128-134). Deterministic.

`SortFinalityProvidersWithZeroedVotingPower` (types/power_table.go:310-337, post-PR-180) sorts with stable PK-hex tiebreak on equal-power and both-zeroed cases. Deterministic.

`ProcessAllPowerDistUpdateEvents` iterates btc-tip heights in order; per-height inner work uses KV iterator order over deterministic stores. New active FPs are explicitly sorted (line 311-313).

**Verdict**: post-fix code is determinism-clean. Hardening item: the original PR #180 fix is intact.

**3.1.6 Refund hazard**

`IndexRefundableMsg(ctx, req)` is called only at msg_server.go:224 — last line of the canonical happy path (no fork, no prior evidence). Decision-flow:

| Outcome | State mutation | Refund? |
|---------|---------------|---------|
| ValidateBasic / activationHeight fail | none | no |
| FP slashed/jailed/deleted | none | no |
| zero voting power | none | no |
| exact-duplicate sig | none | no |
| pub-rand not found / not timestamped | none | no |
| VerifyFinalitySig fails | none | no |
| fork branch (slash or half-evidence) | **SetEvidence + maybe slash** | **NO** |
| canonical with prior evidence (slash) | **SetSig + SetEvidence + slash + updateFP** | **NO** |
| pure canonical happy path | SetPubRand + SetSig + updateFP | **yes** |

Slashing-path no-refund is by-design: a slashable FP forfeits the tx fee. But the *submitter* (anyone can submit) also gets nothing — a slashing-watcher pays gas. Acceptable.

`CommitPubRandList` is NOT in `isRefundTx`'s allowlist (refund_tx_decorator.go:115-138); it always pays gas. There's also no `fp.IsSlashed()/IsJailed()` check on `CommitPubRandList` — slashed FPs can keep wasting their own gas. Hardening item.

### 3.2 x/btcstaking findings

**3.2.1 SelectiveSlashingEvidence trust model (msg_server.go:685-716)**

```go
func (ms msgServer) SelectiveSlashingEvidence(...) (...) {
    fpSK, fpPK := btcec.PrivKeyFromBytes(req.RecoveredFpBtcSk)
    fpBTCPK := bbn.NewBIP340PubKeyFromBTCPK(fpPK)
    if err := ms.SlashFinalityProvider(ctx, fpBTCPK.MustMarshal()); err != nil {
        return nil, err
    }
    // emit selective slashing event with the SK
}
```

The FP public key is *derived* from the supplied SK bytes via `btcec.PrivKeyFromBytes`. So there's no way to "frame" an FP whose SK you don't know — the lookup succeeds only if you submitted the actual SK of a registered FP. **Verdict**: by-design and unforgeable.

**3.2.2 Delegation re-registration race**

`CreateBTCDelegation` (`btc_delegations.go:36-40`) rejects duplicates by staking-tx-hash:
```go
delegation := k.getBTCDelegation(ctx, stakingTxHash)
if delegation != nil { return types.ErrReusedStakingTx.Wrapf(...) }
```

Delegations are NEVER deleted from `BTCDelegationKey` store (verified by grep — the only `store.Delete` in `x/btcstaking` is for `PowerDistUpdateKey`, not delegations). So re-registration is permanently blocked once a delegation has been inserted, even after UNBONDED/EXPIRED.

`AddBTCDelegationInclusionProof` (`inclusion_proof.go:113-115, 132-134`) rejects if `btcDel.HasInclusionProof()` or `btcDel.BtcUndelegation.DelegatorUnbondingInfo != nil`. No race.

**3.2.3 BTCUndelegate intent-stickiness**

Once `DelegatorUnbondingInfo` is set, `IsUnbondedEarly() = true` forever (`btc_delegation.go:96-98, 119-162`). `GetStatus` puts the UNBONDED branch first:

```go
func (d *BTCDelegation) GetStatus(...) BTCDelegationStatus {
    if d.IsUnbondedEarly() { return BTCDelegationStatus_UNBONDED }
    if !d.HasCovenantQuorums(...) { return BTCDelegationStatus_PENDING }
    if !d.HasInclusionProof() { return BTCDelegationStatus_VERIFIED }
    if btcHeight < d.StartHeight { return BTCDelegationStatus_UNBONDED }
    if btcHeight + d.UnbondingTime >= d.EndHeight { return BTCDelegationStatus_EXPIRED }
    return BTCDelegationStatus_ACTIVE
}
```

`BTCUndelegate` (`msg_server.go:521-681`) also rejects an UNBONDED/EXPIRED delegation up-front (line 560-562). The intent-based design is explicitly documented in the godoc at lines 525-540 — BTC reorgs shallower than `BtcConfirmationDepth` removing the unbonding tx do NOT restore the delegation. Deeper reorgs halt the chain via `HaltIfBtcReorgLargerThanConfirmationDepth` (`btc_reorg.go:13-29`). **Verdict**: by-design and consistent.

**3.2.4 Covenant signature aggregation**

`AddCovenantSigs` (msg_server.go:255-401) verifies adaptor sigs via `ParseEncVerifyAdaptorSignatures` (`btc_slashing_tx.go:196-227`), Schnorr unbonding sig via `VerifyTransactionSigWithOutput`, and unbonding-slashing adaptor sigs. The mathematical property of adaptor signatures (verify succeeds iff decrypt succeeds with the matching SK) means a sig that "looks valid" but doesn't decrypt at slash time is impossible.

**Latent ambiguity**: The dedup check (`msg_server.go:270-275`) uses `&&`:
```go
if btcDel.IsSignedByCovMember(req.Pk) && btcDel.BtcUndelegation.IsSignedByCovMember(req.Pk) {
    return nil, types.ErrDuplicatedCovenantSig
}
```
A covenant member who signed only staking-side could re-submit with both, and `BTCDelegation.AddCovenantSigs` (`types/btc_delegation.go:334`) appends without dedup. The msg schema requires `req.SlashingTxSigs` AND `req.SlashingUnbondingTxSigs` AND `req.UnbondingTxSig` together (line 290, 322, etc.), so the only legal flow is "submit both at once or be rejected". The dedupe ambiguity is unreachable today but a future schema relaxation could break the quorum count. Hardening item.

**3.2.5 Status FSM correctness for slashed-FP delegations**

`GetStatus` does NOT consult the FP's `IsSlashed` flag. A delegation under a slashed FP still reports `ACTIVE` from this function. Voting-power zeroing happens at the `x/finality/keeper/power_dist_change.go` consumer level by skipping the slashed FP. Document this convention so callers don't misuse `GetStatus`.

**3.2.6 Multi-level stake expansion**

`BtcStakeExpand` (msg_server.go:140-218) requires `IsBtcDelegationActive(req.PreviousStakingTxHash)`. There's no `if d.IsStakeExpansion() { return err }` guard, so chains A → A' → A'' are allowed. Each expansion is a new delegation with its own ParamsVersion; the prior is undelegated when the new one is included on BTC.

Same-block race: If `tx_1 = MsgAddFinalitySig` slashes FP1 and `tx_2 = MsgBtcStakeExpand` expands a delegation under FP1, the inner `validateStakedFPs` (`btc_delegations.go:46`) inside `Keeper.CreateBTCDelegation` re-reads the FP from store and sees the freshly-set `SlashedBabylonHeight > 0`, returning `ErrFpAlreadySlashed`. The expansion is correctly rejected.

`IsBtcDelegationActive` at the BtcStakeExpand entry (line 143) does NOT consult FP slashing, but the inner `validateStakedFPs` catches it. Subtle two-stage safeguard.

**3.2.7 Covenant overlap for n=k**

`hasSufficientCovenantOverlap` (msg_server.go:732-760) checks the intersection of old and new committees is ≥ `requiredOverlap`. For n=k = 5, all 5 old members must be in the new committee. The call sites pass `oldParams.CovenantQuorum` / `prevParams.CovenantQuorum`, which by construction is ≤ committee size. Correct.

### 3.3 x/btccheckpoint findings

**3.3.1 Cross-module FSM consistency**

The cleanup cascade depends on `clearEpochData(parent)` → `parentEpochInfo = &epochInfo{bestSubmission: nil}` → the next iteration step visiting the child and triggering the special-case branch at line 355-366. This works because Cosmos KV iterators see synchronous writes.

The `break` at line 327-331 fires when `len(currentEpoch.Keys) == 0`. In normal operation, this corresponds to an epoch that was *previously* cleared (cleanup is one-shot per call). Within a single `checkCheckpoints` invocation, a parent that gets cleared sets `currentEpoch.Keys = []` and continues; the next iteration loop step visits the next epoch (which is now a "child" with a cleared parent in mind).

**Subtle**: If somehow a *child* epoch had `len(Keys) == 0` from a prior pass while its parent (later in iteration order? no, parents are smaller-numbered) didn't, the break would fire and skip later children. This shouldn't happen — but the assertion is implicit. Hardening: add a panic-on-violation or a comment with the invariant `∀e' > e: keys(e) == [] ⇒ keys(e') == []`.

**3.3.2 BTC reorg of a Finalized epoch**

Lines 333-351 of `checkCheckpoints`:
```go
if currentEpoch.Status == types.Finalized {
    if len(currentEpoch.Keys) != 1 { panic("Finalized epoch must have only one valid submission") }
    subInfo, err := k.GetSubmissionBtcInfo(ctx, *currentEpoch.Keys[0])
    if err != nil { panic("Finalized epoch submission must be on main chain") }
    ...
}
```

`GetSubmissionBtcInfo` returns error iff `headerDepth` returns `errSubmissionUnknown` (the header is off the main chain). This happens iff a BTC reorg deeper than `CheckpointFinalizationTimeout = 100` orphaned the previously-finalized checkpoint. The chain deterministically panics — safety-over-liveness fail-stop.

`HaltIfBtcReorgLargerThanConfirmationDepth` (`x/btcstaking/keeper/btc_reorg.go:13-29`) panics earlier when `largestReorg.BlockDiff >= BtcConfirmationDepth = 10`. So the chain typically halts at the `k`-depth threshold long before reaching the `w`-depth Finalized-panic. Both halts are intentional.

**3.3.3 Conflict-halt EndBlock wiring (x/checkpointing/abci.go:30-35)**

```go
func EndBlocker(ctx context.Context, k keeper.Keeper) {
    if conflict := k.GetConflictingCheckpointReceived(ctx); conflict {
        panic(types.ErrConflictingCheckpoint)
    }
}
```

Verified: the conflict flag, once set by `VerifyCheckpoint` detecting a different-BlockHash valid-BLS-multi-sig for an epoch, causes the EndBlock to panic. The flag persists in KVStore, so the chain re-panics on every restart until manual recovery. **Verdict**: by-design, correctly wired.

Hardening: the EndBlocker doesn't log fields before panicking; operators see only the stack trace. Adding (epoch, conflicting BlockHash) to a log just before the panic would help post-mortem.

**3.3.4 Duplicate-submission allowance**

The protocol permits multiple BTC submissions for the same epoch from different vigilantes. `HasSubmission` dedups by the full `SubmissionKey` = `[TransactionKey{Hash, Index}, TransactionKey{Hash, Index}]`. The same checkpoint content in different (block, tx_index) pairs is a different SubmissionKey and is accepted. `getEpochChanges` picks the "best" (deepest) submission for finalisation.

The BLS multi-sig is signed over `(epoch, BlockHash)` (`x/checkpointing/types/utils.go::GetSignBytes`), so cross-epoch replay (submitting a different epoch's BLS as if it were the current one) fails BLS verification.

### 3.4 x/checkpointing findings

**3.4.1 Vote-extension validation layering**

| Check | `vote_ext.go::VerifyVoteExtension` (CometBFT layer) | `proposal.go::VerifyVoteExtension` (proposer layer) |
|-------|----------------------------------------------------|-----------------------------------------------------|
| Length > 0 | ✓ (line 121-124) | ✓ (line 227-229) |
| `MaxVoteExtensionSize = 1024` | ✗ **MISSING** | ✓ (line 231-234) |
| `unknownproto.RejectUnknownFieldsStrict` | ✗ **MISSING** | ✓ (line 237-239) |
| Unmarshal | ✓ | ✓ |
| Round-trip Marshal integrity check | ✗ **MISSING** | ✓ (line 246-257) |
| `ve.Validate()` | ✓ (line 134-138, added by `9c52e24a`) | ✓ (line 259-261, added by `9c52e24a`) |
| Epoch number match | ✓ | (n/a — done elsewhere) |
| Signer/Validator address bech32 + match | ✓ (line 150-154) | ✓ (line 263-271) |
| BlockHash `bytes.Equal(req.Hash)` | ✓ (line 157, fixed by `9c52e24a`) | ✓ (line 273) |
| BLS sig verify | ✓ (line 164-175) | ✓ (line 279-281) |

**Real hardening gap**: a Byzantine validator can broadcast 100KB vote extensions with duplicate protobuf fields. The CometBFT layer accepts them; they're relayed over precommit gossip across all n^2 validator pairs. Only at the proposer layer (building the injected tx) are they pruned. The bandwidth amplification on the gossip layer is not bounded.

**3.4.2 Proposer pruning trust**

`PrepareProposal` calls `getValidBlsSigsAndPruneCommitInfo` which MUTATES `extCommit.Votes[i]` to mark invalid extensions as absent. The injected `MsgInjectedCheckpoint` carries the pruned `ExtendedCommitInfo`. `ProcessProposal` then runs `ValidateVoteExtensions` against the injected commit info plus rebuilds the checkpoint via `getValidBlsSigs` (read-only).

Since pruning is deterministic given the same vote-extension bytes, any honest validator running the same code reaches the same conclusions. A Byzantine proposer dropping a valid sig that wouldn't affect the 2/3 threshold has no effect on the rebuilt checkpoint (the pruned sigs would be pruned by validators too, by definition). A Byzantine proposer dropping a valid sig that DROPS the checkpoint below 2/3 — then the rebuild fails on validators too, the proposal is rejected, next round.

The TODO at line 459-461 ("indicates the existence of a fork (>1/3 malicious voting power) and we should probably send an alarm and stall the blockchain") is **incorrect** as an interpretation. The mismatch would actually indicate proposer-side tampering, not >1/3 vote-extension equivocation. Halting on this would give any malicious proposer a chain-halt primitive. Current reject-only behaviour is correct.

**3.4.3 BLS aggregation correctness**

`FindSubset` (`epoching/types/validator.go:49-66`) iterates `i := 0; i < len(vs); i++` and checks `bm.Get(i)`. The BTC raw checkpoint format hard-codes bitmap length to 13 bytes = 104 bits (`btctxformatter/formatter.go:48-51`). For validator sets ≤ 104, all bits are in range. For larger sets, `bm.Len() < len(vs)` errors out before iteration. Safe.

Note: PR #287 ("Fix vulnerability when processing bls sig transactions") was about adding `LastCommitHash` binding to the legacy pre-vote-extension flow, NOT about bitmap bounds. Distinct historical concern.

**3.4.4 Hook propagation**

I re-read all six `MultiCheckpointingHooks` methods in `x/checkpointing/types/hooks.go:18-70`. Only `AfterRawCheckpointForgotten` had the early-return bug (fixed by PR #1908). All other hooks correctly loop and return on first error.

The keeper-level wrappers in `x/checkpointing/keeper/hooks.go` are single-hook calls; no analogous bug possible.

The current MultiCheckpointingHooks wiring (`app/keepers/keepers.go:554-556`) registers only `EpochingKeeper.Hooks()` and `MonitorKeeper.Hooks()`. ZoneConcierge subscribes to other hooks (epoching, finality), not checkpoint-status hooks.

### 3.5 Cross-module observations

**3.5.1 Power-dist event ordering: SLASHED dominates JAILED**

`processEventsAtHeight` (power_dist_change.go:372-388) defers SLASHED events into `state.SlashedEvents`. `processInactiveFp` and per-height JAILED/UNJAILED apply immediately. After all per-height events are processed, `processSlashedEvents` (line 464-478) finally applies SLASHED, which sets `state.FPStatesByBtcPk[hex] = SLASHED` (overwrites any prior state).

The consumer in finality/keeper/power_dist_change.go:265-279 has:
```go
case ftypes.FinalityProviderState_SLASHED:
    continue  // skip — FP not added to new dist cache → power = 0
```

So a slashed-then-jailed (impossible) or jailed-then-slashed (possible) FP has its slashed flag dominate; its voting power is always 0.

**3.5.2 Stale commission in rewards (closed PR #1953)**

The voting-power distribution cache snapshots FP commission at the time of snapshot. `MsgEditFinalityProvider` updates the FP's commission in the btcstaking store but not in the cache. PR #1953 (`c1c2abe1`) added a refresh step before `RewardBTCStaking`. Historical bug; closed.

**3.5.3 Costaking AfterBtcDelegationUnbonded hook (closed GHSA-4rmq-mc2c-r495)**

Original logic at `x/costaking/keeper/hooks_finality.go`:
```go
if !isFpActiveInPrevSet || !isFpActiveInCurrSet { return nil }
```
This was wrong because it failed to subtract sats when an FP went from active → inactive in the same block as the delegation unbonded. Fixed by `b833baeda` (Dec 2025):
```go
if !isFpActiveInPrevSet { return nil }
```
New rule: subtract iff FP was active in the previous set. Out of scope for the four target modules.

---

## 4. Bug Family Synthesis (Phase 4 input)

See the Modeling Brief (`modeling-brief.md`) for the formal Bug Families. Summary:

| Family | Mechanism | Open Bugs | Closed/Historical | Severity | Modelable |
|--------|-----------|-----------|-------------------|----------|-----------|
| 1 | EOTS evidence lifecycle + pub-rand precommitment | #1984 | #1253, #174, #218 | HIGH | YES |
| 2 | Liveness/jailing bypass via active toggle | #1852 | #324, #620 | HIGH | YES |
| 3 | Checkpoint lifecycle FSM + BTC reorg coupling | — | #1908, #1136, #287, #842 | HIGH | YES |
| 4 | Vote-extension aggregation + proposer trust | (CR1 hardening) | GHSA-m6wq, GHSA-2fcv, PR #1911, PR #1923, `d0b75cfe` | MEDIUM-HIGH | YES |
| 5 | Power-dist event ordering + slash-vs-jail | — | #1813, #1805, #342, #180, #1875 | MEDIUM | YES |
| 6 | Governance + rewarding catch-up | #1979, #950, #938 | #992, #829 | LOW (safety) | partial |

---

## 5. False-Positive Exclusions

Items considered but excluded from MC targets:

- **Adaptor signature cryptographic details** — abstracted to authentication axioms. The receiver-side verification predicate (`EncVerifyAdaptorSignature`) is the bug surface in practice; modeling curve math adds nothing.
- **EOTS curve math** — same; model as `MathExtract(sig1, sig2, msg1, msg2)` operator, treat the algebra as sound.
- **BIP-322 / BIP-340 / Schnorr signature parsing canonicality** (#1853) — implementation-only; no protocol effect at the abstraction layer.
- **Hex normalization in gov proposals** (#1979) — string-handling bug; trivial to fix; not state-machine.
- **`MaxVoteExtensionSize` at CometBFT layer** (CR1) — bandwidth concern; modeling adds no value.
- **CometBFT block-production / vote-collection** — abstract: assume CometBFT delivers `(height, hash, voteExtensions)` tuples.
- **Stock Cosmos SDK modules** — out of scope per target instructions.
- **Wasm / IBC / zoneconcierge / EVM / monitor** — out of scope.
- **Refund accounting** — economic, no safety effect.
- **GHSA-4rmq-mc2c-r495 (`AfterBtcDelegationUnbonded` hook)** — module is `x/costaking`, out of the four targets.

Items considered as model-checkable but excluded as "already-fixed, no new mechanism to explore" (per `bug-archaeology.md` § 1.4):

- **PR #218 / #176 (VP `max(w, minUnbondingTime)` before timelock)** — fix is straightforward, no further unaudited sites in this mechanism; recorded as historical evidence under Family 1.
- **PR #1271 / #1253 (`MsgEquivocationEvidence` validation)** — completely fixed; would just re-derive the existing check. Recorded as evidence.
- **PR #186 / #174 (nil-proof panic)** — implementation-only; trivial to fix.
- **PR #287 (LastCommitHash binding)** — legacy pre-vote-extension flow; current vote-extension architecture supersedes it.
- **PR `9c52e24a` (nil block hash)** — fix is in tree; modeling the vulnerability would be `git revert` style. Recorded as evidence for Family 4.
- **PR #1908 (`AfterRawCheckpointForgotten` hook propagation)** — fix is in tree; recorded as evidence for Family 3.

---

## 6. Reference Pointers

See `modeling-brief.md` § 7 for the consolidated list. Key sources:
- Babylon whitepaper: "Bitcoin Staking: Secure Proof-of-Stake using Bitcoin", docs.babylon.network
- Aumayr et al., "Generalized Channels from Limited Blockchain Scripts and Adaptor Signatures"
- Babylon's own EOTS construction paper
- DLS 1988 (partial-synchrony BFT model); Castro-Liskov 1999 (PBFT)
- CometBFT vote-extension RFC and ABCI++ spec
