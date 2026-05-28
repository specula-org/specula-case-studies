# Modeling Brief: Solana Tower BFT (`anza-xyz/agave`)

## 1. System Overview

- **System**: `anza-xyz/agave` — the maintained Solana validator client (fork of `solana-labs/solana`); Tower BFT is the production consensus protocol live on Solana mainnet since 2020.
- **Language**: Rust, ~22 kLOC of Tower BFT consensus code (split across `core/src/consensus.rs` and `core/src/consensus/`, plus replay-stage / vote-listener / OC-verifier driver files).
- **System category**: **Category A (Distributed / Message-Passing)** with a **Byzantine threat model** (stake-weighted; safety requires ≤ ⌊n/3⌋ Byzantine stake). Sub-category: **vote-lockout BFT** — distinct from quorum-cert BFT in that there are no leader-issued QCs/TCs; safety is enforced by each validator's exponentially-growing local lockouts plus stake-weighted thresholds for switching and confirming.
- **Protocol**: Tower BFT. Validators vote on PoH-ordered slots; each vote occupies a stack slot with a doubling lockout (lockout = `2^confirmation_count`). Switching forks requires accumulating `SWITCH_FORK_THRESHOLD = 0.38` stake-weighted lockouts on the alternate fork past the last vote. A slot reaches **duplicate / optimistic confirmation** at `DUPLICATE_THRESHOLD = 0.52` stake. The vote-threshold check requires `≥ VOTE_THRESHOLD_SIZE = 2/3` stake at depth `VOTE_THRESHOLD_DEPTH = 8`. Note: `SWITCH_FORK_THRESHOLD + DUPLICATE_THRESHOLD + DUPLICATE_LIVENESS_THRESHOLD = 1.0` is the algebraic identity that keeps OC safe against ≤ 1/3 Byzantine stake.
- **Key architectural choices deviating from textbook BFT**:
  - **No quorum certificates** — switching/confirmation derived from accumulated per-validator lockouts.
  - **PoH (Proof of History)** provides total order on slots; modeling treats this as an oracle.
  - Tower is **persisted to a plain file with no fsync** (`tower_storage.rs:213-218`, comment "hurts performance"); tower↔blockstore writes are **not write-ordered** (`consensus.rs:1748-1752`).
  - **Voting-service thread is separate** from the replay-stage thread; vote decisions in replay-stage send `VoteOp` over a channel to voting-service which then saves the tower **before** broadcasting the vote tx.
  - **Stray-restored-slot**: persisted tower's `last_voted_slot` not found in current ledger at replayed root → tower marks itself "stray" and uses **weakened switch-proof semantics** (`is_valid_switching_proof_vote` returns `Some(true)` when `last_vote_ancestors` is empty).
  - **`#[serde(skip)]`** on `stray_restored_slot`, `last_vote_tx_blockhash`, `last_switch_threshold_check` — these safety-relevant fields are NOT persisted across restart.
  - **Cluster supports runtime identity rotation** (`set-identity` admin RPC) — towers are identity-keyed and must reload.
- **Concurrency model**: single-threaded replay stage drives `Tower` mutations; separate voting-service thread persists + broadcasts; cluster-info-vote-listener thread aggregates gossip votes. `BankForks` is the shared DAG (`RwLock`).

## 2. Bug Families

### Family A: Tower-restore-after-crash soundness (HIGH)

**Mechanism**: When the persisted tower disagrees with the locally-replayed ledger state at restart, the code falls into recovery paths that weaken Tower BFT's safety guarantees — admitting `empty_ancestors` substitution, "freebie votes" without switch proofs, and silent fallback to bank-derived tower. The persistence layer itself lacks fsync, so the on-disk tower can lag the broadcast vote.

**Evidence**:
- Historical: Open issue **#23135** (stray votes after restart → switching violation, 4+ years open), open issue **#23137** (snapshot >512 slots ahead → SlotHashes panic), open issue **#25598** (should use AccountsDB longer slot history); fixed `cd2878acf` (hard-fork root loss), `befe8b9d9`+`07955e79a` (set-identity tower reload), `ace24a7c8` (default tower marked stray), `3e24b410f` (cross-restart refresh eligibility).
- Code analysis: `consensus.rs:881-898` (empty-ancestors short-circuit returning `Some(true)`), `:975-1005` (`empty_ancestors_due_to_minor_unsynced_ledger`: admits "shouldn't result in slashing" but no proof), `:1058-1073` (TODO "freebie vote that may violate switching thresholds"), `:1038-1040` (TODO "last vote on a dupe + restart"), `:1476` (panic on `replayed_root` `TooOld` in SlotHistory), `:1493-1500` (`TooOldTower` silent fallback when `--require-tower=false`), `:1631-1646` vs `:706` (divergent `last_voted_slot` notions after restore), `:1748-1752`+`:1781-1789` (admitted tower↔blockstore non-ordering), `tower_storage.rs:213-218` (no fsync), `voting_service.rs:114-149` (tower save BEFORE vote-tx broadcast → phantom-vote on crash).

**Affected code paths**:
- `Tower::adjust_lockouts_after_replay` / `Tower::adjust_lockouts_with_slot_history` (`consensus.rs:1462-1650`)
- `Tower::make_check_switch_threshold_decision` empty-ancestors branch (`consensus.rs:1076-1090`)
- `Tower::is_valid_switching_proof_vote` (`consensus.rs:858-925`)
- `FileTowerStorage::store` (`consensus/tower_storage.rs:205-220`)
- `voting_service::handle_vote` (`voting_service.rs:107-165`)
- `reconcile_blockstore_roots_with_external_source` (`consensus.rs:1753-1807`)

**Suggested modeling approach**:
- Variables: split `Tower` into **persistent state** (`persisted_tower[v]`: votes, root, last_vote, stray flag) and **volatile state** (`live_tower[v]`: same fields but in-RAM). Add `last_broadcast_vote[v]` and `cluster_observed_vote[v]` to capture in-flight votes.
- Actions: introduce explicit **`SaveTower(v)`**, **`BroadcastVote(v)`**, **`Crash(v)`**, **`Restart(v)`**, and **`AdjustLockoutsAfterReplay(v)`** actions. `Crash` discards `live_tower`; `Restart` loads `persisted_tower` and may invoke the empty-ancestors / stray short-circuit.
- Granularity: split the current `record_bank_vote → push_vote → voting_sender.send → tower_storage.store → send_vote_transaction` chain into **separate sub-actions** with crash points between each. Verify safety against any reachable crash sequence.

**Priority**: HIGH.
**Rationale**: Three open Solana issues (#23135, #23137, #25598) directly describe the unaudited risk; the code itself contains TODOs admitting safety gaps ("freebie vote that may violate switching thresholds"); no fsync makes the persistence non-atomic in practice. TLA+ is well-suited to enumerate the crash/restore state space.

---

### Family B: Switch-threshold proof asymmetries (HIGH)

**Mechanism**: `make_check_switch_threshold_decision` accumulates `locked_out_stake` from two distinct iteration paths (frozen-bank lockout-intervals vs gossip latest-votes), each with slightly different filters and inequality directions. Combined with the empty-ancestors short-circuit from Family A, this creates conditions where a victim validator could be tricked into believing it has 38% switch proof when it doesn't, or could miss legitimate switch opportunities.

**Evidence**:
- Historical: `06b098e44` (stray-vote refactor — fixed over-permissive `is_candidate_slot_descendant_of_last_vote`), `1eaa5cf1a` (removed superfluous conditional), `7f3d3ebe3` (optimistic stake bypass extracted).
- Code analysis: `consensus.rs:881-898` (empty-ancestors case returns `Some(true)` without GCA check), `:1117-1216` (lockout-intervals branch calls `is_valid_switching_proof_vote(*candidate_slot)` but counts `lockout_interval_start` — different slot), `:1198, 1203` (`!last_vote_ancestors.contains(start) && start > root` as the only filter on `lockout_interval_start`), `:1218-1268` (gossip branch uses `> last_voted_slot`, asymmetric with lockout-intervals branch using `>=`), `:1167` (`assert!(!last_vote_ancestors.contains(candidate_slot))` — runtime invariant), `:1058-1073` (duplicate-rollback "freebie vote" — TODO admits switching threshold may be violated).

**Affected code paths**:
- `Tower::make_check_switch_threshold_decision` (`consensus.rs:959-1273`) — both iteration branches
- `Tower::is_valid_switching_proof_vote` + `greatest_common_ancestor` (`consensus.rs:858-957`)
- `Tower::check_switch_threshold` (`consensus.rs:1276-1303`)

**Suggested modeling approach**:
- Variables: track a per-validator `lockout_intervals[v]` set of `(start_slot, end_slot, voter)` plus a per-validator `latest_frozen_vote[v]: (slot, hash)`. The switch-proof set must be computed from BOTH.
- Actions: model `CheckSwitchThreshold(v, switch_slot)` that returns a `SwitchForkDecision`. **Crucially, split into two parallel sub-actions** that match the two iteration branches of the implementation; assert they produce equivalent decisions (or characterize the asymmetry).
- Invariants: `SwitchProofIsSufficient` — if `Tower` returns `SwitchProof(_)` then `locked_out_stake > 0.38 * total_stake` actually holds against the modeled honest-validator votes. `FreebieVoteIsBounded` — characterize the exact preconditions under which `consensus.rs:1066-1072` fires, and verify the resulting cluster state is recoverable.
- Granularity: model `SWITCH_FORK_THRESHOLD` as a constant ≤ 1/3 (Byzantine bound) so the spec parameterizes over thresholds.

**Priority**: HIGH.
**Rationale**: The two-branch asymmetry, combined with Family A's empty-ancestors shortcut, is exactly the class of subtle safety bug TLA+ excels at. The "freebie vote" is an acknowledged-known relaxation that has never been formally bounded.

---

### Family C: Tower adoption and non-atomic state updates (MEDIUM-HIGH)

**Mechanism**: `Tower` has three coupled pieces of state (`vote_state`, `last_vote`, `ForkStats.is_locked_out` cache) that must update atomically. Historical bugs `85cc6ace0` (cache not refreshed) and `329c6f131` (`last_vote` not rebuilt) were caused by missing co-update; both fixes are in current code, but the underlying non-atomic mutation pattern remains, and Byzantine peers / hot-spare scenarios could expose related races.

**Evidence**:
- Historical: `85cc6ace0` (CRITICAL: cache freshness after adoption), `329c6f131` (CRITICAL: `last_vote` rebuild after adoption), `97efbdc30` (defer tower save until push_vote), `1444baa42` (`return`→`continue` in dup-confirm batch), `fb97e93fe` (missing duplicate-confirm rollup), `befe8b9d9`+`07955e79a` (set-identity tower reload), open issues **#32880, #35152**.
- Code analysis: `replay_stage.rs:4400` (`tower.vote_state = bank_vote_state` wholesale replacement), `:4448-4457` (`cache_tower_stats` refresh loop — the fix), `consensus.rs:686-698` (`update_last_vote_from_vote_state` — the fix), `:696` (timestamp uses OLD `last_voted_slot`), `:706-714` (panic on `vote_too_old`), `:720-721` (sequential mutation of `vote_state` then `last_vote`), `replay_stage.rs:2900-2988` (handle_votable_bank multi-step), `:3296-3311` (push_vote channel send), `voting_service.rs:114-119` (save then broadcast, `exit(1)` on store error), `tower1_14_11.rs:22-39` (**`#[serde(skip)]`** on `stray_restored_slot`, `last_vote_tx_blockhash`, `last_switch_threshold_check`).

**Affected code paths**:
- `ReplayStage::adopt_on_chain_tower_if_behind` (`replay_stage.rs:4338-4458`)
- `ReplayStage::compute_bank_stats` (`replay_stage.rs:4205-4328`)
- `ReplayStage::handle_votable_bank` / `push_vote` (`replay_stage.rs:2870-3315`)
- `Tower::record_bank_vote_and_update_lockouts` + `update_last_vote_from_vote_state` (`consensus.rs:673-735`)

**Suggested modeling approach**:
- Variables: `vote_state[v]`, `last_vote[v]`, `fork_stats_cache[v][slot]` modeled separately. Add **adoption action** `AdoptOnChainVoteState(v, bank)` that updates `vote_state`, then forces the cache refresh.
- Invariants: `TowerCoherent(v) == vote_state[v].last_voted_slot() = last_vote[v].last_voted_slot()` — should hold at every reachable state outside the action's atomic body.
- Granularity: split adoption into THREE sub-steps (`vote_state ← bank`, `last_vote ← rebuild_from_vote_state`, `cache ← refresh_all_frozen_banks`); allow non-determinism between steps and verify invariants are not violated by intermediate observations.

**Priority**: MEDIUM-HIGH.
**Rationale**: Two of the top-10 historical CRITICAL fixes are in this family. The non-atomic pattern is unchanged; only the specific co-update sites are patched. TLA+ should verify the invariant `TowerCoherent` is preserved across all current call sites AND under adversarial schedulers (hot-spare race).

---

### Family D: Optimistic-confirmation hash-drop on notification path (MEDIUM-HIGH)

**Mechanism**: OC stake accumulation in `track_optimistic_confirmation_vote` is correctly keyed on `(slot, hash)` via per-hash `VoteStakeTracker`. But the downstream `BankNotification::OptimisticallyConfirmed(slot)` carries ONLY the slot. RPC consumers index `bank_forks` by slot and promote whichever locally-replayed variant is present — even if the cluster's 0.52 stake voted for a different hash on a duplicate slot.

**Evidence**:
- Historical: Open issue **#12307 (anza-xyz/agave)** explicitly describes this gap; `3e6f0e9f9` (`return`→`break` in OC loop — superficially related but doesn't fix the hash-drop).
- Code analysis: `cluster_info_vote_listener.rs:744` (notification send drops hash), `rpc/src/optimistically_confirmed_bank_tracker.rs:46` (enum has no hash field), `:297-322` (handler uses `bank_forks.get(slot)`); contrast with `cluster_info_vote_listener.rs:727` (`duplicate_confirmed_slot_sender.send(vec![(last_vote_slot, last_vote_hash)])` — preserves hash).

**Affected code paths**:
- `ClusterInfoVoteListener::track_new_votes_and_notify_confirmations` (`cluster_info_vote_listener.rs:744-748`)
- `OptimisticallyConfirmedBankTracker::process_notification` (`rpc/src/optimistically_confirmed_bank_tracker.rs:297-322`)

**Suggested modeling approach**:
- Variables: `oc_threshold_reached[slot][hash]: BOOLEAN`, `rpc_oc_view[v]: (slot, hash)` (per-validator RPC's report).
- Actions: model `AccumulateOCVote(v, slot, hash)`, `NotifyOC(slot)` (hash dropped), `RpcResolveOC(slot)` (selects local hash).
- Invariants: `RpcOCImpliesClusterOC` — if `rpc_oc_view[v] = (slot, hash)` then `oc_threshold_reached[slot][hash]` holds in the cluster (this is what currently fails).

**Priority**: MEDIUM-HIGH.
**Rationale**: Issue #12307 is open in agave (May 2026 ticket per archaeology). This is a concrete, well-scoped finding suited to a small TLA+ extension.

---

### Family E: Per-hash stake counting enables Byzantine OC double-counting (HIGH)

**Mechanism**: `VoteStakeTracker` deduplicates voters within a single `(slot, hash)` bucket. A Byzantine validator that gossips two votes for the same slot with different hashes contributes its stake to BOTH per-hash buckets. Combined with the slot-only `latest_vote_slot_per_validator` filter (uses `>=` not `>`), the gossip ingest path does not reject same-slot equivocation.

**Evidence**:
- Code analysis: `consensus/vote_stake_tracker.rs:14-38` (`add_vote_pubkey` per-tracker), `cluster_info_vote_listener.rs:91` (`HashMap<Hash, VoteStakeTracker>` — separate counter per hash), `:807-810` (`filter(|slot| ... **slot >= *latest_vote_slot)` — `>=` is permissive), `consensus/latest_validator_votes_for_frozen_banks.rs:51-68` (multiple hashes APPENDED per validator per slot — intentional, fix `985c0dcdd`), `replay_stage.rs:2508-2515` (`assert_eq!(prev_hash, ...)` panic when both hashes reach DC — detection, not prevention; **DoS vector**).
- The algebraic identity `0.38 + 0.52 + 0.1 = 1.0` ensures that with ≤ 33% Byzantine stake, two conflicting `(slot, hash_A)` and `(slot, hash_B)` cannot BOTH reach 0.52 honestly. But the per-hash counter doesn't enforce this — it relies on the Byzantine bound holding cluster-wide.

**Affected code paths**:
- `VoteStakeTracker::add_vote_pubkey` (`consensus/vote_stake_tracker.rs:14-38`)
- `ClusterInfoVoteListener::track_optimistic_confirmation_vote` (`cluster_info_vote_listener.rs:940-955`)
- `LatestValidatorVotesForFrozenBanks::check_add_vote` (`consensus/latest_validator_votes_for_frozen_banks.rs:51-95`)

**Suggested modeling approach**:
- Variables: `gossip_votes[v]: SUBSET (slot, hash)` per validator (Byzantine can equivocate by adding two entries for same slot), `oc_stake[slot][hash]: stake`.
- Actions: `ByzantineEquivocate(v, slot, hash_a, hash_b)` allowed for v ∈ `Faulty`. `AccumulateOCVote(slot, hash)` sums stake correctly per-bucket.
- Invariants: `NoTwoOCConfirmations` — at most one `(slot, hash)` reaches `oc_stake ≥ 0.52`, given Byzantine stake ≤ 1/3. (This should HOLD when properly modeled; failure indicates a bug in the algebraic identity or in the per-validator deduplication.)

**Priority**: HIGH.
**Rationale**: Composes with Families A, D, G. Byzantine equivocation is a Layer-2 BFT action (per `bft-analysis.md` §1.2.1) that this protocol's threshold accounting must withstand.

---

### Family F: OC violation detection (under-detects rooted-but-different-hash) (MEDIUM)

**Mechanism**: `OptimisticConfirmationVerifier::verify_for_unrooted_optimistic_slots` only compares hash when `optimistic_slot == root`. For ancestor slots that ARE in `root_ancestors` but with a DIFFERENT hash than the OC'd version, no violation is logged.

**Evidence**:
- Code analysis: `optimistic_confirmation_verifier.rs:42-53` (the detection predicate is slot-only for ancestors).
- Detection is LOG-ONLY; open issues **#7521** (slashing v0 not deployed), **#8113** (no fail-stop), **#6962** (single-implementation security) all acknowledge protocol does not enforce.

**Suggested modeling approach**: cover within Families D + E; the under-detection itself is not a separate spec extension, but the spec should assert that any reachable OC-then-rollback is flagged by SOME detection path. If under-detection is real, the invariant `OCRollbackIsDetected` will fail.

**Priority**: MEDIUM.

---

### Family G: Duplicate-confirmed assertion panics as DoS surface (LOW for TLA+)

**Mechanism**: `assert_eq!(prev_hash, duplicate_confirmed_hash, ...)` (`replay_stage.rs:2508, 4681`) panics if the duplicate-confirmed path observes contradictory hashes for the same slot. Combined with Family E's per-hash equivocation enablement, a Byzantine subset can cause victim validators to PANIC.

**Priority**: LOW for TLA+ modeling (DoS, not safety violation). Better verified by integration tests / fuzz harness.

---

### Family H: Set-identity hot-swap (LOW for new TLA+ work; historically critical)

**Mechanism**: Identity rotation at runtime requires reloading the tower. Multiple historical CRITICAL fixes (`befe8b9d9`, `07955e79a`) plus open issue **#8752** show this is a fragile interaction.

**Priority**: LOW (historical fixes in place; the residual operational issues are about race scheduling rather than protocol logic). The TLA+ model would need to encode admin-RPC operations alongside the consensus protocol, which is a significant spec-scope expansion for limited additional safety reach.

---

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Persistent vs volatile tower state | Family A: ~6 critical fixes + 3 open issues center on the persistence boundary | `persisted_tower[v]` (votes, root, last_vote) vs `live_tower[v]`; add `Crash(v)` and `Restart(v)` actions |
| Tower save / vote-broadcast as separate actions with crash window | Family A: `voting_service.rs:114-149` save-before-broadcast plus no fsync (`tower_storage.rs:213-218`) | Split `handle_votable_bank` into 5 sub-actions: `RecordBankVote`, `MaybeCheckNewRoot`, `EnqueueVoteOp`, `StoreTower`, `BroadcastVoteTx`; allow Crash between any pair |
| Stray-last-vote with empty-ancestors switch-proof short-circuit | Family A+B: open issue #23135 directly describes the unaudited safety hole | `stray[v]: BOOLEAN` per validator; `Tower::is_valid_switching_proof_vote` modeled with empty-ancestors as a dedicated guarded action |
| Two-branch switch-threshold accumulation (lockout-intervals vs gossip) | Family B: history of fixes in this asymmetric design | Two parallel `MakeCheckSwitchThresholdDecision_LockoutIntervals` and `_Gossip` actions; assert equivalence (or characterize divergence) |
| "Freebie vote" on duplicate rollback | Family A+B: TODO at `consensus.rs:1066` admits switching threshold may be violated | Dedicated action `SwitchVoteAfterDuplicateRollback(v, switch_slot)` with no threshold check; verify cluster recoverability |
| Per-hash OC stake accumulation | Family D+E: open #12307 + per-hash counter (issue #12307) | `oc_stake[slot][hash]`; `BankNotification::OptimisticallyConfirmed` modeled as slot-only message |
| Byzantine equivocation: same-slot, different-hash vote | Family E: per-hash counter doesn't dedup validator across buckets | `ByzantineEquivocate(v ∈ Faulty, slot, hash_a, hash_b)` action injects two votes |
| Tower adoption (`adopt_on_chain_tower_if_behind`) | Family C: two top-10 CRITICAL fixes are this exact code path | `AdoptOnChainVoteState(v, bank)` action; split into three sub-actions; verify `TowerCoherent` invariant |
| Lockout-violation injection by Byzantine vote | BFT § 5.1: standard Byzantine action; tests Tower BFT's per-validator lockout enforcement on the recipient side | `ByzantineVoteWithinLockout(v ∈ Faulty, slot)` violates the validator's own lockout; verify cluster correctly detects/rejects |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| PoH (Proof of History) clock skew, signature schemes, sysvar / fee calculation, snapshot serialization | Out of scope per brief; treat slots as opaque ordered integers, signatures as unforgeable from honest validators |
| Banking-stage transaction execution / SVM / accounts-db | Not part of Tower BFT |
| Votor / Alpenglow new protocol (`votor/src/*`, `consensus_pool*`) | Explicitly out of scope — Solana is migrating but Tower BFT remains production-active |
| Heaviest-subtree-fork-choice's internal tree operations | Treat as a function `select_heaviest(stakes, votes) → bank`; bugs like u64 overflow in fork_weight (`6a9f72910`) are unit-test territory |
| Set-identity hot-swap administrative flows | Family H: historical fixes in place; modeling adds admin-RPC scope for marginal safety gain |
| Floating-point precision in threshold check (`(total_stake as f64 * 0.52) as u64`) | Better caught by property-test on integer arithmetic; modeling f64 is impractical |
| Memory-leak TODO in `latest_validator_votes_for_frozen_banks` | Not safety-critical |
| Detection-only OC verifier under-detection (Family F) | Subsumed by Families D+E modeling; verifier itself is observability, not protocol |
| Selfish-mining (#7087) | Strategy-space exploration is better-suited to economic analysis than TLA+; well-understood theoretically |
| `panic!`/`unwrap` audit (Family G) | DoS surface, not safety; integration tests / fuzzing fits better |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Persistent vs volatile tower | `persisted_tower[v]`, `live_tower[v]`, `crashed[v]: BOOLEAN` | Model crash recovery | A, C |
| Stray-vote flag | `stray[v]: BOOLEAN`, `stray_restored_slot[v]: Slot` | Track post-restart state | A, B |
| Last broadcast vs cluster-observed | `last_broadcast_vote[v]: VoteTx`, `cluster_observed_votes: SUBSET VoteTx` | Capture phantom-vote window | A, C |
| Switch-threshold accumulators | `lockout_intervals[v]`, `latest_frozen_vote[v]: (Slot, Hash)` | Model both switch-proof branches | B |
| Per-hash OC stake | `oc_stake[Slot][Hash]: Stake`, `oc_voters[Slot][Hash]: SUBSET Validator` | Capture per-hash counting + equivocation | D, E |
| RPC OC view | `rpc_oc_view[v]: Slot ↦ Hash` | Capture hash-drop notification gap | D |
| Byzantine action set | `equivocated_votes: SUBSET (Slot, Hash, Validator)` | Enable BFT adversary | B, E |
| Validator role / liveness | `online[v]: BOOLEAN`, `replayed_slot[v]: Slot` | Sequence crash-and-resume | A |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| LockoutSafety | Safety | If validator `v` cast a vote on slot `s` with lockout `L`, then `v` does not cast a conflicting vote (on a non-descendant slot) within `[s, s+L]` — including after crash/restart | A, B |
| NoConflictingOC | Safety | At most one `(slot, hash)` pair reaches `oc_stake ≥ 0.52` given Byzantine stake ≤ 1/3 | D, E |
| TowerCoherent | Safety | `vote_state[v].last_voted_slot() = last_vote[v].last_voted_slot()` at every state outside an atomic adoption block | C |
| SwitchProofSufficient | Safety | If `Tower::check_switch_threshold` returns `SwitchProof(_)`, then the actual stake of locked-out validators on alternate forks exceeds `SWITCH_FORK_THRESHOLD * total_stake` (over the modeled fact base, not the implementation's filter) | B |
| StrayShortCircuitIsSound | Safety | The empty-ancestors `Some(true)` short-circuit in `is_valid_switching_proof_vote` does not admit candidate slots on the SAME fork as the stray last vote | A, B |
| FreebieVoteIsBounded | Safety | The duplicate-rollback `SwitchProof(Hash::default())` path cannot cause two non-rolled-back slots to conflict | A, B |
| PhantomVoteNotPersisted | Safety | After `Crash(v)` between `StoreTower` and `BroadcastVoteTx`, the cluster's observed-vote set does NOT include the just-stored vote (relies on the protocol-level handling, not fsync) | A |
| RpcOCImpliesClusterOC | Observability | If `rpc_oc_view[v] = (slot, hash)`, then `oc_stake[slot][hash] ≥ 0.52` | D |
| OCRollbackIsDetected | Liveness/observability | Any reachable state where an OC-confirmed `(slot, hash)` is rolled back is observable via `OptimisticConfirmationVerifier` | D, F |
| EquivocationDoesNotInflateOC | Safety | A Byzantine validator that equivocates contributes its stake to AT MOST one OC bucket per slot (this should HOLD given the algebraic 0.38+0.52+0.1=1.0 — the spec verifies it) | E |
| LockoutEnforcedOnReceive | Safety | If a Byzantine validator's vote violates its OWN lockout, no honest validator counts that vote toward its switch proof or OC stake | B, E |
| TowerRestoreDeterministic | Safety | `adjust_lockouts_after_replay` is deterministic given (persisted_tower, slot_history); two crash-restart cycles producing same input yield same output | A |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-A1 | Validator crashes between `BroadcastVoteTx` and `StoreTower`: cluster observes vote V on slot S; persisted tower lacks V. After restart, validator's tower no longer covers V. Can validator now cast a conflicting vote on a non-descendant slot ≤ S+lockout(V)? | LockoutSafety, PhantomVoteNotPersisted | A |
| MC-A2 | Validator restarts with a `last_voted_slot` not in current ancestors (stray case). The empty-ancestors branch of `is_valid_switching_proof_vote` allows ANY candidate slot in switch proof. Can a Byzantine vote-distribution craft a switch proof that wouldn't qualify under non-stray semantics? | StrayShortCircuitIsSound, LockoutSafety | A, B |
| MC-A3 | `FailedSwitchDuplicateRollback` returns `SwitchProof(Hash::default())` with no threshold check. Can a Byzantine subset purge a victim's last vote as "duplicate", then have the victim freebie-switch to a conflicting fork? | FreebieVoteIsBounded | A, B |
| MC-B1 | Lockout-intervals branch counts `lockout_interval_start` after filtering by `is_valid_switching_proof_vote(*candidate_slot)`. Construct fork geometry where `candidate_slot` passes but `lockout_interval_start` shouldn't, and check whether resulting switch proof exceeds 38% when it shouldn't | SwitchProofSufficient | B |
| MC-B2 | Lockout-intervals vs gossip-votes asymmetry (`>=` vs `>`): given a validator with `latest_frozen_vote.slot == last_voted_slot`, is the same validator counted in one branch but not the other? Verify this doesn't cause a 38% miscount | SwitchProofSufficient | B |
| MC-C1 | During `AdoptOnChainVoteState`, three internal mutations happen sequentially (`vote_state`, `last_vote`, cache). Can a scheduler that interleaves another `select_vote_and_reset_forks` between any pair admit a stale-cache vote (the Family C residual)? | TowerCoherent, LockoutSafety | C |
| MC-D1 | Byzantine validator gossips two votes for slot S with hashes A and B. Both bucket-stakes accumulate the Byzantine stake. With ≤ 1/3 Byzantine + an honest ~52% split, can BOTH `(S, A)` and `(S, B)` reach OC? | NoConflictingOC, EquivocationDoesNotInflateOC | D, E |
| MC-D2 | OC fires for `(S, B)` (the cluster-confirmed hash), but local validator replayed `(S, A)`. RPC `bank_forks.get(S)` returns local `(S, A)`. What is the consequence for downstream consumers? Confirm `RpcOCImpliesClusterOC` is violated in this state | RpcOCImpliesClusterOC | D |
| MC-E1 | A Byzantine validator broadcasts a vote that violates its OWN lockout (slashable). An honest validator running `make_check_switch_threshold_decision` receives this vote via gossip. Does the honest validator's switch-proof accounting reject this vote, or does it credit the Byzantine validator's stake? | LockoutEnforcedOnReceive | B, E |
| MC-F1 | A slot S is OC'd as `(S, A)` then rolled back when root advances to a fork containing `(S, B)`. Does `OptimisticConfirmationVerifier::verify_for_unrooted_optimistic_slots` detect this, given that `root_ancestors` may contain S (with hash B) but not the OC'd hash? | OCRollbackIsDetected | D, F |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| T-1 | Concurrent `FileTowerStorage::store` calls — convention says single-threaded but trait allows it | Rust test with two threads racing on `store`; verify final file integrity |
| T-2 | f64 precision in `VoteStakeTracker::add_vote_pubkey` threshold-crossing at mainnet stake totals (~2^58) | Property-based test: feed integer stakes near boundaries, compare integer `(total * pct / 100)` vs `(total as f64 * pct/100.0) as u64` |
| T-3 | `adopt_on_chain_tower_if_behind` after set-identity race | Integration test simulating set-identity admin RPC during compute_bank_stats |
| T-4 | `replay_vote_buffer` duplicate `Executed` handling silent-drop in release mode (`debug_assert!(false)`) | Test that drops duplicate ReplayVoteAction::Executed in release build and observes no propagation |
| T-5 | Memory leak: `latest_validator_votes_for_frozen_banks` never cleans unstaked pubkeys (TODO line 11) | Long-running soak test counting hash-map size growth |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | TODO at `consensus.rs:1038-1040`: "Handle if the last vote is on a dupe, and then we restart" | Discuss with maintainers; possibly add an explicit error path |
| CR-2 | TODO at `consensus.rs:1066`: "freebie vote may violate switching thresholds" | After MC-A3 yields, propose a tighter switch-proof requirement OR a documented bound |
| CR-3 | TODO at `consensus.rs:549`: "populate_ancestor_voted_stakes only adds zeros" | Document the rationale or remove the TODO if intent is settled |
| CR-4 | `NullTowerStorage` is the default in `ValidatorConfig::default()` | Either remove from default config or add a `must_not_be_null_in_production` check at validator startup |
| CR-5 | `set-identity` reload only triggered inside fork-reset branch (`replay_stage.rs:1386-1414`) | Hoist the check to fire every iteration |
| CR-6 | Issue **#12307** (OC notification drops hash) | Thread the hash through `BankNotification::OptimisticallyConfirmed` |
| CR-7 | Issue **#23135** (stray-vote switching violation) | Discuss the empty-ancestors short-circuit semantics after MC-A2 yields evidence |
| CR-8 | `assert_eq!` panic on conflicting duplicate-confirmed hashes (`replay_stage.rs:2508, 4681`) | Replace with `error!` + skip (don't crash the validator on observed Byzantine equivocation) |

## 7. Reference Pointers

- **Full analysis report**: `./analysis-report.md` (this directory)
- **Key source files**:
  - `core/src/consensus.rs` (Tower struct, switch threshold, lockouts — 3932 LOC)
  - `core/src/consensus/tower_storage.rs` (persistence — 277 LOC)
  - `core/src/consensus/tower_vote_state.rs` (lockout stack — 345 LOC)
  - `core/src/consensus/fork_choice.rs` (`select_vote_and_reset_forks` — 491 LOC)
  - `core/src/replay_stage.rs` (main consensus loop — 11757 LOC; focus 2870-3315 for vote flow, 4338-4458 for tower adoption)
  - `core/src/voting_service.rs` (tower save + vote broadcast — 170 LOC)
  - `core/src/cluster_info_vote_listener.rs` (gossip OC ingest — 2221 LOC; focus 491-955)
  - `core/src/optimistic_confirmation_verifier.rs` (OC violation detection — 330 LOC)
- **GitHub issues (open as of mining date, May 2026)**:
  - **#23135** — Stray votes after restart → switching violation
  - **#23137** — Snapshot >512 slots ahead crashes (SlotHashes ring)
  - **#25598** — Tower should use AccountsDB longer slot history
  - **#12307** (agave) — OC notification drops voted hash
  - **#8752** (agave) — Gossip duplicate-instance double-panic
  - **#7521** — Slashing v0 not deployed
  - **#8113** — No consensus failsafe
  - **#6962** — Single-implementation security
  - **#8232** — Leaders build on own fork after partition
  - **#5850** — Tower threshold checks one bank only
- **Production incidents to cite as motivation**:
  - 2021-09 Mainnet outage (tx flood + fork divergence)
  - 2023-11-03 latency event → PR #34120 added shallow threshold check
  - 2023-03 testnet roots-stall → PR #31954 fixed gossip vote drop
  - 2023-08 v1.14↔master MNB consensus divergence (vote-credit off-by-one)
- **Reference algorithm**: Yakovenko 2018 (Solana whitepaper, Tower BFT description); `solana-foundation/specs` for the formal threshold definitions.
- **Constants reference**: `consensus.rs:156-158`, `replay_stage.rs:125-128`, `solana_runtime::commitment::VOTE_THRESHOLD_SIZE`.
- **Caveat — category placement**: classified as Category A (distributed, BFT). `bft-analysis.md` Layer-2 vocabulary applies: §2.1 equivocation (Family E), §2.5 replay / stale-context misuse (Family D), §2.6 amnesia (Family A — stray-vote on restart). Distributed-analysis.md §5.1 (crash and recovery) is the canonical headline this brief focuses on.
