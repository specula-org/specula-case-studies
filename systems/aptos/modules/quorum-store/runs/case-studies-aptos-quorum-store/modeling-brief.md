# Modeling Brief: Aptos Quorum Store

## 1. System Overview

- **System**: `aptos-labs/aptos-core` — `consensus/src/quorum_store/`, the Narwhal-style data dissemination + availability layer that feeds Proofs-of-Store (PoS) into the HotStuff / Jolteon proposal pipeline.
- **Language**: Rust, ~7,500 LOC of core dissemination logic (excluding tests / counters).
- **System category**: **Category A (Distributed / Message-Passing), BFT**. Up to `f` Byzantine batch authors / signers, `n ≥ 3f+1`, partial-synchronous network, static corruption, authenticated (BLS aggregate signatures). The HotStuff voter (already analysed in `aptosbft` / `aptosbft_2`) is treated as an **abstract consumer** of PoSes — Quorum Store does not vote; it produces availability proofs that voters embed in proposals.
- **Protocol**: DiemBFT Quorum-Store design memo + Narwhal (Danezis et al., EuroSys'22). Mainnet-active since 2023; Batch V2 (`enable_batch_v2_tx`) and Optimistic Quorum Store (AIP-106) layered on top during 2025-26.
- **Key architectural choices that deviate from the reference**:
  1. **Optimistic Quorum Store** (AIP-106): proposals may carry **un-certified** batch summaries; receivers fetch the body from the author or other PoS signers on demand.
  2. **Batch V2** parallel to V1: `BatchInfoExt` enum (`V1`, `V2 { batch_kind }`); separate wire types and DB column families.
  3. **Per-author quotas** with three balances (`db_balance`, `memory_balance`, `batch_balance`) in `BatchStore`.
  4. **Round-robin shard dispatch** of remote BatchMsgs across N `BatchCoordinator` workers (network_listener.rs:83-85). Per-author ordering is preserved only WITHIN a shard.
  5. **Cache keyed by `digest` (HashValue), not by `(author, batch_id)`** (batch_store.rs:116) — equivocation is bounded by digest collision, not by author × batch_id × validator memory.
  6. **`BatchProofQueue` collision filter** added in PR #19673: queue rejects second-arrival entries with same `BatchKey = (author, batch_id)` but mismatching `BatchInfoExt` (batch_proof_queue.rs:279-298, 425-439). Coordinator-side aggregation (`ProofCoordinator`) has **no equivalent filter**.
- **Concurrency model**: Tokio multi-task. Per-component "main loops" for `BatchGenerator`, `ProofCoordinator`, `ProofManager`, `QuorumStoreCoordinator`. `BatchStore` is shared lock-free (DashMap). `persist_and_send_digests` (batch_coordinator.rs:101) **spawns a fresh tokio task per remote BatchMsg** — so two BatchMsgs from the same author serialized on a single shard can still race once persist tasks are spawned. The author-keyed `BatchCoordinatorQueueKey::Author(author)` serializes only intra-shard; cross-shard fan-out is round-robin (network_listener.rs:83), not author-hashed.

---

## 2. Bug Families

### Family 1: Author-equivocated batches and parallel PoS aggregation (HIGH)

**Mechanism**: Byzantine batch author signs two distinct bodies under the same `BatchId`. Cache and signing layers dedup by **digest**, not `(author, batch_id)`, so each honest receiver may sign both bodies; the author can aggregate two parallel `IncrementalProofState` entries and broadcast two valid PoSes for the same `(author, batch_id)`. Receivers' `BatchProofQueue` rejects whichever arrives second, but **different validators may accept different first-arrivals** — proposers can disagree on which body backs that `BatchId`.

**Evidence**:
- Historical: PR #19673 "tighten BatchProofQueue ingress checks" (merged) — receiver-side queue collision check was missing; second arrival corrupted `items[batch_key].info` vs `BatchSortKey` vs `remaining_txns_with_duplicates` counters.
- Historical: PR #19676 (the disclosed bug at `types.rs:144`) — mixed V1/V2 entries in V2 wire messages reached `persist_and_send_digests`, panicking via `assert!`/`expect`.
- Code analysis: `batch_store.rs:116, 312, 363` — cache and signing keyed by digest; `last_certified_time` is the only freshness gate.
- Code analysis: `proof_coordinator.rs:234, 290-302` — `batch_info_to_proof: HashMap<BatchInfoExt, IncrementalProofState>` dedup is by the full `BatchInfoExt`, so two distinct digests for the same `(author, batch_id)` produce two parallel aggregation entries on the author.
- Code analysis: `network_listener.rs:83-85` — round-robin shard dispatch, NOT author-hashed; two same-author BatchMsgs can race on different `BatchCoordinator` workers.

**Affected code paths**:
- `BatchStore::insert_to_cache` / `BatchStore::save` (batch_store.rs:302-383)
- `BatchCoordinator::persist_and_send_digests` (batch_coordinator.rs:89-157)
- `ProofCoordinator::init_proof` / `ProofCoordinator::add_signature` (proof_coordinator.rs:270-354)
- `BatchProofQueue::insert_proof` collision branch (batch_proof_queue.rs:279-298)

**Suggested modeling approach**:
- Variables: `signedByValidator [Validator × Validator × BatchId → SUBSET HashValue]` (which digests each validator has signed for `(author, batch_id)`); `proofsFormed [Author × BatchId → SUBSET ProofOfStore]`; `queueCanonicalDigest [Validator × Author × BatchId → HashValue]` (first-arrival rule).
- Actions: `ByzantineAuthorEquivocateBatch(author, batch_id, body1, body2)` produces two distinct digests; receivers' `SignBatch` action signs both (no per-`(author, batch_id)` block). `AggregatePoS(author, batch_info)` checks `signedByValidator` cardinality ≥ 2f+1 for that exact digest.
- Granularity: split `SignBatch` from `PersistBatch` so the digest-dedup vs `(author, batch_id)`-dedup difference is explicit.

**Priority**: High.
**Rationale**: Closed PR #19673 patched the queue ingress, but the upstream layers (signing, proof_coordinator aggregation, queue first-arrival rule) still admit two-PoSes-per-`BatchId` semantics. The cross-validator question — "can two PoSes for the same `BatchId` carry distinct bodies into different proposals" — is open and well-suited to TLA+.

---

### Family 2: Sign / persist / broadcast ordering and cross-epoch recovery (HIGH)

**Mechanism**: Local batch creation persists `BatchId` (incremented) to DB **before** the payload is durably stored, and broadcasts the BatchMsg **after** payload persist but with no atomic guarantee versus signer responses; bootstrap discards prior-epoch batches even when their expiration is still in the future. A crash window or epoch boundary can leave a network-visible PoS referencing a body the local node will refuse to serve.

**Evidence**:
- Historical: PR #11629 "improvements to prevent some batches not getting quorum" — votes arriving before the QS DB write were silently discarded; sign / persist ordering was a real production bug.
- Historical: PR #14861 / #15306 — async block-timestamp updates reached assertions that assumed monotonic synchronous update; required `assert!` removal and asynchronous tolerance.
- Historical: PR #18960 / #18312 — V2 bootstrap GC missed the V2 column family; expired-batch cleanup required cherry-picks to v1.38/1.39/1.42/1.43.
- Code analysis: `batch_generator.rs:158-172` — constructor loads stored `BatchId`, increments, saves `id+1`. `create_new_batch:256-260` increments then **saves the next id BEFORE the batch payload is persisted** at `:710` (`batch_writer.persist(...)`). Window between counter persistence and payload persistence is non-trivial under contention.
- Code analysis: `batch_generator.rs:710` — `self.batch_writer.persist(persist_requests);` **discards the returned `SignedBatchInfo`**, while `batch_coordinator.rs:115/130` binds and forwards the return value via `send_signed_batch_info_msg{,_v2}`. The local author's self-signing path is asymmetric — relies on either receiving its own BatchMsg back via the loopback or never collecting its self-vote.
- Code analysis: `batch_store.rs:213-216` — `load_batches_from_db` discards entries with `value.epoch() < current_epoch` **or** `value.expiration() < gc_timestamp`. A batch persisted in epoch *N* with expiration in the future of epoch *N+1* is **deleted** at the *N+1* bootstrap, regardless of whether peers may still hold a PoS referencing that digest.
- Code analysis: `quorum_store_db.rs:99, 129, 159` — all DB writes use `write_schemas_relaxed` (no fsync). Crash recovery may diverge by which writes hit disk.

**Affected code paths**:
- `BatchGenerator::new` / `create_new_batch` (batch_generator.rs:149-326)
- `BatchGenerator::start` persist + broadcast (batch_generator.rs:705-720)
- `BatchStore::load_batches_from_db` (batch_store.rs:194-280)
- `QuorumStoreDB::put` / `delete_batches` (quorum_store_db.rs:83-89, 93-101, 123-131)

**Suggested modeling approach**:
- Variables: `persistedBatchId [Validator → BatchId]`, `persistedBatches [Validator → SUBSET (Author × BatchId × HashValue)]` (durable), `inMemoryBatches [Validator → ...]` (volatile), `broadcastBatches [SUBSET BatchMsg]`.
- Actions: split `CreateBatch` into `(reserveBatchId, persistBatchId, persistPayload, broadcastBatchMsg)` four-step with potential `Crash` between any pair. `RecoverFromCrash` rebuilds in-memory state from `persistedBatches`. `EpochTransition` action models the bootstrap GC: a persisted batch from epoch *N* is dropped at *N+1*.
- Invariant target: "if a PoS for `(author, batch_id, digest)` exists, then the author has `digest` durably persisted OR ≥ f+1 honest validators do".

**Priority**: High.
**Rationale**: Sign/persist ordering is a textbook BFT-dissemination correctness frontier and has produced production bugs (PR #11629). Cross-epoch persistence is novel relative to existing case studies (aptosbft / aptosbft_2 scope HotStuff voting, not Quorum Store crash recovery). The asymmetric self-signing path at `batch_generator.rs:710` is unaudited.

---

### Family 3: GC ↔ in-flight proof aggregation cross-validator (HIGH)

**Mechanism**: `BatchStore::clear_expired_payload` (batch_store.rs:387) removes the cache entry and the `persist_subscribers` slot under a per-node monotonic `last_certified_time` clock with only a static `expiration_buffer_usecs` grace window. Different validators advance `last_certified_time` at different rates. A slow author's `ProofCoordinator` can complete a 2f+1 aggregation **after** some fast signers have GC'd that body. The resulting PoS references a digest that not all honest validators can serve, and the proposer's own fetch via `BatchRequester` may exhaust signers before completing.

**Evidence**:
- Historical: PR #15452 "optqs bug fixes" — OptQS could not fetch batches from QC signers post-QC, stalling progress; required generalized fetch-responders.
- Historical: PR #15766 "dedup requests to batch fetcher" — multiple concurrent fetches for same batch were unmanaged.
- Historical: PR #15786 — `get_transactions` was not cancellation-safe inside `select!`, dropping in-flight fetch state.
- Code analysis: `batch_store.rs:387-416` (`clear_expired_payload`) — uses `certified_time.saturating_sub(self.expiration_buffer_usecs)` as the prune horizon. No cross-validator coordination.
- Code analysis: `proof_coordinator.rs:286-310` (`init_proof`) — `batch_reader.exists(digest)` is the only freshness gate before initiating aggregation; once initiated, no re-check after GC.
- Code analysis: `batch_requester.rs:142-152` — Byzantine peer can return `BatchResponse::NotFound(ledger_info)` with a forged-but-honestly-signed `LedgerInfo` whose timestamp barely exceeds `expiration`, causing the requester to short-circuit and return `CouldNotGetData` even when honest signers still hold the body.

**Affected code paths**:
- `BatchStore::clear_expired_payload` / `update_certified_timestamp` (batch_store.rs:387-486)
- `ProofCoordinator::init_proof` / `expire` (proof_coordinator.rs:270-403)
- `BatchRequester::request_batch` (batch_requester.rs:101-183)

**Suggested modeling approach**:
- Variables: `localCertifiedTime [Validator → Nat]` (per-node monotonic clock; may drift across validators), `gcdDigests [Validator → SUBSET HashValue]`, `inFlightProofs [BatchInfoExt → SUBSET Validator]` (signers who have not yet voted), `expirationGrace` (constant `expiration_buffer_usecs`).
- Actions: `AdvanceCertifiedTime(v)` may drop digests from `localCache[v]`; honest validators may diverge by up to `expirationGrace` window. `AggregateProof(author, info)` succeeds when 2f+1 voters are still in-flight. `FetchBatch(v, digest)` succeeds only if **some honest peer in the PoS signer set has not yet GC'd `digest`**.
- Invariant target: "a PoS over `digest` implies ≥ f+1 honest validators can still serve `digest` until `digest.expiration + expirationGrace`".

**Priority**: High.
**Rationale**: GC ↔ aggregation race is a non-trivial mechanism with multiple historical OptQS regression PRs. The cross-validator `localCertifiedTime` drift is a clean TLA+ target.

---

### Family 4: ProofManager ↔ BatchStore desync (proposal-time body availability) (MEDIUM)

**Mechanism**: `ProofManager::receive_proofs` inserts PoSes into `BatchProofQueue` **without** checking that the body is locally present in `BatchStore`. A proposer's `pull_proofs` returns `Vec<ProofOfStore>` from which the proposal payload is built. The proposer may include a PoS for which **its own** `BatchStore` does not hold the body. At execution time, `BatchReader::get_or_fetch_batch` triggers a fetch from PoS signers — but signers may have GC'd (Family 3) or be unresponsive.

**Evidence**:
- Code analysis: `proof_manager.rs:69-101` (`receive_proofs`) — no `batch_store.exists()` precondition.
- Code analysis: `batch_proof_queue.rs:759` (`pull_batches_with_transactions`) checks `batch_store.get_batch_from_local` — but `pull_proofs` (proof-tier) does not.
- Code analysis: `batch_store.rs:636` — `get_or_fetch_batch` TODO: "Support V2 batch". Fetched batches are persisted as V1 (`BatchInfo` → `BatchInfoExt::V1` via `.into()` at line 652) even if the original was V2. Subsequent V2-dependent paths may misclassify them.
- Historical: PR #19372 "validate batch metadata limits during payload verification" — `Payload::verify()` previously skipped per-batch metadata limits on `opt_batches` / `inline_batches`. Adjacent verification-gap pattern.

**Affected code paths**:
- `ProofManager::receive_proofs` / `handle_proposal_request` (proof_manager.rs:69-199)
- `BatchProofQueue::pull_proofs` (batch_proof_queue.rs ~759-870)
- `BatchReaderImpl::get_or_fetch_batch` (batch_store.rs:610-670)

**Suggested modeling approach**:
- Variables: `proposerProofQueue [Validator → SET BatchInfoExt]` (the proof queue), `localBodyCache [Validator → SET HashValue]`, `proposedPoSes [Block → SUBSET ProofOfStore]`.
- Actions: `IncludePoSInProposal(v, pos)` admits `pos` from `proposerProofQueue[v]` regardless of whether `pos.digest ∈ localBodyCache[v]`. `ExecuteProposal(v, block)` requires `∀ pos ∈ block: pos.digest ∈ localBodyCache[v]` (after fetch).
- Invariant target: "If a committed block references a PoS for `digest`, then `digest` is reachable from `v` at execution time" (liveness-ish).

**Priority**: Medium.
**Rationale**: Important but the historical fixes (#15452, #15766, #15786, #11162) have already touched this area; the open question is the OptQS-tier composition with V2 fetch-path TODO. Worth modeling once Family 3 is in place.

---

### Family 5: Receiver-side variant / kind homogeneity and ingress validation (MEDIUM, mostly reference)

**Mechanism**: V1 and V2 wire messages share a generic `verify_inner` over `TBatchInfo`; variant-specific gating is layered by concrete `verify` / `verify_v2`. The downstream code (`persist_and_send_digests`, `SignedBatchInfo::try_into`, `ProofOfStore::unpack`) uses `assert!`/`expect`/`try_into` rather than soft errors. If any V1 entry slips into a V2 message (or vice versa), the local node panics — a remote-DoS vector. Receivers also previously skipped per-batch metadata limits on `opt_batches` / `inline_batches`, allowing oversized proposals through.

**Evidence**:
- Historical, **closed**: PR #19676 "Enforce V2-only entries on V2 quorum store wire messages" — the disclosed bug now covered by `types.rs:144-170` regression test. The pattern is fixed.
- Historical, closed: PR #19372 "Validate batch metadata limits during payload verification".
- Historical, closed: PR #19130 / #19192 / #19442 / #19546 / #19548 — encrypted-batch verification gaps and feature-flag gating.
- Code analysis: `batch_coordinator.rs:113-152` — `first_batch_info.is_v2()` drives variant branch; `assert!(!signed_batch_infos.first().expect("must not be empty").is_v2())` is load-bearing. Relies on upstream `verify_v2` being called.

**Suggested modeling approach**: This family is mostly *reference context* for evidence-of-mechanism. The current code is type-system-correct after #19676, and TLA+ does not have a useful surface (the receiver-side gates are now closed). **Do not model the V1/V2 variant gate** as a Phase 4 target — predicted verdict is "documented fix in place; reproduction adds zero information beyond the closed PR".

**Priority**: Low (for TLA+). Keep as reference pointer in §7.
**Rationale**: Closed-bug containment per `bug-archaeology.md` §1.4.

---

### Family 6: Counter / backpressure drift and unchecked decrement underflow (LOW)

**Mechanism**: `ProofManager::update_remaining_txns_and_proofs` (proof_manager.rs:103-109) samples `remaining_total_txn_num` from `BatchProofQueue` only every 200ms via `sample!`. Backpressure decisions read stale values. `BatchProofQueue` uses unchecked `-=` on counters (batch_proof_queue.rs:231-236, 401, 503, 533, 1056-1062, 1232-1238); a logic bug producing one un-paired decrement wraps to `u64::MAX` (debug-build panic, release-build wrap).

**Evidence**:
- Historical: PR #7058 "fix backpressure only checking on commits", PR #13889 "fix remaining txns calculation in proof queue", PR #6818 "fix expired proof metric", PR #11576 "fix counters", PR #6697 "End batch, backpressure fixes" — repeated counter-accounting bugs.
- Code analysis: as above. Self-vote race (proof_coordinator.rs:164-166) — `self_voted` flag is only set inside `add_signature`. If remote signatures reach 2f+1 before the author's own self-vote arrives, the PoS completes without the author's signature; `update_counters_on_expire` then misclassifies the entry.

**Priority**: Low (for TLA+ — best verified by tests and assertions). Capture as code-review / test-verifiable items in §6.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Byzantine batch author signing two distinct bodies under one `BatchId` | Family 1 — open mechanism; receiver-side dedup is digest-keyed; queue first-arrival rule diverges across validators | Action `EquivocateBatch` produces two `Batch<>` records with same `(author, batch_id)`, different `digest`. Receivers' `SignBatch` admits both. |
| Parallel `IncrementalProofState` per `BatchInfoExt` on author | Family 1 — `proof_coordinator.rs:234, 290-302` admits parallel entries by full struct | Allow `proofsBeingAggregated` to contain multiple entries with same `(author, batch_id)`. |
| Receiver-side queue collision filter (first-arrival rule) | Family 1 — `batch_proof_queue.rs:279-298, 425-439` | Variable `queueCanonicalForKey [Validator × (Author × BatchId) → BatchInfoExt]`, set once on first arrival, locked thereafter. |
| Split `CreateOwnBatch` into `reserveBatchId / persistBatchId / persistPayload / broadcastBatchMsg` | Family 2 — current code persists counter before payload, broadcasts after payload but discards self-sign | Four-step action sequence; `Crash` permitted between any pair; recovery resets in-memory state. |
| Cross-epoch bootstrap drop of persisted batches | Family 2 — `batch_store.rs:213-216` discards prior-epoch entries even with future expiration | `EpochTransition` action removes persisted batches with `epoch < current_epoch` regardless of expiration. |
| Per-validator `localCertifiedTime` and `expirationGrace`-windowed GC | Family 3 — validators drift, GC is local | Per-validator monotonic clock; `AdvanceCertifiedTime` drops digests where `expiration + grace < clock`. |
| Proof aggregation completion vs body-GC race | Family 3 — proof can complete after author has GC'd | `AggregateProof` may succeed when fewer than 2f+1 honest signers still hold body. |
| PoS in proposal but body not locally available | Family 4 — `proof_manager.rs:69-101` does not check `batch_store` | `IncludePoSInProposal` does not check `localBodyCache`; `ExecuteProposal` requires fetch chain to terminate. |
| Self-vote timing for own batches | Family 1 + 6 — `self_voted` flag race | `SelfVote` is a separate action that may fire before or after 2f+1 from remote signers. |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| V1/V2 wire-message variant gate (PR #19676) | Closed upstream; type-system enforced; predicted Phase 4 verdict = "documented fix, no new information". Reference pointer only — `types.rs:144-170` regression test. |
| `BatchProofQueue` ingress collision panic (PR #19673) | Closed upstream; queue is now collision-aware. The cross-validator divergence question (Family 1) is the real open surface, not the queue panic itself. |
| Encrypted-batch verification gaps (PR #19130, #19192, #19372, #19442, #19546, #19548) | Out of QS dissemination scope; encrypted-payload validity is a content predicate enforced at the txn-verify boundary, not a dissemination invariant. |
| HotStuff / Jolteon voting state machine | Already covered by `aptosbft` / `aptosbft_2` case studies; treat as abstract consumer. |
| Mempool internals upstream of `BatchGenerator` | Out of scope (case-study boundary in `.prompt-extra.md`). |
| Block-STM / VM execution | Out of scope. |
| Counter / metric drift | Family 6 — not TLA+ suitable; test or code-review. |
| Round-robin shard dispatch (network_listener.rs:83) | Concurrency-amplification mechanism but the safety-relevant effect (concurrent persist races for same author) is already captured by the digest-keyed cache model; modeling N shards adds state-space without new invariant targets. |
| Mempool ↔ batch dedup at txn granularity | The `txn_summary_num_occurrences` map is implementation hygiene, not dissemination safety. |
| `optimistic_sig_verification` / BLS aggregate primitive | The aggregator has a `filter_invalid_signatures` fallback (`ledger_info.rs:517-536`); modeling the BLS primitive breaks the spec's "honest signatures unforgeable" axiom. |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Batch equivocation surface | `signedByValidator [V × (Author × BatchId) → SUBSET HashValue]`, `proofsAggregated [Author × BatchInfoExt → BOOLEAN]`, `queueCanonical [V × (Author × BatchId) → BatchInfoExt]` | Capture digest-keyed dedup, parallel aggregation, per-validator first-arrival | Family 1 |
| Crash and recovery, two-step counter / payload persistence | `persistedBatchId [V → BatchId]`, `persistedPayloads [V → SET (Author × BatchId × HashValue)]`, `inMemory [V → ...]`, `broadcast [SET BatchMsg]` | Sign / persist / broadcast ordering | Family 2 |
| Cross-epoch bootstrap drop | `currentEpoch [V → Nat]`, `EpochTransition` action that drops `persistedPayloads` with `epoch < currentEpoch[v]` | Cross-epoch availability | Family 2 |
| Per-validator GC clock with grace window | `localCertifiedTime [V → Nat]`, `expirationGrace` constant, `gcdDigests [V → SET HashValue]` | GC drift across validators | Family 3 |
| In-flight proof aggregation tracking | `aggInFlight [Author × BatchInfoExt → SUBSET Voter]`, `proofsFormed [Author × BatchInfoExt → SUBSET AggSig]` | Proof formation vs GC race | Family 3 |
| Proposer body availability | `proposalIncludes [Block → SUBSET ProofOfStore]`, `fetchableFrom [V × HashValue → SUBSET V]` | PoS-in-queue vs body-in-store gap | Family 4 |
| Self-vote ordering | `selfVoted [Author × BatchInfoExt → BOOLEAN]`, action `SelfVote` separate from `RemoteVote` | Self-vote race | Family 1, 6 |
| Byzantine NotFound spoof | `byzantineNotFound [V × HashValue → MaybeLedgerInfo]` | Batch requester give-up race | Family 3 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ProofOfStoreUniquenessPerBatchId | Safety (relaxed) | If two PoSes exist with same `(author, batch_id)` but different `digest`, then a Byzantine author exists in `Faulty` | Family 1 |
| QueueCanonicalAgreement | Safety | Two honest validators with `queueCanonical[v1][(a, id)] = d1`, `queueCanonical[v2][(a, id)] = d2` and `d1 ≠ d2` ⇒ `a ∈ Faulty` | Family 1 |
| BodyAvailabilityImplication | Safety | If a PoS over `digest` is committed in a finalized block, then ≥ f+1 honest validators hold `digest` at commit time OR `digest.expiration > current ledger time` | Families 3, 4 |
| ProofImpliesPersist | Safety | If 2f+1 SignedBatchInfo over `(author, batch_id, digest)` exist, then the author durably persisted `digest` (under honest-author assumption); under Byzantine author, no implication | Family 2 |
| CrossEpochSurvival | Safety | A PoS formed in epoch `N` and not yet expired (per ledger time) MUST be either committed or its body still serviceable by ≥ f+1 honest validators after epoch transition `N → N+1` | Family 2 |
| GCImpliesNoOpenAgg | Safety | If validator `v` has GC'd `digest`, then for every honest author `a`, `v` will not contribute a `SignedBatchInfo` for `(a, _, digest)` | Family 3 |
| BatchIdMonotonicity | Safety | For each honest author `a`, sequence of `BatchId` it broadcasts is strictly monotonic; no two BatchMsgs from `a` share `BatchId` (Byzantine: trivially false) | Family 2 |
| SelfVoteAfterPersist | Safety | If `self_voted[a][info] = TRUE`, then `info.digest ∈ persistedPayloads[a]` | Family 2 |
| NoPoSWithoutQuorumOfHonestStorage | Safety | If a valid PoS exists over `info`, then at least f+1 honest validators have at some point stored `info.digest` OR `info.author ∈ Faulty` | Families 1, 2, 3 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

Each item below is a **forward-looking question about an unaudited mechanism** — not a reproduction of a closed PR.

| ID | Description | Expected invariant target | Bug Family |
|----|-------------|---------------------------|------------|
| MC1 | If a Byzantine author broadcasts two bodies under one `BatchId` and ≤ f honest signers respond differently per-body, can two valid PoSes form such that proposers on disjoint subsets of validators each include a different PoS in their proposals — leading to `queueCanonical` disagreement among honest proposers? | QueueCanonicalAgreement | 1 |
| MC2 | Given per-validator `localCertifiedTime` drift up to `expirationGrace`, can an honest author complete 2f+1 aggregation for a batch whose body has been GC'd by f+1 honest validators — yielding a PoS whose body is unrecoverable to a non-Byzantine majority? | BodyAvailabilityImplication | 3 |
| MC3 | Under epoch transition `N → N+1`, can a node bootstrap dropping its prior-epoch batches while the network still holds a valid PoS for one of those batches — and then be unable to serve that PoS as a proposer in epoch `N+1`? | CrossEpochSurvival | 2 |
| MC4 | Can the proposer-side body-availability gap in `ProofManager::receive_proofs` (no `batch_store` check) lead to a state where the proposer's own proposal contains a PoS whose body the proposer must fetch from peers, and where all `request_num_peers` chosen signers have GC'd? | BodyAvailabilityImplication | 4 |
| MC5 | If `SelfVote` arrives at the author's `ProofCoordinator` after 2f+1 remote signatures already aggregated, does the formed PoS lack the author's signature, and is this state distinguishable from a Byzantine author abstaining? | SelfVoteAfterPersist (negation) | 1, 6 |
| MC6 | A Byzantine peer returns `BatchResponse::NotFound(legitimate_recent_ledger_info)` whose `timestamp_usecs` barely exceeds `batch.expiration`. Can this cause an honest requester to abandon a fetch even when ≥ f+1 honest peers still hold the body, leading to proposer failure to assemble its own block? | BodyAvailabilityImplication | 3 |
| MC7 | If two BatchMsgs from the same author land on different `BatchCoordinator` shards via round-robin (network_listener.rs:83) and run concurrently with two distinct digests, can the digest-keyed cache + `last_certified_time` freshness gate produce duplicate `SignedBatchInfo` responses to the author for both bodies? Quantifies the multi-shard amplification of Family 1. | QueueCanonicalAgreement | 1 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|------------------------|
| T1 | `batch_writer.persist()` return value discarded at `batch_generator.rs:710` — local author may never push self-vote into ProofCoordinator from this path | Integration test: assert local author's PoS contains author's signature in the aggregated set within deterministic time after batch broadcast |
| T2 | DashMap entry lock in `BatchStore::insert_to_cache` may race with concurrent `clear_expired_payload` for same digest | Loom-style test or fuzz: assert `peer_quota` balances are conserved across 1000+ insert/evict cycles |
| T3 | Closed `oneshot::Receiver` busy-spinning `tokio::select!` (`batch_requester.rs:164-175`) after `RecvError` | Tokio test: inject a `subscribe()` whose tx is dropped; assert CPU usage in the loop is bounded |
| T4 | Counter underflow on `-=` decrements in `batch_proof_queue.rs` (lines 231-236, 401, 503, 533, 1056-1062, 1232-1238) | Property test: replay arbitrary sequences of `insert_proof`, `insert_batches`, `mark_committed`, `handle_updated_block_timestamp`; assert no counter wraps |
| T5 | Bootstrap `load_batches_from_db` running concurrently with `BatchStore::save` (batch_store.rs:156-189 spawn_blocking + Arc returned immediately) | Integration test: trigger save during bootstrap; assert quota and cache invariants |
| T6 | Oversized-txn busy-loop in `batch_generator.rs:371-383` — mempool keeps returning the poisoned txn | Mempool mock: place a > `sender_max_batch_bytes` txn; assert generator marks it ineligible after one pull rather than re-pulling forever |
| T7 | V2 fetch TODO at `batch_store.rs:636` — fetched batch persisted as V1 even when original was V2 | Integration test: V2-author broadcasts batch; node misses BatchMsg; fetcher retrieves; assert persisted entry retains `is_v2() == TRUE` |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|------------------|
| R1 | `BatchGeneratorCommand::ProofExpiration` always uses `self.my_peer_id` (batch_generator.rs:781) — silently no-op for remote batches inserted via `handle_remote_batch` | Confirm intent; document asymmetry or fix |
| R2 | `ensure!` panics via `assert!`/`expect!` in `persist_and_send_digests` paths still rely on upstream `verify_v2` — type-system mitigates but a `Result` would be more defensive | Discuss with maintainers whether soft-error fallback is appropriate |
| R3 | `last_certified_time` is loaded `Relaxed` (batch_store.rs:489) but updated `SeqCst::fetch_max` | Audit memory ordering; document why Relaxed is sufficient |
| R4 | `BatchId::increment` uses unchecked `id += 1` with no overflow check | Document u64 horizon; consider `saturating_add` |
| R5 | `clean_and_get_batch_id` `assert!(current_epoch >= epoch)` panics on regressed epoch (quorum_store_db.rs:171) — would crash node on snapshot-rollback recovery | Replace `assert!` with `Result`; consider operator recovery story |
| R6 | TODO `proof_manager.rs:178` — "Support unique txn calculation" for opt-batches | Track follow-up; opt-batch txn dedup vs proof-tier dedup is currently inconsistent |
| R7 | TODO `batch_coordinator.rs:254` — "maybe don't message batch generator if the persist is unsuccessful" | Confirm whether `RemoteBatch` arrival should be conditional on persist success |
| R8 | `_ => unreachable!()` in `network_listener.rs:123` would panic on a new `VerifiedEvent` variant | Replace with exhaustive match + soft-fail |
| R9 | `BatchRequester` "give up after retry_limit" returns `CouldNotGetData` (batch_requester.rs:180); the caller (`get_or_fetch_batch`) propagates this error up — confirm proposer fallback when this happens during its own proposal execution | Trace caller chain; document |
| R10 | `BatchKey` collision drops second arrival but counter increments for the **first** arrival's `BatchInfoExt`; in a Byzantine equivocation case the "first arrival" is whichever network reorder picks — non-deterministic across validators | Audit whether non-determinism in `queueCanonical` is acceptable (yes for safety, possibly bad for proposer convergence) |

---

## 7. Reference Pointers

- **Full analysis report**: `/home/ubuntu/Specula/case-studies/aptos-quorum-store/.specula-output/analysis-report.md`
- **Key source files**:
  - `consensus/src/quorum_store/batch_generator.rs` (798 lines) — own-batch creation, BatchId persistence, broadcast
  - `consensus/src/quorum_store/batch_coordinator.rs` (292 lines) — receive remote, persist, sign
  - `consensus/src/quorum_store/batch_store.rs` (699 lines) — DashMap cache, per-peer quotas, subscribe, GC
  - `consensus/src/quorum_store/proof_coordinator.rs` (524 lines) — aggregate SignedBatchInfo into PoS
  - `consensus/src/quorum_store/proof_manager.rs` (375 lines) — PoS queue, proposal pulls, backpressure
  - `consensus/src/quorum_store/batch_proof_queue.rs` (1259 lines) — per-peer fairness, dedup, expiration, collision filter
  - `consensus/src/quorum_store/batch_requester.rs` (183 lines) — request from PoS signers, retry, NotFound short-circuit
  - `consensus/src/quorum_store/network_listener.rs` (130 lines) — round-robin shard dispatch
  - `consensus/src/quorum_store/quorum_store_db.rs` (254 lines) — RocksDB persistence, relaxed writes
  - `consensus/consensus-types/src/proof_of_store.rs` (700+ lines) — `BatchInfo`/`BatchInfoExt`, `SignedBatchInfo`, `ProofOfStore`, `SignedBatchInfoMsg::verify_inner`
  - `consensus/src/quorum_store/types.rs:144-170` — disclosed-bug regression test
- **Closed PRs (reference context for Bug Families; NOT modeling targets)**:
  - PR #19676 — V2 wire-message variant gate (the disclosed bug; Family 5)
  - PR #19673 — `BatchProofQueue` ingress collision filter (Family 1 evidence)
  - PR #11629 — sign / persist ordering (Family 2 evidence)
  - PR #14861, #15306 — async timestamp updates (Family 2 evidence)
  - PR #18960, #18312 — V2 bootstrap GC (Family 2 evidence)
  - PR #19372, #19130, #19192, #19442, #19546, #19548 — verification gaps (Family 5 evidence)
  - PR #15452, #15766, #15786 — OptQS fetch / dedup / cancellation (Families 3, 4 evidence)
  - PR #7058, #13889, #6818, #11576, #6697 — counter drift (Family 6 evidence)
  - PR #19446 — `aptos_channel` drop-on-full to prevent blocking stall (architectural mitigation)
  - PR #14644 — `optimistic_sig_verification` introduction (BLS aggregator design)
- **Open PRs** (enhancements, not bug reports): #19717 (FastProof), #19671 (age-based pull order)
- **Reference algorithm / paper**:
  - Narwhal: Danezis, Kokoris-Kogias, Sonnino, Spiegelman, *Narwhal and Tusk: A DAG-based Mempool and Efficient BFT Consensus*, EuroSys'22.
  - DiemBFT-Quorum-Store memo (in-tree docs, also AIP-26 and AIP-106).
- **Out of scope per `.prompt-extra.md`**: Jolteon voter state machine (covered by `aptosbft`/`aptosbft_2`), mempool internals, Move VM, txn execution semantics, governance, RPC, network transport (use `Network` trait as abstract).
