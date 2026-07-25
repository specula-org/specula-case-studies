# Modeling Brief: Aptos BFT (HotStuff / Jolteon)

## 1. System Overview

- **System**: `aptos-labs/aptos-core`, the BFT consensus that drives Aptos mainnet. Scope is `consensus/` only (out of scope: execution, mempool, governance, RPC, Move VM, network transport).
- **Language**: Rust. Core safety-rules ~1250 LOC; round-manager and pipeline ~6 kLOC; consensus-types verifiers ~3 kLOC.
- **Protocol**: AptosBFT — 2-chain HotStuff (Jolteon) extended with **order votes** (3-hop ordering, AIP-89) and **optimistic proposals** (AIP-131, leader extends parent before parent's QC arrives).
- **System category**: **Category A (Distributed / Message-Passing)** with a **Byzantine threat model** (`n ≥ 3f + 1`, static authenticated faulty set, partial synchrony). Composition of the 6 distributed fault families with the BFT adversary categories from `bft-analysis.md` is required.
- **Key architectural choices that deviate from textbook HotStuff/Jolteon**:
  - SafetyRules is a **separate process/thread** addressed by RPC (`safety_rules_manager.rs`, `SerializerService` / `ThreadService` / `ProcessService` backends).
  - Decoupled execution pipeline: Order → BufferManager → Execution → Signing → Persist as **separate Tokio tasks** wired by 12 *unbounded* channels (`decoupled_execution_utils.rs:96`).
  - Two ordering paths in the same code: regular vote → QC → 2-chain commit, **AND** order-vote → `WrappedLedgerInfo` (commit cert in 3 hops).
  - Two proposal paths: `ProposalMsg` (BLS-signed Block) and `OptProposalMsg` (no signature on `block_data`).
  - Optimistic optimisations everywhere: optimistic signature verification, optimistic block payload prefetch, pre-commit before commit-proof.
- **Concurrency model**: One `tokio::select!` event loop per epoch in `RoundManager::start`. Safety-relevant signing serialised through `Arc<Mutex<MetricsSafetyRules>>`. Pipeline phases run on independent tasks behind channels. Network verification runs on a bounded blocking executor (so an epoch transition can race with in-flight verifications).
- **Persistent state (SafetyData)**: `epoch`, `last_voted_round`, `preferred_round`, `one_chain_round`, `last_vote`, `highest_timeout_round`. Persisted via `set_safety_data`; the new fields `one_chain_round` and `highest_timeout_round` are `#[serde(default)]`, defaulting to 0 on legacy on-disk data.
- **Prior-round context**: The earlier formal analysis on this codebase confirmed one defense-in-depth gap (order-vote / regular-vote round-tracking asymmetry) and **failed to reproduce** the hypothesised double-vote-after-crash because it required a Byzantine equivocating proposer that was not modelled. The hypotheses for this round are the Byzantine-proposer half of MC-4, plus several new mechanism candidates this analysis surfaced.

## 2. Bug Families

### Family 1 — Crash-window double vote with Byzantine equivocating proposer (HIGH)

**Mechanism**: `guarded_construct_and_sign_vote_two_chain` signs the vote (`safety_rules_2chain.rs:88`) **before** persisting `safety_data` (`:92`). If a Byzantine peer can observe the signed vote (e.g. the SafetyRules RPC backend returned the bytes; a process-level `ProcessService` worker is doing the IO) and the node then crashes before `set_safety_data` is durable, on recovery `last_voted_round` reads the old value. A Byzantine leader that supplies a *different* proposal at the same round re-enters the `verify_and_update_last_vote_round` check at `safety_rules.rs:218-225` — the check passes because `last_voted_round` is still R−1 — and the node signs a second, conflicting vote at round R. Equivocation is observed by honest validators; safety is broken.

The corresponding timeout path persists *before* signing (`safety_rules_2chain.rs:47` then `:49`), which is the canonical fix. Commit `f58e184471` is the historical analogue (timeout-side equivocation fix). The vote-path equivocation has no deterministic-signing escape hatch because the vote payload differs across conflicting proposals.

**Evidence**:
- Code analysis: `safety_rules_2chain.rs:88-92` (sign-then-persist for regular vote); `:115-117` (same pattern in order-vote path with `preferred_round`/`one_chain_round` advance lost); `safety_rules.rs:412-413` (commit vote has no persist at all and explicit TODOs).
- Historical: Issue **#18298** — community reporter filed the same observation with a PoC; maintainer disputed on grounds that the persist precedes the network broadcast. The dispute is contingent on the SafetyRules backend's `set` being synchronously durable, which is **not** guaranteed by `OnDiskStorage` (`on_disk.rs:64-70` writes a temp file then `fs::rename` with **no `fsync` / `sync_all`**) and was the reason the timeout path was already fixed by `f58e184471`. The Byzantine-equivocating-proposer half of MC-4 was explicitly noted as unmodelled in the previous round.
- Echo-timeout re-entry through `EchoTimeout` can cause two timeouts to be signed for the same round across a crash window (`round_manager.rs:1855-1857` × `safety_rules_2chain.rs:37-45`; `safe_to_timeout` allows `round == last_voted_round`).
- `SafetyData::one_chain_round` and `highest_timeout_round` use `serde(default)` → 0 after binary upgrade from a legacy format, widening the accept set for order-votes and 2-chain timeouts.

**Affected code paths**:
- `consensus/safety-rules/src/safety_rules_2chain.rs:53-95` (`guarded_construct_and_sign_vote_two_chain`)
- `consensus/safety-rules/src/safety_rules_2chain.rs:97-119` (`guarded_construct_and_sign_order_vote`)
- `consensus/safety-rules/src/safety_rules.rs:372-418` (`guarded_sign_commit_vote`, two open TODOs)
- `consensus/safety-rules/src/persistent_safety_storage.rs:150-170` (`set_safety_data` plus cache clear-on-error)
- `secure/storage/src/on_disk.rs:64-70` (no fsync)

**Suggested modeling approach**:
- Variables: split `last_voted_round` into `persistent_last_voted_round[s]` and `inflight_signed_vote[s]` (the latter exists between sign and persist). Add `persistent_last_vote[s]` and `inflight_last_vote[s]` analogously.
- Actions: split `Vote(s, r, v)` into `SignVote(s, r, v)` (creates `inflight_signed_vote`, emits message) and `CompletePersistVote(s)` (writes `persistent_last_voted_round`). Add `Crash(s)` that drops `inflight_*` and any non-persistent state. After `Crash`, `Recover(s)` reloads from persistent state only. Provide also the atomic combined action for trace validation.
- Compose with **2.1 Equivocation** (Byzantine proposer issues conflicting proposals at the same round) and **2.6 Amnesia** (the recovered validator now "forgets" its earlier vote).
- Invariant: no honest validator may have two distinct emitted Vote messages with the same `(epoch, round)`.

**Priority**: High
**Rationale**: This is the unmodelled half of MC-4 from the prior round. Issue #18298 is filed in production. The mechanism is concrete: the persist-order asymmetry vs the timeout path is visible in the source. No upstream fix has landed.

---

### Family 2 — Order-vote vs regular-vote / timeout guard asymmetry (HIGH)

**Mechanism**: Order voting (AIP-89) was added after the original 2-chain rules and inherited a *strictly weaker* guard surface than regular votes. Each historical PR has fixed exactly one missing check (#13711 added epoch, #14129 split QC verification, #14637 made the RX bind the QC into pending state, #13605 added `process_certificates` advance). The remaining asymmetries in the current code:

| Guard | Regular vote (`construct_and_sign_vote_two_chain`) | Order vote (`construct_and_sign_order_vote`) | Timeout vote |
|---|---|---|---|
| Epoch | `verify_epoch` (`safety_rules.rs:70`) | `verify_epoch` (`:94`) — added by #13711 | `verify_epoch` (`safety_rules_2chain.rs:26`) |
| `last_voted_round` (read) | yes (`:218`) | **NO** | yes (`:37-42`) |
| `last_voted_round` (update on success) | yes (`:225`) | **NO** | yes when `>` (`:43-45`) |
| `highest_timeout_round` (read) | no | yes (`safe_for_order_vote`, `:170`) | no |
| Block author signature | yes (`safety_rules.rs:73-77`) | **NO** | n/a |
| Block well-formedness | yes (`:78-80`) | **NO** | n/a |
| Persist before sign | **NO** (sign `:88`, persist `:92`) | **NO** (sign `:115`, persist `:117`) | yes (`:47` persist, `:49` sign) |
| `ensure_round_and_sync_up` (RX side) | yes (`round_manager.rs:1739` for VoteMsg, `:1900` for RoundTimeoutMsg) | **NO** (`process_order_vote_msg` skips it) | yes |
| Per-author equivocation map (aggregator) | yes (`pending_votes.rs:287-309` emits `EquivocateVote`) | **NO** (`pending_order_votes.rs:61-157` has no `author_to_vote`) | first-write-wins via BTreeMap (`timeout_2chain.rs:320-329`) |
| Subsequent-message QC verification | n/a (each VoteMsg signature verified) | only FIRST `OrderVoteMsg` per `li_digest` verifies the QC (`round_manager.rs:1613-1633`) | n/a |

Multiple of these compose: an honest validator can regular-vote at R, an external Byzantine peer triggers `construct_and_sign_order_vote` at the same R with a different `OrderVoteProposal`, and the order-vote path neither reads nor updates `last_voted_round`. The signed artifacts are over distinct payloads (`vote_data.hash()` vs `HashValue::zero()`), so they are not "the same vote", but the *signer* produced two distinct safety-critical signatures at the same round.

**Evidence**:
- Code analysis: `safety_rules_2chain.rs:97-178`; `safety_rules.rs:87-111` vs `:67-85`; `round_manager.rs:1582-1660` (no `ensure_round_and_sync_up`); `pending_order_votes.rs:61-157` (no equivocation map).
- Historical: **PRs #13711, #14129, #14637, #13605, #14570, #18023, #15452** — six order-vote-specific corrections in a row, all clustering after #13023's order-vote introduction. Each fixed one omission; the list above is what still survives.
- Prior round's "DA-28" (view advance side-effect on rejected Prepare) and the earlier confirmed gap in this codebase are in the same family.

**Affected code paths**:
- `consensus/safety-rules/src/safety_rules.rs` — `verify_proposal` vs `verify_order_vote_proposal`
- `consensus/safety-rules/src/safety_rules_2chain.rs` — `guarded_construct_and_sign_vote_two_chain` vs `guarded_construct_and_sign_order_vote` vs `guarded_sign_timeout_with_qc`, and `safe_for_order_vote`
- `consensus/src/round_manager.rs:1582-1660` — `process_order_vote_msg`
- `consensus/src/pending_order_votes.rs:61-157` — `insert_order_vote`
- `consensus/consensus-types/src/order_vote_msg.rs:48-67` — `verify_order_vote`

**Suggested modeling approach**:
- Variables: distinguish `voted_for[s, e, r]` (which value(s) the validator has voted for) from `order_voted_for[s, e, r]`. Track `highest_timeout_round[s]` as a separate variable from `last_voted_round[s]`.
- Actions: `OrderVote(s, r, v)` as a *separate* action whose guards exactly mirror the implementation's `safe_for_order_vote` (only `r > highest_timeout_round`). Do **not** add a `last_voted_round` guard on this action — the goal is to expose what the implementation actually permits.
- Aggregator: model `pending_order_votes` as a per-(round, digest) bag with no author-deduplication (matching the lack of equivocation map). Allow a single Byzantine validator's signature to contribute to two distinct digests' aggregators.
- Composition: this Family combines with **Family 1** (crash-window) and with **2.7 Certificate / Quorum-Proof Manipulation** below.

**Priority**: High
**Rationale**: Six historical PRs and a confirmed unfixed asymmetry (no `last_voted_round` interlock on order votes). The prior round established that this family is bug-dense; this audit shows more checks are still missing.

---

### Family 3 — Certificate / message value-binding gaps (HIGH)

**Mechanism**: Receiver-side `verify` predicates in `consensus-types/` are inconsistent about *which* fields of a message they actually authenticate. Several signed messages omit fields from the signed payload (so a relayer can rewrite them in transit), and several `verify` methods do not check the value-binding helpers they ship with. This makes category **2.7 Certificate / Quorum-Proof Manipulation** load-bearing.

| Cert / message | Verification gap | File:line |
|---|---|---|
| `WrappedLedgerInfo::verify` | Does NOT call `verify_consensus_data_hash` (the helper is at `:53-62`, but `verify` at `:90-108` only runs aggregate sig + a round-0 shortcut). `vote_data` is therefore unsigned/attacker-controlled. Combined with the round-0 short-circuit, a Byzantine sender can ship a wrapped LI that passes `verify` with 0 signatures and arbitrary `vote_data.proposed`. | `consensus-types/src/wrapped_ledger_info.rs:90-108` |
| `TwoChainTimeoutCertificate::verify` | Does NOT enforce the 2f+1 quorum — only aggregate signature validity and `hqc_round == max(signed)`. Quorum is the caller's responsibility. | `consensus-types/src/timeout_2chain.rs:141-183` |
| `OrderVoteMsg::verify_order_vote` | Does NOT verify the embedded QC's signatures — comment at `:47` says "verified in the round manager when used". A Byzantine peer can ship an `OrderVoteMsg` with a forged QC paired with a valid OrderVote whose `commit_info` matches. | `consensus-types/src/order_vote_msg.rs:47-67` |
| `RoundTimeout` | `RoundTimeoutReason` is NOT part of `TimeoutSigningRepr`. A man-in-the-middle can rewrite `reason` (e.g. `NoQC` → `PayloadUnavailable`) while keeping the signature. | `consensus-types/src/round_timeout.rs:17-22` and `timeout_2chain.rs:66-72` |
| `OptProposalMsg` | No signature on `block_data`. Authentication is only "sender field == proposer field". By contrast, `ProposalMsg` requires `proposal.validate_signature(validator)`. | `consensus-types/src/opt_proposal_msg.rs:96-131` |
| `Vote` ↔ `RoundTimeout` | Both sign byte-identical `TimeoutSigningRepr`. A signature from one envelope can be lifted into the other (vote's `two_chain_timeout` field). | `vote.rs:152` (open TODO) + `round_timeout.rs:97-107` |
| `Vote/RoundTimeout/Proposal` `verify` | All three explicitly defer `sync_info.verify` (comments `vote_msg.rs:77-80`, `round_timeout.rs:167-169`, `proposal_msg.rs:126`). Any consumer reading off `vote_msg.sync_info()` fields before calling `.verify()` is reading attacker-controlled data. | as cited |
| `safety_rules::sign_commit_vote` | No `verify_epoch(old_ledger_info.epoch(), &safety_data)`; no `last_committed_round` dedup; no extension check. Explicit TODOs at `:412-413`. | `consensus/safety-rules/src/safety_rules.rs:372-418` |

**Evidence**: code analysis as cited; PR #14637 history (order-vote QC binding) and PR #13986 history (commit-vote / ordered-LI mismatch after fast-forward) confirm the value-binding mechanism is bug-prone.

**Affected code paths**: see table.

**Suggested modeling approach**:
- Use the **`ByzReuseRealCertificate`** action from `bft-analysis.md` § 2.7 — a Byzantine sender takes a real existing certificate and mutates its value (or its embedded fields). The base predicate models the receiver-side gaps: e.g. for `WrappedLedgerInfo`, the verifier does not bind `vote_data` to the signed LedgerInfo, so `ByzReuseRealCertificate` should be allowed to mutate `vote_data.proposed.round`.
- For `OrderVoteMsg`, model the deferred-QC-verify gap explicitly: the inner QC field in subsequent OrderVoteMsgs is `ByzForgeable` (no honest-signature forgery; the QC bytes can be replaced by any QC the receiver wouldn't independently verify).
- For `sign_commit_vote`, split the commit-vote action and add an explicit `BadEpoch` precondition that the implementation fails to check.
- Invariant: if a node signs a commit vote for `new_ledger_info`, then the new_ledger_info's `commit_info` actually extends an `ordered_only` LI the node has previously certified — currently *not* enforced by `match_ordered_only`.

**Priority**: High
**Rationale**: Multiple discrete value-binding omissions, each at a receiver predicate that the rest of the codebase trusts. This is the bug class the BFT case-study reference singles out as the highest-yield (autobahn DA-1/DA-2/DA-3 are all instances).

---

### Family 4 — Cross-epoch replay (MEDIUM)

**Mechanism**: Several code paths use round / id only, not `(epoch, round, id)`, or check epoch via release-stripped `debug_assert`. PR #13711 added the epoch check to `verify_order_vote_proposal` on the *signing* side, but the *receive-and-aggregate* side at `round_manager.rs:1582-1660` still relies on the EpochManager filter on `OrderVoteMsg.epoch` and does not bind the inner QC's `certified_block().epoch()` to the order-vote's epoch. In the same file family:

- `consensus-types/src/timeout_2chain.rs:248-257` — `TwoChainTimeoutWithPartialSignatures::add` has `debug_assert_eq!` for epoch / round matching. In release these are no-ops; the aggregator silently absorbs a cross-epoch / cross-round timeout. The downstream `TwoChainTimeoutCertificate::verify` does re-sign-check using the cert's claimed epoch/round, so the bad cert fails the next hop's verify — making this a *liveness/DoS* surface for the local node (its own aggregator is poisoned), not a direct safety violation.
- `epoch_manager.rs:1692-1750` — the bounded-executor verification task captures `epoch_state.verifier` by Arc-clone before spawning. After `start_new_epoch` rotates state, a verification result already in flight is delivered through the old `round_manager_tx`, which by then has shut down — so the message is silently dropped. The order-of-operations is currently safe, but a refactor that left the old RM alive across the rotation would expose a real cross-epoch delivery.
- `SafetyData` is reset to `(new_epoch, 0, 0, 0, None, 0)` on epoch advance — correct (rounds are per-epoch), but combined with `OnDiskStorage` non-durability (Family 1) means a Byzantine epoch downgrade through a forged proof would erase round history. Mitigated by `EpochChangeProof::verify(&waypoint)` upstream.

**Evidence**:
- Code analysis: `consensus-types/src/timeout_2chain.rs:248-257`; `consensus-types/src/order_vote_msg.rs:47-67`; `consensus/src/epoch_manager.rs:1692-1750`.
- Historical: PR **#13711** (epoch check added in signing path), PR **#2990** (leader reputation cross-epoch fetch), PR **#12018** (RPC epoch dispatch), and the prior round's `MC_epoch` `ReceiveTimeoutWeakEpoch` / `ReceiveOrderVoteWeakEpoch`.

**Affected code paths**:
- `consensus-types/src/timeout_2chain.rs:242-263` (`TwoChainTimeoutWithPartialSignatures::add`)
- `consensus-types/src/order_vote_msg.rs:47-67` (`verify_order_vote`)
- `consensus/src/round_manager.rs:1582-1660` (`process_order_vote_msg`)
- `consensus/src/epoch_manager.rs:1692-1750` (in-flight verification across epoch transition)

**Suggested modeling approach**:
- Compose **2.5 Replay** with **5.5 ConfigChange** (epoch transition). Use the `ByzReplay` action with `newCtx = newEpoch`: a Byzantine identity takes a real signed message from epoch N and re-emits it claiming `epoch = N+1`.
- For the `debug_assert` site, split the aggregator action into `BeginAggregate(s, cert)` and `AddSignature(s, sig, claimed_epoch)`. In `MC.tla`, allow `claimed_epoch != cert.epoch` and observe whether the resulting cert can pass downstream verify (it shouldn't, per the analysis — so MC should *not* find a safety bug here, only a DoS). This becomes a falsifiable hypothesis.
- Build on the prior round's `MC_epoch.tla` — the existing `ReceiveTimeoutWeakEpoch` / `ReceiveOrderVoteWeakEpoch` actions already cover the signing side; extend to cover the RX-side aggregator.

**Priority**: Medium
**Rationale**: Partly covered by prior round. The aggregator-side `debug_assert` gap is new evidence; the inner-QC-epoch unbinding in `OrderVoteMsg` is a real implementation asymmetry left over after PR #13711's fix.

---

### Family 5 — Pipeline race / decoupled-execution non-atomicity (MEDIUM, mostly test/code-review)

**Mechanism**: The execution pipeline is 4 separate Tokio tasks plus per-block future graphs in `pipeline_builder.rs`. Inter-phase channels are all *unbounded* (`buffer_manager.rs:96-100`); persistence is not atomic across multiple steps (`block_store.rs:531-568` mutates in-memory tree at `:559` then persists at `:564`; `block_store.rs:348-358` takes two separate `inner.write()` locks); pre-commit state is in-memory only and recomputed from `root_block_round` on restart (`pipeline_builder.rs:83-117`, `block_store.rs:251-253`); sync-manager inserts peer-supplied QCs without re-verifying signatures (`sync_manager.rs:359-364`, `:521-527`, author's own TODO `:530-531`).

This family is the most active source of historical bugs (PRs #17766, #12239, #15746, #19359, #19084, #4232 — six pipeline races in a row), but most of the residual gaps are about local persistence ordering and async hand-off — issues that are best caught by integration tests / Loom-style execution-order testing rather than TLA+. The interesting modelable subset is:

- The signing/persist gap for *commit votes*: `safety_rules.sign_commit_vote` does no persistence (`safety_rules.rs:372-418`). Commit votes are broadcast from `pipeline_builder.rs:1215-1217` and a 30s rebroadcast (`buffer_manager.rs:861-863`) is the only mitigation. The buffer-manager comment makes the lack of persistence explicit: "Since we don't persist the votes, nodes that crashed would lose the votes even after send ack."
- The `assert_eq!` on commit-info inconsistency in `buffer_item.rs:149, :262` panics the BufferManager if local execution disagrees with a pre-aggregated commit proof. Safety-correct, liveness-bad.

**Evidence**: code analysis as cited; six historical PRs.

**Affected code paths**:
- `consensus/src/pipeline/buffer_manager.rs:96-100, 412-431, 861-863`
- `consensus/src/pipeline/buffer_item.rs:149, :262, :65-77`
- `consensus/src/pipeline/pipeline_builder.rs:83-117, 1215-1217, 1257-1263, 1297-1305`
- `consensus/src/pipeline/persisting_phase.rs:65-79`
- `consensus/src/block_storage/block_store.rs:251-253, 348-358, 524-526, 531-568`
- `consensus/src/block_storage/block_tree.rs:381, 591-599`
- `consensus/src/block_storage/sync_manager.rs:328-365, 510-635`

**Suggested modeling approach**:
- For commit-vote ordering, add a *commit-vote-broadcast* action separate from *commit-proof-persist* and check that a node that has broadcast a commit vote can later be made to broadcast a *different* commit vote at the same logical position (via Family 1's crash mechanism applied to commit votes).
- Most other pipeline-race gaps are best left to test-verification (§ 6.2).

**Priority**: Medium
**Rationale**: Historically very bug-dense, but model-checking-suitable subset is narrow; the rest is mechanical reasoning about lock acquisitions and channel ordering.

---

### Family 6 — Recovery / sync state divergence (LOW)

**Mechanism**: `RecoveryManager::start` (`recovery_manager.rs:120-170`) exits via `process::exit(0)` on successful recovery (`:154-157`) — there is no graceful handoff back to RoundManager in the same process. Anything queued in `event_rx` past the success message is dropped. `BlockStore::fast_forward_sync` (`sync_manager.rs:481-641`) writes the tree (`save_tree :619`), then drives execution (`sync_to_target :629`), then re-reads `storage.start :635` — three steps with no atomicity. A crash in between can leave block tree ahead of execution state.

**Evidence**: PRs **#13986, #1826, #13864**; code analysis as cited.

**Affected code paths**:
- `consensus/src/recovery_manager.rs:84-170`
- `consensus/src/block_storage/sync_manager.rs:481-641`
- `consensus/safety-rules/src/safety_rules.rs:372-418` (`guarded_sign_commit_vote` lacks state to detect "I previously signed an ordered-only LI that's incompatible with the recovered chain")

**Suggested modeling approach**: This is largely covered by composing `Crash` (5.1) with `Snapshot/StateTransfer` (5.6). The "process exit + operator restart" semantics can be approximated by a sequence of `Crash; Recover` with no in-flight message preservation. Lower priority for this round given Families 1-4.

**Priority**: Low
**Rationale**: Bug-class historically real but already amortised across CFT-style spec mechanisms.

---

### Family 7 — Optimistic-proposal bypass (LOW-MEDIUM)

**Mechanism**: `OptProposalMsg` is a parallel proposal path with weaker checks than `ProposalMsg`:
- No BLS signature on `block_data` — only "sender == proposer field" (`opt_proposal_msg.rs:96-131`).
- `failed_authors` validation in `process_proposal` is gated `if !proposal.is_opt_block()` (`round_manager.rs:1259-1274`).
- At receive time, the proposer's claimed `grandparent_qc` is matched only by `id` against `sync_info.HQC` (`opt_proposal_msg.rs:68-74`); at vote time, `Block::new_from_opt` (`round_manager.rs:902`) substitutes the *local* HQC — the proposer's QC claim is never re-checked against the block_store.

**Evidence**: code analysis as cited; PR #15452 fixed an OptQS staleness bug in the same family.

**Affected code paths**:
- `consensus/consensus-types/src/opt_proposal_msg.rs`
- `consensus/src/round_manager.rs:820-913, 1259-1274`

**Suggested modeling approach**: model `ProposeOpt(s, r, v)` as a distinct proposal action without an author signature; expose the `is_valid_proposer` check happening only on the queue branch (`round_manager.rs:864`) and not on the immediate-loopback branch (`:854`). Invariant: any block voted on must have come from the leader of its round.

**Priority**: Low-Medium
**Rationale**: Concrete asymmetries with regular ProposalMsg but mostly relies on network-layer authentication for safety today.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| **Sign-then-persist crash window** in vote / order-vote paths | Family 1 — addresses the unmodelled MC-4 half | Split `Vote` into `SignVote` and `CompletePersistVote`; add `Crash`/`Recover` that drops in-flight; persistent state is what survives |
| **Byzantine equivocating proposer** at same round | Family 1 composition partner — required to trigger the crash-window | `ByzEquivocate(s, r, v1, v2)` from `bft-analysis.md` § 2.1 — Byzantine `s ∈ Faulty` emits two distinct Vote-eligible proposals |
| **Order-vote action without `last_voted_round` interlock** | Family 2 — the surviving asymmetry after PRs #13711/#14129/#14637 | Distinct `OrderVote(s, r, v)` whose guard is only `r > highest_timeout_round[s]`; does not consult or update `last_voted_round[s]` |
| **Pending-order-votes aggregator with no equivocation map** | Family 2 — `pending_order_votes.rs:61-157` is asymmetric with `pending_votes.rs:287-309` | Model `pending_order_votes` as a bag keyed by `(round, digest)` accepting any author for any digest; allow a single faulty `s` to contribute to two distinct digests' aggregators |
| **WrappedLedgerInfo verify omission** (`vote_data` unsigned) | Family 3 — `verify` skips `verify_consensus_data_hash` | `ByzReuseRealCertificate(s, wli, val_target)` mutates only `vote_data.proposed.round`; receiver-side predicate matches the implementation (sig-only, no value-binding) |
| **OrderVoteMsg deferred-QC verification** | Family 3 — receiver only verifies QC of FIRST per `li_digest` | Model two paths in `ProcessOrderVote`: `WithVerifiedQC` and `WithoutVerifiedQC`; on the latter, the carried QC is the value the Byzantine sender wants the receiver to "absorb" |
| **`sign_commit_vote` missing epoch / extension checks** | Family 3 — TODOs at `safety_rules.rs:412-413` | `SignCommitVote(s, ordered_li, new_li)` with the implementation's actual guards (only `match_ordered_only` and signature threshold) — no epoch, no extension; expose what TLC can find |
| **Cross-epoch order-vote replay through inner QC** | Family 4 — `OrderVoteMsg::verify_order_vote` doesn't bind OrderVote.epoch to QC.epoch | Extend prior round's `MC_epoch.tla` `ReceiveOrderVoteWeakEpoch` to also allow the inner QC's `certified_block.epoch` to differ from `order_vote.epoch` |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| **`OnDiskStorage` lack of `fsync`** | This is a storage-backend defect, not a protocol-layer issue. The protocol-layer crash window (Family 1) already assumes "the persist may be lost". |
| **FIFO vs documented LIFO in `network.rs`** | Doc/code mismatch (Family 5 finding 5); code-review-only. |
| **Pipeline phase channel unboundedness** | Local resource concern, not protocol logic. |
| **Pre-commit / commit-ledger ordering** | The semantics belong to the executor's storage layer, not consensus safety. Pre-commit is documented as "not client-visible". |
| **Equivocation slashing absence** (`pending_votes.rs:299-308` logs only) | Slashing is on-chain governance, out of scope. |
| **RPC self-message short-circuit** (`epoch_manager.rs:1721`) | Network-layer authentication assumption; defensible. |
| **Recovery `process::exit(0)`** | Implementation choice; modelling the "operator restart" boundary adds states without adding bug-finding value beyond Family 1. |
| **`pessimistic_verify_set` reset per epoch** | Optimisation cache; per-epoch CPU waste, not a safety issue. |
| **PreVote-style optimisations** | Not present in this codebase. |
| **All randomness / DKG paths** | Out of scope per prompt; they are a separate signing pipeline. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Non-atomic vote persist | `persistent_safety_data[s]`, `inflight_signed_vote[s]`, `inflight_persist_pending[s]` | Capture the crash window between sign and persist in `guarded_construct_and_sign_vote_two_chain` | 1 |
| Crash + recovery action | `crashed[s]` flag; `Crash(s)` drops volatile state, `Recover(s)` reloads `persistent_safety_data` | Required to reach the post-crash double-vote scenario | 1 |
| Byzantine equivocation by proposer | (faulty set actions; no new variables, just `ByzEquivocate` action body) | Provides the conflicting proposal that triggers the double-vote at recovered round | 1, 2 |
| Order-vote action and aggregator | `order_voted_for[s, e, r]`, `pending_order_votes[e, r, digest]` | Distinguish order-vote from regular vote at the spec level; no per-author dedup | 2 |
| WrappedLedgerInfo value-rebind | `ByzReuseRealCertificate` shape with `EXCEPT !.vote_data.proposed.round = X` | Models `verify` omission of `verify_consensus_data_hash` | 3 |
| OrderVoteMsg inner-QC trust split | flag `first_seen_digest[e, r]` to gate verifier strictness | Models receiver only verifying the QC on FIRST sighting | 2, 3 |
| Commit-vote missing epoch / extension | `signed_commit_for[s, ordered_li, new_li]` — distinct from `voted_for` | Models `sign_commit_vote` accepting an arbitrary `new_ledger_info` whose `commit_info` matches `match_ordered_only` | 3 |
| Cross-epoch ByzReplay | `ByzReplay(s, m_old, newEpoch)` action | Combine with `5.5 ConfigChange` for epoch boundaries (extend `MC_epoch.tla`) | 4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| `Agreement` | Safety | No two honest validators commit different blocks at the same height | Standard; baseline for all families |
| `NoDoubleVote` | Safety | An honest validator emits at most one `Vote` per `(epoch, round)`. **Strengthened from prior round** to test the post-crash recovery path. | Family 1 |
| `NoCrossPathSign` | Safety | An honest validator does not emit both a `Vote` and an `OrderVote` for distinct values at the same `(epoch, round)`. Currently the implementation does not guard this on the order-vote side. | Family 2 |
| `OrderVoteAggregatorDedup` | Safety | If `pending_order_votes` reports `EnoughVotes` for a digest, no two of the 2f+1 signers are the same author. **Currently violated** because the aggregator has no per-author check. | Family 2 |
| `QCValueBound` | Safety | If `WrappedLedgerInfo::verify` returns Ok, `vote_data.proposed` equals what the 2f+1 signers actually voted for. **Currently violated** because `verify_consensus_data_hash` is skipped. | Family 3 |
| `TCQuorumPower` | Safety | If `TwoChainTimeoutCertificate::verify` returns Ok, the signers form ≥ 2f+1 voting power. **Currently relies on caller** — modelable as "the verify pred does or does not include the threshold check". | Family 3 |
| `CommitEpochBound` | Safety | A node signs a commit vote only for `new_ledger_info` whose `epoch` matches `safety_data.epoch`. **Currently violated** (`sign_commit_vote` does no epoch check). | Family 3 |
| `OrderVoteEpochBound` | Safety | An accepted order vote's inner QC has the same `certified_block().epoch()` as the order-vote's epoch. **Currently not enforced at RX**. | Family 4 |
| `RecoverPreservesLastVote` | Safety (crash-recovery) | After `Crash(s); Recover(s)`, `persistent_safety_data[s].last_voted_round` ≥ any round at which `s` had emitted a Vote whose response had been received by an honest peer. This is **currently violated** under the sign-then-persist ordering. | Family 1 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected violation | Bug Family |
|----|-------------|-------------------|------------|
| MC-1 | Byzantine equivocating proposer + crash between sign and persist allows the recovered honest validator to sign a second vote at the same round for a different block | `NoDoubleVote`, `RecoverPreservesLastVote` | 1 |
| MC-2 | A node that has regular-voted at round R then accepts a Byzantine-supplied OrderVoteProposal at round R with a different block, signs an OrderVote because `safe_for_order_vote` doesn't consult `last_voted_round` | `NoCrossPathSign` | 2 |
| MC-3 | Two distinct `li_digest` order-cert quorums can both reach 2f+1 in `pending_order_votes` at the same round because the aggregator has no per-author equivocation check | `OrderVoteAggregatorDedup` (then propagate to `Agreement`) | 2 |
| MC-4 | A receiver accepts a `WrappedLedgerInfo` whose `vote_data` was rebound to a different round by a Byzantine relayer (no signature on `vote_data` since `verify_consensus_data_hash` is not called in `verify`) | `QCValueBound` | 3 |
| MC-5 | `sign_commit_vote` accepts a `new_ledger_info` whose epoch differs from `safety_data.epoch` because there is no `verify_epoch` call in the commit-vote path | `CommitEpochBound` | 3 |
| MC-6 | A Byzantine relayer replays a real `OrderVote` from epoch N as an `OrderVoteMsg` in epoch N+1 whose inner QC remains from N, slipping past the RX-side epoch filter (which checks only `order_vote.epoch`) | `OrderVoteEpochBound`, `Agreement` | 4 |
| MC-7 | Echo-timeout re-entry combined with `safe_to_timeout`'s `round == last_voted_round` admission lets an honest node sign two distinct timeouts for the same round across a crash window | `NoDoubleVote` (timeout variant) | 1 |

Each MC item is a *forward-looking* mechanism question, not a reproduction of a closed PR. The historical PRs in § 2 are reference context for why the family is bug-prone.

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|-------------------------|
| T-1 | `OnDiskStorage::write` lacks `sync_all`/directory `fsync` — power-loss after `rename` can revert | Crash-injection harness on a power-loss-emulating filesystem (e.g. `dm-flakey`) plus a SafetyData round-trip |
| T-2 | `set_safety_data` clears cache to None on storage error, next read pulls from disk | Mock storage backend to return Err after a successful real write; assert cache state |
| T-3 | `SafetyData` `serde(default)=0` on `one_chain_round`, `highest_timeout_round` for legacy on-disk format | Deserialize a serialised legacy SafetyData; assert post-load values |
| T-4 | `pipeline_builder.rs:1215-1217` broadcasts commit vote with no preceding persist; 30s rebroadcast is the recovery | Kill node between sign and rebroadcast; assert other validators do not see a divergent commit vote on restart |
| T-5 | `BlockStore::insert_single_quorum_cert` mutates in-memory tree before saving | Inject save failure; assert restart consistency |
| T-6 | `BlockStore::send_for_execution` takes two separate `inner.write()` locks; readers see inconsistent state | Concurrent reader thread under Loom |
| T-7 | `BufferManager::process_ordered_blocks` dispatches execution before pushing buffer item | Loom test with reordered scheduling |
| T-8 | `sync_manager.rs:328-365` (`fetch_quorum_cert`) inserts peer-supplied QCs without re-verifying signatures | Inject a peer that returns blocks with forged `quorum_cert` fields; assert downstream `find_root` rejects |
| T-9 | `pessimistic_verify_set` is reset per epoch (`validator_verifier.rs:199`) | Cross-epoch test that exercises the optimistic-then-pessimistic path |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | `consensus-types/src/timeout_2chain.rs:248-257` — promote `debug_assert_eq!` to `ensure!` for epoch/round | Submit PR; one-line fix |
| CR-2 | `consensus-types/src/round_timeout.rs:17-22` — include `RoundTimeoutReason` in `TimeoutSigningRepr`, or document that consumers must not act on `reason` for safety | Design discussion with maintainers |
| CR-3 | `consensus-types/src/wrapped_ledger_info.rs:90-108` — make `verify` call `verify_consensus_data_hash`, OR introduce a typed wrapper so unverified `vote_data` cannot be read | Submit PR |
| CR-4 | `consensus-types/src/vote.rs:152` (TODO) — Ensure `Vote.two_chain_timeout` is None when `RoundTimeoutMsg` is enabled | Add the enforcement |
| CR-5 | `consensus/safety-rules/src/safety_rules.rs:412-413` — add `verify_epoch(old_li.epoch(), &safety_data)`, add `last_committed_round` to SafetyData, add real extension check | Address the explicit TODOs |
| CR-6 | `consensus/src/network.rs:191` — doc says LIFO; code at `:756-760` is FIFO; correct one or the other | One-line fix |
| CR-7 | `consensus/src/round_manager.rs:1582-1660` (`process_order_vote_msg`) — add `ensure!(order_vote.epoch() == quorum_cert.certified_block().epoch())` to bind inner QC epoch | Submit PR |
| CR-8 | `consensus/src/round_manager.rs:976-992` (`process_sync_info_msg`) — add `validator.is_validator(peer)` check before processing | Discuss; impacts non-validator full nodes |
| CR-9 | `consensus/src/pending_order_votes.rs:61-157` — add per-author equivocation map mirroring `pending_votes.rs:287-309` | Submit PR; mirror existing logic |
| CR-10 | `consensus/src/block_tree.rs:381` — author's own question "We are updating highest_ordered_cert but not highest_ordered_root. Is that fine?" — resolve | Author follow-up |

## 7. Reference Pointers

- **Full analysis report**: `/home/ubuntu/Specula/case-studies/aptosbft_2/.specula-output/analysis-report.md`
- **Component-level deep reports**: `deep-safety-rules.md`, `deep-round-manager.md`, `deep-types.md`, `deep-pipeline.md`, `deep-aggregation.md`
- **Archaeology report**: `archaeology-report.md` (coverage stats: 90+ candidates surfaced, 35 deeply read, 23 confirmed safety-relevant, 12 false positives excluded)
- **Key source files**:
  - `consensus/safety-rules/src/safety_rules.rs` (500 LOC) — vote rules
  - `consensus/safety-rules/src/safety_rules_2chain.rs` (215 LOC) — 2-chain timeout / vote / order-vote helpers
  - `consensus/safety-rules/src/persistent_safety_storage.rs` (278 LOC) — persistence boundary
  - `consensus/src/round_manager.rs` (2434 LOC) — event loop
  - `consensus/src/recovery_manager.rs` (174 LOC)
  - `consensus/src/pending_votes.rs` (869 LOC) — vote aggregation
  - `consensus/src/pending_order_votes.rs` (378 LOC) — order vote aggregation (no equivocation map)
  - `consensus/src/pipeline/buffer_manager.rs`, `pipeline_builder.rs` — decoupled execution
  - `consensus/src/block_storage/{block_store.rs, block_tree.rs, sync_manager.rs}`
  - `consensus/consensus-types/src/{vote.rs, vote_msg.rs, order_vote_msg.rs, timeout_2chain.rs, wrapped_ledger_info.rs, sync_info.rs, opt_proposal_msg.rs, round_timeout.rs, quorum_cert.rs, safety_data.rs}`
- **GitHub issues/PRs (Family-tagged)**:
  - Family 1: Issue **#18298**, commit **`f58e184471`** (timeout-side analog).
  - Family 2: PRs **#13023** (order vote intro), **#13711**, **#13605**, **#14129**, **#14637**, **#14570**, **#18023**, **#15452**.
  - Family 3: PRs **#13986** (commit-vote / ordered-LI mismatch after fast-forward), **#14637** (QC binding in pending_order_votes).
  - Family 4: PRs **#2990**, **#12018**, **#13711**.
  - Family 5: PRs **#17766**, **#12239**, **#15746**, **#19359**, **#19084**, **#4232**, **#15361**.
  - Family 6: PRs **#13986**, **#1826**, **#13864**, **#4445**, **#4232**.
- **Reference algorithm**: HotStuff (Yin et al., 2019); Jolteon: <https://arxiv.org/pdf/2106.10362>; AIP-89 (order votes); AIP-131 (optimistic proposals).
- **Prior in-house spec**: previous round's `MC_epoch.tla` (`ReceiveTimeoutWeakEpoch` / `ReceiveOrderVoteWeakEpoch`). New round should extend rather than re-derive.
