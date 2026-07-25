# Analysis Report: Solana Tower BFT (`anza-xyz/agave`)

This is the long-form audit trail for the modeling brief at `./modeling-brief.md`. Findings are grouped by bug family; each finding cites `file:line` and notes severity.

---

## Phase 1 — Reconnaissance

### Repository layout

The agave fork is mid-restructure: a new "Votor" (Alpenglow) consensus subsystem is being added in parallel with the existing **Tower BFT** implementation. The reference brief explicitly scoped to Tower BFT; Votor (`votor/src/*`, `consensus_pool*`, `event_handler`, `votor.rs`) is out of scope.

Canonical Tower BFT paths on current `master` (commit `83de46a`):

| File | LOC | Role |
|------|-----|------|
| `core/src/consensus.rs` | 3932 | Tower struct, lockouts, switch threshold (`SWITCH_FORK_THRESHOLD=0.38`), vote threshold (`VOTE_THRESHOLD_DEPTH=8`, `threshold_size=2/3`), tower restore (`adjust_lockouts_after_replay`), persistence interface |
| `core/src/consensus/tower_storage.rs` | 277 | `TowerStorage` trait, `FileTowerStorage` (no fsync), `NullTowerStorage`, `SavedTower(Versions)` |
| `core/src/consensus/tower_vote_state.rs` | 345 | In-validator mirror of vote-program lockout stack (`process_next_vote_slot`, `double_lockouts`, `pop_expired_votes`) |
| `core/src/consensus/fork_choice.rs` | 491 | `select_vote_and_reset_forks`, `SwitchForkDecision`, `can_vote_on_candidate_bank` |
| `core/src/consensus/heaviest_subtree_fork_choice.rs` | 4687 | Heaviest-subtree fork choice algorithm |
| `core/src/consensus/progress_map.rs` | 661 | Per-bank `ForkStats` cache (`is_locked_out`, `vote_threshold`, `lockout_intervals`) |
| `core/src/consensus/latest_validator_votes_for_frozen_banks.rs` | 552 | Gossip-vote tracker for switching proofs |
| `core/src/consensus/vote_stake_tracker.rs` | 100 | Per-hash stake counter with threshold-crossing notification |
| `core/src/replay_stage.rs` | 11757 | Main consensus event loop; `handle_votable_bank`, `push_vote`, `check_and_handle_new_root`, `compute_bank_stats`, `adopt_on_chain_tower_if_behind`, dump-and-repair |
| `core/src/voting_service.rs` | 170 | Async tower-save + vote-tx broadcast (single thread per validator) |
| `core/src/cluster_info_vote_listener.rs` | 2221 | Gossip-vote ingestion; OC accumulation via `VoteStakeTracker` |
| `core/src/optimistic_confirmation_verifier.rs` | 330 | Detect OC slots not eventually rooted (logs only — not enforced) |
| `core/src/commitment_service.rs` | 811 | Per-validator commitment aggregation |
| `core/src/vote_simulator.rs` | 450 | Test harness for consensus tests |

### Key protocol constants

```rust
// consensus.rs:156-158
const VOTE_THRESHOLD_DEPTH_SHALLOW: usize = 4;        // log-only experimental
pub const VOTE_THRESHOLD_DEPTH: usize = 8;            // hard threshold check
pub const SWITCH_FORK_THRESHOLD: f64 = 0.38;          // 38% to switch forks

// replay_stage.rs:125-128
pub const DUPLICATE_LIVENESS_THRESHOLD: f64 = 0.1;    // 10%
pub const DUPLICATE_THRESHOLD: f64 =                  // 0.52 — duplicate-confirm threshold
    1.0 - SWITCH_FORK_THRESHOLD - DUPLICATE_LIVENESS_THRESHOLD;

// from solana_runtime::commitment
const VOTE_THRESHOLD_SIZE: f64 = 2.0 / 3.0;           // 2/3 supermajority
```

Note the algebraic identity `0.38 + 0.52 + 0.1 = 1.0`. As long as Byzantine stake ≤ 1/3, two conflicting `DUPLICATE_THRESHOLD`-confirmed slots cannot both exist (an honest majority must intersect).

### Architecture and concurrency

- Replay stage on **single thread** — the only mutator of `Tower` in steady state.
- Voting service on a **separate thread** — receives `VoteOp` from an unbounded `crossbeam_channel`, calls `tower_storage.store(...)`, then sends vote tx, then `cluster_info.push_vote(...)`.
- Cluster-info vote listener on a separate thread — ingests gossip votes, calls `track_optimistic_confirmation_vote`, fires `BankNotification::OptimisticallyConfirmed(slot)` to RPC.
- Banking-stage on multiple threads — executes vote transactions in blocks.
- `BankForks` is an `RwLock`-protected DAG of `Bank`s; replay stage holds short read locks.

System category: **Category A (Distributed / Message-Passing)** with a **Byzantine threat model** — Tower BFT depends on stake-weighted thresholds and treats up to ⌊n/3⌋ validators as adversarial. Sub-category: **vote-lockout BFT** (PoH-ordered slots + per-validator persistent towers; no pre-cluster QC).

---

## Phase 2 — Bug Archaeology

### Git history (15000 commits fetched from origin/master)

- **Tower BFT bug-fix commits identified**: ~73 raw matches across `core/src/consensus.rs`, `core/src/consensus/`, `core/src/replay_stage.rs`, `core/src/voting_service.rs`, `core/src/cluster_info_vote_listener.rs`, `core/src/optimistic_confirmation_verifier.rs`; ~35 substantive after excluding refactors/lints/alpenglow-prep.
- **Top 10 safety-critical fixes (full diff reviewed)**:
  1. `85cc6ace0` — Update `is_locked_out` cache when adopting on-chain vote state (CRITICAL: stale cache → slashable double-vote)
  2. `329c6f131` — When syncing from vote state, update `last_vote` too (CRITICAL: stale broadcast)
  3. `06b098e44` — Refactor stray-last-vote in switch threshold (CRITICAL: over-permissive descendant check)
  4. `fb97e93fe` — Fix duplicate-confirmed rollup detection for descendants (HIGH: missing 0.52-threshold path)
  5. `befe8b9d9` + `07955e79a` — Set-identity tower reload at startup (CRITICAL: using wrong identity's tower)
  6. `07f38838a` + `6859d652b` — Shallow vote-threshold check at depth 4 (HIGH: tuning saga)
  7. `cd2878acf` — Hard-fork root reconciliation (HIGH: missing-to-root)
  8. `ace24a7c8` — Default tower no longer flagged as stray (MEDIUM-HIGH: `None==None` false positive)
  9. `1444baa42` — `return` → `continue` in `mark_slots_duplicate_confirmed` (HIGH: missed batches)
  10. `6f72258e3` — Vote refresh stuck when last vote outside SlotHashes (HIGH: liveness loss)

### GitHub issues (38 deeply read with `gh issue view --comments` across both `anza-xyz/agave` and `solana-labs/solana`)

| Issue | Repo | State | Mechanism |
|-------|------|-------|-----------|
| **#23135** | solana-labs | **OPEN** | Stray votes after restart with lost ledger → switching proof can count ancestors → safety violation |
| **#23137** | solana-labs | OPEN | Restart from snapshot >512 slots ahead of last vote crashes (`SlotHashes` is 512-entry ring); operator must delete tower (risk) or wait |
| **#25598** | solana-labs | OPEN | Tower restore should use AccountsDB's longer slot history |
| **#7087** | solana-labs | CLOSED | Selfish-mining attack: minority over-commits, withholds, then releases — forces majority into 2^16-slot lockout |
| **#8232** | solana-labs | OPEN | Leaders continue building on own fork after partition (no data-availability gate for own block) |
| **#5850** | solana-labs | OPEN | Tower threshold only checks one bank — attacker can ratchet lockout across partitions |
| **#7521** | solana-labs | OPEN | No slashing for lockout violation (slashing v0 unimplemented) |
| **#8113** | solana-labs | OPEN | No fail-stop if every validator simultaneously misses a consensus check |
| **#6962** | solana-labs | OPEN | Whole network is one implementation; need external supervisor |
| **#12307** | anza-xyz | **OPEN** | OC notification drops voted hash → RPC can promote local hash A when cluster OC'd hash B |
| **#8752** | anza-xyz | OPEN | Gossip duplicate-instance + `push_vote` panic → double-panic on identity hot-swap race |
| **#34107** | solana-labs | OPEN (production) | Nov-3-2023 latency event: long replay-loop time → deep towers → skipped slots. Led to PR #34120 |
| **#30669** | solana-labs | CLOSED | March-2023 testnet roots-stall: gossip vote listener dropping full-tower votes + VOTE_THRESHOLD_DEPTH too forgiving |
| **#32880** | solana-labs | CLOSED | `last_voted_slot must be in heaviest_subtree_fork_choice` panic after identity hot-swap (fixed v1.14.25/v1.16.10) |
| **#35152** | solana-labs | CLOSED | `set-identity` while waiting for supermajority → tower has stale pubkey → crash |
| **#32889** | solana-labs | CLOSED | Off-by-one vote-credit accounting for long-delinquent validators after VoteStateUpdate (consensus divergence between v1.14 ↔ master) |
| **#30060** | solana-labs | CLOSED | `RequestHeapFrame` allowed in v1.14 but not v1.13 (consensus divergence on MNB) |
| **#23545** | solana-labs | CLOSED | `#[serde(skip)] lamports_per_signature` → bank-hash divergence after 512+ slot offline |
| **#27566** | solana-labs | CLOSED | Vote refresh broken when slot is outside SlotHashes |
| **#16768** | solana-labs | CLOSED | Generating vote from bank diff doesn't recreate lockouts (root cause of VoteStateUpdate rewrite) |
| **#17578** | solana-labs | STALE | Node stopped freezing banks due to duplicate-checking chain issue |
| **#11713** | solana-labs | OPEN | Re-enable repairing duplicate slots confirmed by network |

### Coverage statistics

- **Commits collected**: 73 candidate bug-fix commits in core files
- **Commits classified**: ~35 substantive Tower BFT fixes after refactor/lint exclusions
- **Commits deeply analyzed** (`git show` full diff): top 10 plus archaeology-cross-references
- **Issues collected via gh issue list**: ~120 candidates across keyword searches (tower, lockout, optimistic, switch, fork choice, consensus, duplicate, set-identity, hot-spare)
- **Issues deeply read** (full comment thread via `--comments`): 38
- **Confirmed bugs**: 22 (15 fixed, 7 open)
- **Disputed/user-error excluded**: 4 (#11008 native-loader, #579/35493 disk-full, others)
- **Tracking/meta tickets**: 4 (#14436, #34107 family)
- **Design-defect open**: 8 (#23135, #23137, #25598, #8232, #5850, #7521, #8113, #6962)

---

## Phase 3 — Deep Analysis: Bug Families

### Family A: Tower-restore-after-crash soundness gaps (open issues + acknowledged TODOs)

**Mechanism**: After a validator crashes/restarts, the persisted tower is loaded and reconciled with the replayed-from-snapshot state. If they disagree, the code falls into specific recovery paths that admit weakened safety guarantees.

**Code evidence**:
- `consensus.rs:881-898` (`is_valid_switching_proof_vote` empty-ancestors branch): returns `Some(true)` for any candidate slot when `last_vote_ancestors` is empty (stray case), with only an `assert!(self.is_stray_last_vote())`. The accompanying ASCII-art argument assumes the stray vote descends from "some earlier root than the latest root" — an unverified geometric claim. **Direct match for open issue #23135.**
- `consensus.rs:975-1005` (`empty_ancestors_due_to_minor_unsynced_ledger`): admits "shouldn't result in slashing by itself" with no proof; substitutes empty ancestors when ledger is missing.
- `consensus.rs:1058-1073` (TODO "Properly handle this case"): "Allowing switch vote on ... because last vote ... was rolled back" — returns `SwitchProof(Hash::default())` with NO switching-threshold verification. **"Freebie vote that may violate switching thresholds."**
- `consensus.rs:1038-1040` (TODO): "Handle if the last vote is on a dupe, and then we restart. The dupe won't be in heaviest_subtree_fork_choice ... but the last vote will be persisted in tower."
- `consensus.rs:1476` (`assert_eq!(slot_history.check(replayed_root), Check::Found)`): hard panic if `replayed_root` is `TooOld` in 1M-slot SlotHistory ring. **Direct match for open issue #23137.**
- `consensus.rs:1493-1500` (`TooOldTower`): silent fallback to bank-derived tower when `--require-tower=false` (the **default** in `ValidatorConfig`). **Issue #25598 calls for using AccountsDB's longer history.**
- `consensus.rs:1631-1647` vs `consensus.rs:706`: divergence between `last_vote.last_voted_slot()` and `vote_state.last_voted_slot()` after restore — `record_bank_vote_and_update_lockouts` panic guard uses `vote_state`, not `last_vote`.
- `consensus.rs:1748-1752` (comment): "we don't impose any ordering guarantee or any kind of write barriers between tower (plain old POSIX fs calls) and blockstore (through RocksDB)".
- `consensus.rs:1781-1789`: "Unfortunately, we can't supply duplicate-confirmed hashes ... correctly overcoming this limitation is hard..."
- `consensus/tower_storage.rs:213-217`: `File::create(.bin.new) → serialize_into → fs::rename`. **No `file.sync_all()`** (commented "hurts performance; pipeline sync-ing and submitting votes to the cluster!"). **No parent dir fsync.**
- `voting_service.rs:114-122`: tower_storage.store is called **before** vote tx broadcast (line 140-149). If validator crashes after store but before send, on-disk tower is updated but the cluster never observed the vote → phantom vote.

**Historical bugs in family**: `cd2878acf`, `ace24a7c8`, `befe8b9d9`, `07955e79a`, `531793b4b`, `3e24b410f`. Open issues: **#23135 (open since 2022), #23137 (open since 2022), #25598 (open since 2022), #34062**.

**TLA+ suitability**: VERY HIGH. The whole class of "tower disagrees with bank state after restart" is exactly the kind of crash-recovery state space a TLA+ spec can enumerate.

**Priority**: HIGH.

---

### Family B: Switch-threshold proof asymmetries (Byzantine-exploitable)

**Mechanism**: `make_check_switch_threshold_decision` is the gatekeeper for switching forks; it accumulates `locked_out_stake` across two distinct code paths and one boolean predicate, each with subtly different filters.

**Code evidence**:
- `consensus.rs:858-925` (`is_valid_switching_proof_vote`): the predicate gating which votes count toward the 38% switch proof. Three sub-cases:
  - Same-fork (descendant) check: `is_descendant_slot(candidate_slot, last_voted_slot)` (line 877).
  - **Empty-ancestors short-circuit (line 881-898)**: returns `Some(true)` for ANY candidate when `last_vote_ancestors.is_empty()` (i.e. stray). **No filter on candidate_slot's relationship to switch_slot.** This is the Family A interaction.
  - GCA-vs-switch_slot check (line 923-924): ensures `switch_slot` descends from GCA(`candidate_slot`, `last_voted_slot`).
- `consensus.rs:1117-1216` (lockout-intervals branch): iterates `lockout_intervals` of each `candidate_slot`'s `fork_stats`, counts `LockoutInterval.start` if `!last_vote_ancestors.contains(start) && start > root`. **Calls `is_valid_switching_proof_vote(*candidate_slot, ...)`** — NOT on `lockout_interval_start`.
- `consensus.rs:1218-1268` (gossip / latest-votes branch): iterates `max_gossip_frozen_votes`, requires `*candidate_latest_frozen_vote > last_voted_slot` AND `is_valid_switching_proof_vote(*candidate_latest_frozen_vote, ...)`. Different inequality (`>` vs `>=`).
- `consensus.rs:1167` (`assert!(!last_vote_ancestors.contains(candidate_slot))`): runtime invariant check on filtered `candidate_slot`. Reachable in pathological cases when stats are partial.
- `consensus.rs:1058-1073` (the duplicate-rollback "freebie vote"): bypasses switch threshold entirely. **TODO admits "may violate switching thresholds".**

**Historical bugs**: `06b098e44` (stray-vote refactor), `1eaa5cf1a` (removed superfluous conditional), `7f3d3ebe3` (stake-check bypass factored out).

**Byzantine exploitability**: combined with Family A or Family F (equivocation), a Byzantine subset could potentially craft a slot graph + vote pattern that triggers the freebie-vote or the empty-ancestors shortcut on a victim validator at restart.

**Priority**: HIGH.

---

### Family C: Tower adoption / non-atomic state updates (residual after `85cc6ace0`)

**Mechanism**: `Tower::vote_state` is the validator's lockout stack; `Tower::last_vote` is the actual transaction broadcast to the cluster; `ForkStats.is_locked_out`/`vote_threshold` is a per-bank cache. These three pieces must all be updated atomically — the historical bug `85cc6ace0` was caused by one (the cache) not being refreshed after `tower.vote_state = bank_vote_state`.

**Code evidence**:
- `replay_stage.rs:4400` (in `adopt_on_chain_tower_if_behind`): `tower.vote_state = bank_vote_state;` — wholesale replacement.
- `replay_stage.rs:4448-4457`: `cache_tower_stats` refresh loop for all `frozen_banks`. **Fix from `85cc6ace0`.**
- `consensus.rs:686-698` (`update_last_vote_from_vote_state`): rebuilds `last_vote` from `vote_state`. **Fix from `329c6f131`.**
- `consensus.rs:696`: `new_vote.set_timestamp(self.maybe_timestamp(self.last_voted_slot().unwrap_or_default()))` — passes OLD `last_voted_slot` (from `last_vote`) to timestamp logic, not the new vote slot.
- `consensus.rs:706-714` (`record_bank_vote_and_update_lockouts` panic): `panic!("VoteTooOld")` if `vote_slot <= vote_state.last_voted_slot()`. Reachable after adoption if a candidate vote bank's slot is now stale.
- `consensus.rs:720-721`: `vote_state.process_next_vote_slot(...)` then `update_last_vote_from_vote_state(...)` — two sequential mutations, no panic-safe rollback.
- `replay_stage.rs:2900` (`tower.record_bank_vote(bank)`) → `2912` (`check_and_handle_new_root`) → `2976` (`push_vote`): three-step non-atomic update of in-memory tower + blockstore root + vote-tx generation.
- `replay_stage.rs:3296-3311` (`push_vote`): creates `SavedTower`, sends on `voting_sender` channel. If the channel send fails or the voting_service thread has crashed, the validator's in-memory tower advances but the on-disk state lags.
- `voting_service.rs:114-119`: `tower_storage.store` is sync but error → `std::process::exit(1)`.
- `consensus/tower1_14_11.rs:22-39`: **`stray_restored_slot`, `last_vote_tx_blockhash`, `last_switch_threshold_check` are `#[serde(skip)]`** — NOT persisted across restart. Reset to defaults on load.

**Historical bugs**: `85cc6ace0`, `329c6f131`, `97efbdc30` (defer tower save until push_vote), `1444baa42`, `fb97e93fe`. **Issues #32880, #35152.**

**Priority**: HIGH (TLA+ should model crash actions that partition durable vs volatile state).

---

### Family D: Optimistic confirmation: hash dropped on the notification path (issue #12307 OPEN)

**Mechanism**: OC accumulation in `track_optimistic_confirmation_vote` is keyed on `(slot, hash)` via the per-hash `VoteStakeTracker`. But the downstream notification `BankNotification::OptimisticallyConfirmed(slot)` carries only the slot. RPC consumers look up `bank_forks.get(slot)` and adopt whichever locally-frozen variant is present — even if the cluster's 0.52 stake voted for a different hash.

**Code evidence**:
- `cluster_info_vote_listener.rs:744` (the notification): `sender.sender.send((BankNotification::OptimisticallyConfirmed(last_vote_slot), dependency_work))`. **Hash dropped here.**
- `rpc/src/optimistically_confirmed_bank_tracker.rs:46`: `pub enum BankNotification { OptimisticallyConfirmed(Slot), ... }` — no hash field.
- `rpc/src/optimistically_confirmed_bank_tracker.rs:297-322` (handler): `let bank = bank_forks.read().unwrap().get(slot);` — slot-only lookup.
- `cluster_info_vote_listener.rs:91, 101-106` (`SlotVoteTracker.optimistic_votes_tracker: HashMap<Hash, VoteStakeTracker>`): per-hash storage.
- `cluster_info_vote_listener.rs:940-955`: `track_optimistic_confirmation_vote` keys on hash correctly.
- `cluster_info_vote_listener.rs:727`: **`duplicate_confirmed_slot_sender.send(vec![(last_vote_slot, last_vote_hash)])`** — the duplicate-confirm path *does* preserve the hash. So only the RPC OC notification path drops it.

**Detection vs prevention**: the duplicate-confirm path will eventually catch hash divergence via `check_slot_agrees_with_cluster` (`replay_stage.rs:2502-2515`), which **`assert_eq!(prev_hash, ...)` panics** on contradiction (Family E). So RPC may transiently report wrong hash; replay-stage will eventually crash if it observes both hashes confirmed.

**Historical bug**: `3e6f0e9f9` (`return` → `break` in OC loop — superficially related, but the deeper hash-drop is still present). **Open issue #12307.**

**Priority**: MEDIUM-HIGH (RPC observability + interaction with Family F).

---

### Family E: Per-hash stake counting + Byzantine equivocation enables OC double-counting

**Mechanism**: `VoteStakeTracker` deduplicates voters within a single `(slot, hash)` bucket via `HashSet<Pubkey>`. But across two distinct hashes for the same slot — Byzantine equivocation — the same validator's stake is counted under BOTH buckets. Combined with the `latest_vote_slot_per_validator` filter being slot-only (line 807-810), the gossip path doesn't reject the equivocation upstream.

**Code evidence**:
- `consensus/vote_stake_tracker.rs:14-38`: `add_vote_pubkey` — `is_new = !self.voted.contains(&vote_pubkey)`. Per-tracker, not per-validator.
- `cluster_info_vote_listener.rs:91`: `optimistic_votes_tracker: HashMap<Hash, VoteStakeTracker>` — separate counter per hash.
- `cluster_info_vote_listener.rs:807-810`: `filter(|slot| **slot > root && **slot >= *latest_vote_slot)` — `>=` is permissive; same-slot different-hash votes pass.
- `consensus/latest_validator_votes_for_frozen_banks.rs:51-68`: when same validator's vote arrives for same `vote_slot` but different `frozen_hash`, the new hash is **appended** to `latest_frozen_vote_hashes`. (Bug `985c0dcdd` fix.)
- `consensus/vote_stake_tracker.rs:27-33`: threshold-crossing check uses `(total_stake as f64 * threshold) as u64` — **f64 precision loss** at mainnet stake totals (~2^58, beyond f64's 53-bit mantissa).

**TLA+ suitability**: VERY HIGH — Byzantine equivocation against threshold accounting is a classical BFT modeling target.

**Priority**: HIGH (composes with Family D and Family A).

---

### Family F: Detection-only OC violation tracking (under-detects + log-only)

**Mechanism**: `OptimisticConfirmationVerifier` watches for OC slots that don't get rooted. It uses slot-only ancestry checks; a slot in `root_bank.ancestors` with a DIFFERENT hash than the OC'd one is silently NOT flagged.

**Code evidence**:
- `optimistic_confirmation_verifier.rs:42-53`: detection logic:
  ```rust
  (*optimistic_slot == root && *optimistic_hash != root_bank.hash())
      || (!root_ancestors.contains_key(optimistic_slot) &&
          !blockstore.is_root(*optimistic_slot))
  ```
  Hash comparison ONLY for the `slot == root` case. For ancestor slots, the check is slot-only — a rooted ancestor with different hash is missed.
- `optimistic_confirmation_verifier.rs:68-83` (`add_new_optimistic_confirmed_slots`): `if new_optimistic_slot > self.snapshot_start_slot` — strict `>`, silently drops slot equal to snapshot start.
- `optimistic_confirmation_verifier.rs:88-90`: result is logged via `error!` and `datapoint_warn` — **no enforcement, no slashing, no shutdown**.
- Open issues **#7521 (slashing v0)**, **#8113 (no fail-stop)**, **#6962 (single-implementation security)** all admit the design depends on social/operational response rather than protocol-enforced rejection.

**Priority**: MEDIUM (TLA+ can verify the under-detection; the lack of enforcement is a design choice the brief should NOT propose to change).

---

### Family G: Duplicate-confirmed assertion panics (DoS surface)

**Mechanism**: When a duplicate-confirmed-hash differs from a previously-seen one, the replay thread **panics**. Combined with Family D (RPC drops hash) and Family E (Byzantine equivocation can drive both hashes to threshold), this is a denial-of-service vector.

**Code evidence**:
- `replay_stage.rs:2508-2512` (`process_duplicate_confirmed_slots`): `assert_eq!(prev_hash, duplicate_confirmed_hash, ...)` panics on mismatch. **`progress.set_duplicate_confirmed_hash` happens BEFORE the assert** (line 4679 in `mark_slots_duplicate_confirmed`), so partial state update precedes panic.
- `replay_stage.rs:4681-4685` (`mark_slots_duplicate_confirmed`): same pattern.
- `consensus.rs:1088`: `panic!("no ancestors found with slot: {last_voted_slot}")` — reachable in non-stray case if pruning races.
- `consensus.rs:1104`: `panic!("Should never consider switching to ancestor ({switch_slot}) of last vote ...")`
- `consensus.rs:708`: `panic!("Error while recording vote {} {} in local tower {:?}", ..., VoteError::VoteTooOld)`.
- `voting_service.rs:118`: `std::process::exit(1)` on tower-storage error.
- `replay_stage.rs:3301`: `std::process::exit(1)` on `SavedTower::new` failure.

**Priority**: MEDIUM (DoS, not safety; but worth flagging for code review).

---

### Family H: Set-identity hot-swap interactions (known critical fixes, residual gaps)

**Mechanism**: Validators support runtime identity rotation (`set-identity` admin RPC). The tower is identity-specific; failing to reload on identity change leaves the validator running with another identity's lockout history.

**Code evidence**:
- `replay_stage.rs:1386-1414`: set-identity tower-reload only triggered inside the **`else` branch where `last_reset != reset_bank.last_blockhash()`** (the fork-reset branch). If no fork-reset event occurs, identity change is deferred.
- `consensus.rs:1638-1646`: after `adjust_lockouts_with_slot_history`, `stray_restored_slot = self.last_vote.last_voted_slot()` — but if the loaded tower was the WRONG identity's, this is a vote that this identity never authorized.
- Historical: **`befe8b9d9`** (reload tower if set-identity during startup), **`07955e79a`** (graceful exit on tower load failure).
- Open issues **#8752** (gossip duplicate-instance double-panic), **#35152** (set-identity while waiting for supermajority).

**Priority**: MEDIUM (multiple historical CRITICAL fixes; residual issues mostly operational/observability).

---

### Family I: Selfish-mining / minority over-commitment (#7087)

**Mechanism**: A small minority (5%) of validators with consecutive leader rotations can build aggressive lockouts on a private fork, withhold the votes, then release them; the majority is forced into deep lockouts on the wrong fork.

**Historical**: Issue **#7087** closed under v1.8.0, but the mitigation is "fork-weight heuristics" rather than a hard rule. The 4-deep@38% threshold (`07f38838a`/`6859d652b`/PR #34120 — log-only currently) is the closest preventive measure.

**Priority**: LOW for TLA+ (the parameter space and selfish-mining strategy is well-understood theoretically; modeling adds little).

---

## Phase 3 — Findings unconnected to a family

These don't form a coherent family but are worth recording.

- `consensus.rs:1305-1307` (`is_first_switch_check`): tracks first-ever switch check, used only to gate a warn log. Never reset across votes → warn fires at most once per process lifetime.
- `consensus.rs:799-801` (`Tower::root().unwrap()`): unconditional unwrap on `vote_state.root_slot`. Invariant currently holds via all constructors but is informal.
- `consensus.rs:848` (`assert!(ancestors.contains(&root_slot))` in `is_locked_out`): comment "This case should never happen because bank forks purges all non-descendants of the root every time root is set" — depends on caller's lock discipline.
- `consensus/tower_storage.rs:25-53` (`try_into_tower`): signature verification uses validator's own pubkey — doesn't defend against insider with disk access (out of typical threat model).
- `consensus/tower_storage.rs:116-118` (`TowerStorage: Sync + Send` + `FileTowerStorage::store(&self, ...)`): no internal lock on concurrent writes. By convention only `voting_service` writes, but `Tower::save` is `pub` and reachable from any thread.
- `consensus/tower_storage.rs:121-134` (`NullTowerStorage`): wired into `ValidatorConfig::default()` (`validator.rs:428`). Test-only by convention, not by type.
- `cluster_info_vote_listener.rs:530-559` (`filter_verified_votes`): authorized-voter check uses `vote.last_voted_slot()` to pick epoch — votes spanning an epoch boundary may use the wrong authorized voter for earlier slots.
- `cluster_info_vote_listener.rs:236-245`: `debug_assert!(false, ...)` for duplicate Executed replay votes — silent drop in release builds.
- `consensus/tower_vote_state.rs:75-79` (`double_lockouts`): `i.checked_add(v.confirmation_count() as usize).expect(...)` — could panic if a self-signed corrupted tower has `confirmation_count` > MAX_LOCKOUT_HISTORY.
- `commitment_service.rs:246-280`: own-validator vote state from local tower can lead local commitment cache to report finalization before the vote tx has actually landed in the cluster.

---

## Coverage notes / known limitations

- **`heaviest_subtree_fork_choice.rs` (4687 LOC)** was NOT deep-read by a dedicated subagent. Bug archaeology surfaced `6a9f72910` (u64 overflow in fork_weight) and `504f2ee89` (deepest-slot metric). Future analysis rounds should give this file a dedicated pass — the fork-choice algorithm has its own correctness invariants.
- **`progress_map.rs`** (661 LOC) was not deep-read. The `ForkStats` cache freshness story (Family C) is the most prominent concern but other locks/invariants in this file could harbor issues.
- **`cluster_slots_service`** files (cluster_slots.rs, slot_supporters.rs) — these support repair, not consensus directly. Out of scope.
- **Repair stage** (`core/src/repair/`) interactions with consensus (e.g., `ancestor_hashes_service.rs` triggers duplicate-detection) were touched lightly. The dump-and-repair flow (Family C-adjacent) was characterized via archaeology.

---

## Reference pointers (for the spec author)

- **Most-relevant TODOs in code**:
  - `consensus.rs:1038-1040` — restart with last vote on a dupe
  - `consensus.rs:1066` — freebie vote may violate switch threshold
  - `consensus.rs:549` — populate_ancestor_voted_stakes only adds zeros
  - `latest_validator_votes_for_frozen_banks.rs:11` — clean outdated/unstaked pubkeys
  - `replay_stage.rs:2028` — alternate version of descendant confirmed after ancestor
  - `replay_stage.rs:2283` — RPC queries holding stale Bank
  - `replay_stage.rs:3621` — thread-safety of blockstore replay results
- **Comments admitting safety gaps**:
  - `consensus.rs:1748-1752` — tower↔blockstore not write-ordered
  - `consensus.rs:1781-1789` — can't supply duplicate-confirmed hashes on root reconciliation
  - `consensus.rs:975-1005` — "shouldn't result in slashing" but no proof
- **Open Solana issues to keep in modeling rationale**:
  - **#23135** — stray vote + switching violation (DIRECT modeling target)
  - **#23137** — snapshot >512 slots ahead of vote
  - **#12307** — OC notification drops hash
  - **#8752** — gossip duplicate-instance double-panic
  - **#7087** — selfish mining
- **Production incidents to cite as motivation**:
  - 2021-09 — Mainnet outage (tx flood + fork divergence)
  - 2023-11-03 — High latency event leading to PR #34120
  - 2023-03 — Testnet roots-stall (gossip vote drop, PR #31954)
  - 2023-08 — v1.14↔master MNB consensus divergence (vote-credit off-by-one)
