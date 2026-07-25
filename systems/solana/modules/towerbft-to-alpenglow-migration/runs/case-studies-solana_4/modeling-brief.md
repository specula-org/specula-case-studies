# Modeling Brief: Solana TowerBFT ⇄ Alpenglow Migration (`anza-xyz/agave`)

## 1. System Overview

- **System**: `anza-xyz/agave` — Solana validator client, mainnet-deployed. HEAD `21fb994c21` (2026-05-19, master). Tower BFT is the *current* production consensus; **Alpenglow / Votor is the next-gen BFT protocol actively being upstreamed** (89 commits to `votor/` in the last 6 months).
- **Language**: Rust. Scope of this brief: ~8 KLOC AG core (`votor/src/`) + ~780 LOC migration state machine (`votor-messages/src/migration.rs`) + ~2 KLOC of Tower BFT migration-boundary code (`core/src/consensus.rs`, `core/src/replay_stage.rs` migration paths).
- **System category**: **Category A (Distributed / Message-Passing)** with a **Byzantine threat model**. Sub-category: **multi-protocol coexistence** — TowerBFT (vote-lockout, 1/3 Byzantine tolerance) and Alpenglow (quorum-cert "20+20" model: 20% Byzantine + 20% offline) run *simultaneously* during the migration epoch. Each protocol assumes its own threshold model; the migration protocol bridges them.
- **Protocol**: Migration is a self-contained 5-phase state machine: `PreFeatureActivation` → `Migration` → `ReadyToEnable` → `AlpenglowEnabled` → `FullAlpenglowEpoch`. Key invariant: during `Migration`, the cluster discovers a *single* "genesis block" `G` that becomes the root of Alpenglow's chain; ≥82% stake must vote `Vote::Genesis(G)` to mint a `CertificateType::Genesis(G)`. Threshold algebra: `SWITCH_FORK_THRESHOLD (38%) − (1 − GENESIS_VOTE_THRESHOLD (82%)) = MIGRATION_MALICIOUS_THRESHOLD (20%)` — so unique super-OC requires < 20% double-voters.
- **Key architectural choices deviating from textbook BFT**:
  - **Cluster-wide protocol cutover via on-chain feature flag** (`agave_feature_set::alpenglow`). Once a slot activates the feature, all validators count `MIGRATION_SLOT_OFFSET=5000` slots and start the migration. The cutoff is *local* — each validator independently computes it from the on-chain feature record of a *rooted* slot.
  - **Three writers to `BankForks`** after AG: replay, block-creation-loop, votor (set_root). Caused production deadlock (#12039); mitigated by serializing back to replay (#12448).
  - **Genesis cert auto-promotes block to notar-fallback-or-stronger** at `consensus_pool.rs:379-380` — used internally as an implicit `NotarizeFallback`-equivalent for parent-ready tracking, but **not** exposed by the public `block_has_notar_fallback_or_stronger()` query (`B3` below).
  - **Per-hash duplicate-block pools** for Notarize and NotarizeFallback (`DuplicateBlockVotePool`), but **per-pubkey simple pools** for all other vote types (`SimpleVotePool`), including Genesis. Mixed-mode bookkeeping recurrence of historical bug fixed in `76a83971e5`.
  - **No fsync on vote history** (`vote_history_storage.rs:155-170`) — same tradeoff as Tower BFT's tower file.
  - **`MigrationStatus` panics on bad inputs in many places** (`assert_eq!`, `unreachable!`, `panic!`). Recent fix `f0ceb8a852` relaxed two of the worst races, but downstream `assert!(is_ready_to_enable())` callers re-introduce them.
- **Concurrency model**: Old TBFT model + AG additions = 5+ writers/readers of shared state. Replay (writer of bank_forks, mutator of MigrationStatus phase), VotingService (Tower tx + tower save), PohService (ticks), BlockCreationLoop (AG block production), EventHandler (AG voting), ConsensusPoolService (cert ingest), BlsSigverifier (sig verify).
- **Prior briefs already covered**: solana_2 and solana_3 are the canonical Tower BFT briefs. Both *explicitly* placed Votor / Alpenglow out of scope. **This brief covers exactly that boundary** plus the AG pool that runs post-migration.

## 2. Bug Families

### Family 1: Migration Phase Transitions — TOCTOU and Adversarial Assertion Triggers — HIGH

**Mechanism**: `MigrationStatus` has 5 phases guarded by `RwLock<MigrationPhase>` plus two atomics (`shutdown_poh`, `poh_service_started`). Multiple threads (replay_stage main loop, block_component_processor in replay, gossip-driven cert ingest in consensus_pool) call `set_genesis_block`, `set_genesis_certificate`, and `is_ready_to_enable` *without* a single critical section spanning their dependency. Each call point assumes a phase that another thread can advance past, and uses `assert!` / `panic!` on violation.

**Evidence**:
- Historical: `f0ceb8a852` (#11727, 2026-04-02) — race between `set_genesis_block` and concurrent `enable_alpenglow`; previously `unreachable!` panic, now silent return. Fix relaxes the *immediate* assertions but not the *downstream* `assert!`.
- Historical: `9d9a1f93a8` (#12225) — `account for PohService during startup migration` — same race in startup path.
- Historical: `813aede070` (#12025) — `startup replay: upstream migration status during startup` — migration state needs to be reconstructed from genesis cert + feature flag on snapshot restart; no fincert in snapshot (open #12364).
- Code analysis: `runtime/src/block_component_processor.rs:260-267` — `assert!(migration_status.is_ready_to_enable())` after `set_genesis_certificate` that may silently no-op (Finding A4).
- Code analysis: `votor-messages/src/migration.rs:597-600` — `assert!(slot < migration_slot)` panics on attacker-constructed Genesis cert (Finding A1).
- Code analysis: `votor-messages/src/migration.rs:683-701` — `enable_alpenglow_during_startup` TOCTOU on `poh_service_started` (Finding A6).
- Code analysis: `core/src/replay_stage.rs:1633-1645` — `panic!` when local `genesis_bank.block_id() ≠ certified block_id`; no recovery (Finding A5).

**Affected code paths**:
- `MigrationStatus::set_genesis_block` (`votor-messages/src/migration.rs:508-568`)
- `MigrationStatus::set_genesis_certificate` (`votor-messages/src/migration.rs:574-622`)
- `MigrationStatus::enable_alpenglow_during_startup` (`votor-messages/src/migration.rs:671-702`)
- `MigrationStatus::initialize` for snapshot restart (`votor-messages/src/migration.rs:373-413`)
- `MigrationStatus::poh_service_is_shutting_down` (`votor-messages/src/migration.rs:652-665`)
- `ReplayStage::enable_alpenglow` (`core/src/replay_stage.rs:1610-1704`)
- `BlockComponentProcessor::set_alpenglow_genesis_certificate` (`runtime/src/block_component_processor.rs:240-270`)
- `Consensus_pool::insert_certificate` (`votor/src/consensus_pool.rs:374-381`)

**Suggested modeling approach**:
- **Variables**:
  - `migration_phase[v] ∈ {PreFFA, Migration(ms, gb?, gc?), ReadyToEnable(gc), AlpenglowEnabled(gc), FullAGEpoch(gc, e)}`
  - `ff_activation_slot[v]`, `migration_slot[v]`, `genesis_block_view[v]`, `genesis_cert_view[v]`
  - `poh_service_started[v] ∈ BOOLEAN`, `shutdown_poh[v] ∈ BOOLEAN`
  - `crashed[v] ∈ BOOLEAN` for crash/restart composition
- **Actions** (one per transition point):
  - `RecordFeatureActivation(v, slot)` — PreFFA → Migration
  - `DiscoverSuperOC(v, fork)` → calls `SetGenesisBlock(v, b)` for the discovered block
  - `SetGenesisBlock(v, b)` — three outcomes: (a) sets gb in Migration phase; (b) silently returns post-Migration; (c) panics if gb already set to different block (A3)
  - `SetGenesisCertificate(v, cert)` — three outcomes mirroring (a)/(b)/(c)
  - `EnableAlpenglow(v)` — ReadyToEnable → AlpenglowEnabled (via PoH shutdown protocol)
  - `EnableAlpenglowDuringStartup(v)` — variant for the startup path (A6 race)
  - `Crash(v)`, `Recover(v)` — `Recover` calls `Initialize(root_epoch, ff_slot, cert)`
  - `IngestGenesisCert(v, cert)` — adversary-controlled action: receive cert from gossip and call SetGenesisCertificate; the cert's slot can be adversary-chosen (A1)
- **Granularity**: each panic site becomes a *guarded* action — invariant `MigrationDoesNotPanic` asserts the precondition implied by the panic. If TLA+ finds a reachable state where the precondition fails, that's the bug.
- **Invariants**:
  - `GenesisBlockUnique`: at most one `discovered_genesis_block[v]` value per validator across all forks
  - `SetGenesisCertificateAssertion`: `cert.cert_type.slot() < migration_slot[v]` when received
  - `IsReadyToEnableAfterSetCert`: after a sequence `set_genesis_block; set_genesis_certificate;` on the same execution, phase ∈ {ReadyToEnable, AlpenglowEnabled} (A4)

**Priority**: **High**
**Rationale**: 5+ recent commits in this exact area, including a directly safety-relevant race fix (#11727). Multiple open issues (#12039 deadlock in adjacent code). The migration is a *one-time* event but happens to every cluster — a panic crashes all validators that ingest the trigger condition.

---

### Family 2: Super-OC Discovery — Fork-Agnostic Stake Counting — HIGH

**Mechanism**: `parent_is_super_oc` is computed per-fork by summing `voted_stake` for every vote-account whose `last_voted_slot()` (read from the bank's on-chain vote state) equals `parent_slot`. The slot equality check is *fork-agnostic* — a Byzantine validator who equivocates by landing votes on two forks at slot N produces two valid bank states each crediting that validator to that fork's super_oc_stake.

**Evidence**:
- Code analysis: `core/src/consensus.rs:481-484` — `if last_landed_voted_slot == parent_slot { super_oc_stake += voted_stake; }` (Finding A2)
- Code analysis: `core/src/consensus.rs:545-547` — `parent_is_super_oc = bank_slot == parent_slot + 1 && Fraction::new(super_oc_stake, total_stake) > GENESIS_VOTE_THRESHOLD`
- Code analysis: `core/src/replay_stage.rs:4374-4405` — when `parent_is_super_oc`, the latest ancestor `< migration_slot` is chosen as the genesis block and `set_genesis_block` is called (which triggers Family 1's panic when called twice with different values).
- Design constraint: protocol invariant says "less than 20% double-voters" guarantees unique super-OC. The arithmetic is `SWITCH_FORK_THRESHOLD (38%) − (1 − GENESIS_VOTE_THRESHOLD) = MIGRATION_MALICIOUS_THRESHOLD (20%)`. But the *implementation* counts Byzantine equivocators once per fork, so under exactly the 20% limit, the per-fork accounting may admit two forks to BOTH cross 82%.

**Affected code paths**:
- `Tower::collect_vote_lockouts` / `compute_bank_state` (`core/src/consensus.rs:407-602`)
- `ReplayStage::compute_bank_stats` migration branch (`core/src/replay_stage.rs:4374-4405`)
- `MigrationStatus::set_genesis_block` (Family 1's panic site)

**Suggested modeling approach**:
- **Variables**:
  - `landed_votes[v, fork, slot] : Pubkey ↦ block_id` — what's on-chain in this validator's view of this fork
  - `super_oc_stake[v, fork, parent_slot] : Stake`
  - `discovered_genesis_block[v, fork] : Option<Block>`
- **Actions**:
  - `LandVote(byz, fork, slot, hash)` for Byzantine equivocator — appends to `landed_votes[*, fork, slot]` (each fork's view potentially independent)
  - `ComputeSuperOC(v, fork, parent_slot, bank_slot)` — sums per-fork landed votes, sets `parent_is_super_oc`
  - `DiscoverGenesisBlock(v, fork)` — calls `SetGenesisBlock` on the chosen ancestor
- **Invariants**:
  - `UniqueSuperOC`: For any (parent_slot), the set `{fork : parent_is_super_oc[*, fork, parent_slot] = true}` has cardinality ≤ 1 — OR Byzantine equivocators exceed `MIGRATION_MALICIOUS_THRESHOLD = 20%`.
  - `GenesisBlockAgreement`: For any two honest validators v1, v2: `discovered_genesis_block[v1] = discovered_genesis_block[v2]` if both are defined.
- **Granularity**: distinguish (a) Byzantine validators equivocating across forks; (b) the *symmetric* honest computation across forks; (c) the threshold check. The TLA+ check verifies whether the 20% bound is actually tight or if the implementation needs `< 18%` due to double-counting.

**Priority**: **High**
**Rationale**: The "20+20" model's tightness depends on this. If the threshold is actually breakable at < 20%, that's a protocol-level bug. Even if not, the modeling clarifies the operating envelope. Combined with Family 1's panic, the failure mode is *immediate cluster crash* once any validator discovers two competing super-OC forks.

---

### Family 3: Genesis Vote Pool — Per-Hash Counting Missing — HIGH

**Mechanism**: Genesis votes carry a `block_id` (per `vote_to_cert_types`), but are routed to `SimpleVotePool` (which does *not* segregate by `block_id`). The cert-assembly path reads `pool.total_stake()` — sum of all Genesis vote stakes regardless of block_id — and compares to the 82% threshold. Once 82% accumulates *across both* block_id buckets, a cert with `cert_type = Genesis(slot, block_id_X)` is built whose BLS aggregate includes signatures over BOTH `Vote::Genesis(slot, X)` and `Vote::Genesis(slot, Y)`. The local validator broadcasts a malformed cert and may panic if the cert's `block_id` differs from its own `discovered_genesis_block`.

**Evidence**:
- Historical: `76a83971e5` (#9394, 2025-12-03) — *exact same bug class* was previously fixed in the deprecated `collect_votes` method. The refactor that removed `collect_votes` reintroduced the issue via pool-routing.
- Code analysis: `votor/src/consensus_pool.rs:173-183` — `_ => VotePool::SimpleVotePool(...)` catches Genesis (Finding B1).
- Code analysis: `votor-messages/src/consensus_message.rs:206` — `CertificateType::Genesis(_, _) => (GENESIS_VOTE_THRESHOLD, &[VoteType::Genesis])`.
- Code analysis: `votor/src/consensus_pool.rs:230-244` — `update_certificates` accumulated_stake = `pool.total_stake()` for SimpleVotePool.
- Code analysis: `votor/src/consensus_pool.rs:251-264` — `cert_builder.aggregate(pool.votes())` aggregates all votes without filtering by block_id.

**Affected code paths**:
- `ConsensusPool::new_vote_pool` (`consensus_pool.rs:173-183`)
- `ConsensusPool::update_certificates` (`consensus_pool.rs:213-272`)
- `CertificateBuilder::aggregate` for `SingleVote` builder (`certificate_builder.rs:198-205`)

**Suggested modeling approach**:
- **Variables**:
  - `genesis_votes[v, slot, block_id] : SUBSET Pubkey` (per-hash dedup applied)
  - `genesis_pool_total_stake[v, slot] : Stake` (the SimpleVotePool's view — sum across hashes)
  - `genesis_certs_built[v, slot] : Set<Certificate>` (locally produced)
- **Actions**:
  - `CastGenesisVote(v, slot, block_id)`
  - `IngestGenesisVote(v, voter, slot, block_id)` — adds to pool
  - `BuildGenesisCert(v, slot)` — if `genesis_pool_total_stake[v, slot] ≥ 82%`, builds cert with the *current* vote's block_id
- **Invariants**:
  - `GenesisCertWellFormed`: every locally built Genesis cert has its block_id supported by `≥ 82%` stake voting for that specific block_id (not summed across hashes).
  - `GenesisCertSafety`: at most one block_id reaches 82% with honest-only votes; under ≥ 20% Byzantine equivocation, two block_ids reaching threshold composes with Family 1/2 panics.

**Priority**: **High**
**Rationale**: A regression of a known-and-fixed bug at a different code site. The recent fix in `76a83971e5` is a *single line* — but it was in the deprecated path. The current architecture re-introduced the bug via routing choice. Compounds with Family 2 (panic on second `set_genesis_block`).

---

### Family 4: Alpenglow Pool Bounds and DoS Assertions — HIGH

**Mechanism**: `parent_ready_tracker` and `consensus_pool` use `assert!` macros with bounds derived informally; under valid (signed) external certs, these bounds can be exceeded. Each panic is a DoS — a Byzantine adversary who can convince honest validators to mint or relay certs that push the count past the bound crashes all of them.

**Evidence**:
- Historical: `9665d09c22` (#12327) — assertion `<= MAX_ENTRIES_PER_PUBKEY_FOR_NOTARIZE_LITE (3)` was wrong; raised to `MAX_NOTAR_FALLBACK_BLOCKS = 7`. The *new* bound is informally justified ("fix wrong assertion threshold") with no proof.
- Re-derivation (analysis-report.md §4.2 B2): 4 × 80% honest + Byzantine 20% × X ≥ 60% × X → X ≤ 8. Plus Genesis at the same slot: X = 9. So 7 is *too tight* under the protocol's stated 20% Byzantine threshold.
- Code analysis: `parent_ready_tracker.rs:111` — `assert!(status.notar_fallbacks.len() <= MAX_NOTAR_FALLBACK_BLOCKS);` (Finding B2).
- Code analysis: `consensus_pool.rs:90-94` — panic in `get_key_and_stakes` if `entry.stake == 0` "should never happen, there is no rank for zero stake" — adversary controls the on-chain stake state during stake decay.
- Code analysis: `consensus_pool.rs:430-433` — `assert_ne!(validator_stake, 0)` same site duplicated.
- Code analysis: `consensus_pool.rs:236-242` — `panic!("Duplicate block pool for {vote_type:?} expects a block id for certificate {cert_type:?}")` — relies on caller invariant.

**Affected code paths**:
- `ParentReadyTracker::add_new_notar_fallback_or_stronger` (`parent_ready_tracker.rs:93-138`)
- `ConsensusPool::get_key_and_stakes` (`consensus_pool.rs:74-100`)
- `ConsensusPool::add_vote` and `update_certificates` (`consensus_pool.rs:416-485`, `213-272`)

**Suggested modeling approach**:
- **Variables**:
  - `notar_fallbacks[slot] : SUBSET Hash` (distinct block_ids with NotarFallback cert)
  - `notarize_votes[v, slot, block_id] : Stake`, `notarize_fallback_votes[v, slot, block_id] : Stake`
  - `byzantine_stake`, `offline_stake`, `honest_active_stake`
- **Actions**:
  - `HonestNotarizeFallbackVote(v, slot, block_id)` (each honest validator can vote NotarizeFallback for ≤ 3 distinct block_ids per slot)
  - `ByzantineNotarizeFallbackVote(v_byz, slot, block_id)` — Byzantine can vote for arbitrarily many
  - `BuildNotarFallbackCert(slot, block_id)` — if stake ≥ 60%, create cert; passes to add_new_notar_fallback_or_stronger
- **Invariants**:
  - `NotarFallbackBoundedByProtocol`: `|notar_fallbacks[slot]| ≤ 8` (computed bound, not the implementation's 7).
  - `AssertionDoesNotFire`: `|notar_fallbacks[slot]| ≤ MAX_NOTAR_FALLBACK_BLOCKS = 7` (implementation invariant) is checked; if TLA+ finds a reachable state with 8 entries, the implementation assertion needs adjustment.

**Priority**: **High**
**Rationale**: DoS via valid protocol moves. The "fix" `9665d09c22` is *recent and informal*. Either the bound is wrong, or the protocol parameters need tightening — TLA+ checks which.

---

### Family 5: Vote History Persistence and Restart — HIGH

**Mechanism**: Alpenglow's `VoteHistory` is the equivalent of Tower BFT's `Tower` — but inherits the same bug class. `add_vote` mutates in-memory state *before* the vote is successfully sent; `generate_vote_tx` may fail (NoRankFound, NoAuthorizedVoter, HotSpare, etc.) leaving in-memory state advanced but no BLSOp emitted. No rollback path exists. `set_root` mutates in-memory state but does not persist. The on-disk file has no fsync (same documented tradeoff as TBFT).

**Evidence**:
- Code analysis: `votor/src/voting_utils.rs:233-277` — `add_vote` before `generate_vote_tx` (Finding C1).
- Code analysis: `votor/src/vote_history.rs:238-249`, callers in `votor/src/root_utils.rs:35-82` — `set_root` not persisted (Finding C3).
- Code analysis: `votor/src/vote_history_storage.rs:155-170` — no fsync, documented as tradeoff (Finding C2).
- Code analysis: `votor/src/voting_service.rs:204-225` — persist then broadcast.
- Adjacent TBFT history: solana_3 brief Family A is the exact same mechanism for Tower BFT.
- Open issue: #12364 — "No finalization certificate in snapshot" — on restart from snapshot, pool initializes without finalization cert.

**Affected code paths**:
- `VoteHistory::add_vote` (`vote_history.rs:164-203`)
- `VoteHistory::set_root` (`vote_history.rs:238-249`)
- `voting_utils::insert_vote_and_create_bls_message` (`voting_utils.rs:233-277`)
- `voting_utils::generate_vote_message` (`voting_utils.rs:279-300`)
- `VoteHistoryStorage::store` (`vote_history_storage.rs:155-170`)
- `VotingService::handle_vote` (`voting_service.rs:200-260`)

**Suggested modeling approach**:
- **Variables**:
  - `vote_history_in_mem[v]`, `vote_history_on_disk[v]`, `voting_channel[v] : Seq<BLSOp>`
  - `cluster_observed_votes[v] : Set<Vote>` — what's been actually transmitted
- **Actions**:
  - `RecordVote(v, vote)` — in-mem add
  - `GenerateVoteTxSuccess(v, vote)` — sends BLSOp
  - `GenerateVoteTxFail(v, vote)` — leaves in-mem advanced, no BLSOp
  - `PersistVoteHistory(v)` — voting service does the actual store
  - `Crash(v)`, `Recover(v)` — discards in-mem, loads on-disk
  - `SetRoot(v, slot)` — in-mem only; persist deferred
- **Invariants**:
  - `NoDoubleVotePostRestart`: After Crash+Recover, the first vote v issues has type/slot consistent with `cluster_observed_votes[v]`.
  - `VoteHistoryMonotonicAcrossRoots`: root persisted ≥ all root values observed.

**Priority**: **High**
**Rationale**: Direct parallel of Tower BFT's well-known Family A (covered in solana_3); same mechanism re-implemented for AG. Standard crash-modeling territory; AG's reliance on BLS signatures doesn't change the persistence model bug.

---

### Family 6: Standstill / Liveness Detection — MEDIUM

**Mechanism**: Standstill detection in `event_handler.rs` is supposed to detect when the cluster stops finalizing and trigger vote/cert re-broadcasts to recover. The implementation has multiple liveness-impacting bugs: missing re-broadcast (#12232), wrong slot stored (#12350, fixed), missing reset of `standstill_slot` on newer finalized (Finding C4), and metrics resets (#12373, #12374).

**Evidence**:
- Historical (closed): `3651df65ed` (#12350), `2028c58fba` (#12374), bug from #12232 about missing cert re-broadcast.
- Historical (closed): `1b6a85a234` (#12439) — `do not scale DELTA_BLOCK during standstill`.
- Historical (closed): `6b40f5b0a3` (#12462) — `account for Turbine latency in DELTA_TIMEOUT`.
- Code analysis: `event_handler.rs:485-508` — `match standstill_slot { Some(_) => { debug_assert_eq!(...); if ... warn! } }` does NOT update standstill_slot on newer finalized (Finding C4).
- Code analysis: `event_handler.rs:436-461` — Finalized handler only resets if `block.0 > standstill_slot` (Finding C8).
- Open: timer manager interactions with `consensus_pool_service.rs:256-266` re-emission.

**Affected code paths**:
- `EventHandler::process_event` Standstill / Finalized branches (`event_handler.rs:436-508`)
- `ConsensusPoolService` standstill timer + emit (`consensus_pool_service.rs:256-266`)
- `TimerManager::calculate_timeout_multiplier` (`timer_manager/timers.rs:19-28`)
- `ConsensusPoolServiceStats::standstill` (`consensus_pool_service/stats.rs:96-101`)

**Suggested modeling approach**:
- **Variables**:
  - `standstill_slot[v] : Option<Slot>`, `highest_finalized_slot[v] : Slot`, `last_finalized_event_seen[v] : Slot`
  - `timer_multiplier[v, slot] : Real` (computed from standstill_slot)
- **Actions**:
  - `EmitStandstill(v, hf_slot)`, `EmitFinalized(v, block)`, `ProcessStandstill`, `ProcessFinalized`
  - `ComputeTimeout(v, slot)` — uses standstill_slot
- **Invariants**:
  - `StandstillEventuallyCleared`: if `highest_finalized_slot` advances past `standstill_slot`, then `standstill_slot` becomes None within bounded steps.
  - `TimeoutMultiplierBounded`: `timer_multiplier[v, slot] ≤ some_protocol_bound` for all reachable states.

**Priority**: **Medium**
**Rationale**: Liveness bugs, not safety. Family 6 includes multiple already-fixed bugs that share the same *mechanism* (post-finalization state machine handling stale finalized_slot views). Modeling exposes whether the current code's invariants are correct or if more bugs hide in the same family.

---

### Family 7: BankForks Multi-Writer Coordination Under AG — MEDIUM

**Mechanism**: Pre-AG, only replay_stage writes `BankForks`. Post-AG, replay, block-creation-loop, and votor's set_root all write — producing a triple-thread deadlock pattern (open #12039) when the locks taken on `RwLock<BankForks>` interleave with locks taken by replay (which holds bank_forks while doing other operations). Mitigated by serializing writes back to replay (#12448), but the underlying multi-writer ownership is unchanged.

**Evidence**:
- Open: #12039 — "triple thread deadlock w/ alpenglow". Production-observed.
- Historical: `52446464d5` (#12448) — `votor: serialize bank forks writes back to replay thread`.
- Historical: `121b9eda08` (#11753) — `replay: upstream switching duplicate banks on ParentReady` — duplicate bank handling, cross-protocol.
- Historical: `ee2d9dc201` (#12006) — `replay: address reentrant locking with Bank::new_from_parent`.
- Code analysis: `replay_stage.rs:1555-1601` — `alpenglow_handle_newly_frozen_banks`, mutates state without bank_forks lock.

**Affected code paths**:
- `BankForks::insert` / `set_root` / `prune_program_cache` — multiple callers
- `ReplayStage::alpenglow_handle_newly_frozen_banks` (`replay_stage.rs:1555-1601`)
- `BlockCreationLoop` write paths (out of scope; mentioned for context)
- `Votor::set_root` (`votor/src/root_utils.rs`)

**Suggested modeling approach**: This is a concurrency / lock-ordering bug; standard TLA+ deadlock detection. Variables = set of locks each thread holds at each PC; actions = lock acquire/release; invariant = no circular wait.

**Priority**: **Medium**
**Rationale**: Real production deadlock, already mitigated. The brief lists this for completeness; the modeling exists more for *future* AG changes that might reintroduce multi-writer patterns. Lower priority than the safety families (1-5) but worth a TLA+ check.

---

### Family 8: Repair / Block-ID Verification Adversary Surface — MEDIUM (BFT category 2.7)

**Mechanism**: AG's chained block-id mechanism (SIMD-340) relies on Merkle proofs for `ParentFecSetCount` and `block_id` lookups. Recent open issue #12496 confirms the Merkle tree construction (`ledger/src/shred/merkle_tree.rs:61`) hashes the last leaf with itself — an adversary can manipulate the implicit FEC set count by 1 via `BlockIdRepairResponse::ParentFecSetCount`. Combined with #12466 (block-ID repair stalls without Turbine) and #12495 (ParentFecSetCount proof not verified), the repair path has multiple safety/liveness gaps.

**Evidence**:
- **Open** #12496 — "Malleable proof for FEC set size in double-Merkle repair" (consensus-team).
- Open #12466 — "Block-ID repair stalls if no Turbine block received".
- Open #12411 — "Blacklist peers sending bad repair responses".
- Closed #12495 — "Not verifying ParentFecSetCount proof".

**Affected code paths**:
- `ledger/src/shred/merkle_tree.rs`
- `ledger/src/blockstore.rs:1820-1824` (FEC count)
- `core/src/repair/block_id_repair_service.rs`
- AG block-id chained validation

**Suggested modeling approach**: This is BFT category 2.7 (certificate manipulation) at the block-id repair layer. Out of immediate scope for the consensus-protocol spec but should be referenced.

**Priority**: **Medium** (separate spec; reference here)
**Rationale**: Open safety-relevant issue. Listed for reference; a full TLA+ model of repair would need its own brief.

---

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|---|---|---|
| 5-phase migration state machine | Family 1: all panics live here | Variable `migration_phase[v]`; each transition is an action; each panic is a checked precondition |
| Genesis block / cert separately | Family 1 set_genesis_* race | Variables `genesis_block_view[v]`, `genesis_cert_view[v]` with non-atomic set actions |
| Super-OC discovery per-fork | Family 2: fork-agnostic stake counting | `super_oc_stake[v, fork, parent_slot]`; Byzantine equivocation action populates votes on multiple forks |
| Per-hash Genesis votes | Family 3: SimpleVotePool aggregates across hashes | `genesis_votes[v, slot, block_id]` with separate pool views; verify cert builder produces matching block_id |
| NotarizeFallback count per slot | Family 4: assertion bound | `notar_fallbacks[slot] : SUBSET Hash`; honest contribution capped at 3 per pubkey; Byzantine unbounded |
| Vote history persist vs in-mem | Family 5: same as TBFT solana_3 Family A | `vote_history_in_mem[v]`, `vote_history_on_disk[v]`, crash actions reset in-mem only |
| Standstill state | Family 6: multiple recent bug fixes | `standstill_slot[v]`, `timer_multiplier[v, slot]`; verify monotonicity |
| Multi-thread BankForks writers | Family 7: open deadlock issue | Per-thread program counter + lock-set; verify no circular wait |

### 3.2 Do Not Model

| What | Why |
|---|---|
| Tower BFT internals (lockouts, switch threshold, fork choice tree) | Covered in solana_2 and solana_3 briefs; this brief is *complementary* not a re-derivation |
| PoH clock model | Slots opaque ordered ints; PoH shutdown modeled as state transition only |
| BLS signature scheme correctness | Honest signatures unforgeable; Byzantine can sign anything (per bft-analysis.md) |
| Block production internals (`block_creation_loop`, BCL leader scheduling) | Adjacent subsystem; out of brief scope |
| Repair Merkle proof verification (#12496) | Separate brief territory; reference only |
| AG vote rewards (#11850, #12233) | Reward subsystem; not consensus safety |
| Geyser, RPC, metrics | Observability; not protocol |
| Fast leader handover (`update_parent`) | New mechanism but separate from migration / pool; flag for future brief |
| `consensus_rewards` purge fix (`02e2275a21`) | Already-fixed `sub`-vs-`add` sign error; reference-only |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|---|---|---|---|
| MigrationStatus phase + sub-state | `migration_phase`, `ff_activation_slot`, `migration_slot`, `genesis_block_view`, `genesis_cert_view`, `poh_service_started`, `shutdown_poh` | Migration TOCTOU and panics | 1, 2, 5 |
| Super-OC per-fork | `landed_votes[fork, slot] : Pubkey ↦ Hash`, `super_oc_stake[fork, slot]`, `parent_is_super_oc[fork, slot]` | Family 2 fork-agnostic counting | 2 |
| Per-hash genesis votes + SimpleVotePool model | `genesis_votes[slot, block_id] : SUBSET Pubkey`, `pool_total_stake[slot]` | Family 3 routing bug | 3 |
| NotarizeFallback count | `notar_fallbacks[slot] : SUBSET Hash` with per-pubkey caps | Family 4 bound check | 4 |
| Vote history persistence | `vote_history_in_mem`, `vote_history_on_disk`, `voting_channel`, `Crash`, `Recover` | Family 5 persistence | 5 |
| Standstill state | `standstill_slot`, `timer_multiplier`, event ordering | Family 6 liveness | 6 |
| Adversary model: Byzantine + offline | `Byzantine ⊆ V`, `Offline ⊆ V`, `|Byzantine|/total < 0.20`, `|Offline|/total < 0.20`, equivocation actions | All BFT families | 1, 2, 3, 4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| MigrationDoesNotPanic | Safety | No reachable state violates the implicit `assert!` preconditions in `set_genesis_block`, `set_genesis_certificate`, `is_ready_to_enable`, `enable_alpenglow` | Family 1 |
| GenesisBlockAgreement | Safety | Two honest validators discover the same genesis_block OR Byzantine equivocators ≥ MIGRATION_MALICIOUS_THRESHOLD | Family 1, 2 |
| UniqueSuperOC | Safety | At most one fork crosses GENESIS_VOTE_THRESHOLD per parent_slot, given Byzantine < 20% | Family 2 |
| GenesisCertWellFormed | Safety | Every locally built Genesis cert's block_id is supported by ≥ 82% stake voting for that *specific* block_id (not summed across hashes) | Family 3 |
| GenesisCertBLSAggregateValid | Safety | The BLS aggregate signature of any built Genesis cert verifies against its claimed `cert_type.block_id` | Family 3 |
| NotarFallbackBoundedBy8 | Safety | `|notar_fallbacks[slot]| ≤ 8` for all reachable states under honest≥80% / byz≤20% | Family 4 |
| AssertionDoesNotFire (NotarFallbackBound) | Safety | `|notar_fallbacks[slot]| ≤ MAX_NOTAR_FALLBACK_BLOCKS = 7` for all reachable states (implementation invariant; will FAIL if Family 4 finding holds) | Family 4 |
| NoDoubleVotePostRestart | Safety | After `Crash(v) + Recover(v)`, the next vote v issues is consistent with cluster_observed_votes[v] (not a conflicting type on same slot) | Family 5 |
| VoteHistoryRootMonotonic | Safety | `vote_history_on_disk[v].root ≤ vote_history_in_mem[v].root` at all times; eventually equal | Family 5 |
| StandstillEventuallyCleared | Liveness | If `highest_finalized_slot[v]` advances past `standstill_slot[v]`, then `standstill_slot[v]` becomes None within bounded steps | Family 6 |
| TimeoutMultiplierBounded | Safety | `timer_multiplier[v, slot]` is bounded by a protocol-defined function of slots-since-standstill | Family 6 |
| NoBankForksDeadlock | Liveness | The graph of lock waits among `BankForks` writers is acyclic | Family 7 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected violation | Bug Family |
|---|---|---|---|
| MC1 | After `set_genesis_block(B)` then concurrent `enable_alpenglow` then `set_genesis_certificate(C)` then `assert!(is_ready_to_enable())` (block_component_processor.rs:260-267): Can the assert fire because phase advanced past Migration between the calls and both set_* silently no-op'd? | `MigrationDoesNotPanic` | 1 |
| MC2 | Byzantine validators (≤ 20% stake) equivocate on slot N across two forks, both landing a vote on-chain. Honest validators on each fork compute `super_oc_stake[fork, N]`. Can BOTH forks cross the 82% threshold and have two honest validators call `set_genesis_block` with distinct values, triggering Family 1's assert_eq panic? | `UniqueSuperOC`, `GenesisBlockAgreement` | 1, 2 |
| MC3 | Byzantine leader during migration emits two distinct alpenglow genesis candidate blocks A, B. Honest validators split (e.g., 41% / 41%). All vote Genesis(slot, X_i) once. Pool's `total_stake() = 82%` triggers cert build. Does the built cert pass BLS verification under its claimed `block_id`? Does the local node panic via `set_genesis_certificate` mismatch? | `GenesisCertWellFormed`, `GenesisCertBLSAggregateValid` | 3 |
| MC4 | Byzantine stake ≤ 20% drives a sequence of `Notarize`/`NotarizeFallback` votes that create 8 distinct notar-fallback certs for the same slot. The 8th certificate insertion triggers the `assert!(len <= 7)` panic. Reachable under stated threshold? | `NotarFallbackBoundedBy8` (HOLDS), `AssertionDoesNotFire` (FAILS) | 4 |
| MC5 | Honest validator generates a vote, `add_vote` updates in-memory state, `generate_vote_tx` returns `NoRankFound` (transient stake event at epoch boundary). The vote is NOT sent. Validator crashes. On restart, the on-disk vote history is older. Can the next vote be a conflicting type for the same slot? | `NoDoubleVotePostRestart` | 5 |
| MC6 | Validator roots slot R via `set_root` (in-memory only). Crashes before next vote. On restart, on-disk root is < R. Can the validator re-cast votes for slots in [on-disk-root, R) that were already covered by the new root? | `VoteHistoryRootMonotonic` | 5 |
| MC7 | First `Standstill(N)` emitted; later, finalization advances to M > N; a second `Standstill(M)` is emitted before any `Finalized` event reaches event_handler. Does `standstill_slot` remain stuck at N, causing unbounded growth of `timer_multiplier(slot)`? | `StandstillEventuallyCleared`, `TimeoutMultiplierBounded` | 6 |
| MC8 | Two threads (replay, votor::set_root) attempt to write BankForks simultaneously while a third thread (BCL) holds bank_forks for read. Verify the lock graph: is there a reachable circular wait? | `NoBankForksDeadlock` | 7 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| TV1 | `block_has_notar_fallback_or_stronger(genesis_block)` returns false for the genesis cert; check whether downstream `SafeToNotar` fires correctly for intrawindow first-slot-after-genesis blocks | Integration test: set up genesis cert + skip first alpenglow slot + ingest a duplicate-block notarize on slot M+1; assert SafeToNotar fires (currently fails) |
| TV2 | `get_notarize_cert(slot)` arbitrarily picks lex-smallest among multiple Notarize certs; under Byzantine double-signing, this may not match the `Finalize` cert's intended block_id | Insert `Notarize(slot, A)` and `Notarize(slot, B)` via add_certificate, then `Finalize(slot)`; inspect `VotorEvent::Finalized` block_id |
| TV3 | `pending_safe_to_notar` HashSet unbounded growth under sustained Byzantine 20% pumping safe-to-notar without parent certification | Byzantine simulator: hold parent slot uncertified, gossip many safe-to-notar pairs over many slots; measure memory |
| TV4 | `add_new_notar_fallback_or_stronger` O(K²) work under K consecutive skip certs from Byzantine | Microbenchmark: feed K=10000 consecutive skip certs; measure time |
| TV5 | `request_switch` blocking-send deadlock when switch_bank_sender (bounded 100) is full | Saturate replay; observe event_handler stalls |
| TV6 | `standstill: false` reset in stats every 10s independent of actual state (#12373 was about `never reset to false` — the *current* fix overshoots and resets even while in standstill) | Trigger standstill, wait > 10s, query stats |
| TV7 | `enable_alpenglow_during_startup` race when PohService starts between TOCTOU points | Stress test with parallel startup paths |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR1 | `genesis_bank.block_id() != Some(block_id)` panic at replay_stage.rs:1633-1645 has no recovery path; should this trigger dump-and-repair instead? | Discuss with maintainers; the existing duplicate-slot machinery exists, just isn't invoked here |
| CR2 | `consensus.rs:528 assert_eq!(vote_state.nth_recent_lockout(0).map(|l| l.slot()), Some(bank_slot))` — release-build panic on adversarial vote state. Same comment as solana_3 CR2 — repeated here because the migration path also calls this | Convert to graceful error |
| CR3 | The `unreachable!()`-instead-of-`return-Err` pattern in `MigrationStatus`'s `set_*` methods (when phase mismatches) is partially relaxed in #11727. Audit remaining `unreachable!()` instances in migration.rs and consensus_pool.rs and check whether each is robust to ingest of attacker-constructed cert/vote bytes | Per-call review; convert any non-honest-internal precondition to `Result` |
| CR4 | `update_certificates` reads `total_stake` from the *current vote's* `epoch_stakes_from_slot(vote.slot()).total_stake()`. Within a single vote's processing, all vote_types share the slot. But the cached `accumulated_stake` includes prior votes possibly stored under a different `total_stake` snapshot at epoch boundaries | Verify epoch-boundary slot bookkeeping |
| CR5 | `MIGRATION_MALICIOUS_THRESHOLD = 20%` is hardcoded; protocol invariant comments at migration.rs:80-86 do not derive it from first principles. Check whether the math (`SWITCH_FORK_THRESHOLD − (1 − GENESIS_VOTE_THRESHOLD) = MALICIOUS_THRESHOLD`) holds under all Family-2 cross-fork double-counting scenarios | Discuss with consensus-team |
| CR6 | `assert!(genesis_bank.is_frozen())` at replay_stage.rs:1632 — frozen-state assumptions during migration | Verify always true under the call chain |
| CR7 | Open issue #12329: `verified_certs` / `completed_cert_types` / `generated_cert_types` are three separate data structures across `bls_sigverifier.rs` and `consensus_pool.rs`. Consistency burden is a latent bug source | Merge per maintainer proposal |
| CR8 | Open issue #11849, #11850: AG vote reward payout during migration epoch incomplete | Mark as in-progress |
| CR9 | Open issue #11062: BLS sigverifier denial-of-service via spam of unverifiable votes | Add rate-limiting per peer |

## 7. Reference Pointers

### Files in scope (this brief)

**PRIMARY**:
- `votor-messages/src/migration.rs` (~780 LOC) — MigrationStatus, all panics
- `core/src/replay_stage.rs` (5354 LOC) — migration call sites at lines 780-1750, 2700-3100, 4280-4500
- `core/src/consensus.rs` lines 410-600 — parent_is_super_oc
- `runtime/src/block_component_processor.rs` lines 240-270 — set_genesis_* call sequence

**SECONDARY (Alpenglow pool)**:
- `votor/src/consensus_pool.rs` (2132 LOC)
- `votor/src/consensus_pool/parent_ready_tracker.rs` (418 LOC)
- `votor/src/consensus_pool/vote_pool.rs` (240 LOC)
- `votor/src/consensus_pool/slot_stake_counters.rs` (398 LOC)
- `votor/src/consensus_pool/certificate_builder.rs` (571 LOC)
- `votor/src/common.rs` (constants + conflicting_types)
- `votor-messages/src/consensus_message.rs` (limits_and_vote_types)

**SECONDARY (Event handler + vote history)**:
- `votor/src/event_handler.rs` (1871 LOC)
- `votor/src/voting_utils.rs` (644 LOC)
- `votor/src/vote_history.rs` (541 LOC), `vote_history_storage.rs` (241 LOC)
- `votor/src/voting_service.rs` (406 LOC)
- `votor/src/consensus_pool_service.rs` (978 LOC)
- `votor/src/timer_manager/timers.rs`

### Companion briefs (Tower BFT, prior work)

- `case-studies/solana_2/.specula-output/modeling-brief.md` — Tower BFT bifurcation, switch threshold, crash window, OC equivocation, gossip-vs-replay (5 families).
- `case-studies/solana_3/.specula-output/modeling-brief.md` — Tower BFT extended: stray-vote recovery, switch-proof asymmetries, tower adoption non-atomic, OC hash-drop, equivocation, OC violation detection, identity hot-swap (8 families).

**Composition**: A complete TLA+ spec set for Solana consensus = solana_3's TBFT families A–H + this brief's Families 1–7 + a separate brief for repair / block-id (#12496 area).

### GitHub issues (consensus-team label, deeply read)

- **Open + safety-relevant**: #12039 (deadlock), #12496 (Merkle malleable), #12466 (BlockID repair stall), #12411 (peer blacklist), #11284 (blocking send), #11062 (bls sigverify DoS), #11112 (cache overhaul), #11850 (AG rewards migration), #12364 (snapshot no fincert), #12329 (cert data-structure dup), #11411 (RwLock perf), #7476 (testing control).
- **Closed but reference-context for mechanism**: #11727 (set_genesis race fix), #12327 (notar-fallback assertion fix), #9394 (genesis vote filter), #12350 (standstill_slot livelock fix), #12328 (SafeToNotar logic fix), #12226 (TimeoutCrashedLeader early fix), #12199 (UpdateParent fix), #12232 (cert rebroadcast), #12373 (standstill stats reset), #11607 (base3 empty primary).

### Reference docs

- **Alpenglow whitepaper v1.1** — referenced in `votor/src/consensus_pool/slot_stake_counters.rs:102-104` ("White paper v1.1 page 22"). Page 22 covers SafeToNotar threshold semantics.
- **SIMD-340** — chained block ID validation.
- **SIMD-357** — VAT (validated block finalization).
- **SIMD-291** — commission rate basis points.
- **SIMD-438** — Rent Increase Safeguard (current HEAD commit `21fb994c21`).
- **Tower BFT** — Yakovenko 2018 whitepaper; references in solana_2 / solana_3.

### Migration timeline constants

- `MIGRATION_SLOT_OFFSET = 5000` (migration starts 5000 slots after FF activation slot)
- `MIGRATION_MALICIOUS_THRESHOLD = 20%`
- `GENESIS_VOTE_THRESHOLD = 82%` (note: `SWITCH_FORK_THRESHOLD + GENESIS_VOTE_THRESHOLD ≥ 1.20`)
- `GENESIS_VOTE_REFRESH = 400 ms`
- `MAX_NOTAR_FALLBACK_BLOCKS = 7`
- `MAX_ENTRIES_PER_PUBKEY_FOR_NOTARIZE_LITE = 3`
- `SAFE_TO_NOTAR_*` thresholds (40%, 20%, 60%)
- `DELTA = 250 ms`, `DELTA_TIMEOUT = DELTA + 3·DELTA = 1 s`, `DELTA_STANDSTILL = 10 s`

### Full analysis report

- `analysis-report.md` (this directory) — coverage statistics, per-finding verification log, full bug-fix commit table, all subagent findings with file:line citations.

### Category-overlay reference

- This brief is **Category A + BFT overlay**. Applied references:
  - `bft-analysis.md` §2.1 equivocation (Family 2, 3)
  - `bft-analysis.md` §2.5 replay / stale ctx (Family 1 — TOCTOU on phase)
  - `bft-analysis.md` §2.6 amnesia / restart (Family 5)
  - `bft-analysis.md` §2.7 cert manipulation (Family 8, repair)
  - `distributed-analysis.md` §5.1 crash & recovery (Family 5)
  - `distributed-analysis.md` §5.4 non-atomic persistence (Family 5)
  - `distributed-analysis.md` §5.5 configuration / membership change (Family 1 — *the* membership change of this codebase: protocol cutover)
