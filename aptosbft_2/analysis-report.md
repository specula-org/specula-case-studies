# Aptos BFT Code Analysis — Detailed Audit Trail

This is the detailed audit log for the Aptos BFT (HotStuff/Jolteon) case study. The handoff to spec generation is `modeling-brief.md`. This file documents methodology, coverage statistics, every cited file:line, every issue/PR examined, and every finding with full context.

System: `aptos-labs/aptos-core`, `consensus/` directory only.
Date: 2026-05-12.

---

## 1. Methodology and Coverage Statistics

### 1.1 Phases executed

| Phase | Approach | Output |
|---|---|---|
| 1. Reconnaissance | Mapped `consensus/` tree and the in-tree README; classified the system; sized core files | This document § 2 |
| 2. Bug Archaeology | One subagent ran 50+ targeted `gh search` queries against `aptos-labs/aptos-core`; verified PR diffs and discussions for every hit that matched the consensus paths in scope | `archaeology-report.md` |
| 3. Deep Analysis | Five subagents in parallel, one per major file group (safety-rules, round-manager, consensus-types, pipeline, vote-aggregation/epoch-manager) | `deep-safety-rules.md`, `deep-round-manager.md`, `deep-types.md`, `deep-pipeline.md`, `deep-aggregation.md` |
| 4. Synthesis | This file + `modeling-brief.md` | — |

### 1.2 Git history note

The local repository at `/home/ubuntu/Specula/case-studies/aptosbft_2/artifact/aptos-core/` is a single-commit snapshot (`24235317 [jwk-consensus] Clean up state lookup in process_peer_request (#19710)`). Git-history mining was therefore done **via GitHub `gh`** rather than local `git log`. This is a complete substitute because every PR returns its merged diff and discussion via `gh pr view --comments` / `gh pr diff`.

### 1.3 Coverage statistics

From the archaeology subagent:

| Bucket | Count |
|---|---|
| Targeted `gh search` queries executed | 50+ |
| Distinct candidate PRs/issues surfaced | 90+ |
| Candidates deeply read (description + diff or comments) | 35 |
| Confirmed safety-relevant items | 23 |
| Open / unresolved with safety intent | 4 |
| Explicit false-positive exclusions | 12 |
| Specific in-prompt anchors verified | PR **#13711** (order-vote epoch check added), commit **`f58e184471`** (timeout-signing check added), Issue **#18298** (sign-then-persist) |

From the deep-analysis subagents:

| File group | LOC analysed | Top-level findings |
|---|---|---|
| safety-rules (5 files) | 1,250 | 10 ranked S-findings + 7 atomicity-table rows + 16-guard asymmetry table |
| round_manager + recovery + round_state + proposal_generator | 3,893 | 10 ranked findings + handler check table for 8 message types |
| consensus-types verifiers (13 files) | 2,974 | 10 ranked findings + verification inventory for 14 verify methods |
| pipeline + block_storage (14 files) | analysed in full | 10 ranked F-findings + crash-window table for 8 persistence sites |
| pending_votes / pending_order_votes / network / network_interface / epoch_manager | 4,727 | 10 ranked findings + epoch-routing decision tree + validator-set lookup table |

Coverage is concentrated on the BFT-safety-critical files; the 50+ files in `consensus/src/dag/` (the DagBFT prototype) and `consensus/src/quorum_store/` (data dissemination) were touched only where they are dependencies of the in-scope code (e.g. `dag/commit_signer.rs` was consulted for cross-reference, `quorum_store_msg_tx` routing was examined in `epoch_manager.rs`).

---

## 2. Phase 1 — Reconnaissance

### 2.1 In-tree structure (from `consensus/README.md` + `ls`)

```
consensus
├── src
│   ├── round_manager.rs              (2434 LOC) main event loop
│   ├── recovery_manager.rs           (174 LOC)
│   ├── epoch_manager.rs              (2170 LOC)
│   ├── pending_votes.rs              (869 LOC)
│   ├── pending_order_votes.rs        (378 LOC)
│   ├── network.rs                    (1067 LOC)
│   ├── network_interface.rs          (243 LOC)
│   ├── block_storage/
│   │   ├── block_store.rs            (~900 LOC)
│   │   ├── block_tree.rs             (~600 LOC)
│   │   └── sync_manager.rs           (~900 LOC)
│   ├── liveness/
│   │   ├── round_state.rs            (387 LOC)
│   │   ├── proposal_generator.rs     (898 LOC)
│   │   └── proposer_election.rs / leader_reputation.rs / unequivocal_proposer_election.rs
│   ├── pipeline/                     (decoupled execution, ~12 files)
│   │   ├── buffer_manager.rs
│   │   ├── buffer_item.rs
│   │   ├── pipeline_builder.rs
│   │   ├── signing_phase.rs
│   │   ├── persisting_phase.rs
│   │   ├── execution_phase.rs / execution_schedule_phase.rs / execution_wait_phase.rs
│   │   └── decoupled_execution_utils.rs / pipeline_phase.rs / commit_reliable_broadcast.rs
│   ├── consensus_observer/, dag/, quorum_store/, rand/  (out of scope)
├── consensus-types/src               (~3 kLOC of message types + verifiers)
│   ├── vote.rs (176)  vote_msg.rs (82)  vote_data.rs (86)
│   ├── order_vote.rs (94)  order_vote_msg.rs (68)  order_vote_proposal.rs (50)
│   ├── timeout_2chain.rs (510)  round_timeout.rs (184)
│   ├── quorum_cert.rs (168)  wrapped_ledger_info.rs
│   ├── proposal_msg.rs (157)  opt_proposal_msg.rs (334)  opt_block_data.rs
│   ├── sync_info.rs (224)  safety_data.rs (70)  block.rs (663)  pipelined_block.rs
│   └── ...
└── safety-rules/src                  (1250 LOC)
    ├── safety_rules.rs (500)
    ├── safety_rules_2chain.rs (215)
    ├── persistent_safety_storage.rs (278)
    ├── consensus_state.rs (83)
    └── safety_rules_manager.rs (174)
```

### 2.2 Concurrency model

- `RoundManager::start` is a single `tokio::select!` (`round_manager.rs:2107`) per epoch that owns mutable `RoundState`, `pending_opt_proposals`, `pending_order_votes`. Hands off to safety-rules via `Arc<Mutex<MetricsSafetyRules>>` (`round_manager.rs:354`).
- Network message verification runs on a `bounded_executor.spawn_blocking` (`epoch_manager.rs:1711`).
- Pipeline phases are independent Tokio tasks wired by `unbounded` channels (`buffer_manager.rs:96-100`).
- Per-block pipeline futures live in `pipeline_builder.rs` and are driven by per-block oneshot channels (`pipeline_builder.rs:316-365`).
- SafetyRules backend can be in-process (`local_client.rs`), thread (`thread.rs`), or process (`process.rs` via SerializerService).
- Persistence: `set_safety_data` is the only durable safety state; backend is `OnDiskStorage` (test) or `Vault` (prod).

### 2.3 Atomicity boundary inventory

| Operation | Atomic? | Notes |
|---|---|---|
| `safety_data` read | yes (cached `Option<SafetyData>` clone) | Returned by clone; mutations to caller's clone need explicit `set_safety_data` to persist |
| `set_safety_data` | not durable in OnDisk backend (no `fsync`) | `OnDiskStorage::write` does temp + rename, no `sync_all` (`on_disk.rs:64-70`) |
| Vote sign + persist | NOT atomic | `safety_rules_2chain.rs:88-92` signs then persists |
| Timeout sign + persist | atomic in correct order (persist `:47`, sign `:49`) | The intended pattern |
| Block insert + tree mutation | not atomic across calls | `block_store.rs:524-526` saves then mutates in-memory; `:531-568` mutates in-memory then saves |
| `send_for_execution` | not atomic | Two separate `inner.write()` lock acquisitions (`block_store.rs:348-358`) |
| `commit_callback` storage IO + tree mutation | not atomic across success/failure | Storage prune failures `warn!`-only; tree advances regardless (`block_tree.rs:591-599`) |

### 2.4 Classification

**Category A (Distributed / Message-Passing)** with **BFT threat model**.

- Distributed fault families needed: 5.1 Crash, 5.2 Network (loss/reorder), 5.3 Timeout, 5.4 NonAtomicPersist, 5.5 ConfigChange (epoch transition), 5.6 not load-bearing here (snapshots are local execution, not protocol-layer).
- Byzantine action categories needed: **2.1 Equivocation** (proposer issues conflicting proposals), **2.2 Invalid Content Fabrication** (forged QC content), **2.5 Replay** (cross-epoch order-vote / timeout replay), **2.6 Amnesia** (post-crash recovered validator), **2.7 Certificate / Quorum-Proof Manipulation** (WrappedLedgerInfo value-rebind, deferred QC verify).
- Conditional categories deferred: **2.4 Selective Dissemination** (no historical evidence in this codebase that this is the load-bearing surface); **2.8 Evidence** (slashing is on-chain, out of scope per prompt); **2.9 Adaptive** (validator set is fixed within an epoch — adaptive across epochs is captured by 5.5 ConfigChange).

This decision is repeated in `modeling-brief.md` § 1.

---

## 3. Phase 2 — Bug Archaeology (full evidence)

The full archaeology output is in `archaeology-report.md`. Summary table reproduced here for self-containment:

### 3.1 Confirmed safety-relevant PRs (23)

| # | One-line | Family |
|---|---|---|
| **PR #13711** | Add epoch check in `verify_order_vote_proposal` | 2 |
| **commit `f58e184471`** | Add `BadTimeoutLastVotedRound` / `BadTimeoutPreferredRound` / `IncorrectEpoch` checks to `sign_timeout` | 1 (timeout-side analog) |
| **PR #14637** | Sync up QC in order vote message → bind QC into `pending_order_votes` | 2 |
| **PR #14129** | Optimise QC verification + split `verify` into `verify_order_vote` + lazy QC verify | 2, 3 |
| **PR #13986** | Fix `InvalidOrderedLedgerInfo` after fast-forward sync (commit-vote / ordered-LI mismatch) | 6, 3 |
| **PR #17766** | Race in `BlockStore::add_certs` — sync HQC before HCC | 5 |
| **PR #12239** | Race: epoch-change notification before commit task spawned | 5 |
| **PR #15746** | Companion: move `send_epoch_change` to `PersistingPhase` after the actual commit | 5 |
| **PR #1826** | Missing QC when `highest_commit_cert` points at a dangling node after fast-sync | 6 |
| **PR #2990** | Cross-epoch leader election filter — `(epoch, round)` instead of round-only | 4 |
| **PR #4232** | Block-store race: prune-during-rebuild | 5 |
| **PR #4445** | Block-retrieval edge case (`need_sync_for_ledger_info` underwhelming) | 5/6 |
| **PR #13864** | Block-retrieval self-retrieval timeout | 6 |
| **PR #13605** | `RoundManager::new_ordered_cert` inserted QC without `process_certificates` advance | 2 |
| **PR #9879/#9891** | Re-broadcast condition inverted (`<` vs `>=`) | 5 |
| **PR #15452** | OptQS: ignore stale proposals due to fetch lag | 7 |
| **PR #15361** | Move `payload_manager.notify_commit` to after commit | 5 |
| **PR #18023** | BufferManager: ack commit-vote when round equals `highest_committed_round` | 5 |
| **PR #14570** | Cache commit votes for future rounds in BufferManager | 5 |
| **PR #14482** | `pending_commit_proofs` for LI received before round in buffer | 5 |
| **PR #18970** | Sender-author binding for `RandShare`/`FastShare` | (out of scope: rand) |
| **PR #19142** | Chunky DKG equivocation bug | (out of scope: DKG) |
| **PR #19359** | Rand-manager deadlock in multi-block batches | 5 |
| **PR #19084** | Module-cache deadlock on pipeline teardown | 5 |
| **Issue #18298** | Sign-then-persist crash window — disputed by maintainer | 1 |

### 3.2 False positives explicitly excluded (12)

- Move governance "voting boundary" PRs (on-chain voting, not BFT consensus).
- PR **#13023** — feature implementation, not bug fix.
- PR **#14346** — liveness heuristics tuning.
- PR **#16850** — refactor / dead-code cleanup.
- PR **#16327** — JWK consensus, not BFT.
- PR **#19613** — self-marked INVALID by author after they realised the bug didn't exist.
- PR **#19450** — pure metric/timestamp accuracy.
- PR **#19174** — latency-tuning experiment.
- PR **#19323** — leader-rep tuning.
- PR **#18280** — empty validator set / stake module.
- PR **#18834** — randomness off-by-one.
- PR **#18646** — randomness optimisation.
- PR **#19063, #19315, #19475** — observer / RPC / DoS hardening.
- "Move type-safety" / "reference safety" / "move-prover" PRs — Move language safety, not BFT.

### 3.3 Open / unresolved (4)

| # | Title | Status |
|---|---|---|
| Issue **#18298** | Non-atomic SafetyData persistence enables double-voting after crash recovery | CLOSED, **Disputed**, no patch |
| PR **#19684** | jwk-consensus epoch-replay (doc-only) | OPEN, doc-only |
| PR **#19673** | tighten BatchProofQueue ingress checks | OPEN |
| PR **#19444** | Add test for non-proposer connections | DRAFT |

---

## 4. Phase 3 — Deep Analysis (consolidated)

The full per-file analyses are in the five `deep-*.md` files. This section consolidates them by Bug Family, with file:line evidence for every claim. Findings tagged `[VERIFIED]` were re-checked against the source (a second Read or Grep call) before inclusion.

### 4.1 Family 1 — Crash-window double vote (VERIFIED)

**F1.1 [VERIFIED]** `safety_rules_2chain.rs:53-95` — `guarded_construct_and_sign_vote_two_chain` orders sign before persist:

```rust
let signature = self.sign(&ledger_info)?;          // line 88
let vote = Vote::new_with_signature(...);          // line 89
safety_data.last_vote = Some(vote.clone());        // line 91 in-memory
self.persistent_storage.set_safety_data(safety_data)?; // line 92 persist
Ok(vote)                                            // line 94
```

Compare with the timeout path at `safety_rules_2chain.rs:19-51` which orders correctly:

```rust
self.update_highest_timeout_round(timeout, &mut safety_data); // L46
self.persistent_storage.set_safety_data(safety_data)?;        // L47 persist FIRST
let signature = self.sign(&timeout.signing_format())?;        // L49 sign AFTER
```

**F1.2 [VERIFIED]** `safety_rules_2chain.rs:97-119` — `guarded_construct_and_sign_order_vote` also signs before persist (sign `:115`, persist `:117`). The persisted state lost in a crash here is `preferred_round` and `one_chain_round` advances from `observe_qc(:108)` — a regular vote following recovery would then accept a block whose parent QC round was previously rejected.

**F1.3 [VERIFIED]** `safety_rules.rs:412-413` — explicit TODOs in `guarded_sign_commit_vote`:

```rust
// TODO: add guarding rules in unhappy path
// TODO: add extension check
```

The function performs no `set_safety_data` at all (`safety_rules.rs:372-418` end-to-end). Combined with the lack of a `last_committed_round` field in `SafetyData`, a Byzantine peer could obtain repeated distinct commit-vote signatures from the same validator at the same logical commit position.

**F1.4 [VERIFIED]** `secure/storage/src/on_disk.rs:64-70` — `OnDiskStorage::write` lacks `fsync`/`sync_all`:

```rust
fn write(&self, data: &HashMap<String, Value>) -> Result<(), Error> {
    let contents = serde_json::to_vec(data)?;
    let mut file = File::create(self.temp_path.path())?;
    file.write_all(&contents)?;
    fs::rename(&self.temp_path, &self.file_path)?;
    Ok(())
}
```

The `OnDiskStorage` is documented as "should not be used in production" (`on_disk.rs:22`) but is the test default. Production uses `Vault` which delegates durability to the remote service.

**F1.5 [VERIFIED]** `consensus-types/src/safety_data.rs:8-21` — `serde(default)` on `one_chain_round` and `highest_timeout_round`:

```rust
pub struct SafetyData {
    pub epoch: u64,
    pub last_voted_round: u64,
    pub preferred_round: u64,
    #[serde(default)]
    pub one_chain_round: u64,
    pub last_vote: Option<Vote>,
    #[serde(default)]
    pub highest_timeout_round: u64,
}
```

After binary upgrade from a legacy on-disk format, both fields default to 0, widening the accept set for `safe_to_timeout` (which checks `qc_round >= one_chain_round`) and `safe_for_order_vote` (which checks `round > highest_timeout_round`).

**F1.6 [VERIFIED]** `round_manager.rs:1855-1857` — `EchoTimeout` re-entry path:

```rust
VoteReceptionResult::EchoTimeout(_) if !self.round_state.is_timeout_sent() => {
    self.process_local_timeout(round).await?;
}
```

Combined with `safety_rules_2chain.rs:37-45` allowing `timeout.round() == last_voted_round` (only strictly less is rejected), a node that crashed between `sign_timeout_with_qc` and `record_round_timeout` (`round_manager.rs:1071`) can on restart sign a second timeout for the same round.

**Issue #18298 status (re-verified)**: Reporter (`stevdza`) filed PoC tests; maintainer `danielxiangzl` replied "the vote is persisted before being sent to the network." The disputed code path matches `safety_rules_2chain.rs:53-95` in the local snapshot. The maintainer's reply is correct *if* `set_safety_data` is synchronous-durable; it is not under `OnDiskStorage` (no fsync), and the `Vault` backend's durability depends on Vault server config. The Byzantine-equivocating-proposer half — required for a *different* vote to arrive at round R after the crash — is the unmodelled MC-4 from the prior round.

### 4.2 Family 2 — Order-vote vs regular-vote / timeout asymmetry (VERIFIED)

**F2.1 [VERIFIED]** `safety_rules_2chain.rs:168-178` — `safe_for_order_vote`:

```rust
fn safe_for_order_vote(&self, block: &Block, safety_data: &SafetyData) -> Result<(), Error> {
    let round = block.round();
    if round > safety_data.highest_timeout_round { Ok(()) } else { Err(...) }
}
```

The only check is `round > highest_timeout_round`. There is **no** `last_voted_round` interlock. A regular vote at round R sets `last_voted_round = R`; a subsequent order-vote at round R passes `safe_for_order_vote` provided `R > highest_timeout_round`. The order-vote also does **not** update `last_voted_round`.

**F2.2 [VERIFIED]** `safety_rules.rs:87-111` — `verify_order_vote_proposal` skips `validate_signature` and `verify_well_formed`:

```rust
self.verify_epoch(proposed_block.epoch(), &safety_data)?;     // L94 (added by #13711)
let qc = order_vote_proposal.quorum_cert();
if qc.certified_block() != order_vote_proposal.block_info() { ... }
if qc.certified_block().id() != proposed_block.id() { ... }
self.verify_qc(qc)?;
```

Compare `verify_proposal` at `safety_rules.rs:67-85`:

```rust
self.verify_epoch(proposed_block.epoch(), &safety_data)?;
self.verify_qc(proposed_block.quorum_cert())?;
proposed_block.validate_signature(&self.epoch_state()?.verifier)?;  // skipped by order-vote
proposed_block.verify_well_formed()?;                                // skipped by order-vote
```

**F2.3 [VERIFIED]** `round_manager.rs:1582-1660` — `process_order_vote_msg` does NOT call `ensure_round_and_sync_up`. Compare with `process_vote_msg` (`:1733-...` calls it at `:1739`), `process_round_timeout_msg` (`:1900`), and `process_proposal_msg` (`:781`).

**F2.4 [VERIFIED]** `pending_order_votes.rs:61-157` — has **no** per-author equivocation map. Compare with `pending_votes.rs:287-309`:

```rust
if let Some((previously_seen_vote, ll_digest)) = author_to_vote.get(&vote.author()) {
    if &li_digest != ll_digest {
        error!(SecurityEvent::ConsensusEquivocatingVote, ...);
        return VoteReceptionResult::EquivocateVote;   // line 307
    }
    ...
}
```

The order-vote insertion (`insert_order_vote`) only computes `li_digest = order_vote.ledger_info().hash()` (`:68`) and then enters the `li_digest_to_votes.entry(li_digest).or_insert_with(...)` map (`:71-81`). A Byzantine validator that sends two `OrderVote(li_digest_A)` and `OrderVote(li_digest_B)` for the same round is silently accepted; both signatures contribute to two distinct `SignatureAggregator`s.

**F2.5 [VERIFIED]** `round_manager.rs:1613-1633` — only the FIRST OrderVoteMsg per `li_digest` triggers `quorum_cert.verify`; subsequent messages pass `None` to `insert_order_vote`. Verified at `pending_order_votes.rs:71-81` (`expect("Quorum Cert is expected ...")` if the caller passes `None` for a fresh digest — this would panic the consensus thread if a future race ever broke the `exists` precondition).

**F2.6 [VERIFIED]** `consensus-types/src/order_vote_msg.rs:47-67` — the comment at line 47 explicitly says "The quorum cert is verified in the round manager when the quorum certificate is used." So the receiver-side verify only checks `order_vote.author() == sender`, `quorum_cert.certified_block() == order_vote.ledger_info().commit_info()`, and `order_vote.verify(validator)` (signature only). The QC's signatures and value-binding are NOT verified here.

### 4.3 Family 3 — Certificate value-binding (VERIFIED)

**F3.1 [VERIFIED]** `consensus-types/src/wrapped_ledger_info.rs:90-108` — `verify` does NOT call `verify_consensus_data_hash` (the helper is at `:53-62`). The struct's `vote_data` field is therefore unsigned/attacker-controlled. The comment at lines 14-18 acknowledges: "vote_data and consensus_data_hash inside signed_ledger_info are not used anywhere in the code and can be set to dummy values" — but if any caller reads `wrapped.vote_data.proposed()` after only `verify`, they read attacker data. Combined with the round-0 short-circuit at `:97-103`, an attacker can build a wrapped LI passing `verify` with no signatures and arbitrary `vote_data`.

**F3.2 [VERIFIED]** `consensus-types/src/timeout_2chain.rs:141-183` — `TwoChainTimeoutCertificate::verify` does NOT enforce 2f+1 voting power. It calls `verify_aggregate_signatures` (signature only) and `timeout.verify` (carried QC), plus `hqc_round == max(signed)`. Quorum is the caller's responsibility.

**F3.3 [VERIFIED]** `consensus-types/src/round_timeout.rs:17-22` (`RoundTimeoutReason`) and `consensus-types/src/timeout_2chain.rs:66-72` (`TimeoutSigningRepr`) — the signing format covers only `{epoch, round, hqc_round}`; `RoundTimeoutReason` is NOT in the signed payload. A man-in-the-middle can rewrite `reason` while keeping the signature.

**F3.4 [VERIFIED]** `consensus-types/src/opt_proposal_msg.rs:96-131` — `verify` does NOT call `validate_signature` on the carried `block_data`. Authentication is only the network-layer `sender == proposer` field comparison. By contrast, `ProposalMsg::verify` at `proposal_msg.rs:114-117` requires `proposal.validate_signature(validator)`.

**F3.5 [VERIFIED]** `consensus-types/src/vote.rs:152` (open TODO):

```
// TODO(ibalajiarun): Ensure timeout is None if RoundTimeoutMsg is enabled.
```

A Vote's `two_chain_timeout` field signs the same `TimeoutSigningRepr` as a `RoundTimeoutMsg`. With both paths active, an aggregator that listens on both channels could double-count the same signer's timeout signature.

**F3.6 [VERIFIED]** `vote_msg.rs:77-80`, `round_timeout.rs:167-169`, `proposal_msg.rs:126` — all three network-edge `verify` methods explicitly defer `sync_info.verify`. Any consumer reading off `vote_msg.sync_info()` fields before `.verify()` reads attacker-controlled QCs/TCs/LIs.

**F3.7 [VERIFIED]** `safety_rules.rs:372-418` — `guarded_sign_commit_vote` performs:
- `signer()` lookup (`:377`)
- `is_ordered_only` / `match_ordered_only` (`:381-403`)
- `ledger_info.verify_signatures(&self.epoch_state()?.verifier)` (`:407-410`) — uses CURRENT epoch's verifier, but `safety_data.epoch` is NOT cross-checked
- The two TODOs at `:412-413`
- `sign(&new_ledger_info)` (`:415`)

No `verify_epoch(old_ledger_info.epoch(), &safety_data)`. No persistence of `last_committed_round`. No proof that `new_ledger_info` extends `old_ledger_info` beyond `match_ordered_only` field equality.

### 4.4 Family 4 — Cross-epoch replay (VERIFIED)

**F4.1 [VERIFIED]** `consensus-types/src/timeout_2chain.rs:248-257` — `TwoChainTimeoutWithPartialSignatures::add` uses `debug_assert_eq!` for epoch and round equality; release-stripped. Direct cross-epoch acceptance via this debug_assert is NOT a safety violation because `TwoChainTimeoutCertificate::verify` reconstructs the per-signer `TimeoutSigningRepr` using the cert's claimed epoch/round and the per-signer signature would not validate. **However**, a Byzantine peer who can deliver cross-epoch `TwoChainTimeout` messages to an honest aggregator silently corrupts that aggregator's local state in release — a liveness/DoS surface (the produced cert later fails verification and is dropped).

**F4.2 [VERIFIED]** `consensus-types/src/order_vote_msg.rs:47-67` — `verify_order_vote` does NOT enforce `order_vote.epoch() == quorum_cert.certified_block().epoch()`. PR #13711 added the epoch check on the *signing* side (`safety_rules.rs:94`); the *receive-and-aggregate* side at `round_manager.rs:1582-1660` still relies only on the EpochManager filter on `OrderVoteMsg.epoch`.

**F4.3 [VERIFIED]** `epoch_manager.rs:1692-1750` — bounded-executor verification captures `epoch_state.verifier` (Arc-clone at `:1717`) before `spawn_blocking`. After `start_new_epoch` rotates `self.epoch_state` (line 1243, 1279), an in-flight verification result is delivered through the OLD `round_manager_tx` (cloned at `:1702`). `shutdown_current_processor` (`:657-703`) awaits the OLD RM's acknowledgement before swapping, so currently the worst case is the message being silently dropped (channel closed). A future refactor that left the OLD RM alive across the rotation would expose a real cross-epoch delivery.

**F4.4 [VERIFIED]** `safety_rules.rs:294-303` — `guarded_initialize` resets `SafetyData` to `(new_epoch, 0, 0, 0, None, 0)` on epoch advance. Correct (rounds are per-epoch), but combined with F1.4 (no fsync), a Byzantine epoch downgrade through a forged proof would erase round history. Mitigated by `EpochChangeProof::verify(&waypoint)` at `:268`.

### 4.5 Family 5 — Pipeline race / decoupled-execution (VERIFIED)

**F5.1 [VERIFIED]** `consensus/src/pipeline/buffer_manager.rs:96-100` — every inter-phase channel uses `unbounded::<T>()`. There is no back-pressure between phases; only the intake `block_rx` honours `need_back_pressure()` (`:924-928`).

**F5.2 [VERIFIED]** `block_store.rs:531-568` — `insert_single_quorum_cert` sets `pipelined_block.set_qc(...)` in-memory at `:559` then persists at `:564`. Crash between leaves the QC visible to this run but lost on restart.

**F5.3 [VERIFIED]** `block_store.rs:348-358` — `send_for_execution` takes two separate `inner.write()` lock acquisitions:

```rust
self.inner.write().update_ordered_root(block_to_commit.id());     // L348
self.inner.write().insert_ordered_cert(finality_proof_clone.clone()); // L349
```

A reader between them sees the new ordered_root but the old highest_ordered_cert.

**F5.4 [VERIFIED]** `pipeline_builder.rs:1215-1217` — commit vote is broadcast inside the `commit_vote()` future *before* any DB write. `safety_rules.guarded_sign_commit_vote` (`safety_rules.rs:372-418`) does NOT persist anything. Documented at `buffer_manager.rs:861-863`: "Since we don't persist the votes, nodes that crashed would lose the votes even after send ack." 30s rebroadcast is the only recovery.

**F5.5 [VERIFIED]** `buffer_item.rs:149` and `:262` — `assert_eq!` on commit-info inconsistency. If a Byzantine peer pushes a commit decision aggregated against a different state and our local execution disagrees, the BufferManager process panics. Safety-correct (we cannot sign two conflicting commit infos), liveness-bad.

**F5.6 [VERIFIED]** `sync_manager.rs:328-365` (`fetch_quorum_cert`) and `:521-527` (`fast_forward_sync`) — peer-supplied QCs are inserted via `insert_single_quorum_cert` without re-verifying signatures. The defence is `LedgerRecoveryData::find_root` against the trusted commit cert anchor; intermediate QCs along the way may transiently be unverified forgeries. Author's own TODO at `:530-531`: "this is probably still necessary, but need to think harder, it's pretty subtle."

**F5.7 [VERIFIED]** `pipeline_builder.rs:83-117` and `block_store.rs:251-253` — `pre_commit_status` is in-memory only, recomputed from `root_block_round` on startup. If the executor pre-committed round R (which is ahead of the ordered/commit root) and crashed before commit, the recovered `pre_commit_status.round` is the commit root, not R.

**F5.8 [VERIFIED]** `round_manager.rs:533-549` — leader's proposal-signing task captures `sync_info`, `safety_rules`, `proposal_generator` at spawn time. While the task is running, the main loop can process a TC for round r and trigger another `NewRoundEvent` for r+1. The spawned task is unaware; `safety_rules.guarded_sign_proposal` rejects only if `block_data.round() <= safety_data.last_voted_round` (`:356`), and `last_voted_round` is updated only on voting, not on round-advancement. Result: stale-round proposal can be broadcast.

### 4.6 Family 6 — Recovery / sync (VERIFIED)

**F6.1 [VERIFIED]** `recovery_manager.rs:154-157` — `process::exit(0)` on success. No graceful handoff. Anything queued in `event_rx` past the success message is dropped.

**F6.2 [VERIFIED]** `sync_manager.rs:481-641` — `fast_forward_sync` writes the tree (`save_tree :619`), drives execution (`sync_to_target :629`), then re-reads `storage.start :635` — three steps with no atomicity.

### 4.7 Family 7 — Optimistic-proposal (VERIFIED)

**F7.1 [VERIFIED]** `consensus-types/src/opt_proposal_msg.rs:96-131` — see F3.4. No leader signature on `block_data`.

**F7.2 [VERIFIED]** `round_manager.rs:1259-1274` — `failed_authors` validation gated `if !proposal.is_opt_block()`. Opt-proposals skip this validation entirely.

**F7.3 [VERIFIED]** `round_manager.rs:881-913` — at `process_opt_proposal`, the receiver demands `hqc.certified_block().id() == opt_block_data.parent_id()` (`:897`) but never checks that the proposer's claimed `grandparent_qc` matches anything in the local block_store. `Block::new_from_opt` (`:902`) substitutes the *local* HQC. The proposer's grandparent QC claim is never re-checked.

---

## 5. Phase 4 — Synthesis: How Families compose

This is reflected in `modeling-brief.md` § 2 and § 6.1 but recorded here for the audit trail.

| Composition | What it produces | MC ID |
|---|---|---|
| Family 1 × 2.1 Equivocation × 5.1 Crash | Honest validator signs two distinct votes at the same round across recovery — the unmodelled MC-4 half | MC-1 |
| Family 2 × 2.1 Equivocation | Same validator signs both a Vote and an OrderVote for distinct values at the same round | MC-2 |
| Family 2 × multiple distinct OrderVoteProposals at same round | Two `li_digest` aggregators concurrently reach 2f+1 in `pending_order_votes` | MC-3 |
| Family 3 (WrappedLedgerInfo) × 2.7 ByzReuseRealCertificate | A `verify`-passing wrapped LI carries attacker-chosen `vote_data` | MC-4 |
| Family 3 (commit-vote) × 2.5 Replay | Cross-epoch commit-LI accepted because `sign_commit_vote` lacks epoch check | MC-5 |
| Family 4 × 2.5 Replay × 5.5 ConfigChange | Real OrderVote from epoch N replayed in epoch N+1 with inner QC from N | MC-6 |
| Family 1 (timeout variant) × Echo-timeout re-entry | Two distinct timeout signatures for same round across crash | MC-7 |

---

## 6. Verification Discipline

For each finding above, the following discipline was applied (per `references/deep-analysis.md` § 2):

- **Re-read**: every cited line was read at least once via the Read tool. Findings tagged `[VERIFIED]` were cross-referenced by the synthesis pass.
- **Compensating mechanisms**: the analysis explicitly notes when a check exists at a different layer (e.g. F4.1 — the aggregator `debug_assert` is compensated by the downstream `verify` reconstructing `TimeoutSigningRepr`; F4.3 — the in-flight verification race is compensated by `shutdown_current_processor` await).
- **Full execution path**: the round-manager handler check table (in `deep-round-manager.md` § 1) traces each entry from `EpochManager::check_epoch` through `UnverifiedEvent::verify` to the handler.
- **Design intent**: explicit comments and TODOs in the source were quoted verbatim where relevant (`safety_rules.rs:412-413`, `wrapped_ledger_info.rs:14-18`, `vote.rs:152`, `block_tree.rs:381`, `sync_manager.rs:530-531`, `buffer_manager.rs:861-863`).
- **Real-world impact**: Issue **#18298** is the only filed report of Family 1 mechanism; the maintainer's reply makes the implicit assumption explicit (durability of `set_safety_data`).

### 6.1 Findings explicitly excluded with reason

- **`SafetyRules::sign_proposal` does not bump `last_voted_round`** (`safety_rules.rs:346-370`): An honest leader is called once per round by the round manager, and proposal signing is "consensus-layer responsibility", not SafetyRules. Demoted to `Code-Review-Only` (CR-list note).
- **`MetricsSafetyRules.retry`** (`metrics_safety_rules.rs:71-85`): retries only on `IncorrectEpoch` / `WaypointOutOfDate` after re-initialise; idempotent for vote-signing assuming the `last_vote` cache holds.
- **`ConsensusState` mutable getter signature mismatch**: cosmetic.
- **`Display` string omits `one_chain_round` / `highest_timeout_round`**: operational only.
- **Move governance "voting boundary"**: not BFT consensus.
- **JWK consensus / DAG / DKG / randomness**: out of scope per prompt.

---

## 7. Component-level reports (cross-references)

The following five reports contain the full per-file analyses that this consolidated report draws from. Each was produced by a parallel subagent reading every cited file in full.

- `deep-safety-rules.md` — 5 files, 1,250 LOC, 10 ranked findings.
- `deep-round-manager.md` — 4 files, 3,893 LOC, 10 ranked findings + 8-handler check table.
- `deep-types.md` — 13 files, 2,974 LOC, 10 ranked findings + 14-method verify inventory.
- `deep-pipeline.md` — 14 files, 10 ranked findings + crash-window table for 8 sites.
- `deep-aggregation.md` — 5 files, 4,727 LOC, 10 ranked findings + epoch-routing decision tree.

All five are stored in this directory. The handoff to spec generation is `modeling-brief.md`.
