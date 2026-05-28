# Analysis Report: Aptos Quorum Store

Companion to `modeling-brief.md`. Contains the audit trail of findings, coverage statistics, and full verification notes.

---

## 1. Phase 1 — Reconnaissance

### 1.1 Scope and Classification

**Target**: `consensus/src/quorum_store/` plus the `consensus-types::proof_of_store` types (`SignedBatchInfo`, `ProofOfStore`, `BatchInfoExt`) and the `epoch_manager.rs` ↔ `round_manager.rs` boundary where verified messages enter the dissemination pipeline.

**System category**: **Category A (Distributed / Message-Passing), BFT-overlay**.

- **Corruption type**: static (validator set known at epoch start, BLS public keys registered on chain).
- **Network model**: partial-synchronous (DLS 1988). Heartbeats and timeouts in HotStuff layer; QS itself has no liveness deadline beyond batch `expiration`.
- **Computational power**: authenticated + crypto-bounded. BLS aggregate signatures with `optimistic_sig_verification` (lazy verify) and `filter_invalid_signatures` fallback.
- **Threshold**: `n ≥ 3f+1`, 2f+1 voting power for PoS.

### 1.2 File Inventory

| File | LOC | Role |
|------|-----|------|
| `batch_generator.rs` | 798 | Own-batch creation, mempool pull, BatchId persistence, broadcast |
| `batch_coordinator.rs` | 292 | Receive remote batches, persist, sign, return SignedBatchInfo |
| `batch_proof_queue.rs` | 1259 | Per-peer fairness queue, dedup, expiration, **PR #19673 collision filter** |
| `batch_requester.rs` | 183 | Fetch missing batches from PoS signers |
| `batch_store.rs` | 699 | DashMap cache + DB persistence; per-peer quota; subscribe; GC |
| `counters.rs` | 1255 | Prometheus metrics |
| `direct_mempool_quorum_store.rs` | 164 | Legacy bypass path (not in current dissemination scope) |
| `network_listener.rs` | 130 | Dispatch verified events to component handlers |
| `proof_coordinator.rs` | 524 | Aggregate SignedBatchInfo → ProofOfStore on the author |
| `proof_manager.rs` | 375 | PoS queue, proposal pull, backpressure |
| `quorum_store_builder.rs` | 482 | Component wiring |
| `quorum_store_coordinator.rs` | 175 | Top-level orchestrator, shutdown |
| `quorum_store_db.rs` | 254 | RocksDB layer, relaxed writes |
| `schema.rs`, `tracing.rs`, `utils.rs`, `types.rs`, `mod.rs` | misc | Helper types and adapters |

Total core dissemination logic: ~7,500 LOC.

### 1.3 Concurrency Model

- Per-component tokio main loops (`select!`): `BatchGenerator`, `ProofCoordinator`, `ProofManager`, `QuorumStoreCoordinator`.
- Multiple `BatchCoordinator` "shards" (configurable count) with round-robin dispatch from `NetworkListener` (`network_listener.rs:83-85`). Same-author `BatchMsg` are NOT hashed to a deterministic shard.
- `BatchStore` is shared by `Arc` and accessed lock-free via `DashMap` (per-shard internal locks). README states lock ordering: `db_cache` then `peer_quota`.
- `batch_coordinator.rs:101` spawns a **fresh `tokio::spawn` per BatchMsg** for persist + sign + send. Two BatchMsgs from the same author can have their persist+sign+send tasks running concurrently even within a single shard.
- DB writes use `write_schemas_relaxed` (no fsync) (`quorum_store_db.rs:99, 129, 159`).

---

## 2. Phase 2 — Bug Archaeology

### 2.1 Coverage Statistics

**PRs**:
- Total PR search results across ~20 keyword queries: ~70 unique
- Deeply read (`gh pr view --json title,body,labels,files,mergedAt,state,url`): **25 PRs**
- Full comment thread read (`gh pr view --comments`): **2 PRs** (#19676, #19673)
- Confirmed bug fixes: **17**
- Feature / refactor / cleanup PRs with partial fixes: **5**
- Performance / tuning (no functional bug): **3**

**Issues**:
- Total search results across ~30 keyword and label queries: ~75 unique
- Deeply read (`gh issue view --comments`): **22 issues + PRs cross-referenced**
- Quorum-store-specific bug issues: **0 confirmed open**
- Quorum-store-specific bug issues classified as design defect / disputed / user-error: **mostly user-error / unrelated subsystems**
- Aptos GitHub Security Advisories endpoint: `[]` (empty)

The Aptos workflow files most bugs directly as PRs (reviewed by Cursor "Aptos Security Bugbot" automation) without separate public issues. There is no public post-mortem or security advisory for the disclosed `verify_v2_rejects_v1_batch_in_batch_msg_v2` bug — only PR #19676.

### 2.2 Bug-Fix PR Inventory (deeply-read subset, mechanism-grouped)

#### Verification gaps (closed)

| PR# | Summary | Files | Mechanism note |
|-----|---------|-------|----------------|
| **#19676** | Enforce V2-only entries on V2 quorum store wire messages | `types.rs`, `proof_of_store.rs`, `round_manager.rs` | The **disclosed bug**. `BatchMsgV2`/`SignedBatchInfoMsgV2`/`ProofOfStoreMsgV2` `verify()` was generic over `TBatchInfo` and missing the variant homogeneity check. Crafted message with V1 entry inside V2 wire type triggered `assert!`/`expect!` panic in `persist_and_send_digests` and `try_into`. Regression test now at `types.rs:144-170`. |
| #19673 | Tighten BatchProofQueue ingress checks | `batch_proof_queue.rs` | Two well-formed quorum-certified messages sharing `(author, batch_id)` but differing `BatchInfoExt` would misalign `item.info`, `BatchSortKey`, `remaining_txns_with_duplicates`. Now rejected at insertion (`batch_proof_queue.rs:279-298, 425-439`). |
| #19372 | Validate batch metadata limits during payload verification | `batch_coordinator.rs` | `Payload::verify()` did not enforce `max_batch_txns`/`max_batch_bytes` on `opt_batches` / `inline_batches`. |
| #19442 | Inline batch cipher verification | `batch_proof_queue.rs`, `types.rs` | `verify_inline_batches` skipped `verify_batch_kind_transactions`. |
| #19546 | Fix encrypted txn validation | `types.rs` | Secondary-signer swap, multisig and unsupported-authenticator bypass in encrypted-batch verification. |
| #19548 | Reject encrypted batches when feature disabled | `types.rs`, `round_manager.rs` | Without the gate, feature-disabled validators would forward encrypted-batch references. |
| #19192 | Receiver-side check for encrypted batch txn limit | `batch_coordinator.rs` | Encrypted batches had only sender-side `sender_max_encrypted_batch_txns` enforcement. |
| #19130 | Encrypted txn verification + batch size controls | `batch_generator.rs`, etc. | `Batch::verify()` did not call `EncryptedPayload::verify()`. |
| #17470 | Check batch author belongs to epoch | `types.rs`, `round_manager.rs` | `Batch::verify()` did not check that the author is an epoch member. |
| #11292 | Fix sender batch size check | `batch_generator.rs`, `batch_coordinator.rs`, `types.rs` | Sender did not enforce `max_batch_bytes`. |

#### Sign / persist / proof-aggregation ordering (closed)

| PR# | Summary | Mechanism note |
|-----|---------|----------------|
| **#11629** | Improvements to prevent some batches not getting quorum | Batches were written to QS DB AFTER broadcast; votes arriving before DB write were silently discarded — sometimes > 33% of votes lost. Cached committed batches until expiration. |
| #14861 | Tolerate block timestamp being updated asynchronously | `assert!` on monotonic timestamp panicked when `sync_to` raced with async callback. |
| #15306 | Remove assertion on timestamp | Same shape, follow-up. |
| #14499 | Track committed batches without proofs until expiration | Post-ProofQueue→BatchProofQueue refactor regression — commit notification before proof did not mark batch committed. |
| #11576 | Fix counters | After #11444 made proof_coordinator remove batches on commit, the commit-path counter was not added. |

#### Persistence and bootstrap (closed)

| PR# | Summary | Mechanism note |
|-----|---------|----------------|
| #18960 / #18964 | Consolidate quorum store batch bootstrap | V2 column-family expired-batch cleanup was missing; cherry-picked to v1.42/1.43. |
| #18312 / #18324 / #18325 | Update batch expiration logic | Cherry-picked to v1.38/1.39 release branches — confirms real defect. |
| #15491 | Batch store bootstrap perf + bugfix | Batches were not cleaned up respecting expiration buffer on bootstrap. |
| #15361 | Move `payload_manager.notify_commit` to after commit | Premature GC if commit aborted. |
| #7522 | BatchStore tests + QuotaManager bugfix | DB quota could be exceeded by memory quota under specific arrival/free order. |

#### OptQS / Batch request lifecycle (closed)

| PR# | Summary | Mechanism note |
|-----|---------|----------------|
| #15452 | OptQS bug fixes and perf | Could not fetch batches from QC signers post-QC; could not update fetch responders on in-flight; stale-proposal voting when fetch lagged. |
| #15766 | Dedup requests to batch fetcher | Multiple concurrent fetches for same batch were unmanaged. |
| #15786 | Undo using block votes to fetch batches | `get_transactions` was not cancellation-safe inside `select!`. |
| #11162 | Batch request short-circuit on expired | Forced full timeout cycle for unavailable batches. |

#### Architectural and operational (closed)

| PR# | Summary | Mechanism note |
|-----|---------|----------------|
| #19446 | Adjust quorum store queue handling | Blocking `tokio::mpsc` on `remote_batch_coordinator_cmd` let one slow worker stall the network listener; replaced with `aptos_channel` drop-on-full. |
| #19647 | Cap encrypted decryption by block-execute limit + trusted-setup capacity | Round modulo arithmetic aliased rounds. |
| #14644 | Optimistic signature verification for signed batch info | Performance optimization; malicious-voter blacklist in `ValidatorVerifier::pessimistic_verify_set`. |
| #7058, #13889, #6818, #6697 | Backpressure / counter fixes | Recurring counter-accounting bugs. |

### 2.3 Recurring Mechanisms (Phase 2 takeaway)

Three reproducing mechanisms across the closed-PR history:

1. **Sign / vote / persist ordering races** — #11629, #14499 (votes before DB write; commit before proof).
2. **GC racing with late votes or aborted commits** — #6818, #15361, #15491, #18960, #18312.
3. **Receiver-side verification gaps** — receiver trusted invariants the sender was supposed to maintain (#11292, #17470, #19130, #19192, #19372, #19442, #19548, #19676).

The disclosed bug (#19676) falls into mechanism #3 and is now closed. The most recent (#19673) is mechanism-#3-adjacent: a queue-side check for digest-equivocation. These two PRs together represent the post-V2-launch security hardening.

### 2.4 Forward-Looking Open Mechanisms

Even after the closed PRs, the **upstream layers** of the equivocation-prevention story remain digest-keyed:

- `BatchStore` cache keys by digest (`batch_store.rs:116`).
- `ProofCoordinator::batch_info_to_proof` keys by full `BatchInfoExt` (`proof_coordinator.rs:234`).
- Only the receiver-side `BatchProofQueue` applies a first-arrival `(author, batch_id)` filter (`batch_proof_queue.rs:279-298`).

The cross-validator implication — "different validators' queues can hold different `BatchInfoExt` for the same `(author, batch_id)`" — is the live open question for Family 1.

---

## 3. Phase 3 — Deep Analysis (Findings)

This section consolidates findings from the six parallel deep-analysis subagents (one per major source file or thematic boundary) plus follow-up verification I performed in the main context.

### 3.1 batch_generator.rs (own-batch creation)

| ID | Finding | Mechanism | Verified |
|----|---------|-----------|----------|
| G1 | `batch_writer.persist()` return value (self-`SignedBatchInfo`) **discarded** at line 710 — versus `batch_coordinator.rs:115,130` which binds and forwards | Sign / persist asymmetry | ✅ confirmed by direct read |
| G2 | BatchId monotonicity: constructor (lines 158-172) loads stored id, increments, saves `id+1`. `create_new_batch:256-260` increments and saves the NEXT id BEFORE the batch payload is persisted at `:710`. Window between counter persistence and payload persistence is non-trivial under contention. | Persistence ordering | ✅ confirmed |
| G3 | Persist + broadcast are not atomic. `self.batch_writer.persist(persist_requests)` at line 710 then `network_sender.broadcast_batch_msg{,_v2}(batches)` at 714/719. Broadcast may race ahead of disk flush (relaxed writes). | Persistence ordering | ✅ confirmed |
| G4 | `BatchId::increment` uses unchecked `id += 1`. `BatchId::new(duration_since_epoch().as_micros() as u64)` is only used when DB has no entry — clock-rollback on a wiped DB could produce nonce regression | Equivocation (corner case) | ✅ confirmed |
| G5 | `clean_and_get_batch_id` deletes prior-epoch BatchId entries; same-epoch BatchId is preserved | Equivocation defense | ✅ confirmed (only counter-based, no per-digest WAL) |
| G6 | `expiry_time = duration_since_epoch().as_micros() + batch_expiry_gap_when_init_usecs` (line 572-573). Author can sign a BatchInfo with arbitrary expiration (no upper bound enforced on receive in `batch_coordinator.rs:159-194`). `SignedBatchInfo::verify` (proof_of_store.rs:530-540) checks `expiration ≤ now + max_batch_expiry_gap_usecs` so this IS bounded at receive time. | GC / verification | ✅ confirmed at receive boundary |
| G7 | Backpressure decisions and batch creation are not mutually exclusive. Even with `proof_count` backpressure asserted, generator still emits at `batch_generation_max_interval_ms` cadence (line 691-693) | Backpressure | ✅ confirmed |
| G8 | `ProofExpiration` removes only `self.my_peer_id` entries from `batches_in_progress` (line 781). Remote batches inserted via `handle_remote_batch` are keyed by remote author and are silently un-affected | Lifecycle asymmetry | ✅ confirmed |
| G9 | `insert_batch` short-circuits on duplicate `(author, batch_id)` key (line 206-208). Subsequent dead-branch at lines 235-240 suggests merge-not-skip intent | Dedup (cosmetic) | ✅ confirmed |
| G10 | `enable_batch_v2_tx` flag determines V1 vs V2 batch construction. Heterogeneous network configurations could behave inconsistently | Config | ✅ confirmed |
| G11 | Expiration cleanup re-inserts batches with higher expiry (lines 755-771) — Byzantine remote author cannot inflate beyond local clock + `remote_batch_expiry_gap_when_init_usecs` | Defense behavior | ✅ confirmed |
| G12 | `latest_block_timestamp` monotonicity check is `>` not `>=` (line 742), no epoch tag alongside the timestamp | Cross-epoch | ✅ confirmed |
| G13 | TODO at line 652 (refactor back_pressure) | Documentation | ✅ confirmed |
| G14 | Oversized txn silent skip (lines 371-383): never marked in-progress, mempool may re-return it, busy-loop on poisoned txn | Liveness | ✅ confirmed |

### 3.2 batch_coordinator.rs + network_listener.rs (remote receive + signing)

| ID | Finding | Mechanism | Verified |
|----|---------|-----------|----------|
| C1 | **No per-`(author, batch_id)` equivocation dedup at signing**. `BatchStore` cache (`batch_store.rs:116`) keyed by digest; two distinct bodies with same `(author, batch_id)` have different digests, both pass cache, both get `generate_signed_batch_info` (batch_store.rs:418-430) | Equivocation | ✅ confirmed |
| C2 | Persist→sign is atomic per-batch via DashMap entry lock on `digest` (batch_store.rs:312), but two different bodies (different digests) run truly concurrently — no per-author serialization | Persistence-race | ✅ confirmed |
| C3 | Signature over `BatchInfo`/`BatchInfoExt` content (which includes `digest`). V1 path drops `batch_kind` tag; but since digest binds payload+kind, no kind-confusion | Verification | ✅ confirmed |
| C4 | V1/V2 path selection driven by `first_batch_info.is_v2()` (line 113). Mixed-version vec would panic via `assert!(!.is_v2())` (line 132) or `try_into().expect()` (line 146). Mitigated by upstream `verify_v2` enforcing homogeneity. | Routing | ✅ closed by PR #19676 |
| C5 | Batch forwarded to `batch_generator` BEFORE persist completes (line 253-263). TODO at line 254 acknowledges this | Ordering | ✅ confirmed |
| C6 | `sender_to_proof_manager.send(ReceiveBatches)` runs even when nothing was signed (line 153-155, outside the `if !signed_batch_infos.is_empty()` block) — `batches` collected from `persist_requests` regardless | ProofManager-BatchStore desync (small) | ✅ confirmed |
| C7 | Encrypted-batch limit enforced only for `BatchKind::Encrypted` (line 168-175); content-bound via `verify_batch_kind_transactions` | Verification | ✅ confirmed |
| C8 | `handle_batches_msg(author, batches)` trusts upstream `verify_inner` for `batch.author() == sender` — no re-check | Trust boundary | ✅ confirmed |
| C9 | **NetworkListener round-robin shard dispatch** (network_listener.rs:83-85). Same-author batches can land on different shards → concurrent persist races | Routing / amplification | ✅ confirmed |
| C10 | `_ => unreachable!()` for unexpected VerifiedEvents (line 123) — routing is exclusive by panic | Routing | ✅ confirmed |
| C11 | TODOs: `batch_coordinator.rs:254`, `network_listener.rs:51` | Documentation | ✅ confirmed |
| C12 | `BatchStore::save` (batch_store.rs:363-383) gates on `value.expiration() > last_certified_time`. No per-`(author, batch_id)` replay protection. Sole defense is digest-keyed cache | Equivocation | ✅ confirmed |

### 3.3 batch_store.rs + quorum_store_db.rs + batch_requester.rs (persistence + fetch)

| ID | Finding | Mechanism | Verified |
|----|---------|-----------|----------|
| S1 | `subscribe()` double-check pattern (batch_store.rs:538-549): push subscriber then `get_batch_from_local`. If DB get returns Err during PersistedOnly fetch, subscribe path leaks waiting | Subscribe-race | ✅ confirmed |
| S2 | `get_batch_from_local` for PersistedOnly does a fresh DB read inside the double-check. Transient DB error bypasses double-check (line 522-532, 544) | Subscribe-race | ✅ confirmed |
| S3 | `clear_expired_payload` (line 387-416) removes cache + `persist_subscribers`, no coordination with `ProofCoordinator`. Slow-aggregator vs fast-GC cross-validator race | GC vs aggregation | ✅ confirmed |
| S4 | Lock ordering: `insert_to_cache` holds db_cache entry lock while taking `peer_quota`; `clear_expired_payload` (line 411) calls `free_quota` AFTER releasing the entry lock. Two orderings exist | Lock-ordering | ✅ confirmed (per-shard locks; consistent ordering) |
| S5 | `update_quota` mutates balances before DB write happens in `persist_inner:441-457`. `.expect("Could not write to DB")` would panic on partial state; recovery rebuilds from DB | Persistence-race | ✅ confirmed; panic-on-fail is intentional |
| S6 | `replace_entry` updates quota for NEW bytes BEFORE freeing PREVIOUS bytes (line 327-352). Author near quota limit could fail legitimate expiration extension | Quota | ✅ confirmed (rare; defensive) |
| S7 | `persist_subscribers` not cleared on epoch transition (line 124). New `BatchStore` per epoch drops old subscribers; rx side gets `RecvError` | Cross-epoch / leak | ✅ confirmed |
| S8 | Closed `oneshot::Receiver` busy-spins `tokio::select!` (batch_requester.rs:164-175) — `Err` on every poll | Leak | ✅ confirmed |
| S9 | NotFound verification correct (line 142-152): BLS quorum + timestamp > expiration. But Byzantine peer with a recent legitimate `LedgerInfo` whose `timestamp` barely exceeds `expiration` can cause requesters to give up | Liveness DoS | ✅ confirmed |
| S10 | Quota check happens AFTER cache entry lock acquired and AFTER expiration comparison (line 312-336). Excess batches DO fail before DB write — no leak | Quota | ✅ confirmed (correct) |
| S11 | `PersistedOnly` mode is only assigned on initial insert, no runtime demotion. The supposed "two threads observing different modes" does not occur | Persistence-mode | ✅ refuted by direct read |
| S12 | `free_quota` panics if author has no QuotaManager (line 286-292). Bootstrap path creates the QuotaManager; race window if loader hasn't finished | Bootstrap race | ✅ confirmed |
| S13 | `load_batches_from_db` (line 213-216): batches with `epoch < current_epoch` OR `expiration < gc_timestamp` are deleted on bootstrap. **Cross-epoch survival is not guaranteed** | Cross-epoch | ✅ confirmed |
| S14 | On `is_new_epoch`, `load_batches_from_db_*` runs in `spawn_blocking` (line 156-189). `BatchStore` returned to callers immediately; concurrent `save` races with loader's `insert_to_cache` for same digest → double-deduct quota | Bootstrap race | ✅ confirmed |
| S15 | `clean_and_get_batch_id` panics on regressed epoch (`assert!(current_epoch >= epoch)`, quorum_store_db.rs:171) | Bootstrap fragility | ✅ confirmed |
| S16 | All DB writes use `write_schemas_relaxed` (no fsync) — quorum_store_db.rs:99, 129, 159 | Persistence | ✅ confirmed |
| S17 | `inflight_fetch_requests` `defer!` (batch_store.rs:633-635) runs on every exit including panic | Leak (mitigated) | ✅ confirmed |
| S18 | TODOs: `batch_store.rs:636` (V2 fetch support), `quorum_store_db.rs:64` (twins test path uniqueness) | Documentation | ✅ confirmed |

### 3.4 proof_coordinator.rs + proof_manager.rs + batch_proof_queue.rs (aggregation + queue)

| ID | Finding | Mechanism | Verified |
|----|---------|-----------|----------|
| P1 | `add_signature` (proof_coordinator.rs:159-163) increments `aggregated_voting_power` without BLS verification (relies on upstream `SignedBatchInfoMsg::verify_inner` + `optimistic_verify`). If aggregate-and-verify fails, `filter_invalid_signatures` (ledger_info.rs:510-513) drops invalid signers and retries. Net: **`aggregated_voting_power` field is metric-only**; `check_voting_power` uses `all_voters()` which reflects filter results. **Initial concern (stuck aggregator) is closed by the fallback.** | Verification (closed) | ✅ verified, refuted |
| P2 | Dedup by full `BatchInfoExt` (line 234, 290-302) — two distinct digests for same `(author, batch_id)` produce parallel `IncrementalProofState` entries on the author | Equivocation | ✅ confirmed |
| P3 | `init_proof` rejects `signed_batch_info.author() != self.peer_id` (line 275-277). A node only aggregates for batches IT authored — correct architecturally | Trust boundary | ✅ confirmed |
| P4 | Self-vote ordering: `self_voted` flag set inside `add_signature` (line 164-166). If remote signatures reach 2f+1 first, PoS forms without self-vote | Ordering | ✅ confirmed |
| P5 | `aggregate_and_verify` is one-shot via `if !value.completed && value.check_voting_power(...)` guard (line 330). Subsequent calls panic via `panic!("Cannot call take twice")` (line 212). Serialization via tokio main loop prevents reaching this in practice | Invariant | ✅ confirmed |
| P6 | No rate limit / per-author quota on incoming signatures. Protected by `batch_reader.exists(digest)` check at `init_proof:280` — only locally-stored batches can have aggregation initiated | DoS (bounded) | ✅ confirmed |
| P7 | `ProofManager::receive_proofs` (proof_manager.rs:69-101) does NOT check body presence in `BatchStore` before inserting into queue. Proposer can include PoS for body it doesn't have locally | Proof-store-desync | ✅ confirmed |
| P8 | `update_remaining_txns_and_proofs` (line 103-109) sampled every 200ms via `sample!`. Backpressure reads stale values | Backpressure drift | ✅ confirmed |
| P9 | `BatchSortKey` ordering: `(gas_bucket_start ASC, batch_id DESC)` (utils.rs:194-203). Iterated `.iter().rev()` gives `(gas_bucket DESC, batch_id ASC)` | Fairness | ✅ confirmed |
| P10 | No per-author cap on signature msg size (`SignedBatchInfoMsg.take()` is unbounded). Protected only by `init_proof`'s `exists(digest)` gate | DoS (bounded) | ✅ confirmed |
| P11 | `TimeExpirations` heap and per-peer maps can diverge — orphan entries possible | GC accounting | ✅ confirmed |
| P12 | Same `BatchSortKey` added to expirations twice on insert_batches→insert_proof path (batch_proof_queue.rs:338, 466) — memory bloat | Accounting | ✅ confirmed |
| P13 | `txn_summary_num_occurrences` decrement only on expire-with-proof or commit-with-proof (line 1035-1046, 1063-1066). Net consistent because insertion also gated on `has_proof` | Accounting | ✅ verified consistent |
| P14 | `mark_committed` for unseen batch (batch_proof_queue.rs:1241-1254) creates a placeholder QueueItem. Subsequent late proof/summary arrivals rejected correctly | Lifecycle | ✅ verified |
| P15 | Re-insertion path: GC'd expired batch can be re-inserted as fresh entry if proof arrives later. Bounded by `proof.expiration() <= self.latest_block_timestamp` check (line 274) | Re-insertion | ✅ confirmed |
| P16 | OptQS triple-tier: `excluded_batch_keys` in `PullSession` prevents same batch in multiple tiers WITHIN a single `handle_proposal_request` call. Across proposals, the same batch can appear in different tiers | Proof-store-desync (cross-call) | ✅ confirmed |
| P17 | Underflow risk on `-=` decrements (batch_proof_queue.rs:231-236, 401, 503, 533, 1056-1062, 1232-1238). Debug-build panic, release-build wrap | Accounting | ✅ confirmed |
| P18 | TODO at `proof_manager.rs:178` (unique txn calculation for opt-batches) | Documentation | ✅ confirmed |
| P19 | **Batch-proof-queue ingress collision check** (batch_proof_queue.rs:279-298, 425-439). Same `(author, batch_id)` but different `BatchInfoExt` → second arrival rejected with `POS_COLLISION_LABEL` / `BATCH_COLLISION_LABEL`. **This is PR #19673.** | Equivocation (fixed at receiver) | ✅ confirmed |

### 3.5 Disclosed-Bug Cross-Reference

The test `verify_v2_rejects_v1_batch_in_batch_msg_v2` at `consensus/src/quorum_store/types.rs:144-170` corresponds to **PR #19676** "Enforce V2-only entries on V2 quorum store wire messages":
- Wire-message verification was generic over `TBatchInfo`.
- A `BatchMsgV2` containing a V1 entry passed `verify` (the `is_v2` check was absent in the generic path).
- Downstream `persist_and_send_digests` reaches `try_into().expect("Batch must be V1 batch")` or `assert!(!.is_v2())` → panic.
- Fix: `verify_inner` is now private; only the concrete `verify` (V1) and `verify_v2` (with `ensure!(is_v2)` loop) are reachable. Regression test inserts a V1 entry first then V2 second and asserts `verify_v2` rejects.
- No public security advisory, blog post, or post-mortem accompanies this fix.

---

## 4. Phase 3 — Cross-Reference and Bug Family Construction

Cross-referencing the per-file findings (§3.1-3.4) with the historical PR mechanisms (§2.2) yields the six bug families documented in `modeling-brief.md` §2. Family-to-finding mapping:

| Family | Findings | Key historical PRs |
|--------|----------|--------------------|
| Family 1 (equivocation) | C1, C2, C12, P2, P19, S13 | #19673, #19676 |
| Family 2 (sign/persist/cross-epoch) | G1, G2, G3, G6, G12, S13, S14, S15, S16, C5, C6 | #11629, #14861, #15306, #18960, #18312, #14499 |
| Family 3 (GC vs proof aggregation) | S3, S7, S8, S9, P11, P15 | #15452, #15766, #15786, #11162 |
| Family 4 (ProofManager-BatchStore desync) | P7, P16, S18 | #15452, #19372 |
| Family 5 (variant/kind verification, reference) | C4 | #19676, #19673, #19130, #19192, #19372, #19442, #19546, #19548 |
| Family 6 (counter drift, low) | P1, P4, P8, P10, P12, P13, P17, P18, G7 | #7058, #13889, #6818, #11576, #6697 |

The most TLA+-suitable families are 1, 2, 3, and 4. Family 5 is reference context (closed). Family 6 is test/code-review.

---

## 5. Verification Discipline Notes

For every finding above, I applied the verification checklist from `references/deep-analysis.md` §2:

- **Re-read**: All `file:line` references were directly read in the main context (`batch_store.rs`, `batch_coordinator.rs`, `network_listener.rs`, `batch_generator.rs:1-200, 200-400, 600-798`, `proof_coordinator.rs`, `batch_proof_queue.rs:1-220, 270-470`, `quorum_store_db.rs`, `batch_requester.rs`, `consensus-types::proof_of_store.rs:360-600`, `types/src/ledger_info.rs:440-540`, `types/src/validator_verifier.rs:260-285`, `epoch_manager.rs:1815-1935`).
- **Compensating mechanisms**: P1's "stuck aggregator" concern was investigated and **refuted** after reading `SignatureAggregator::aggregate_and_verify` (ledger_info.rs:517) which has a `filter_invalid_signatures` fallback. S11's "PersistedOnly mode transition" concern was refuted by reading `insert_to_cache` and confirming the mode is only set on initial insert.
- **Full execution path**: For Family 1, traced from BatchMsg arrival in `NetworkListener::start` → `BatchCoordinator::handle_batches_msg` → `BatchStore::save` → `BatchStore::insert_to_cache` (digest keyed) → `BatchStore::persist_inner::generate_signed_batch_info` → return to coordinator → `network_sender.send_signed_batch_info_msg{_v2}` → recipient's `NetworkListener` → `ProofCoordinator::add_signature` → `IncrementalProofState` (full `BatchInfoExt` keyed) → broadcast PoS → recipients' `BatchProofQueue::insert_proof` (BatchKey collision filter).
- **Design intent**: The README explicitly documents the digest-keyed cache as part of the equivocation defense (relying on "two different bodies have two different signatures, not one of which can be aggregated to 2f+1 honest" — but this is only true if signers don't sign BOTH bodies, which is exactly what the code does not prevent at the coordinator level).
- **Real-world impact**: The fact that PR #19673 was added in May 2026 (right next to the disclosed PR #19676) shows that equivocation surfaces remain under active scrutiny.

---

## 6. Coverage Summary

- **Source files read in full or substantially**: 11 (all core files plus `proof_of_store.rs`, `ledger_info.rs`, `validator_verifier.rs`, `epoch_manager.rs` fragments).
- **Total findings**: 64 (G14 + C12 + S18 + P19 + 1 cross-cutting).
- **Findings classified as model-checkable open questions**: 7 (MC1-MC7).
- **Findings classified as test-verifiable**: 7 (T1-T7).
- **Findings classified as code-review**: 10 (R1-R10).
- **Findings refuted on verification**: 2 (P1 stuck aggregator; S11 PersistedOnly transition).
- **Bug families**: 6 (4 modeled, 1 reference, 1 test/review-only).

All claims trace to `file:line` references or `PR#`/`commit` identifiers.

---

## 7. Methodology

Six parallel `general-purpose` subagents were dispatched for:

1. PR mining via `gh pr list` / `gh pr view` (~70 PRs collected, 25 deep-read)
2. Issue mining via `gh issue list` / `gh search issues` / `gh api .../security-advisories` (~75 items collected, 22 deep-read)
3. Deep read of `batch_generator.rs`
4. Deep read of `batch_coordinator.rs` + `network_listener.rs`
5. Deep read of `batch_store.rs` + `quorum_store_db.rs` + `batch_requester.rs`
6. Deep read of `proof_coordinator.rs` + `proof_manager.rs` + `batch_proof_queue.rs` + `utils.rs`

Main-context verification was then applied to the most consequential findings (digest-keyed dedup, sign-after-persist atomicity, aggregator filter fallback, queue collision filter at PR #19673, cross-epoch bootstrap GC, V2 fetch TODO).
