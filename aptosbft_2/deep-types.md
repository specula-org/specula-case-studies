# Aptos BFT consensus-types — Deep verification analysis

Scope: receiver-side verification logic that guards every node from Byzantine
senders. All line citations refer to files under
`/home/ubuntu/Specula/case-studies/aptosbft_2/artifact/aptos-core/consensus/consensus-types/src/`.

Cross-referenced helpers:
- `aptos-core/types/src/validator_verifier.rs` lines 254-285 (`verify`,
  `optimistic_verify`).
- `aptos-core/types/src/ledger_info.rs` lines 303-308 (`verify_signatures` =
  `verify_multi_signatures(self.ledger_info(), &self.signatures)`).
- `aptos-core/consensus/src/round_manager.rs` line 180 (only
  `verify_order_vote` is invoked on inbound order-vote messages — the QC
  packed inside is NOT verified at network-layer entry).

---

## 1. Verification function inventory

| Function | File:line | Sender authentication | Content checks | What is NOT checked |
|---|---|---|---|---|
| `Vote::verify` | `vote.rs:151-175` | `optimistic_verify(self.author, &self.ledger_info, &self.signature)` (BLS over `LedgerInfo`) | `self.ledger_info.consensus_data_hash() == self.vote_data.hash()` (155); inner `vote_data.verify()` (well-formedness only); when `two_chain_timeout` present, that `(timeout.epoch, timeout.round) == (self.epoch, vote_data.proposed.round)` (162-166), then `timeout.verify` and signature on `timeout.signing_format()` | **Does not verify** that `ledger_info.commit_info()` is consistent with anything the sender could have observed (e.g. epoch of `LedgerInfo` vs `vote_data.proposed.epoch`); does not enforce TODO at line 152 ("ensure timeout is `None` if RoundTimeoutMsg is enabled"); does not validate sender is a permitted voter for the proposed round (only that they are *some* validator with a public key). |
| `VoteMsg::verify` | `vote_msg.rs:56-81` | indirectly via `vote.verify` | `vote.author == sender` (57-62); `vote.epoch == sync_info.epoch` (63-66); `vote.proposed.round > sync_info.highest_round()` (67-70); when timeout present, `timeout.hqc_round <= sync_info.highest_certified_round()` (71-76) | The bundled `SyncInfo` is **not** verified here (comment 77-79: "we are going to verify it only in case we need it"). A Byzantine sender can therefore ship arbitrary fake QCs/TCs in the embedded `SyncInfo`, and they pass `VoteMsg::verify` even when they would have failed `SyncInfo::verify`. Subsequent code paths must remember to call `sync_info.verify(...)` before trusting any field. |
| `TwoChainTimeout::verify` | `timeout_2chain.rs:74-81` | none (this is a payload struct, signature is checked by callers) | `hqc_round() < round()`; recursive `quorum_cert.verify(validator)` | No epoch field of the carried QC is cross-checked against `self.epoch`; a TC field where `qc.certified_block.epoch != self.epoch` is not rejected here. (See debug_assert audit.) |
| `TwoChainTimeoutCertificate::verify` | `timeout_2chain.rs:141-183` | aggregate BLS over per-signer `TimeoutSigningRepr { epoch, round, hqc_round_signed_by_that_signer }` (147-167); `timeout.verify(validator)` covers the highest QC | `hqc_round == max(signed rounds)` (170-181) | Does **not** check that the signers form a quorum: `verify_aggregate_signatures` only checks signatures match — there is no `check_voting_power` here. The 2f+1 threshold is therefore not enforced inside `verify`; correctness depends on every caller separately invoking `check_voting_power` (none do in these files). Also does not verify the carried `timeout.epoch` matches the `validator` set's epoch — a TC built from epoch e signatures could pass if the validator set used to verify it happens to overlap. |
| `QuorumCert::verify` | `quorum_cert.rs:119-148` | aggregate BLS via `signed_ledger_info.verify_signatures(validator)` (143) which calls `verify_multi_signatures(ledger_info(), signatures)` | `ledger_info.consensus_data_hash() == vote_data.hash()` (121-124) — **this is the value-binding hook**; for round 0 (genesis) extra structural checks (128-141); inner `vote_data.verify()` (146) | `verify_multi_signatures` itself enforces a *super majority* threshold via `check_voting_power(..., true)` — so quorum is enforced for QCs (unlike TCs above). However, no cross-check that `ledger_info.epoch == vote_data.proposed.epoch`. |
| `OrderVote::verify` | `order_vote.rs:83-93` | `optimistic_verify(self.author, &self.ledger_info, &self.signature)` (BLS over `LedgerInfo`) | `ledger_info.consensus_data_hash() == HashValue::zero()` (84-87) — i.e. enforces that this LedgerInfo has no vote-data binding | The "consensus_data_hash must be zero" guard means an OrderVote signature covers `LedgerInfo` whose `consensus_data_hash` field was forced to zero. **Aside from `commit_info` and zero hash, nothing in the LedgerInfo is bound to anything else here.** No epoch check beyond what's inside `ledger_info`. |
| `OrderVoteMsg::verify_order_vote` | `order_vote_msg.rs:48-67` | `order_vote.author == sender` (53-58); delegates BLS to `order_vote.verify` | `quorum_cert.certified_block() == order_vote.ledger_info().commit_info()` (59-62) | Comment at 47 explicitly says **"The quorum cert is verified in the round manager when the quorum certificate is used."** The QC's signatures and value-binding are NOT verified here. A Byzantine peer can ship an unsigned/forged QC, paired with a valid OrderVote whose `commit_info()` happens to match `qc.certified_block()`. This is fine **only if** the round manager actually verifies the QC before using it. The check at `round_manager.rs:180` only calls `verify_order_vote`. |
| `WrappedLedgerInfo::verify` | `wrapped_ledger_info.rs:90-108` | aggregate BLS via `signed_ledger_info.verify_signatures(validator)` | Genesis short-circuit: if `ledger_info.round == 0` only check `get_num_voters() == 0` (97-103) | Critically, **`verify_consensus_data_hash()` (53-62) is NOT called inside `verify`.** The wrapped struct's `vote_data` field is therefore *not* bound to the `signed_ledger_info` during verification. The comment at line 14-18 acknowledges this: "vote_data and consensus_data_hash inside signed_ledger_info are not used anywhere in the code and can be set to dummy values" — but this also means a Byzantine sender can swap `vote_data` to anything because it isn't covered by signatures. Any caller that reads `wrapped.vote_data.proposed()` is reading attacker-controlled data. The only verified content is what's inside the signed `LedgerInfo` itself (`commit_info`). |
| `OrderVoteProposal` | `order_vote_proposal.rs` | none | none — no `verify` method exists | This struct is internal/safety-rules, not network-facing. |
| `SyncInfo::verify` | `sync_info.rs:138-212` | three nested aggregate BLS calls (HQC/HOC/HCC); each via the per-cert `verify` | epoch consistency between HQC, HOC, HCC, TC (140-150); `HQC.round >= HOC.round` (152-156); `HOC.round >= HCC.round` (158-165); HOC and HCC commit_info are non-empty (167-175); in non-test builds, `HCC.commit_info` is not "ordered only" (178-185) | Calls `WrappedLedgerInfo::verify` for HOC/HCC, which (see above) only verifies that the *signed LedgerInfo* itself has 2f+1 signatures; it does NOT re-verify the embedded `vote_data`. Because the verifier passed in is the *current* validator set, a SyncInfo from a different epoch will fail signature verification — but a SyncInfo whose HCC is *behind* the receiver's current state will still pass and can be replayed (it is not freshness-checked). |
| `RoundTimeout::verify` | `round_timeout.rs:97-107` | `validator.verify(self.author, &self.timeout.signing_format(), &self.signature)` (BLS over `TimeoutSigningRepr`) | `timeout.verify(validator)` (98) — recursively verifies the embedded QC | Reason field (`reason: RoundTimeoutReason`) is **not part of the signed payload** (`signing_format()` only contains `epoch`, `round`, `hqc_round`). A Byzantine peer can attach an arbitrary `reason` to a legitimate signature (e.g. claim payload was unavailable when the round just timed out normally). |
| `RoundTimeoutMsg::verify` | `round_timeout.rs:153-171` | delegates to `RoundTimeout::verify` | `round_timeout.epoch == sync_info.epoch` (154-157); `round_timeout.round > sync_info.highest_round()` (158-161); `timeout.hqc_round <= sync_info.highest_certified_round()` (162-166) | Same SyncInfo-deferral comment (167-169) — the carried `SyncInfo` is **not** verified here. |
| `VoteData::verify` | `vote_data.rs:59-80` | none | epochs of parent/proposed match (60-63); `parent.round < proposed.round` (64-67); `parent.timestamp <= proposed.timestamp` (68-71); version monotonicity unless decoupled execution dummy (72-78) | Pure well-formedness; no signature check here. |
| `ProposalMsg::verify` | `proposal_msg.rs:82-128` | `proposal.validate_signature(validator)` (114-117) — block author's sig over `BlockData`; `proposal_author == sender` (92-99) | parallel `payload.verify(...)` (101-112); if a TC is present in sync_info, that TC is verified (122-125); finally `verify_well_formed()` | `verify_well_formed` (33-80) checks block is non-NIL, round > 0, proposal epoch == sync_info epoch, parent_id == sync_info HQC certified_block id, `previous_round == max(proposal QC round, sync_info highest TC round)`. It does **NOT** verify the proposal's own carried `quorum_cert` (the `Block::quorum_cert()`). The QC is verified only via the `validate_signature` path on `Block` (need to inspect Block) — but more importantly `sync_info` is not verified (123-126). |
| `OptProposalMsg::verify` | `opt_proposal_msg.rs:96-131` | `proposer == sender` (106-111) (no block-author signature for opt-proposals — see Section E) | parallel `payload.verify` and `grandparent_qc.verify(validator)` (113-127); then `verify_well_formed` | No signature on the OptProposal itself. The leader is not authenticated (only "the sender claims to be the proposer"). The sync_info is not verified. The `proposer` field is taken from `block_data` which is never signed. See Section E for full attacker scenario. |
| `OptProposalMsg::verify_well_formed` | `opt_proposal_msg.rs:54-94` | none | `block_data.verify_well_formed()` (well-formedness on opt block); `round > 1` (58-62); epoch matches sync_info (63-66); grandparent_qc.certified_block.id == sync_info HQC certified_block.id (68-74); `round - 2 == grandparent_qc.certified_block.round` (75-87); no TC in sync_info (89-92) | Does NOT check that `proposer` is the legitimate leader of `round`. |

---

## 2. `debug_assert` audit

Only one file in the inventory contains `debug_assert*`:
**`timeout_2chain.rs`** (`TwoChainTimeoutWithPartialSignatures::add` at lines 242-263).

| Line | Assertion | Variable | Enforced in release? | Risk |
|---|---|---|---|---|
| `timeout_2chain.rs:248-252` | `debug_assert_eq!(self.timeout.epoch(), timeout.epoch(), "Timeout should have the same epoch as TimeoutCert")` | inbound `timeout.epoch()` vs the cert's `self.timeout.epoch()` | **No.** Stripped in release. The function then unconditionally calls `self.signatures.add_signature(author, hqc_round, signature)` (262). | **Production risk:** epoch mismatch in `add()` is silently accepted in release builds. See analysis below. |
| `timeout_2chain.rs:253-257` | `debug_assert_eq!(self.timeout.round(), timeout.round(), "Timeout should have the same round as TimeoutCert")` | inbound `timeout.round()` vs cert's `self.timeout.round()` | **No.** Same path: round-mismatched timeouts are added regardless. | **Production risk:** round mismatch in `add()` is silently accepted in release. |

`TwoChainTimeoutWithPartialSignatures` is the local aggregator used between
receiving individual `TwoChainTimeout` votes and producing a
`TwoChainTimeoutCertificate`. The **brief's specific concern** (cross-epoch
replay reaching a release-build node) plays out here:

- `add()` does NOT enforce epoch/round equivalence in release.
- A Byzantine peer who can reach the aggregator with a `TwoChainTimeout` whose
  internal `epoch != self.timeout.epoch()` would inject their signature into
  the partial-sig map (line 262 has no guard). The signature was over
  `TimeoutSigningRepr { epoch=their_epoch, round=their_round, hqc_round }` — a
  message different from what the cert claims to aggregate.
- The downstream `aggregate_signatures` (267-282) builds a
  `TwoChainTimeoutCertificate` whose **claimed epoch** is `self.timeout.epoch()`
  but the **signature being aggregated** was signed over
  `their_epoch`. When the aggregated cert is later verified by a peer:
  - `TwoChainTimeoutCertificate::verify` (141-183) reconstructs
    `TimeoutSigningRepr { epoch: self.timeout.epoch(), round: self.timeout.round(), hqc_round: round }` (155-160) using the **aggregator's** claimed epoch/round.
  - The aggregate signature verification will fail because the bytes-signed
    differ. So the **bad cert will not pass downstream verification** — the
    invariant survives because of the verify path, not because of the
    `add()` path. **However**: a single honest aggregator that processes a
    cross-epoch timeout from a Byzantine sender will pollute its own partial
    sig set silently in release; the resulting cert it tries to publish
    later will simply fail to validate, wasting a round and possibly
    triggering DoS / slashing edge cases that depend on whether the local
    aggregator considers the cert "ours". This is a liveness / DoS bug
    rather than an immediate safety bug — but the brief's specific
    concern (release nodes accepting cross-epoch replay through this path)
    is **partially** validated: the invariant relies on the downstream
    verify, not on local enforcement.

There are no other `debug_assert*` calls in the listed files.

`assert_eq!` in `AggregateSignatureWithRounds::new` (`timeout_2chain.rs:362`)
is a real (release) assertion: `assert_eq!(sig.get_num_voters(), rounds.len());`
That one is enforced.

---

## 3. Certificate value-binding analysis

| Cert | Signed payload (per signer) | What `verify` binds to that payload | Substitution possible? |
|---|---|---|---|
| `QuorumCert` | `LedgerInfo` (its 2f+1 signatures cover serialized `LedgerInfo`) | `quorum_cert.rs:121-124` enforces `ledger_info.consensus_data_hash == vote_data.hash()`. Therefore the QC's `vote_data` is bound to the LedgerInfo via the consensus-data-hash field. | No: substituting `vote_data` invalidates the hash equality; substituting `ledger_info` invalidates signatures. **Sound.** |
| `WrappedLedgerInfo` | `LedgerInfo` only | `wrapped_ledger_info.rs:90-108`: ONLY `signed_ledger_info.verify_signatures()`. The `verify_consensus_data_hash` helper exists at lines 53-62 but is **NOT called from `verify`** (only from `certified_block` and `into_quorum_cert`). | **Yes.** A Byzantine sender can attach an arbitrary `vote_data` field to a wrapped LI — any caller that reads `wrapped.vote_data` after only running `verify` is reading unsigned data. The "safe" usage is `wrapped.commit_info()` (which returns the signed `ledger_info().commit_info()`); unsafe usage is anything that touches `wrapped.vote_data`. This is by design per the design doc comment at lines 14-18, but it's a **footgun**. |
| `TwoChainTimeoutCertificate` | per signer: `TimeoutSigningRepr { epoch, round, hqc_round_for_that_signer }` (98-103) | `timeout_2chain.rs:141-183`: aggregate verify with reconstructed per-signer message; then `hqc_round == max(signed_hqc)`; the carried `quorum_cert` (the highest one) is verified separately. | Partial. The round and the highest-hqc-round are bound, but value-binding is **only** to "this signer signed off on a timeout for `(epoch, round)` with their hqc round being `r_i`". The carried `QuorumCert` itself is the QC that *the highest-hqc signer* claims to have, and it's verified by `timeout.verify` — but no signer actually signed *this specific QC*; they signed only its round number. So a Byzantine aggregator that controls one signer who signed `hqc_round=H` could substitute any *other* valid QC at round H. This is a real substitution surface for the "highest QC" carried by a TC. |
| `OrderVote`'s LedgerInfo | `LedgerInfo` (with `consensus_data_hash = 0`) | `order_vote.rs:84-87`: enforces `consensus_data_hash == HashValue::zero()`, then BLS sig over the LI. | The LI's `commit_info` is signed. So the order vote binds the signer to "I attest commit_info should be `commit_info()`". But the **paired QC in `OrderVoteMsg`** is only consistency-checked (`qc.certified_block() == order_vote.ledger_info().commit_info()` at lines 59-62) — the QC itself is not signature-verified inside `verify_order_vote`. **Substitution possible** for the QC unless the round manager later runs `qc.verify`. |

Conclusion: QC binding is sound. WrappedLedgerInfo's `vote_data` is unbound,
relying on documented "don't read it" convention. TC's "highest QC" pointer is
unbound (only its round is signed). OrderVoteMsg's QC is unbound at network
intake — relies on round-manager calling `.verify()` later.

---

## 4. Cross-message replay (signature-payload coverage)

| Message | Signed bytes | Replayable across? |
|---|---|---|
| `Vote` | `LedgerInfo` (with `consensus_data_hash = vote_data.hash()`) | The `LedgerInfo` includes `commit_info` which carries epoch/round/id/version. Combined with the consensus-data-hash binding, the signed bytes encode (epoch, round-of-proposed, parent-id, ...) — replay across (epoch, round) is **not** possible. |
| `Vote`'s 2-chain timeout | `TimeoutSigningRepr { epoch, round, hqc_round }` | Distinct from the vote LedgerInfo signature. **Important asymmetry**: the timeout signature does NOT cover the *vote's* commit info, so the same signer can validly produce both a vote-on-block-X *and* a 2-chain-timeout-for-round-r without conflict. This is documented as "fast-vote with timeout" but it means the receiver cannot tell, from signatures alone, whether the signer voted on block X or just timed out — both are present. The receiver-side aggregator must avoid double-counting. |
| `OrderVote` | `LedgerInfo` (with `consensus_data_hash = 0`) | The signed payload is the entire `LedgerInfo`, which includes `commit_info().epoch()` and `commit_info().round()`. Cross-round replay requires forging a different commit_info. **However**, vote vs order-vote asymmetry: a regular `Vote`'s `LedgerInfo` has `consensus_data_hash = vote_data.hash()`; an `OrderVote`'s `LedgerInfo` has `consensus_data_hash = 0`. Both are signed by the same key. If the verification logic for a `Vote` accepts `LedgerInfo` with consensus_data_hash zero (it does not — line 155 enforces equality), no overlap occurs. Conversely, `OrderVote::verify` enforces zero (line 84-87). The two paths are disjoint by virtue of those checks. |
| `RoundTimeout` | `TimeoutSigningRepr { epoch, round, hqc_round }` | Identical signing format as Vote's 2-chain timeout. **A signature collected for a `RoundTimeoutMsg` is byte-identical to a signature that would unlock a 2-chain timeout in a `Vote`**. So a Byzantine relayer who collected a `RoundTimeout` for `(e, r, hqc)` can mint a `Vote` whose 2-chain-timeout sub-field uses that signature, provided they also produce a vote LedgerInfo for round r and reuse the timeout signature. This is exploitable iff the receiver-side aggregator counts both as if they were separate timeout signers — which depends on dedup logic above the type layer. |
| `TwoChainTimeout` (signing) | `TimeoutSigningRepr { epoch, round, hqc_round }` | Same as above — **no `reason` field**, no per-message nonce. |
| Proposal block | `BlockData` (covered by `validate_signature`) — exact contents in `block.rs`. | Not in scope here, but `ProposalMsg::verify_well_formed` enforces `proposal.parent_id == sync_info.HQC.certified_block.id` and `previous_round == max(proposal QC round, sync_info TC round)` (`proposal_msg.rs:51-73`). |
| `OptProposalMsg` | **Nothing** at the message level. | The only authentication is "sender field == proposer field" (no signature). The `grandparent_qc` is verified, but the opt-proposal itself is unsigned. See Section E. |

The biggest cross-replay concern is the `RoundTimeout` ↔ `Vote.two_chain_timeout`
signature-format identity: both sign `TimeoutSigningRepr`. Dedup must be at the
per-signer layer above this code; nothing in the type definitions prevents the
same BLS signature from being re-presented in a different envelope.

---

## 5. SyncInfo handling

`SyncInfo::verify` (`sync_info.rs:138-212`) does the right structural and
quorum checks: epoch consistency between HQC/HOC/HCC/TC (140-150), round
ordering (152-165), non-empty commit info (167-175), and recursively verifies
each carried cert with the supplied `validator`.

What `verify` does NOT do:
- It does not check that the received `SyncInfo` is "fresher" than my local
  state. (`has_newer_certificates` exists at 218-223 but is the caller's
  responsibility.)
- It does not check that the carried HCC is the *highest* HCC the network has
  reached — a Byzantine sender can ship a *valid past* SyncInfo to push
  another node back. (Combined with the receiver tolerating
  `highest_round` going up, this is mostly benign.)
- Critically: **`VoteMsg::verify` and `RoundTimeoutMsg::verify` defer
  SyncInfo verification** (`vote_msg.rs:77-80`, `round_timeout.rs:167-170`).
  The SyncInfo travels unverified through the verify-at-network-edge layer.
  Whoever later consumes `vote_msg.sync_info()` or
  `round_timeout_msg.sync_info()` MUST call `.verify()` first; if they don't,
  the receiver can be tricked into believing in a non-existent QC/TC/LI.

A Byzantine validator can absolutely construct a `SyncInfo` that passes
`verify` if they have legitimate certs at hand (those certs *are* signed by
2f+1). The risk is: they ship an old, valid `SyncInfo` to revive replays of
old QCs. Combined with the WrappedLedgerInfo vote_data unboundness (Section
3), an attacker could construct a `SyncInfo` whose HOC.vote_data field is
adversarial while the signed LedgerInfo is genuine. Any code that reads
`sync_info.highest_ordered_cert().vote_data.proposed()` (rather than
`commit_info()`) is reading attacker data.

---

## 6. Optimistic-proposal verification

`OptProposalMsg::verify` (`opt_proposal_msg.rs:96-131`) verifies:
- `sender == proposer` (`block_data.author()`).
- `payload.verify` (txn payload well-formedness).
- `grandparent_qc.verify(validator)` (full QC sig verification).
- `verify_well_formed` checks (54-94):
  - `block_data.verify_well_formed()`: parent.round = grandparent.round + 1,
    self.round = parent.round + 1, all in same epoch, no reconfiguration on
    grandparent, payload epoch matches, strictly increasing timestamps, not
    too far in the future (`opt_block_data.rs:75-116`).
  - `round > 1`.
  - epoch == sync_info.epoch.
  - `block_data.grandparent_qc.certified_block.id == sync_info.HQC.certified_block.id`.
  - `round - 2 == grandparent_qc.certified_block.round`.
  - sync_info has NO timeout cert.

Critical missing checks:
1. **No leader/proposer authentication.** The opt-proposal carries no
   signature on `block_data`. The `verify` function only checks that the
   sender field on the network message equals the `proposer` field inside
   the block. Therefore **any validator can claim to be the leader of round
   `r`** — e.g. validator B can craft an OptBlockData with
   `author = leader_of_r` *if they could spoof the network sender*. They
   can't directly spoof at the network layer if mTLS / signed envelopes
   exist at a lower layer, but **the consensus-types layer offers no
   defence**. By contrast, `ProposalMsg` requires
   `proposal.validate_signature(validator)` (`proposal_msg.rs:114-117`) on
   the carried `Block`.
2. **No leader-of-round check.** Neither `verify` nor `verify_well_formed`
   queries any `ProposerElection` to confirm `proposer == leader_of(round)`.
   A validator who is *not* the leader of round r could legitimately be
   accepted as the opt-proposal sender (subject only to network-layer
   sender check). This is presumably intentional — leader checking is in the
   round manager — but worth flagging that the type-layer offers no
   protection.
3. **Parent BlockInfo is unverified.** The opt-proposal carries
   `parent: BlockInfo` (`opt_block_data.rs:26`) which is the round-(r-1)
   parent. There is no QC for the parent (only for the grandparent). A
   Byzantine "leader" can forge any parent BlockInfo as long as
   `parent.round = grandparent_qc.round + 1` and `parent.id != grandparent.id`
   wouldn't be checked here — the ID-equality check at line 69 only ties
   `grandparent_qc.id == sync_info.HQC.id`, not parent to grandparent. The
   safety argument relies on the recipient executing the parent block from
   their own block tree before voting.
4. **Sync info unverified at message edge** (line 129).

Attacker scenario: a Byzantine party who is not the actual round-r leader
can ship a well-formed `OptProposalMsg` with `author = themselves`. Receivers
that trust the sender field will accept it; they may then race-vote on the
opt-proposal's contents. If they ALSO see the legitimate leader's regular
`ProposalMsg` for round r, they may end up evaluating two parallel chains in
the same round. Safety still depends on the safety-rules signing logic
forbidding the second vote; liveness suffers.

---

## 7. Per-file findings (line-cited)

### `vote.rs`
- Lines 152, "TODO(ibalajiarun): Ensure timeout is None if RoundTimeoutMsg is enabled."
  An unfulfilled TODO. Until done, a Byzantine voter can attach a 2-chain
  timeout signature to a vote even when the network is running the
  `RoundTimeoutMsg` path; aggregators that listen on both channels could
  double-count timeout votes.
- Lines 161-170: when timeout is present, only the *coarse*
  `(epoch, round) == (vote.epoch, vote.proposed.round)` is enforced. The
  `hqc_round` inside the timeout is not constrained to anything in the vote.

### `vote_msg.rs`
- Lines 77-80 explicitly defer SyncInfo verification. Any code reading
  `vote_msg.sync_info()` must run `.verify()` itself.

### `timeout_2chain.rs`
- Lines 248-257: `debug_assert_eq!` (epoch, round) — see Section 2.
- Line 169-181: `TwoChainTimeoutCertificate::verify` does not enforce the 2f+1
  threshold (no `check_voting_power`).
- Lines 305-318 (`replace_signature`, `remove_signature`) are
  `#[cfg(any(test, feature = "fuzzing"))]` — fine.

### `quorum_cert.rs`
- Lines 119-148: properly value-binds `vote_data` to the signed
  `LedgerInfo` via consensus-data-hash. Strongest of the cert types.

### `order_vote.rs`
- Line 84-87: enforces `consensus_data_hash == 0`. This means **the order
  vote signs the LedgerInfo *minus* any vote-data binding** — the receiver
  cannot tell from this signature what `vote_data` (parent block) the
  signer was extending. The contract is "I attest the commit info should
  be X"; that is sufficient for the order-vote use case but means
  order-votes cannot be re-purposed as quorum-cert signatures.

### `order_vote_msg.rs`
- Lines 47-67: explicit comment "The quorum cert is verified in the round
  manager when the quorum certificate is used." Confirmed at
  `consensus/src/round_manager.rs:180` — only `verify_order_vote` is called
  on inbound. **A Byzantine peer can ship an `OrderVoteMsg` whose `quorum_cert`
  has invalid signatures**; it will pass `verify_order_vote` as long as
  `qc.certified_block() == order_vote.ledger_info().commit_info()`. The
  later round-manager-side QC verification is the only barrier.

### `order_vote_proposal.rs`
- No verification, internal struct.

### `sync_info.rs`
- Line 60: `highest_2chain_timeout_cert = highest_2chain_timeout_cert.filter(|tc| tc.round() > highest_quorum_cert.certified_block().round())`.
  Constructor-side filter; could leak attacker-controlled drop logic if
  attacker can modify HQC. (Mostly benign; constructor-side.)
- Lines 61-68: `fail_point!("consensus::ordered_only_cert", …)` injects a
  test-only behaviour. With the `failpoints` feature enabled in production
  this would degrade the highest_commit_cert to highest_ordered_cert and
  emit unexecuted state as committed. Should not be enabled in release.
- Line 178-185: HCC "ordered only" check is `#[cfg(not(any(test, feature="fuzzing")))]`.
  Honest behaviour in release; tests pass even with an ordered-only HCC.

### `round_timeout.rs`
- Lines 97-107: `RoundTimeout::verify` signs only `signing_format()` =
  `{epoch, round, hqc_round}` — `RoundTimeoutReason` (lines 17-22) is
  **unsigned**. An attacker can substitute the `reason` field on any
  legitimate signed `RoundTimeout` in transit. If the receiver makes
  decisions based on `reason` (e.g. "if `PayloadUnavailable`, retry the
  payload"), they can be fooled.

### `vote_data.rs`
- Line 65-66: `parent.round() < proposed.round()` (strict). Adjacent rounds
  are required only for `OptBlockData`; `VoteData::verify` allows gaps
  (consistent with TC-driven round skips).

### `wrapped_ledger_info.rs`
- Lines 90-108: `verify` does NOT call `verify_consensus_data_hash` (53-62).
  Consequence: `vote_data` field is unsigned/unbound. Documented as
  intentional but is the largest "footgun" in the file set.
- Line 97: comment "Earlier, we were comparing self.certified_block().round()
  to 0. Now, we are comparing self.ledger_info().ledger_info().round() to 0.
  Is this okay?" — open question in the source. With the new check, a
  WrappedLedgerInfo whose `vote_data.proposed.round != 0` but whose
  `signed_ledger_info.ledger_info.round == 0` would be silently treated as
  genesis and skip signature verification. Because `vote_data` is unbound
  (above), **a Byzantine sender can ship a wrapped LI whose `vote_data`
  proposes a high-round block and whose `signed_ledger_info` is the genesis
  (round 0) LI** — `verify` returns Ok with no signatures required. Any
  caller reading `wrapped.vote_data.proposed()` then sees an attacker-chosen
  block claiming to be certified.

### `proposal_msg.rs`
- Lines 122-125: TC inside `sync_info` is verified; `sync_info` itself is
  not (see line 126).
- Lines 51-57: `proposal.parent_id == sync_info.HQC.certified_block.id` is
  enforced — but `sync_info.HQC` itself is unverified at this stage (only
  inside the embedded `verify` calls of `verify_well_formed`'s callees, which
  is `proposal.validate_signature` not `sync_info.verify`).

### `opt_proposal_msg.rs`
- See Section 6.

---

## 8. Top suspicious findings (mapped to bug families)

1. **`WrappedLedgerInfo::verify` skips `verify_consensus_data_hash` —
   certificate value-binding bug.** (`wrapped_ledger_info.rs:90-108`,
   helper at 53-62.) `vote_data` is attacker-controlled. Any caller using
   `wrapped.vote_data.proposed()` after only `verify` is reading unsigned
   data. Combined with the round-0 bypass (97-103), an attacker can build a
   wrapped LI that passes `verify` with no signatures yet claims any
   high-round block via `vote_data`. **Family: certificate value-binding /
   cross-epoch replay.**

2. **`debug_assert_eq!` for epoch/round in `TwoChainTimeoutWithPartialSignatures::add` (`timeout_2chain.rs:248-257`).** Stripped in release. The claim
   in the brief — "Byzantine validators could exploit this in production" —
   is partially correct: the local aggregator silently accepts cross-epoch /
   cross-round timeouts, which the downstream `verify` will reject because
   the per-signer signing payload includes the epoch/round. The realistic
   exploit is **liveness denial** of the local node: poison the partial-sig
   aggregator so the produced TC fails verification and gets discarded. Not
   a direct safety violation, but the brief's specific concern is valid and
   should be hardened by promoting these to real `ensure!`/`if`-return.
   **Family: cross-epoch replay (DoS surface).**

3. **`TwoChainTimeoutCertificate::verify` does NOT enforce 2f+1 quorum**
   (`timeout_2chain.rs:141-183`). It calls `verify_aggregate_signatures` (no
   threshold check) and `timeout.verify` (only verifies the carried QC),
   plus the consistency between max signed `hqc_round` and the cert's
   `hqc_round`. The voting-power check is the caller's responsibility. If
   any code path treats a verified TC as "good" without separately checking
   threshold, a single signer's TC would be accepted. **Family: pipeline
   race / certificate value-binding.**

4. **`OrderVoteMsg::verify_order_vote` does NOT verify the embedded QC**
   (`order_vote_msg.rs:47-67`, comment at 47). Receiver-side QC verification
   is deferred to the round manager. A Byzantine peer can ship an
   `OrderVoteMsg` carrying a forged QC paired with a valid (single-signer)
   order vote whose `commit_info` matches the forged QC's `certified_block`.
   Any code that takes the QC out of an order-vote message before the round
   manager verifies it is reading attacker data. **Family: order-vote vs
   regular-vote asymmetry / pipeline race.**

5. **`RoundTimeoutReason` is unsigned** (`round_timeout.rs:17-22, 97-107`).
   The signing format (`signing_format()` in `timeout_2chain.rs:66-72`)
   covers only `{epoch, round, hqc_round}`. A man-in-the-middle (or any
   relayer) can rewrite `reason: NoQC` to `reason: PayloadUnavailable {
   missing_authors }` while keeping the original signature. Receivers that
   take action based on `reason` can be misled. **Family: opt-proposal
   bypass / cross-message replay (signed payload omission).**

6. **`OptProposalMsg` has no signature on `block_data`** (`opt_proposal_msg.rs:96-131`,
   and `OptBlockData` has no signing helper in `opt_block_data.rs`). The
   only authentication is a network-layer sender field. By contrast,
   `ProposalMsg` requires `proposal.validate_signature(validator)`. If
   sender authentication at the network layer is ever bypassed (e.g.
   gossip relay through trusted peers), the consensus-types layer offers
   zero defence on an opt-proposal. **Family: opt-proposal bypass.**

7. **Vote ↔ RoundTimeout signature reuse** (`vote.rs:161-170`,
   `round_timeout.rs:97-107`, both signing `TimeoutSigningRepr`). The two
   message envelopes carry byte-identical signed payloads. A Byzantine
   relayer can lift the signature out of a `RoundTimeoutMsg` and place it
   into the `two_chain_timeout` field of a forged `Vote` (constructing a
   matching vote LedgerInfo around it). Whether this matters depends on
   whether downstream aggregators count the same signer twice across the
   two channels. **Family: crash-window double vote / cross-message
   replay.**

8. **SyncInfo verification is consistently deferred** (`vote_msg.rs:77-80`,
   `round_timeout.rs:167-169`, `proposal_msg.rs:126`). All three
   network-edge `verify` methods explicitly skip `sync_info.verify(...)`.
   Any consumer that uses fields off of `sync_info()` before invoking
   `.verify()` is exposed to fully attacker-controlled QCs/TCs/LIs. The
   pattern is correct *only if* every consumer is disciplined; a single
   mistaken read is a vulnerability. **Family: pipeline race /
   certificate value-binding.**

9. **`Vote::verify` allows a 2-chain timeout to be attached even when the
   network is running `RoundTimeoutMsg`** (TODO at `vote.rs:152`). Until
   the TODO is resolved, an aggregator that listens for both `Vote` and
   `RoundTimeoutMsg` could double-count the same signer. **Family: crash-
   window double vote.**

10. **`OptProposalMsg::verify_well_formed` checks
    `grandparent_qc.id == sync_info.HQC.id`** (`opt_proposal_msg.rs:68-74`)
    but the sync_info itself is unverified at this point. So an attacker who
    can ship a fake sync_info whose HQC is a forged QC (verifiable only at
    a later step) can tunnel a forged grandparent reference into the
    receiver's view. **Family: opt-proposal bypass / pipeline race.**

---

## 9. Cross-epoch replay assessment (brief's specific concern)

The brief asks whether release-build nodes can be made to accept cross-epoch
replays through the `debug_assert_eq!` in `timeout_2chain.rs`.

Findings:
- The two `debug_assert_eq!` calls live in the *aggregator*
  (`TwoChainTimeoutWithPartialSignatures::add`), not in the *verifier*.
- The verifier (`TwoChainTimeoutCertificate::verify`, `TwoChainTimeout::verify`)
  is fully runtime-enforced (real `ensure!` and signature checks).
- **Direct cross-epoch acceptance via this debug_assert is not possible**,
  because the per-signer signed payload includes `epoch`. Cross-epoch
  signatures will fail aggregate verification on the receiver side.
- **Indirect impact**: a Byzantine peer who can deliver cross-epoch
  `TwoChainTimeout` messages to an honest aggregator silently corrupts that
  aggregator's local state in release. The corruption manifests as
  invalid certs being produced and dropped — a liveness/DoS concern, not a
  safety violation.

Cross-epoch replay paths that *do* exist independently of this debug_assert:
- `WrappedLedgerInfo::verify` skipping consensus-data-hash binding (Finding
  #1) lets an attacker substitute `vote_data` across epochs because the
  field is never signed.
- `SyncInfo` verification being deferred at three message edges (Finding
  #8) means cross-epoch fields are tunneled through `vote_msg`/`round_timeout_msg`/`proposal_msg` until later read. The `SyncInfo::verify` epoch
  consistency checks (`sync_info.rs:140-150`) only fire when `verify` is
  actually called.

Recommendations the brief implies:
- Promote the two `debug_assert_eq!` to real `ensure!`/`if !... { return }`
  guards in `add()` (timeout_2chain.rs:248-257).
- Make `WrappedLedgerInfo::verify` also call `verify_consensus_data_hash`
  (or change the API so `vote_data` cannot be read after only `verify`).
- Enforce 2f+1 voting-power threshold inside
  `TwoChainTimeoutCertificate::verify`.
- Remove the deferred-SyncInfo pattern, or wrap consumer-side reads behind
  a "verified" type-state.
- Either sign `RoundTimeoutReason` or document that consumers must not act
  on `reason` for safety.
- Decide whether opt-proposals should be signed by the leader, given the
  asymmetry with regular `ProposalMsg`.
