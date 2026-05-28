# Code Analysis Report: Solana / Agave — TowerBFT ⇄ Alpenglow Migration Boundary

**Repository**: `anza-xyz/agave` at HEAD `21fb994c21` (2026-05-19, master branch)
**Analysis date**: 2026-05-20
**Scope** (this case study, complementing solana_2 and solana_3 which covered Tower BFT in detail):
- The TowerBFT → Alpenglow migration state machine (`votor-messages/src/migration.rs`)
- Tower BFT side of the migration: super-OC discovery, genesis-vote casting (`core/src/consensus.rs`, `core/src/replay_stage.rs`)
- Alpenglow `ConsensusPool` certificate assembly (`votor/src/consensus_pool*`, `votor/src/event_handler.rs`)
- The interaction between Tower-replayed state and the new BFT-cert state machine

The reference algorithm in the task definition is **Tower BFT**. The migration is the *Tower BFT extension* by which Solana cuts over to Alpenglow. Prior briefs (solana_2, solana_3) explicitly placed `votor/` and migration logic *out of scope*; this brief covers exactly that boundary, plus the new BFT pool that runs in steady state once migration completes.

---

## 1. Category Classification

**Category A (Distributed / Message-Passing)** with a **Byzantine threat model**.

Justification:
- Network RPC, gossip, BLS signature aggregation, multi-thread state machines per validator.
- Tower BFT's 1/3 Byzantine tolerance carries through; Alpenglow's "20+20" model (20% Byzantine + 20% offline) is tighter.
- During the migration **both** consensus protocols run concurrently against the same `BankForks`: each one mutates state and reads from the other.
- The whole brief uses distributed-analysis vocabulary (5.1 Crash, 5.4 Non-atomic persistence, 5.5 Membership/migration). BFT overlay 2.1 (equivocation), 2.5 (replay/stale ctx), 2.6 (amnesia / restart) all apply.

---

## 2. Phase 1 — Reconnaissance

### 2.1 Repository structure

```
artifact/agave/
├── core/                              # Tower BFT + cross-cutting state
│   └── src/
│       ├── consensus.rs               (3932 LOC) — Tower struct, switch threshold
│       ├── consensus/                 (~7 KLOC) — fork-choice, tower-storage, vote tracking
│       ├── replay_stage.rs            (5354 LOC) — main consensus loop, *both* TBFT and AG paths
│       ├── replay_stage/              — dead_slots.rs, update_parent.rs (fast leader handover)
│       ├── cluster_info_vote_listener (2221 LOC) — gossip vote ingest, OC tracking
│       ├── optimistic_confirmation_verifier.rs — OC verifier
│       └── voting_service.rs          — Tower vote tx broadcast + tower save
├── votor/                             # NEW Alpenglow consensus (8.0 kLOC core)
│   └── src/
│       ├── consensus_pool.rs          (2132 LOC) — BFT pool, cert assembly
│       ├── consensus_pool/            — parent_ready_tracker, vote_pool,
│       │                                slot_stake_counters, certificate_builder
│       ├── consensus_pool_service.rs  (978 LOC) — async pool driver
│       ├── event_handler.rs           (1871 LOC) — voting state machine
│       ├── vote_history.rs            (541 LOC) — Alpenglow's tower replacement
│       ├── voting_utils.rs            (644 LOC) — generate_vote_tx
│       ├── timer_manager/             — slot timers, standstill detection
│       └── votor.rs                   — coordinator
└── votor-messages/                    # Shared wire-format crate
    └── src/
        ├── migration.rs               (~780 LOC) — MigrationStatus state machine ★
        ├── consensus_message.rs       — Certificate / VoteMessage types
        └── vote.rs                    — Vote enum (Notarize/Skip/Finalize/Genesis)
```

### 2.2 Concurrency model

- **`ReplayStage` main thread**: still single-threaded for fork-choice; calls both `Tower::*` and `MigrationStatus::*`.
- **`VotingService` thread**: persists tower (TBFT) or vote history (AG) and broadcasts vote tx.
- **`PohService` thread**: ticks for Tower BFT; shuts down on migration.
- **`BlockCreationLoop` thread** (AG only): produces blocks during Alpenglow.
- **`ConsensusPoolService` thread** (AG): consumes ConsensusMessages and updates pool.
- **`EventHandler` thread** (AG): consumes `VotorEvent`s and writes vote tx.
- **`BlsSigverifier` thread** (AG): BLS verification of incoming votes / certs.
- **Shared state**: `Arc<RwLock<BankForks>>` (now written by 3 threads in AG: replay, BCL, votor), `Arc<MigrationStatus>` (`RwLock<MigrationPhase>` + atomics).

Per **open issue #12039** ("triple thread deadlock w/ alpenglow"), the AG migration of `BankForks` writers from 1 thread to 3 created a real deadlock in production-testing. Fixed in PR #12448 by serializing writes back to replay.

### 2.3 Constants and thresholds (in scope)

| Constant | Value | Where | Meaning |
|---|---|---|---|
| `MIGRATION_SLOT_OFFSET` | 5000 | votor-messages/src/migration.rs:73 | Slots after FF-activation to begin migration |
| `MIGRATION_MALICIOUS_THRESHOLD` | 20% | votor-messages/src/migration.rs:80 | AG max Byzantine assumption |
| `GENESIS_VOTE_THRESHOLD` | 82% | votor-messages/src/migration.rs:86 | Stake for super-OC / Genesis cert |
| `GENESIS_VOTE_REFRESH` | 400 ms | votor-messages/src/migration.rs:89 | Refresh interval |
| `SWITCH_FORK_THRESHOLD` | 38% | core/src/consensus.rs (TBFT) | Lockout switch (TBFT) |
| `MAX_NOTAR_FALLBACK_BLOCKS` | 7 | votor/src/common.rs:61 | Bound on distinct notar-fallbacks per slot |
| `MAX_ENTRIES_PER_PUBKEY_FOR_NOTARIZE_LITE` | 3 | votor/src/common.rs:60 | Per-validator notar-fallback cap |
| `SAFE_TO_NOTAR_MIN_NOTARIZE_ONLY` | 40% | votor/src/common.rs:63 | SafeToNotar threshold (i) |
| `SAFE_TO_NOTAR_MIN_NOTARIZE_FOR_NOTARIZE_OR_SKIP` | 20% | votor/src/common.rs:64 | SafeToNotar threshold (ii) |
| `SAFE_TO_NOTAR_MIN_NOTARIZE_AND_SKIP` | 60% | votor/src/common.rs:65 | SafeToNotar threshold (ii) |
| `SAFE_TO_SKIP_THRESHOLD` | 40% | votor/src/common.rs:67 | SafeToSkip threshold |
| Notarize cert | 60% Notarize | consensus_message.rs:192 | Slow-path notarize |
| NotarizeFallback cert | 60% (Notarize ∪ NotarizeFallback) | consensus_message.rs:194-197 | |
| FinalizeFast cert | 80% Notarize | consensus_message.rs:198 | |
| Finalize cert | 60% Finalize | consensus_message.rs:201 | |
| Skip cert | 60% (Skip ∪ SkipFallback) | consensus_message.rs:202-205 | |

---

## 3. Phase 2 — Bug Archaeology (Coverage Statistics)

### 3.1 Git mining

- Full git log unshallow: **32,586 commits** total in repo history (after `git fetch --unshallow`).
- Commits touching Tower BFT core files (`core/src/consensus.rs`, `core/src/consensus/`, `replay_stage*`, `voting_service.rs`, `cluster_info_vote_listener.rs`, `optimistic_confirmation_verifier.rs`) in last 6 months: **64 commits**.
- Commits touching `votor/` in last 6 months: **89 commits**.
- Commits touching `votor/` + `votor-messages/` in last year: **173 commits**.
- Bug-fix commits in `votor/` last 2 years (grep "fix|bug"): **27 commits**.
- Bug-fix commits in `votor-messages/` last 2 years: **6 commits**.

### 3.2 Key historical bug-fix commits (analyzed)

| Commit | Date | File | Mechanism | Severity |
|---|---|---|---|---|
| `f0ceb8a852` | 2026-04-02 | votor-messages/src/migration.rs | Race: `set_genesis_block` / `set_genesis_certificate` panicked when phase progressed past `Migration` between dispatch and call. Relaxed `unreachable!` to silent return. | Critical (DoS) |
| `76a83971e5` | 2025-12-03 | votor/src/consensus_pool/vote_pool.rs | Genesis vote `collect_votes` not filtered by `block_id`. Filter added. | Critical |
| `9665d09c22` | 2026-05-11 | votor/src/consensus_pool/parent_ready_tracker.rs | Assertion `len <= MAX_ENTRIES_PER_PUBKEY_FOR_NOTARIZE_LITE` (=3) too tight; cluster with multiple notar-fallback blocks would panic. Raised to `MAX_NOTAR_FALLBACK_BLOCKS = 7`. | High (DoS) |
| `c93e46fb00` | 2026-05-15 | votor/src/consensus_pool_service.rs | `pending_safe_to_notar` dropped if send failed; fix keeps pending. | High |
| `02e2275a21` | 2026-04-30 | votor/src/consensus_rewards.rs | `split_off(root_slot + N + 1)` purged *newer* state instead of older. Sign error. | High |
| `121b9eda08` | 2026-05-* | core/src/replay_stage.rs | `replay: upstream switching duplicate banks on ParentReady`. Cross-protocol duplicate-bank switching. | High |
| `9444f21f9d` | 2026-04-* | core/src/replay_stage.rs | `replay_stage: sends finalization cert to consensus pool` — wiring TBFT slot finality into AG pool. | Medium |
| `52446464d5` | 2026-05-* | core/src/replay_stage.rs | `votor: serialize bank forks writes back to replay thread` — fixes #12039 triple-thread deadlock. | Critical |
| `6b40f5b0a3` | 2026-05-* | votor/src/timer_manager/timers.rs | `fix: account for Turbine latency in DELTA_TIMEOUT` (#12462) | Medium |
| `1b6a85a234` | 2026-05-* | votor/src/timer_manager/timers.rs | `fix: do not scale DELTA_BLOCK during standstill` (#12439) | Medium |
| `3651df65ed` | 2026-05-* | votor/src/event_handler.rs | `store finalized slot in standstill_slot, fix reset` (#12359). Resolved a livelock where parent-ready advanced but no block finalized — standstill never lifted. | High (liveness) |
| `2028c58fba` | 2026-04-* | votor/src/consensus_pool_service/stats.rs | `reset standstill bool upon finalize` (#12374) | Low (metrics) |
| `9d9a1f93a8` | 2026-* | core/src/* | `alpenglow: account for PohService during startup migration` (#12225) — race fix on enable_alpenglow_during_startup. | High |
| `813aede070` | 2026-* | various | `startup replay: upstream migration status during startup` (#12025) | High |
| `05159de693` | 2026-* | vote/src/* | `vote: when alpenglow migration is complete, disallow Tower vote ixs` (#11387) — protocol-level cutoff. | Medium |

### 3.3 GitHub issue verification (deeply read)

| # | State | Title | Verdict / Mechanism |
|---|---|---|---|
| #12039 | OPEN | triple thread deadlock w/ alpenglow | Confirmed. AG split BankForks writers across 3 threads; reproduced production deadlock. Mitigated by #12448 (serialize back to replay). Underlying multi-writer pattern still in code. |
| #12046 | OPEN | Improve `commission_split` for alpenglow | Confirmed. Off-by-one / division correctness in reward path. |
| #12140 | OPEN | Consider TVU relays | Design discussion. |
| #12199 | CLOSED | Fix bug in multiple UpdateParent within block | Confirmed: SlotMeta `has_update_parent` semantics broke when multiple markers existed. |
| #12207 | OPEN | reward metrics tracking | Observability. |
| #12226 | CLOSED | Triggering `VotorEvent::TimeoutCrashedLeader` too early | Confirmed: triggered at `DELTA_TIMEOUT` ignoring leader's `DELTA_FIRST_SLICE` budget. Fixed by adding `DELTA_FIRST_SLICE`. |
| #12232 | CLOSED | Missing certificate re-broadcast upon `VotorEvent::Standstill` | Confirmed liveness gap. `CertificatePoolService` removed and rebroadcast logic lost. |
| #12233 | CLOSED | ag footer reward processing — wrong epoch credit | Confirmed: `update_vote_account(current_epoch, …)` used at boundaries when `reward_epoch` is `bank.epoch_schedule.get_epoch(reward_slot)` — first 8 slots of every epoch hand credits to the wrong epoch. Already-fixed PRs landed; the *mechanism* is reference-context (do not re-derive). |
| #12328 | CLOSED | Fix `SafeToNotar` logic | Confirmed safety-relevant: SafeToNotar emitted without parent-notar-fallback check; intrawindow slots. |
| #12329 | OPEN | Merge `verified_certs`, `completed_cert_types`, `generated_cert_types` | Triple data-structure duplication; consistency burden. |
| #12350 | CLOSED | Store finalized instead of parent-ready as `standstill_slot` | Livelock: parent-ready could advance via skip certs without finalization → standstill never lifted. |
| #12364 | OPEN | No finalization certificate in snapshot | Restart from snapshot lacks finalization cert → pool initializes empty → re-finalize from scratch. |
| #12370 | OPEN | Geyser + alpenglow compatibility | Plugin interface concerns. |
| #12373 | CLOSED | `ConsensusPoolServiceStats::standstill` never reset | Metrics-only. |
| #12386 | CLOSED | adjust eager repair timing for alpenglow | Timing. |
| #12404 | CLOSED | Misleading long timeout for retry | Repair UX. |
| #12411 | OPEN | Blacklist peers sending bad repair responses | Adversary handling. |
| #12466 | OPEN | Block-ID repair stalls if no Turbine block | Liveness. Block-ID-based repair waits for Turbine arrival before kicking in. |
| #12468 | CLOSED | Unused Merkle root field in `WindowIndexForBlockId` | Code cleanup. |
| #12491 | CLOSED | Timeout `REPAIR_REQUEST_TIMEOUT_MS` too short | Timing. |
| #12495 | CLOSED | Not verifying `ParentFecSetCount` proof | Confirmed safety: ParentFecSetCount proofs not verified. |
| **#12496** | **OPEN** | **Malleable proof for FEC set size in double-Merkle repair** | **Confirmed safety**: Merkle tree hashes last leaf with itself → adversary can manipulate FEC set count by 1. Affects block-ID repair / chained block-id validation. Fixed-attempt PR #12506. |
| #12552 | OPEN | Inconsistent traits on `OutgoingMessage` | API consistency. |
| #11062 | OPEN | bls_sigverify: better handling of malicious actors | DoS via spam of bad votes. |
| #11067 | CLOSED | bls_sigverifier: check certs against our own produced certs | Optimization; led to `generated_cert_types`. |
| #11103 | OPEN | bls_sigverifier: measure parallel verify | Perf. |
| #11112 | OPEN | StakedValidatorsCache overhaul | Perf. |
| #11284 | OPEN | Logging/retrying for blocking bls_sender | Confirmed: blocking send in event_handler.rs:L186-area can deadlock. |
| #11285 | OPEN | Audit `send`s for blocking | Pattern-level concern. |
| #11411 | OPEN | GeneratedCertTypes: ArcSwap+CoW vs RwLock | Perf. |
| #11607 | CLOSED | base3 cert verify fails when primary empty | Confirmed: base3 encoding edge case rejected valid cert. |
| #11849 | OPEN | testing AG vote rewards payout | Testing. |
| #11850 | OPEN | implement AG vote reward payout for migration epoch | Confirmed design gap during mixed-protocol epoch. |
| #11067 (BLS) | CLOSED | check certs against our own produced certs | Optimization. |
| #11857 | OPEN | Validator public IP / bind | Networking. |
| #11915 | OPEN | well-known accounts empty deserialize | Defensive. |
| **#7476** | **OPEN** | **Alpenglow Testing Control** | Confirmed design issue: how to test mixed TBFT/AG configurations in CI. |

**Total deeply read**: ~35 issues + 15 PRs. **Confirmed**: 28. **Fixed but reference-value**: 12. **DoS/correctness**: 11. **Open as of analysis date**: 21.

### 3.4 Bug-prone areas (mechanism-grouped)

1. **Migration phase transitions and assertions** — `MigrationStatus` panicked in earlier versions; fix `f0ceb8a852` made transitions tolerant of late arrivals, but multiple callers still `assert!(is_ready_to_enable())` immediately after — re-introducing the race window.
2. **Pool vote-type → pool-class routing** — `SimpleVotePool` vs `DuplicateBlockVotePool` choice in `new_vote_pool`. Genesis votes routed to SimpleVotePool, which does not filter by `block_id`; the historical fix `76a83971e5` was on `collect_votes` which is no longer the codepath.
3. **Cross-thread `BankForks` writers under AG** — issue #12039.
4. **Standstill detection / certs re-broadcast** — issues #12350, #12232, #12373, #12374 — re-emission, livelock, stale state on multiple consecutive Standstills.
5. **Timeouts** — #12226 (TimeoutCrashedLeader too early), #12462 (Turbine latency), #12439 (DELTA_BLOCK during standstill), #12491 (repair timeout).
6. **Repair / Merkle proof verification** — #12496 (malleable FEC count), #12495 (no verify), #12466 (stall without Turbine), #12411 (blacklist bad peers).
7. **Vote-history (Alpenglow's tower) persistence** — like Tower BFT, no fsync (`vote_history_storage.rs:155-170`); persist-then-broadcast in `voting_service.rs`; in-memory `add_vote` BEFORE successful broadcast in `voting_utils.rs:240`.

---

## 4. Phase 3 — Deep Analysis Findings

Three parallel deep-analysis subagents (one per area) returned the findings below. All have been re-read in the main context and verified against exact file:line locations at HEAD `21fb994c21`.

### 4.1 Subagent A: Migration State Machine (`votor-messages/src/migration.rs`, replay_stage.rs migration call sites)

**A1. Adversarial Genesis Certificate slot triggers panic** — `votor-messages/src/migration.rs:597-600`
```rust
assert!(
    slot < *migration_slot,
    "Attempting to set a genesis certificate past the migration start"
);
```
A Genesis cert that passes BLS aggregate verification but encodes `slot >= migration_slot` is a valid byte pattern. With ≥82% Byzantine stake (one notch above the design assumption), an adversary can mint such a cert and gossip it. Every honest node ingesting the cert panics in `add_certificate` → `insert_certificate` → `set_genesis_certificate`. **Verification**: model-checkable; the assertion should reject (via `Err`) rather than panic.

**A2. `super_oc_stake` is fork-agnostic at the `last_voted_slot == parent_slot` predicate** — `core/src/consensus.rs:481-484`, `545-547`
```rust
if last_landed_voted_slot == parent_slot {
    super_oc_stake += voted_stake;
}
...
let parent_is_super_oc = bank_slot == parent_slot + 1
    && Fraction::new(super_oc_stake, NonZeroU64::new(total_stake).unwrap())
        > GENESIS_VOTE_THRESHOLD;
```
`bank.vote_accounts()` returns the *on-chain* vote state landed in *this* bank's fork; so the per-fork tally is consistent with that fork's view of "who voted for parent_slot". However the `last_landed_voted_slot == parent_slot` comparison is by **slot number alone** — a validator's tower may have last voted for slot `parent_slot` on a *different fork* that happens to share the slot number. The bank's on-chain vote state for that validator, on this fork, reflects what landed in *this fork*. But the same slot number can have different block_ids: a Byzantine equivocator who landed votes on two forks at slot N produces two distinct vote-account states landed in two banks at slot N+1. **Each fork's super_oc_stake includes the Byzantine voter once.** Combined with honest validators split across forks, this enables two forks to *both* cross the 82% threshold, leading two different honest validators to call `set_genesis_block` with **distinct** discovered_genesis_blocks. The next `set_genesis_block` call from a different fork's super-OC discovery then triggers the `assert_eq!` panic (A3). **Verification**: model-checkable in TLA+; the protocol invariant ("less than 20% double-voters guarantees uniqueness of super-OC") needs to be checked against the Byzantine threshold actually permitted.

**A3. `set_genesis_block` panic when two different super-OC blocks discovered** — `votor-messages/src/migration.rs:527-532`
```rust
if let Some(prev_genesis_block) = genesis_block {
    assert_eq!(
        *prev_genesis_block, discovered_genesis_block,
        "We have discovered two different alpenglow genesis blocks. Something is wrong",
    );
}
```
Same mechanism as A2 — this is the receiver-side panic. The comment says "Something is wrong" but doesn't justify why the failure mode is `assert_eq!` (panic) rather than rejecting one and logging. **Mitigation**: the panic text explicitly says "We cannot recover without operator intervention" (line 555-561 in similar block). **Verification**: model-checkable.

**A4. TOCTOU on `is_ready_to_enable()` after `set_genesis_certificate`** — `runtime/src/block_component_processor.rs:260-267`
```rust
migration_status.set_genesis_block(genesis_cert.cert_type.to_block().expect(...));
migration_status.set_genesis_certificate(Arc::new(genesis_cert));
assert!(migration_status.is_ready_to_enable());
```
After fix `f0ceb8a852`, both `set_*` calls *silently return* if the phase is no longer `Migration`. So if another thread (replay_stage main loop) called `enable_alpenglow` between the line-244 check `is_alpenglow_enabled()` and the line-267 assert, both `set_*` are no-ops and the assert fires. **Verification**: model-checkable; the fix relaxed the `set_*` panics but the downstream assert keeps the race.

**A5. `genesis_bank.block_id()` mismatch crashes** — `core/src/replay_stage.rs:1633-1645`
```rust
if genesis_bank.block_id() != Some(block_id) {
    panic!(
        "{my_pubkey}: Attempting to enable alpenglow but we have the wrong version of the \
         genesis block our version: ({genesis_slot}, {:?}), certified version \
         ({genesis_slot}, {block_id})",
        genesis_bank.block_id()
    );
}
```
A validator on a minority fork at `genesis_slot` panics rather than running a dump-and-repair to switch to the certified version. Unlike normal duplicate-slot recovery (which uses `cluster_slot_state_verifier` etc.), the migration path has *no* recovery code. **Verification**: code-review-only — the panic is intentional but the lack of recovery path is a design choice with cost.

**A6. `enable_alpenglow_during_startup` PoH-service race** — `votor-messages/src/migration.rs:683-701`
```rust
if self.poh_service_started.load(Ordering::Acquire) {
    let exit = AtomicBool::new(false);
    self.enable_alpenglow(&exit);   // ← uses condvar
    return genesis_slot;
}
// PohService not yet started — go straight:
self.shutdown_poh.store(true, Ordering::Release);
*self.phase.write().unwrap() = MigrationPhase::AlpenglowEnabled { genesis_cert };
```
If `PohService::new` is called between the load at 683 and the phase write at 693-695, the tick-producer can observe `is_alpenglow_enabled() = false` (phase not yet flipped) and enter its main loop; later `shutdown_poh = true` triggers `poh_service_is_shutting_down()` which `unreachable!`s because phase is now `AlpenglowEnabled`, not `ReadyToEnable`. Closed by ordering today (PohService start happens before `process_blockstore_from_root`), but the ordering is not asserted in code. **Verification**: model-checkable.

### 4.2 Subagent B: ConsensusPool Certificate Assembly

**B1. Genesis votes accumulate across distinct `block_id` in `SimpleVotePool`** — `votor/src/consensus_pool.rs:173-183`
```rust
fn new_vote_pool(vote_type: VoteType) -> VotePool {
    match vote_type {
        VoteType::NotarizeFallback => DuplicateBlockVotePool(...),
        VoteType::Notarize         => DuplicateBlockVotePool(...),
        _ => VotePool::SimpleVotePool(SimpleVotePool::default()),   // ← Genesis falls here
    }
}
```
`update_certificates` (lines 230-244) reads `pool.total_stake()` for `SimpleVotePool` — the sum of *all* Genesis votes regardless of `block_id`. Two different `(slot, block_id_A)` and `(slot, block_id_B)` Genesis votes increment the same counter. When ≥82% accumulates *across both* hash buckets, `update_certificates` builds a cert with `cert_type = Genesis(slot, block_id_X)` (`X` = the current vote being processed) and aggregates **all** the stored Genesis vote signatures. The BLS aggregate then includes votes for `block_id_A` AND `block_id_B`, but the cert claims block_id_X — the aggregate will *fail* BLS verification at any honest receiver. Locally the validator broadcasts a malformed cert (filtered out by remote BLS sigverify), but also panics in `set_genesis_certificate` if its local `genesis_block` is the other hash. **Verification**: test-verifiable. This is the *exact* bug class fixed by `76a83971e5` (vote_pool.rs `collect_votes` filter); the refactor `8fdea4cea8` re-introduced the issue at a different layer by changing the pool-routing.

**B2. `MAX_NOTAR_FALLBACK_BLOCKS = 7` bound — formally justified?** — `votor/src/consensus_pool/parent_ready_tracker.rs:111`, `votor/src/common.rs:61`
```rust
status.notar_fallbacks.push(block);
assert!(status.notar_fallbacks.len() <= MAX_NOTAR_FALLBACK_BLOCKS);
```
The bound was raised from 3 to 7 in `9665d09c22` ("fix wrong assertion threshold"). Each block reaching NotarizeFallback requires 60% (Notarize ∪ NotarizeFallback) stake. Each honest pubkey can be in at most `1 (Notarize) + 3 (NotarizeFallback) = 4` distinct blocks. Each Byzantine pubkey can sign for any number. With 80% honest / 20% Byzantine:
- Per-block stake ≥ 60% × X (X = # blocks).
- Honest capacity 4 × 80% = 320% (counting multiplicity).
- Byzantine capacity per-block × X = 20% × X.
- 60% × X ≤ 320% + 20% × X ⇒ X ≤ 8.
Plus Genesis cert at the same slot during migration: X = 9. The assert at line 111 panics if `len > 7`, so **X = 8 (or 9) is reachable, causing DoS.** Validity caveat: this requires Byzantine actors to actually mint these certs (each requires real votes from real validators). External certs via `add_certificate` are sigverified upstream, so the votes are real per-pubkey contributions even from honest validators (who legitimately voted notar-fallback on up to 3 blocks). **Verification**: model-checkable in TLA+.

**B3. `block_has_notar_fallback_or_stronger` ignores `CertificateType::Genesis`** — `votor/src/consensus_pool.rs:583-595`
```rust
pub(crate) fn block_has_notar_fallback_or_stronger(&self, block: Block) -> bool {
    let (slot, block_id) = block;
    self.completed_certificates.contains_key(&CertificateType::NotarizeFallback(slot, block_id))
        || self.completed_certificates.contains_key(&CertificateType::Notarize(slot, block_id))
        || self.completed_certificates.contains_key(&CertificateType::FinalizeFast(slot, block_id))
}
```
`insert_certificate` for `CertificateType::Genesis` calls `parent_ready_tracker.add_new_notar_fallback_or_stronger` (line 379-380) — so the genesis block is treated as notar-fallback-or-stronger internally. But this query function, used by `consensus_pool_service.rs` to gate `SafeToNotar` for intrawindow slots whose parent is the genesis block, *omits* the Genesis cert check. If the first post-migration leader's window starts at slot M and slot M is skipped, then slot M+1's intrawindow child's parent is the genesis block (a slot < M, with only a Genesis cert). The pending-safe-to-notar resolver returns false; `SafeToNotar` never fires. **Verification**: test-verifiable.

**B4. `get_notarize_cert` arbitrarily picks among multiple notarize certs** — `votor/src/consensus_pool.rs:510-518`
```rust
fn get_notarize_cert(&self, slot: Slot) -> Option<Arc<Certificate>> {
    self.completed_certificates.iter().find_map(|(cert_type, cert)| match cert_type {
        CertificateType::Notarize(s, _) if slot == *s => Some(cert.clone()),
        _ => None,
    })
}
```
With ≥20% Byzantine signers, two distinct `Notarize(slot, A)` and `Notarize(slot, B)` certs can both populate `completed_certificates` (received externally via `add_certificate`; no cross-cert dedup). `find_map` over a `BTreeMap` returns the lex-smallest key — i.e., smallest `block_id` hash. When a `Finalize(slot)` cert arrives (line 348), the emitted `VotorEvent::Finalized((slot, block_id), false)` and the `highest_finalized_slot_cert` record an arbitrarily chosen block_id, potentially the *opposite* of what the cluster actually finalized. **Verification**: test-verifiable.

**B5. Unbounded forward walk in `add_new_notar_fallback_or_stronger` / `add_new_skip`** — `votor/src/consensus_pool/parent_ready_tracker.rs:114-137, 141-204`
```rust
for s in slot.saturating_add(1).. {
    ...
    let status = self.slot_statuses.entry(s).or_default();
    if !status.parents_ready.contains(&block) {
        status.parents_ready.push(block);
        ...
    }
    if !status.skip { break; }
}
```
No explicit upper bound; walks while `slot_statuses[s].skip == true`. A Byzantine adversary with ≥20% stake gossiping skip certs for a contiguous range can grow `slot_statuses` map and `parents_ready` Vec linearly per added cert; combined with `add_new_skip`'s reverse iteration, **O(K²)** total work per K consecutive skip certs. **Verification**: test-verifiable / code-review-only.

**B6. Slot-stake_counters_map and pending_safe_to_notar lifecycle** — `consensus_pool.rs:131`, `consensus_pool_service.rs:222, 462-538`
`pending_safe_to_notar: Vec<Block>` and the HashSet at consensus_pool_service.rs:222 are bounded only by `set_root` pruning. A Byzantine adversary controlling 20% stake on slots ahead of root can hold safe-to-notar votes for many slots while the parent slot remains uncertified and the block remains undelivered (so the resolver keeps deferring). DoS amplifier under partition. **Verification**: test-verifiable.

### 4.3 Subagent C: VotorEvent Handler & Vote History Persistence

**C1. Vote-history persistence not gated on broadcast success** — `votor/src/voting_utils.rs:233-277`
`insert_vote_and_create_bls_message` calls `context.vote_history.add_vote(vote)` **before** `generate_vote_tx`. If `generate_vote_tx` returns `NonVoting / HotSpare / WaitForStartupVerification / WaitToVoteSlot / NoRankFound / NoAuthorizedVoter / VoteAccountNotFound`, no `BLSOp` is emitted to the voting service, so the on-disk vote history is **not updated**. The in-memory `voted` set was already mutated. On restart, the on-disk vote history reflects the older state and the validator can re-vote for the same slot with a conflicting type. **Verification**: model-checkable; test-verifiable by forcing NoRankFound mid-slot and restarting.

**C2. No fsync; persist-then-broadcast pipeline** — `votor/src/vote_history_storage.rs:155-170`
```rust
let mut file = File::create(&new_filename)?;
saved_vote_history.serialize_into(&mut file)?;
// file.sync_all() hurts performance; pipeline sync-ing and submitting votes to the cluster!
fs::rename(&new_filename, &filename)?;
// self.path.parent().sync_all() hurts performance same as the above sync
```
Documented tradeoff but means an `fs::rename`-but-no-fsync crash can lose committed-on-cluster votes from local disk. Tower BFT has the same property (`tower_storage.rs`). Combined with C1, the in-memory→bls_sender queue→storage chain is *asynchronous*. **Verification**: code-review-only (kernel-level crash semantics).

**C3. `VoteHistory::set_root` not persisted** — `votor/src/vote_history.rs:238-249`, caller `votor/src/root_utils.rs:35-82`
`set_root` mutates the in-memory `VoteHistory` (drops slots below root) but is *not* followed by any `SavedVoteHistory::store(...)` call. The on-disk file is updated only on the next vote. A root then crash means stale on-disk history at boot. The assertion `assert!(slot >= self.root)` (line 165) lets older votes re-enter the in-memory vote history, including votes from before the new root. **Verification**: model-checkable.

**C4. Standstill handler does NOT update `standstill_slot` on newer finalized** — `votor/src/event_handler.rs:485-508`
```rust
match *standstill_slot {
    Some(old_slot) => {
        debug_assert_eq!(highest_finalized_slot, old_slot);
        if highest_finalized_slot != old_slot {
            warn!(...);     // ← no state mutation
        }
    }
    None => { *standstill_slot = Some(highest_finalized_slot); ... }
}
```
The branch when `standstill_slot.is_some()` only `warn!`s but does **not** update `*standstill_slot`. If `highest_finalized_slot` advances between two Standstill emissions, the timeout multiplier `slots_since_standstill = slot - standstill_slot` grows unboundedly — every subsequent slot timeout becomes more aggressive. `debug_assert_eq!` traps in debug; release silently runs with stale `standstill_slot`. **Verification**: test-verifiable.

**C5. Standstill stats reset loses state** — `votor/src/consensus_pool_service/stats.rs:96-101`
```rust
pub(super) fn maybe_report(&mut self) {
    if self.last_request_time.elapsed() >= STATS_REPORT_INTERVAL {
        self.report();
        *self = Self::new();    // ← resets standstill: false unconditionally
    }
}
```
Resets `standstill` bool to false every 10 s regardless of actual state. Operator metrics report "not in standstill" 10 s after entering. **Verification**: code-review-only (metrics; not safety).

**C6. `pending_safe_to_notar` HashSet may be unbounded** — `votor/src/consensus_pool_service.rs:222, 462-538`
The HashSet is pruned only by `retain` at line 495 (`slot <= highest_finalized` OR block found with parent certified). Under partition, both conditions fail; entries accumulate. **Verification**: test-verifiable.

**C7. `request_switch` / `request_repair` blocking send in event_handler** — `votor/src/event_handler.rs:887-909, 862-884`
```rust
match sender.try_send(event) {
    Err(TrySendError::Full(event)) => {
        error!(...);
        sender.send(event).map_err(...)   // ← unbounded-wait blocking send
    }
    ...
}
```
`switch_bank_sender` is `bounded(100)` (`core/src/tvu.rs:436`). If replay drains slowly, event handler blocks indefinitely, halting voting including standstill refresh. Issues #11284, #11285 acknowledge this category. **Verification**: test-verifiable; **TLA+-modelable** as a liveness bug.

**C8. Standstill handler ordering with Finalized** — `votor/src/event_handler.rs:436-461`
Only `block.0 > standstill_slot` triggers reset in the Finalized handler. If `Standstill(N)` arrives before the in-flight `Finalized((M, _), _)` with `M <= N`, no reset occurs. Currently benign because Standstill carries monotonic `highest_finalized_slot`, but the invariant is unmarked. **Verification**: code-review-only.

---

## 5. Phase 4 — Synthesis into Bug Families (see modeling-brief.md)

See `modeling-brief.md` for the synthesized Bug Families, modeling recommendations, proposed invariants, and the model-checkable / test-verifiable / code-review-only split.

---

## 6. What was NOT covered

- **Tower BFT side**: solana_2 and solana_3 are the canonical briefs. Tower-internal switch threshold, dual configuration, etc., are NOT re-covered here. See those briefs for those mechanisms.
- **Block production (`block_creation_loop`)**: out of scope for this brief; one would need to model leader scheduling.
- **BLS signature scheme correctness**: assumed unforgeable; not modeled. (Per `bft-analysis.md` defaults.)
- **Repair protocol details** (#12466, #12496, #12491): adjacent area with confirmed safety issue (#12496 — Merkle proof malleability). Mentioned but not modeled in this brief; would need its own scope.
- **AG vote rewards** (#11850, #12233): different subsystem; mentioned for completeness only.
- **`block_id` chained validation (SIMD-340)**: post-AG block-id mechanism; verified by deserialization, not in BFT spec scope.

---

## 7. Reference Pointers

### Files in scope (canonical paths at HEAD `21fb994c21`)

**Migration boundary (PRIMARY)**:
- `votor-messages/src/migration.rs` (~780 LOC) — MigrationStatus state machine, set_genesis_block/cert assertions
- `core/src/replay_stage.rs` (5354 LOC) — call sites lines 780-1750 (migration dispatch), 2700-3100 (handle_votable_bank), 4280-4500 (compute_bank_stats with parent_is_super_oc)
- `core/src/consensus.rs` lines 410-600 — `compute_bank_state`, `parent_is_super_oc`
- `runtime/src/block_component_processor.rs` lines 240-270 — set_genesis_* call sequence

**Alpenglow Pool (SECONDARY)**:
- `votor/src/consensus_pool.rs` (2132 LOC)
- `votor/src/consensus_pool/parent_ready_tracker.rs` (418 LOC)
- `votor/src/consensus_pool/vote_pool.rs` (240 LOC)
- `votor/src/consensus_pool/slot_stake_counters.rs` (398 LOC)
- `votor/src/consensus_pool/certificate_builder.rs` (571 LOC)
- `votor/src/common.rs` (constants + conflicting_types + vote_to_cert_types)
- `votor-messages/src/consensus_message.rs` (limits_and_vote_types)

**Vote / Event flow (SECONDARY)**:
- `votor/src/event_handler.rs` (1871 LOC)
- `votor/src/voting_utils.rs` (644 LOC)
- `votor/src/vote_history.rs` (541 LOC)
- `votor/src/vote_history_storage.rs` (241 LOC)
- `votor/src/voting_service.rs` (406 LOC)
- `votor/src/consensus_pool_service.rs` (978 LOC)
- `votor/src/timer_manager/timers.rs`

### Reference: existing Tower BFT briefs (prior work)

- `/home/ubuntu/Specula/case-studies/solana_2/.specula-output/modeling-brief.md` — focuses on Tower bifurcation, switch threshold soundness, crash window, OC equivocation, gossip-vs-replay.
- `/home/ubuntu/Specula/case-studies/solana_3/.specula-output/modeling-brief.md` — overlapping coverage with explicit "Votor / Alpenglow out of scope" note.
- This brief (solana_4) is **complementary** — covers the TBFT⇄AG migration and the AG pool that prior briefs deliberately omitted.

### GitHub issues
- **Migration / pool**: #12039 (deadlock), #12199 (UpdateParent), #12226 (TimeoutCrashedLeader), #12232 (cert rebroadcast), #12328 (SafeToNotar), #12350 (standstill livelock), #12364 (no fincert in snapshot), #12466 (BlockID repair stall), **#12496 (Malleable FEC count)**, #12373 (standstill stats).
- **Tower BFT**: #23135, #25253, #25934, #5850, #7521, #8113 — covered by solana_2/solana_3.

### Reference protocol docs
- Solana TowerBFT: Yakovenko 2018 whitepaper.
- Alpenglow whitepaper (v1.1) — referenced throughout `votor/src/consensus_pool/slot_stake_counters.rs:102-104` ("White paper v1.1 page 22").
- SIMD-340 (chained block id validation), SIMD-357 (VAT), SIMD-291 (commission rate), SIMD-438 (rent increase safeguard).

### Constants reference
- `MIGRATION_SLOT_OFFSET = 5000`, `MIGRATION_MALICIOUS_THRESHOLD = 20%`, `GENESIS_VOTE_THRESHOLD = 82%`, `MAX_NOTAR_FALLBACK_BLOCKS = 7`, `MAX_ENTRIES_PER_PUBKEY_FOR_NOTARIZE_LITE = 3`, `MAX_ENTRIES_PER_PUBKEY_FOR_OTHER_TYPES = 1`.
- All threshold fractions in `votor-messages/src/consensus_message.rs::CertificateType::limits_and_vote_types`.
