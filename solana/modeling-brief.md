# Modeling Brief: Solana Tower BFT (anza-xyz/agave)

## 1. System Overview

- **System**: `anza-xyz/agave` — Solana's active validator client (forked from `solana-labs/solana`).
- **Language**: Rust. Core Tower-BFT logic ≈ 22 K LOC across 11 files under `core/src/consensus/` and `core/src/{replay_stage, voting_service, cluster_info_vote_listener, optimistic_confirmation_verifier, commitment_service}.rs`.
- **System category**: **Category A (Distributed / Message-Passing)** with a **Byzantine threat model**. Sub-category: **vote-lockout BFT** (PoH-ordered slots + per-validator persistent tower). Both `distributed-analysis.md` and `bft-analysis.md` apply.
- **Protocol**: Tower BFT — safety = per-vote exponentially-growing lockout (1 → 2 → 4 → … → 2³² slots) + per-fork-switch 38% switch-threshold + 2/3 stake-weighted optimistic confirmation. No traditional quorum certificates; finality is achieved by **rooting** (32-deep lockout chain).
- **Architectural choices that deviate from standard BFT**:
  - **No on-chain slashing yet** (issues #7521, #8113 OPEN multi-year). Tower safety relies on rational-Byzantine + persistent-tower assumptions.
  - **Persistent tower file** is the per-validator durable safety state (`core/src/consensus/tower_storage.rs`); explicitly written **without `fsync`** for performance.
  - **Adopt-on-chain-tower fallback** (`adopt_on_chain_tower_if_behind`, `core/src/replay_stage.rs:4046`) replaces local tower with bank-derived vote state if on-chain is "ahead" of local — without per-vote provenance audit.
  - **Switch-threshold counts both replayed AND gossip-observed latest votes** (`core/src/consensus.rs:1218-1268`).
  - **PoH oracle** for slot ordering — TLA+ models slots as opaque ordered integers.
- **Concurrency model**: Main ReplayStage event loop on a single thread; voting service on its own thread; vote listener (gossip + replay) on another; commitment / OC / latest-frozen-votes services share state via Arc<RwLock>. Multiple persistence boundaries: tower file (FileTowerStorage), blockstore (RocksDB), accountsdb. Inter-thread channels: `voting_sender` (replay → voting service), `verified_vote_transactions_sender` (gossip-deserializer → tracker).

The Anza fork is mid-migration to **Alpenglow / Votor**, with both code paths reachable under `MigrationStatus`. **Modeling target is Tower BFT** (the production path); Votor and the migration phase machine are noted but excluded.

## 2. Bug Families

### Family 1: Tower Adoption & Crash-Recovery Hazards (HIGH)

**Mechanism**: When the local tower is lost, stale, or behind the on-chain vote-state of the validator's own vote account, the code replaces tower contents with bank-derived state without per-vote provenance verification. Crash recovery is non-atomic and depends on a fsync-skipping tower file.

**Evidence**:
- Code analysis: `core/src/replay_stage.rs:4046-4166` — `adopt_on_chain_tower_if_behind` overwrites `tower.vote_state` from `bank.get_vote_account(my_vote_pubkey)` whenever bank's last-voted-slot exceeds local. Chain of trust transitively assumes runtime is bug-free.
- Code analysis: `core/src/consensus/tower_storage.rs:165-220` — explicit `// file.sync_all() hurts performance` comment, no parent-dir fsync. Voting service stores → broadcasts; crash window admits "tower lost from page cache, vote already on the wire".
- Code analysis: `core/src/consensus.rs:1652-1670` — `initialize_lockouts_from_bank` at the `Tower::new`/`new_from_bankforks` fallback path uses the *heaviest* bank's view of our vote account.
- Code analysis: `core/src/consensus.rs:881-897, 975-1090` — `empty_ancestors_due_to_minor_unsynced_ledger`: when stray last-vote ancestors are unknown, `is_valid_switching_proof_vote` returns `true` for almost every candidate → switch-proof stake inflated.
- Code analysis: `core/src/consensus.rs:1504-1535` — future-tower suspension via `FailedSwitchThreshold(0, total_stake)` covers cross-fork voting only, not same-fork-from-future-tower.
- Code analysis: `core/src/replay_stage.rs:3112-3158` + `core/src/voting_service.rs:107-165` — record-then-store-then-broadcast is 3-step and non-atomic.
- Historical: solana-labs/solana **#23135** (OPEN ~3.25 years) — "Stray votes after restarting from lost tower will cause switching violation" — same mechanism, acknowledged unmitigated.
- Historical: solana-labs/solana **#23137** + **#25598** — tower beyond 512-slot `SlotHashes` window is unreconstructable.
- Historical: solana-labs/solana **#20192** (closed stale) — "Use burner tx to safely initialize tower on restart" proposal.
- Historical: commits `85cc6ace0` (`#33341`), `000ca4ce0` (`#1632`) — repeated bug-fixes in tower-adoption cache-refresh path.

**Affected code paths**:
- `Tower::adjust_lockouts_after_replay` (`consensus.rs:1462`), `adjust_lockouts_with_slot_history` (`consensus.rs:1546`).
- `Tower::initialize_lockouts_from_bank` (`consensus.rs:1652`).
- `Tower::make_check_switch_threshold_decision` empty-ancestors branch (`consensus.rs:975-1090`).
- `ReplayStage::adopt_on_chain_tower_if_behind` (`replay_stage.rs:4046`).
- `ReplayStage::load_tower` (`replay_stage.rs:1587`), `compute_bank_stats` (`replay_stage.rs:3898`).
- `FileTowerStorage::store` (`tower_storage.rs:205`).
- `VotingService::handle_vote` (`voting_service.rs:107`).

**Suggested modeling approach**:
- **Variables**:
  - `tower[v] = ⟨votes : Seq[Lockout], root : Slot, last_vote_slot : Slot, stray_restored_slot : Slot ∪ {⊥}⟩` — in-memory tower per validator
  - `persistedTower[v] = ⟨votes, root, …⟩` — on-disk tower (separate variable)
  - `pendingTower[v]` — set of (tower, vote_tx) pending broadcast (in-flight on the voting-service channel)
  - `onChainVoteState[v][bankSlot]` — the on-chain stored vote state visible from each replayed bank
- **Actions**:
  - `RecordVote(v, slot)` — atomic in-memory tower update.
  - `EnqueueVoteForBroadcast(v, savedTower, voteTx)` — channel send.
  - `PersistTower(v, savedTower)` — write to disk (NO fsync).
  - `BroadcastVote(v, voteTx)` — send to network.
  - `Crash(v)` — lose in-memory tower AND `pendingTower[v]`; pending non-fsync'd write may also be lost (model as nondeterministic).
  - `Restart(v)` — load `persistedTower[v]`; if absent or rejected by `adjust_lockouts_after_replay`, call `LoadTowerFromHeaviestBank(v)`.
  - `AdoptOnChainTowerIfBehind(v, bankSlot)` — when `onChainVoteState[v][bankSlot].last_voted_slot > tower[v].last_voted_slot`, overwrite.
  - `EmptyAncestorsStrayPath` — explicit modeling of the `empty_ancestors_due_to_minor_unsynced_ledger` switch-proof path.
- **Granularity**: split tower-update into 4 atomic sub-actions (`RecordVote`, `Enqueue`, `Persist`, `Broadcast`); allow `Crash` between any pair. Allow Byzantine-built `onChainVoteState` to influence `AdoptOnChainTowerIfBehind`. See `case-studies/aptosbft/spec/MC.tla` `MCCrashBetweenSignAndPersist` for the pattern.

**Priority**: High
**Rationale**: This is the canonical BFT-amnesia × distributed-crash composition (2.6 × 5.1 × 5.4). It is the primary safety surface unique to Tower BFT (no quorum-cert protocols have a "adopt vote state from bank" mechanism). Multiple unfixed multi-year issues confirm the mechanism is bug-prone and the design is acknowledged-but-not-fully-fixed.

---

### Family 2: Switch-Threshold Manipulability via Gossip-Originated Latest Votes (HIGH)

**Mechanism**: The switch-threshold check sums stake from on-chain `lockout_intervals` AND `gossip-observed latest_validator_votes`. Gossip-source votes are signature-verified but NOT cross-verified against on-chain truth, and the gossip-vote map is never pruned across roots. A Byzantine validator (or coalition) can gossip fake latest-vote claims to inflate switch-threshold stake on a victim validator's local view.

**Evidence**:
- Code analysis: `core/src/consensus.rs:1218-1268` — `make_check_switch_threshold_decision` consumes `latest_validator_votes_for_frozen_banks.max_gossip_frozen_votes()` directly; the only filter is the structural `is_valid_switching_proof_vote` (graph-shape check, line 863-925).
- Code analysis: `core/src/consensus/latest_validator_votes_for_frozen_banks.rs:9-17, 22-95` — explicit TODO on lack of pruning; `check_add_vote` with `is_replay_vote=false` admits gossip-only votes.
- Code analysis: `core/src/consensus/fork_choice.rs:113-123` — `recheck_fork_decision_failed_switch_threshold` falls back to unconditional `SameFork` when last vote can't land — Byzantine-engineerable via 512-slot vote-inclusion withholding.
- Code analysis: `core/src/consensus/heaviest_subtree_fork_choice.rs:363-379` vs `:636-639` — `set_tree_root` does not clean `latest_votes`; latent footgun.
- Historical: solana-labs/solana **#7087** (closed security-labeled with no PR) — "Fork choice rule can be tricked by a minority that overcommits to a fork". aeyakovenko: "we need to fix the original issue. A minority fork shouldn't accidentally create a heavier fork."
- Historical: solana-labs/solana **#8232** (OPEN ~5 years) — Leaders continue building on their own fork after partitioning — same fork-choice trust issue.

**Affected code paths**:
- `Tower::make_check_switch_threshold_decision` (`consensus.rs:959`) — specifically the gossip-frozen-votes loop at lines 1218-1268.
- `LatestValidatorVotesForFrozenBanks::check_add_vote` (`latest_validator_votes_for_frozen_banks.rs:29-83`).
- `select_candidates_failed_switch` (`fork_choice.rs:160`) — SameFork fallback.
- `HeaviestSubtreeForkChoice::set_tree_root` (`heaviest_subtree_fork_choice.rs:363`).

**Suggested modeling approach**:
- **Variables**:
  - `gossipFrozenVotes[v] = ⟨slot, hashes : Set[Hash]⟩` — per-(validator, slot) latest-vote claim from gossip
  - `onChainVotes[v][slot] = ⟨slot, hash, lockout⟩` — true on-chain votes (replayed)
- **Actions**:
  - Honest: `GossipVote(v, slot, hash)` requires `onChainVotes[v][slot] ≠ ⊥` and matching hash.
  - **Byzantine** (`v ∈ Faulty`):
    - `ByzGossipFakeLatestFrozenVote(v, slot, hash)` — gossip a vote for a frozen bank that v never voted for on-chain. No precondition tied to `onChainVotes[v]`. Maps to BFT 2.7 certificate-manipulation (value-binding gap) and 2.1 equivocation.
    - `ByzWithholdMyVoteInclusion(target, slot)` — withhold including target's vote in built blocks. Drives the 512-slot SameFork fallback.
- **Invariant**: `SwitchProofRequiresRealLockout` — `SwitchProof(s, v)` decision is reached only when `Σ stake[u] for u ∈ {u : ∃ real_lockout[u, slot'] ∈ onChainVotes, slot' ≥ last_voted_slot, slot' is on a fork incompatible with switch_slot} ≥ 0.38 · total_stake`.

**Priority**: High
**Rationale**: Direct BFT 2.7 (cert/quorum-proof manipulation) attack surface specific to Tower BFT — the switch-threshold is the equivalent of the quorum certificate in this protocol, and its construction trusts gossip-only inputs. Composes naturally with 5.2 (partition / message loss) and 2.1 (equivocation).

---

### Family 3: Optimistic Confirmation Equivocation Accounting (HIGH)

**Mechanism**: Optimistic Confirmation accumulates stake per `(slot, hash)` pair with **no cross-hash dedup at the listener layer**. A ≥1/3 Byzantine stake (or any equivocating subset whose votes split honest stake across both forks) can drive two distinct `(slot, hash_A)` and `(slot, hash_B)` to OC simultaneously. The verifier never explicitly flags dual-hash OC at the same slot — it only surfaces equivocations when the rooted chain later settles on a *third* hash, and the rooting check keys by `Slot`, silently dropping bad-hash entries that share a slot with a rooted slot.

**Evidence**:
- Code analysis: `core/src/consensus/vote_stake_tracker.rs:14-38` and `core/src/cluster_info_vote_listener.rs:940-955` — `add_vote_pubkey` dedups only within `(slot, hash)`; cross-hash dedup is absent by design.
- Code analysis: `core/src/optimistic_confirmation_verifier.rs:11-86` — `unchecked_slots: BTreeSet<(Slot, Hash)>` admits multiple per-slot entries; `add_new_optimistic_confirmed_slots` never asserts uniqueness.
- Code analysis: `core/src/optimistic_confirmation_verifier.rs:39-54` — `verify_for_unrooted_optimistic_slots` keys `root_ancestors` by `Slot`, not `(Slot, Hash)`. Slot S ∈ root_ancestors silently drops every `(S, H_bad)`.
- Code analysis: `core/src/replay_stage.rs:2019-2124` (`purge_unconfirmed_slot`) vs `core/src/cluster_info_vote_listener.rs:144-155` (`purge_stale_state`) — bank dump does not clean `VoteTracker` or `unchecked_slots`; cleanup is gated only on root advancement.
- Code analysis: `core/src/cluster_info_vote_listener.rs:773-791` — OC stake accumulates only on `last_voted_slot_hash` of each vote-tx; intermediate tower slots are ignored.
- Historical: solana-labs/solana **#33669**, **#34102** — flaky `test_optimistic_confirmation_violation_with_tower` / `_without_tower` tests confirm the safety boundary is sensitive.
- Historical: commit `84a934a9f` (2024-10-23) added `BankHashCache`; commit `207fb1d00` (2026-02-19, #10594) REMOVED it. Confirms the OC accumulation pathway is actively evolving.

**Affected code paths**:
- `VoteStakeTracker::add_vote_pubkey` (`vote_stake_tracker.rs:14-38`).
- `ClusterInfoVoteListener::track_optimistic_confirmation_vote` (`cluster_info_vote_listener.rs:940-955`).
- `OptimisticConfirmationVerifier::add_new_optimistic_confirmed_slots` (`optimistic_confirmation_verifier.rs:57-86`).
- `OptimisticConfirmationVerifier::verify_for_unrooted_optimistic_slots` (`optimistic_confirmation_verifier.rs:27-55`).
- `ReplayStage::purge_unconfirmed_slot` (`replay_stage.rs:2019-2124`).

**Suggested modeling approach**:
- **Variables**:
  - `ocStake[(slot, hash)] = Set[Pubkey]` — per-(slot, hash) confirmed-votes set
  - `ocConfirmed = Set[(Slot, Hash)]` — slots that have reached 2/3 (the `unchecked_slots` analog)
  - `rooted = Set[Slot]` — rooted slots
  - `rootedHash[slot]` — the hash that rooted (single per slot)
- **Actions**:
  - `ObserveVote(v, slot, hash, source ∈ {gossip, replay})` — add `v` to `ocStake[(slot, hash)]`. NO check on whether `v` already in `ocStake[(slot, hash')]` for some other `hash'`.
  - `ReachOC(slot, hash)` — when `Σ stake[v] for v ∈ ocStake[(slot, hash)] ≥ 2/3 · total`, add `(slot, hash)` to `ocConfirmed`.
  - `RootSlot(slot, hash)` — adds to `rooted`, `rootedHash[slot] := hash`.
  - **Byzantine**: `ByzVoteOnBothForks(v, slot, hash_a, hash_b)` — same validator emits both votes; both accumulate (BFT 2.1 + 2.7).
- **Invariants**:
  - `NoDualHashOC` (safety) — `∀ s : |{h : (s, h) ∈ ocConfirmed}| ≤ 1`. **This invariant is NOT enforced by code; the goal is to find a counterexample under f = ⌈n/3⌉ Byzantine.**
  - `OCImpliesEventualRoot` (liveness, post-GST) — every `(s, h) ∈ ocConfirmed` eventually has `(s, h) ∈ rooted`.
  - `RolledBackOCBounded` — the count of `(s, h)` events that reach `ocConfirmed` but later have `rootedHash[s] ≠ h` is bounded (the brief asks for "what is the exact bound" — model this as a model-checkable invariant).

**Priority**: High
**Rationale**: This is the core 2/3 OC safety property the brief explicitly flags. The accounting is structurally per-`(slot, hash)`, so Byzantine equivocation is a first-class admitted state, not a runtime error. Combined with Family 1, this is the strongest candidate for finding a *new* safety violation (the question "is the OC rollback bound ≤ what code guarantees?" is forward-looking, not historical).

---

### Family 4: Duplicate-Slot Reconciliation & Fork-Choice State Hazards (MEDIUM-HIGH)

**Mechanism**: Several code paths panic on detected equivocation evidence (assertion violation), and `purge_unconfirmed_slot` mutates fork-choice state in ways the tower cannot undo. Together they create liveness halts (`panic!` → process exit) AND a state-stranding pattern where the tower contains a vote on a slot the local node has purged.

**Evidence**:
- Code analysis: `core/src/replay_stage.rs:2205-2254` — `process_duplicate_confirmed_slots` `assert_eq!(prev_hash, duplicate_confirmed_hash, "Additional duplicate confirmed notification for slot {} with a different hash")`. Stake threshold (≥0.52 per side) means panic fires precisely under ≥1/3 Byzantine equivocation.
- Code analysis: `core/src/replay_stage.rs:2019-2124` — `purge_unconfirmed_slot` clears `bank_forks`, `ancestors`, `descendants`, `progress`, blockstore; **does NOT mutate tower**. Tower retains a vote on the purged slot.
- Code analysis: `core/src/consensus.rs:1100-1109` — "Should never consider switching to ancestor" `panic!` is reachable when `purge_unconfirmed_slot` removes a slot below `last_voted_slot` and fork-choice next picks a heaviest-slot that's an ancestor in the bank graph.
- Code analysis: `core/src/consensus.rs:700-735` — `record_bank_vote_and_update_lockouts` panics on `vote_slot <= last_voted_slot`. Reachable when Family-1 adoption sets `last_voted_slot` higher than heaviest replayable.
- Code analysis: `core/src/consensus/heaviest_subtree_fork_choice.rs:1017-1047` — same-slot vote with smaller hash overrides earlier — `warn!("Got a duplicate vote...")` line 1038 acknowledges. Byzantine validator can shift stake at will.
- Code analysis: `core/src/consensus/heaviest_subtree_fork_choice.rs:27` — `SlotHashKey = (Slot, Hash)` indexes by `bank_hash` only; `block_id` (signed in vote-tx) is excluded from fork-choice.
- Historical: commit `c2bb2b8e60` (2022-10-03, #28172) — "Allow validators to reset to the slot which matches their last voted slot" — direct evidence of stranding-induced liveness fixes.
- Historical: commit `fb97e93fe3` (2024-01-10, #34014) — "fix duplicate confirmed rollup detection for descendants".
- Historical: commit `985c0dcd` (2025-12-20, #9445) — "preserve slot on duplicate frozen votes in dirty set".

**Affected code paths**:
- `ReplayStage::process_duplicate_confirmed_slots`, `mark_slots_duplicate_confirmed` (`replay_stage.rs:2205, 4366`).
- `ReplayStage::purge_unconfirmed_slot`, `dump_then_repair_correct_slots` (`replay_stage.rs:2019, 1809`).
- `Tower::make_check_switch_threshold_decision` panic sites (`consensus.rs:1043, 1088, 1092, 1104, 1167, 1175`).
- `Tower::record_bank_vote_and_update_lockouts` (`consensus.rs:700`).
- `HeaviestSubtreeForkChoice::add_votes`, `mark_fork_invalid_candidate` (`heaviest_subtree_fork_choice.rs:1017, 1328`).

**Suggested modeling approach**:
- **Variables**:
  - `duplicateConfirmed[slot] = Set[Hash]` — observed duplicate-confirmed hashes per slot (Byzantine can produce two-element sets)
  - `purgedSlots = Set[Slot]` — slots removed by `purge_unconfirmed_slot`
- **Actions**:
  - `MarkDuplicateConfirmed(slot, hash)` — if `|duplicateConfirmed[slot]| > 0 ∧ hash ∉ duplicateConfirmed[slot]`, the action transitions to a "Panic" state representing process death.
  - `PurgeUnconfirmed(v, slot)` — remove `slot` from `purgedSlots[v]`'s view but leave it in `tower[v]`.
  - **Byzantine**: `ByzDriveDualDuplicateConfirm(slot, hash_a, hash_b)` — ≥0.52 Byzantine + honest split on each side. Drives the `assert_eq!` panic.
- **Invariant**:
  - `NoDualDuplicateConfirm` — `∀ s : |duplicateConfirmed[s]| ≤ 1`. Same as Family 3's `NoDualHashOC` for a different threshold (0.52 vs 0.667).
  - `TowerConsistentWithPurges` — `last_voted_slot(tower[v]) ∉ purgedSlots[v]`.
- **Liveness**: model `Panic` as a sink state; check that under the Byzantine threshold `f < n/3` the panic is unreachable.

**Priority**: Medium-High
**Rationale**: The dual-hash duplicate-confirm panic is reachable precisely when an equivocation attack succeeds — which is the case the model is designed to *find*. The state-stranding pattern is the unique Tower-BFT analog to "QC committed on different value" but expressed via purges instead of certificates. Composes with Family 1 (purge happens, then tower-adoption tries to "fix" by adopting on-chain state).

---

### Family 5: Lockout Defense-in-Depth Gaps (MEDIUM)

**Mechanism**: Lockout enforcement is *single-sited* — `is_locked_out` is computed by `cache_tower_stats` and read by `can_vote_on_candidate_bank`. The tower-mutation function (`record_bank_vote_and_update_lockouts`) itself does NOT recheck `is_locked_out`. Threshold checks fire only at depths 4 and 8 (since PR #34120 added 4-deep; pre-2023 there was only depth 8). Issue #5850 (OPEN ~5.5 years) argued for threshold at *every* depth.

**Evidence**:
- Code analysis: `core/src/consensus.rs:700-735` — `record_bank_vote_and_update_lockouts` only checks `vote_slot > last_voted_slot`.
- Code analysis: `core/src/consensus.rs:1387-1390` — `vote_thresholds_and_depths = [(4, 0.38), (5, 0.38), (8, 0.667)]`. No threshold at depths 6, 7, 9-32.
- Code analysis: `core/src/consensus.rs:1043, 1088, 1092, 1104, 1167, 1175` — five `panic!`/`unwrap` sites in switch-threshold path.
- Historical: solana-labs/solana **#5850** (OPEN ~5.5 years) — "tower only checks threshold for one bank".
- Historical: solana-labs/solana **#22244** (closed stale) — carllin clarified depth-8 is "an estimate".
- Historical: solana-labs/solana **#34107** (OPEN) — Nov 3 2023 mainnet event led to PR #34120 (depth-4 addition).
- Historical: solana-labs/solana **#7521**, **#8113** (both OPEN-and-stalled multi-year) — slashing not implemented.

**Affected code paths**:
- `Tower::record_bank_vote_and_update_lockouts` (`consensus.rs:700`).
- `Tower::check_vote_stake_thresholds` (`consensus.rs:1370`).
- `Tower::make_check_switch_threshold_decision` (panic sites listed above).

**Suggested modeling approach**:
- Model thresholds as exact fractions: `SWITCH_FORK_THRESHOLD = 38/100`, `VOTE_THRESHOLD_SIZE = 2/3`, `DUPLICATE_THRESHOLD = 52/100`.
- Model `vote_thresholds = {(4, switch), (5, switch), (8, vote)}` as the exact set — TLC search can ask "is the depth-set sufficient under Byzantine f stake?"
- The slashing-absence is part of the *threat model documentation*, not a modeling action. Document explicitly in §3.2 "Do not model".

**Priority**: Medium
**Rationale**: The single-site lockout check is a "future-refactor risk" (latent footgun) rather than a current safety bug. The two-depth threshold is partially addressed; modeling at depth N is straightforward. Slashing-absence is acknowledged-design.

---

### Family 6: Migration & Identity-Swap Window (LOW-MEDIUM, OUT OF SCOPE)

**Mechanism**: Two transition points expose narrow races: (a) Alpenglow/Votor migration phase machine, (b) `set-identity` runtime identity swap.

**Evidence**:
- Migration: `core/src/replay_stage.rs:2774-2788, 944-1018`; `votor-messages/src/migration.rs:101-216`.
- Identity-swap: `core/src/replay_stage.rs:1246-1274, 740-765`; `core/src/consensus/tower_storage.rs:94-101`.
- Historical: commits `befe8b9d9` (#35173), `07955e79a` (#35269); issues #34785, #35152, #28047.

**Affected code paths**: `MigrationStatus`, `ReplayStage` outer loop, `SavedTower::new` pubkey check.

**Suggested modeling approach**: **Do not model.** The migration is a transient configuration event; the identity-swap fixes are well-tested by integration tests. Modeling the migration would require encoding two distinct consensus protocols and their transition — out of proportion to the bug surface.

**Priority**: Low
**Rationale**: Operational concerns; well-covered by integration tests; not the modeling sweet spot.

---

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|---|---|---|
| Per-validator persistent tower vs in-memory tower | Family 1: foundational distinction; tower file is not fsync'd | Two variables `persistedTower[v]`, `tower[v]`; `Crash(v)` resets `tower[v]` but only nondeterministically advances `persistedTower[v]` to track the latest enqueued state |
| `adopt_on_chain_tower_if_behind` action | Family 1: the unique-to-Tower-BFT amnesia mechanism | `AdoptOnChainTower(v, slot)` action that replaces `tower[v]` with `onChainVoteState[v][slot]` when last_voted_slot is greater |
| 3-step record→store→broadcast non-atomic vote | Family 1: pre-fsync vote broadcast race | Split `Vote(v, s)` into `RecordVote`, `EnqueueForBroadcast`, `PersistTower`, `BroadcastVote` actions; allow `Crash` between any pair |
| Switch-threshold proof from BOTH replayed AND gossip-claimed votes | Family 2: the unique-to-Tower-BFT switch-threshold construction | `SwitchProof(s, v)` action that admits both `onChainVotes` AND `gossipFrozenVotes[u]` as evidence; Byzantine `ByzGossipFakeLatestFrozenVote(u, slot, hash)` action |
| 512-slot SameFork escape | Family 2: structural fallback bypass | Bounded counter modeling "vote was not included for > N slots" → SameFork transition |
| Per-(slot, hash) OC stake tracker (no cross-hash dedup) | Family 3: the core OC safety claim | `ocStake[(slot, hash)] = Set[Pubkey]` with no merge across hashes; `ReachOC` action |
| Optimistic-confirmation rollback | Family 3: the brief's open question #4 | `RootSlot(slot, hash')` action where `hash' ≠ hash` for some `(slot, hash) ∈ ocConfirmed`; invariant on bound |
| Duplicate-confirm panic | Family 4: equivocation evidence triggers process death | `MarkDuplicateConfirmed` action transitions to Panic state on second different hash |
| `purge_unconfirmed_slot` mutating fork-choice but not tower | Family 4: tower-stranding pattern | `PurgeUnconfirmedSlot(v, s)` action removes from `validatorView[v]` but not from `tower[v]` |
| Byzantine equivocating votes (signed) on two forks | BFT 2.1 baseline | `ByzVoteOnBothForks(v, slot, hash_a, hash_b)` action |
| Byzantine forge fake "latest gossip vote" | BFT 2.7 (cert-manipulation analog for Tower) | `ByzGossipFakeLatestFrozenVote(v, slot, hash)` — claimed but never on-chain |
| Byzantine amnesia after crash | BFT 2.6 × 5.1 | `Crash(v)` + `Restart(v)` + `AdoptFromBank(v)` where bank's stored vote state is Byzantine-influenced |

### 3.2 Do Not Model

| What | Why |
|---|---|
| PoH / clock skew | Per brief §"Out of scope"; treat as oracle for slot ordering |
| Move/Sealevel VM, accounts-db, gossip transport, RPC | Per brief §Scope; treat as fair-network |
| Cryptographic signature forgery | BFT default; signatures are unforgeable by axiom (`bft-analysis.md` § 1.1 Layer 1) |
| Alpenglow / Votor migration | Family 6; transient configuration event; the production target is Tower BFT |
| `set-identity` identity-swap races | Family 6; operational, well-tested by integration tests |
| f64 precision rounding in thresholds | Model exact fractions; rounding is a refinement (~1 ULP slack) |
| Refresh-vote rate limit (`MAX_VOTE_REFRESH_INTERVAL_MILLIS`) | Performance, not safety |
| `BlockCommitment` aggregation | RPC-only consumer; not consensus-affecting |
| Slashing / evidence pool | Not yet implemented in Solana (issues #7521, #8113 OPEN); Tower BFT relies on rational-Byzantine, not slashing-enforced |
| Sept 2021 outage | Not a pure consensus bug per brief context; tx-flood-triggered fork divergence |

### 3.3 Recommended Adversary Profile

From `bft-analysis.md` §2 / §3 default profile, instantiate the following categories for this Tower BFT brief:

| Category | Status | Reason |
|---|---|---|
| 2.1 Equivocation | **baseline-on** | Required for Family 3 (dual-hash OC) and Family 4 (dual-hash duplicate-confirm) |
| 2.2 Invalid Content Fabrication | **baseline-on** | Required for Byzantine-built bank affecting Family 1 adoption |
| 2.3 Omission / Withholding | **implicit** | Honest-send guard on `s ∉ Faulty`; no explicit action |
| 2.5 Replay / Stale-Context Misuse | **on** | Composes with 5.5 Migration; also gossip-vote staleness in Family 2 |
| 2.6 State Rollback / Amnesia | **baseline-on, central** | Family 1's `Crash + AdoptOnChainTower` is exactly this category, composed with 5.1 Crash. **This is the most important Tower-BFT-specific adversary.** |
| 2.7 Certificate / Quorum-Proof Manipulation | **on, central** | Family 2 (`ByzGossipFakeLatestFrozenVote`) is the Tower-BFT analog of cert-forge — the switch-threshold is the cert. Use `ByzReuseRealCertificate` template: Byzantine reuses a real gossip-vote claim on a fork the validator never actually voted on. |
| 2.4 Selective Dissemination | **conditional, defer** | Solana's switch-threshold considers gossip-frozen-votes globally, not targeted; defer unless brief is extended. |
| 2.8 Evidence / Accountability Lifecycle | **conditional, off** | Solana does NOT implement on-chain slashing yet; explicitly document as out-of-scope. |
| 2.9 Adaptive / Posterior Corruption | **conditional, partial** | Solana is PoS; validators can re-stake. The `max_gossip_frozen_votes` never-pruned finding (Family 2) interacts with retired-validator re-staking. Recommend modeling with `Faulty` as VARIABLE and explicit `ByzPromote` action — minimal addition since brief assumes f < n/3 (stake-weighted threshold). |

### 3.4 Composition Priorities

Per `bft-analysis.md` §6:

| Composition | Bug pattern | Family |
|---|---|---|
| 2.6 Amnesia × 5.1 Crash × 5.4 NonAtomicPersist | The "lost tower" attack | Family 1 |
| 2.7 Cert-Reuse × 2.1 Equivocation | Fake gossip vote shifts switch-threshold | Family 2 |
| 2.1 Equivocation × 5.2 Partition | Dual-hash OC under network split | Family 3 |
| 2.6 Amnesia × 2.1 Equivocation | Tower restored without an equivocation we recently signed | Family 1 + Family 3 |
| 2.7 × 2.4 (deferred) | Selective gossip-vote dissemination | Family 2 (extension) |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|---|---|---|---|
| Per-validator persistent vs in-memory tower | `tower[v]`, `persistedTower[v]`, `pendingTower[v]` | Crash window between record/store/broadcast | Family 1 |
| Multi-hop crash recovery | `crashedRecently : SUBSET Server` | Models lost in-memory + non-fsync tower | Family 1 |
| On-chain vote-state per bank | `onChainVotes[v][bankSlot] : Seq[Lockout]` | Byzantine-influenced bank state for adoption | Family 1, 4 |
| Gossip vs replay latest-vote split | `gossipFrozenVotes[v]`, `replayFrozenVotes[v]` | Switch-threshold inputs split by source | Family 2 |
| Per-(slot, hash) OC tracker | `ocStake[(slot, hash)] = SUBSET Server` | OC equivocation accounting | Family 3 |
| Optimistic-confirmation set | `ocConfirmed : SUBSET (Slot × Hash)` | Track all OC events for rollback analysis | Family 3 |
| Duplicate-confirmed observations | `duplicateConfirmed[slot] : SUBSET Hash` | Detect dual-hash duplicate-confirm | Family 4 |
| Purged-slots view | `purgedView[v] : SUBSET Slot` | Per-validator local-purge state | Family 4 |
| Tower-version multi-depth thresholds | `voteThresholds : SUBSET (Nat × Fraction)` | Capture {(4, 0.38), (5, 0.38), (8, 2/3)} structure | Family 5 |
| Per-validator stake (configurable) | `stake : [Server -> Nat]` | Stake-weighted thresholds | All |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| `LockoutSafety` | Safety | No validator votes on slot `s2` while a deeper-locked vote exists on a different fork at slot `s1` with `s1 + lockout(s1) ≥ s2` | Family 1, 5 |
| `NoDualHashOC` | Safety | `∀ s : |{h : (s, h) ∈ ocConfirmed}| ≤ 1` — at most one hash per slot reaches 2/3 OC | Family 3 |
| `OCImpliesEventualRoot` | Liveness (post-GST) | Every `(s, h) ∈ ocConfirmed` is eventually rooted | Family 3 |
| `OCRollbackBounded` | Safety | If `(s, h) ∈ ocConfirmed` and `rootedHash[s] ≠ h`, then ≥1/3 stake is Byzantine | Family 3 (brief §Open question #4) |
| `NoDualHashDuplicateConfirm` | Safety | `∀ s : |duplicateConfirmed[s]| ≤ 1` under f < n/3 | Family 4 |
| `SwitchProofRequiresRealLockout` | Safety | `SwitchProof(s)` decision requires ≥38% real on-chain locked-out stake (not gossip-only claims) | Family 2 |
| `TowerConsistentWithPersistedAfterCrash` | Safety | After `Crash` + `Restart`, `tower[v] = persistedTower[v]` (i.e., no in-memory votes survive that aren't durable) | Family 1 |
| `AdoptOnChainTowerNoLossOfDurableVote` | Safety | `AdoptOnChainTower` does not move us off a vote that was previously durable AND on-chain | Family 1 |
| `TowerVotesAreOnExistingForks` | Safety | `∀ v, vote ∈ tower[v].votes : vote.slot ∉ purgedView[v]` | Family 4 |
| `NoEquivocatingVoteFromHonest` | Safety | `∀ v ∈ Honest, ∀ slot : |{hash : ∃ vote signed by v on (slot, hash)}| ≤ 1` | Standard BFT |
| `RootedSlotsForkConsistent` | Safety | `∀ s1, s2 ∈ rooted : ancestor-or-descendant(s1, s2)` | Standard finality |

## 6. Findings Pending Verification

### 6.1 Model-Checkable (forward-looking questions, not historical replays)

| ID | Description | Expected invariant violation | Bug Family |
|---|---|---|---|
| MC-1 | Under `f = ⌈n/3⌉` Byzantine equivocating across two forks, can two hashes for the same slot both reach `2/3` OC? (brief Q4) | `NoDualHashOC` | 3 |
| MC-2 | Can a `Crash` between `EnqueueForBroadcast` and `PersistTower`, plus a subsequent `Restart` + `AdoptOnChainTower` from a Byzantine-influenced bank, cause an honest validator to issue a vote that violates `LockoutSafety` against a previously durable vote? (brief Q1, Q2) | `LockoutSafety` | 1 |
| MC-3 | Can `f` Byzantine validators coordinate a `ByzGossipFakeLatestFrozenVote` campaign that triggers `SwitchProof` on a victim validator with < 38% real on-chain locked-out stake? (brief Q3) | `SwitchProofRequiresRealLockout` | 2 |
| MC-4 | What is the exact OC-rollback bound under `f = ⌈n/3⌉`? Model-check `OCRollbackBounded` and report the smallest `f` that produces a rollback. (brief Q4) | `OCRollbackBounded` | 3 |
| MC-5 | Can a Byzantine validator equivocate (BFT 2.1 baseline) to drive *two* distinct duplicate-confirmed observations on the same slot, causing the `assert_eq!` panic at `replay_stage.rs:2231`? | `NoDualHashDuplicateConfirm` (liveness halt) | 4 |
| MC-6 | Can `purge_unconfirmed_slot` strand the tower (`TowerVotesAreOnExistingForks` violated), then `select_forks` reach the "Should never consider switching to ancestor" panic at `consensus.rs:1104`? | Liveness halt | 4 |
| MC-7 | Can a Byzantine validator who previously retired keys and re-staked use stale `max_gossip_frozen_votes` entries (never pruned) to bias a future switch-threshold check, satisfying BFT 2.5 × 2.9 composition? | `SwitchProofRequiresRealLockout` | 2 |
| MC-8 | When `tower_root > replayed_root` (future tower from a snapshot below the tower), can the suspended-decision-due-to-major-unsynced-ledger path be evaded for same-fork voting? (brief Q2) | `LockoutSafety` | 1 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| T-1 | No fsync on tower file at `tower_storage.rs:218` | Integration test: kill -9 validator immediately after a vote is observed on the wire; restart; check whether tower file regressed. Property: persistedTower.last_voted_slot ≥ on-chain-last-vote |
| T-2 | `record_bank_vote_and_update_lockouts` does not check `is_locked_out` | Unit test: synthesize a bank whose `cache_tower_stats.is_locked_out = false` (cache stale), call `record_bank_vote` directly, assert tower invariants violated |
| T-3 | Five panic sites in `make_check_switch_threshold_decision` | Property fuzzing: random `ancestors`/`descendants`/`progress` populations; assert no panic |
| T-4 | `f64` threshold precision near `2/3` | Stake-distribution fuzzing: build cases where integer-exact `> 2/3` flips f64-rounded `> 2.0/3.0` |
| T-5 | `latest_validator_votes_for_frozen_banks` lacks pruning | Long-running integration test (1k+ slots over a lasting partition); assert map size bounded |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| R-1 | `Default for Tower` sets `root_slot = Some(0)` | Discuss with maintainers whether to make Tower::default an explicit "uninitialized" sentinel |
| R-2 | `assert!` in `adjust_lockouts_after_replay` (consensus.rs:1478-1487) does not cover legacy `Tower1_7_14` empty-stack case | Add the third variant to the assert or remove obsolete path |
| R-3 | Refresh-vote path is not persisted (`last_vote_tx_blockhash`, `last_timestamp` regress on crash) | Discuss whether to persist refresh state |
| R-4 | `SlotHashKey` indexes on `bank_hash` but vote-txs commit to `block_id` (consensus state outside fork-choice) | Audit fork-choice for `block_id` consistency assumptions |
| R-5 | Three divergent stake views: `BlockCommitment`, `VoteTracker`, `LatestValidatorVotesForFrozenBanks` | Document the contract that they should NOT be synchronized; design assertion that catches inconsistency |
| R-6 | "Should never consider switching to ancestor" panic is reachable post-purge (replay_stage.rs comment "Allowing switch vote on ... TODO: Properly handle this case" at consensus.rs:1066) | Replace TODO with documented invariant + assertion |
| R-7 | Single-depth threshold check argued in #5850 to be insufficient | Discuss with consensus team whether to add thresholds at depths 6, 7, 12, 16 |

## 7. Reference Pointers

- **Full analysis report**: `/home/ubuntu/Specula/case-studies/solana/.specula-output/analysis-report.md`
- **Key source files** (canonical paths after Anza reorganization):
  - `core/src/consensus.rs` (3932 lines, Tower struct + lockout/switch logic)
  - `core/src/consensus/tower_storage.rs` (277 lines, persistence)
  - `core/src/consensus/fork_choice.rs` (491 lines, `select_vote_and_reset_forks`)
  - `core/src/consensus/heaviest_subtree_fork_choice.rs` (4687 lines, weighted fork tree)
  - `core/src/consensus/latest_validator_votes_for_frozen_banks.rs` (552 lines, gossip+replay latest-vote map)
  - `core/src/consensus/vote_stake_tracker.rs` (100 lines, per-(slot, hash) OC stake)
  - `core/src/consensus/progress_map.rs` (642 lines, cached per-bank stats)
  - `core/src/consensus/tower_vote_state.rs` (345 lines, minimal vote-state)
  - `core/src/replay_stage.rs` (10405 lines; focus 1500–4700: `load_tower`, `adopt_on_chain_tower_if_behind`, `handle_votable_bank`, `push_vote`, `process_duplicate_confirmed_slots`, `purge_unconfirmed_slot`, `handle_new_root`)
  - `core/src/cluster_info_vote_listener.rs` (2221 lines, vote ingestion + OC tracking)
  - `core/src/optimistic_confirmation_verifier.rs` (330 lines, OC-not-rooted detection)
  - `core/src/voting_service.rs` (~170 lines, vote-tx broadcast)
- **GitHub issues** (Family 1): solana-labs/solana #23135, #23137, #25598, #20192, #34785, #35152. **Family 2**: #7087, #6727, #8232. **Family 3**: #33669, #34102, #34107, anza-xyz/agave #12307. **Family 4**: solana-labs/solana #34014, #24710, anza-xyz/agave #9445, #1646. **Family 5**: solana-labs/solana #5850, #22244, #34120, #7521, #8113.
- **Key commits** (file:line in shallow-clone view):
  - Tower-adoption fixes: `85cc6ace0` (#33341, 2023-09-25), `000ca4ce0` (#1632, 2024-06-11)
  - Tower-load resilience: `07955e79a` (#35269, 2024-02-21), `befe8b9d9` (#35173, 2024-02-20)
  - Threshold expansion: `07f38838a` (#34120, 2023-12-12, depth-4 threshold)
  - Duplicate handling: `fb97e93fe` (#34014, 2024-01-10), `985c0dcdd` (#9445, 2025-12-20)
  - OC pathway flux: `84a934a9f` (#3136, 2024-10-23, added BankHashCache), `207fb1d00` (#10594, 2026-02-19, removed BankHashCache)
- **Reference algorithm**: Tower BFT whitepaper (Yakovenko, 2018). The Anza Alpenglow paper (Wadsworth, 2025) defines the successor protocol but is not the modeling target.
- **Reference TLA+ specs**: None in corpus for vote-lockout BFT. The closest analogues — aptosbft, cometbft, autobahn — share BFT adversary categories but have fundamentally different safety-proof structures. Start from `case-studies/aptosbft/spec/MC_epoch.tla` for the *adversary template*, but the *protocol-state* model must be built fresh from this brief.
- **Sub-category in `distributed-analysis.md` Table**: vote-lockout BFT is not pre-tabulated; closest is Raft/Multi-Paxos consensus + BFT overlay. Priority families per this brief: 5.1 Crash (Family 1), 5.4 NonAtomicPersist (Family 1), 5.2 Network/Partition (Family 2/3), 5.3 Timeout (implicit in 512-slot SameFork escape), 2.1/2.6/2.7 (Families 2, 3, 1).
