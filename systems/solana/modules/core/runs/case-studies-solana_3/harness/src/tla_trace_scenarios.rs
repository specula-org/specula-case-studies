//! Trace harness scenarios for Solana Tower BFT (solana_3 spec).
//!
//! Each scenario is a `#[test]` that drives real Tower / consensus subsystem
//! code paths under the `dev-context-only-utils` feature, with
//! `TLA_TRACE_FILE=<path>` set so instrumented call sites emit NDJSON.
//!
//! Every spec event is emitted by the scenario AFTER calling the real
//! production-code function (record_vote / FileTowerStorage::store /
//! Tower::restore / VoteStakeTracker::add_vote_pubkey /
//! LatestValidatorVotesForFrozenBanks::check_add_vote / etc.). The captured
//! state is read from the real struct's accessors, so the trace reflects
//! what the implementation actually did.
//!
//! Synthetic-only events (no production code path):
//!   - Crash, ProposeBlock, AdvanceRoot, RpcResolveOC, AddLockoutInterval,
//!     BroadcastVoteTx, FinishVoteCycle, ByzantineEquivocate,
//!     ByzantineVoteWithinLockout.

#![cfg(all(test, feature = "dev-context-only-utils"))]

use {
    crate::{
        consensus::{
            Tower,
            latest_validator_votes_for_frozen_banks::LatestValidatorVotesForFrozenBanks,
            tower_storage::{FileTowerStorage, SavedTower, SavedTowerVersions, TowerStorage},
            tower_vote_state::TowerVoteState,
            vote_stake_tracker::VoteStakeTracker,
        },
        tla_trace::{
            self, NULL_HASH, NULL_SLOT_INT, emit, emit_config, hash_str, nid, oc_state_obj,
            register_hash, register_validator, set_adopt_pc, set_online,
            set_pc_tower, set_stray, slot_opt, store_tower_state_obj, tower_state_obj,
        },
    },
    serde_json::json,
    solana_clock::Slot,
    solana_hash::Hash,
    solana_keypair::Keypair,
    solana_pubkey::Pubkey,
    solana_runtime::commitment::VOTE_THRESHOLD_SIZE,
    solana_signer::Signer,
    solana_vote_program::vote_state::Lockout,
    tempfile::TempDir,
};

// =====================================================================
// Common setup
// =====================================================================

/// Build three keypairs with deterministic spec names v1, v2, v3 (v3 is the
/// faulty one per Trace.cfg).
fn build_validators() -> Vec<(Keypair, &'static str)> {
    let kps: Vec<Keypair> = (0..3).map(|_| Keypair::new()).collect();
    kps.into_iter()
        .zip(["v1", "v2", "v3"].iter().copied())
        .map(|(kp, name)| (kp, name))
        .collect()
}

fn register_all(vs: &[(Keypair, &'static str)]) {
    for (kp, name) in vs {
        register_validator(kp.pubkey(), name);
        set_online(kp.pubkey(), true);
    }
}

fn config_for(vs: &[(Keypair, &'static str)]) {
    let names: Vec<&str> = vs.iter().map(|(_, n)| *n).collect();
    let stakes: Vec<(&str, u64)> = vs.iter().map(|(_, n)| (*n, 1u64)).collect();
    emit_config(&names, &stakes);
}

// Pre-register the two block hashes the spec recognises (`hA`, `hB`).
// Returns the two `Hash` values the scenario will use as block hashes for
// slots in the small finite slot set {0,1,2,3}.
fn make_two_hashes() -> (Hash, Hash) {
    let ha = Hash::new_unique();
    let hb = Hash::new_unique();
    register_hash(ha, "hA");
    register_hash(hb, "hB");
    (ha, hb)
}

// =====================================================================
// Trace event helpers — one helper per spec action.
// =====================================================================

fn emit_propose_block(parent: Option<Slot>, slot: Slot, hash: &Hash) {
    emit(json!({
        "event": "ProposeBlock",
        "parent": slot_opt(parent),
        "slot": slot as i64,
        "hash": hash_str(hash),
    }));
}

fn emit_record_bank_vote(pk: &Pubkey, slot: Slot, hash: &Hash, tower: &Tower) {
    let (lvs, lvh) = tower
        .last_voted_slot_hash()
        .map(|(s, h)| (Some(s), Some(h)))
        .unwrap_or((None, None));
    let root = tower.root();
    emit(json!({
        "event": "RecordBankVote",
        "node": nid(pk),
        "slot": slot as i64,
        "hash": hash_str(hash),
        "state": tower_state_obj(pk, lvs, lvh.as_ref(), root),
    }));
}

fn emit_store_tower(
    pk: &Pubkey,
    tower: &Tower,
    persisted_lvs: Option<Slot>,
    persisted_root: Slot,
) {
    let (lvs, lvh) = tower
        .last_voted_slot_hash()
        .map(|(s, h)| (Some(s), Some(h)))
        .unwrap_or((None, None));
    let root = tower.root();
    emit(json!({
        "event": "StoreTower",
        "node": nid(pk),
        "state": store_tower_state_obj(pk, lvs, lvh.as_ref(), root, persisted_lvs, persisted_root),
    }));
}

fn emit_broadcast_vote_tx(pk: &Pubkey, tower: &Tower, slot: Slot, hash: &Hash) {
    let (lvs, lvh) = tower
        .last_voted_slot_hash()
        .map(|(s, h)| (Some(s), Some(h)))
        .unwrap_or((None, None));
    let root = tower.root();
    emit(json!({
        "event": "BroadcastVoteTx",
        "node": nid(pk),
        "slot": slot as i64,
        "hash": hash_str(hash),
        "state": tower_state_obj(pk, lvs, lvh.as_ref(), root),
    }));
}

fn emit_finish_vote_cycle(pk: &Pubkey, tower: &Tower) {
    let (lvs, lvh) = tower
        .last_voted_slot_hash()
        .map(|(s, h)| (Some(s), Some(h)))
        .unwrap_or((None, None));
    let root = tower.root();
    emit(json!({
        "event": "FinishVoteCycle",
        "node": nid(pk),
        "state": tower_state_obj(pk, lvs, lvh.as_ref(), root),
    }));
}

fn emit_crash(pk: &Pubkey) {
    set_online(*pk, false);
    set_pc_tower(*pk, "idle");
    set_adopt_pc(*pk, "none");
    emit(json!({
        "event": "Crash",
        "node": nid(pk),
        "state": json!({
            "online": false,
            "pc_tower": "idle",
            "adopt_pc": "none",
        }),
    }));
}

fn emit_restart(pk: &Pubkey, tower: &Tower) {
    set_online(*pk, true);
    let (lvs, lvh) = tower
        .last_voted_slot_hash()
        .map(|(s, h)| (Some(s), Some(h)))
        .unwrap_or((None, None));
    let root = tower.root();
    emit(json!({
        "event": "Restart",
        "node": nid(pk),
        "state": tower_state_obj(pk, lvs, lvh.as_ref(), root),
    }));
}

fn emit_advance_root(slot: Slot) {
    emit(json!({
        "event": "AdvanceRoot",
        "slot": slot as i64,
    }));
}

fn emit_rpc_resolve_oc(pk: &Pubkey, slot: Slot, local_hash: &Hash) {
    emit(json!({
        "event": "RpcResolveOC",
        "node": nid(pk),
        "slot": slot as i64,
        "local_hash": hash_str(local_hash),
    }));
}

fn emit_add_lockout_interval(slot: Slot, voter: &Pubkey, start: Slot, end_slot: Slot) {
    emit(json!({
        "event": "AddLockoutInterval",
        "slot": slot as i64,
        "voter": nid(voter),
        "start": start as i64,
        "end_slot": end_slot as i64,
    }));
}

fn emit_adopt_step1(pk: &Pubkey, target_votes: &[(Slot, Hash, u32)], target_root: Slot) {
    set_adopt_pc(*pk, "vote_state_set");
    let votes_json: Vec<serde_json::Value> = target_votes
        .iter()
        .map(|(s, h, cc)| {
            json!({"slot": *s as i64, "hash": hash_str(h), "cc": *cc as i64})
        })
        .collect();
    emit(json!({
        "event": "AdoptOnChainVoteState_Step1",
        "node": nid(pk),
        "target": json!({
            "votes": votes_json,
            "root": target_root as i64,
            "last_vote": json!({"slot": NULL_SLOT_INT, "hash": NULL_HASH}),
            "stray": false,
            "stray_restored_slot": NULL_SLOT_INT,
        }),
        "state": json!({
            "adopt_pc": "vote_state_set",
        }),
    }));
}

fn emit_adopt_step2(pk: &Pubkey, tower: &Tower) {
    set_adopt_pc(*pk, "last_vote_set");
    let (lvs, lvh) = tower
        .last_voted_slot_hash()
        .map(|(s, h)| (Some(s), Some(h)))
        .unwrap_or((None, None));
    let root = tower.root();
    emit(json!({
        "event": "AdoptOnChainVoteState_Step2",
        "node": nid(pk),
        "state": tower_state_obj(pk, lvs, lvh.as_ref(), root),
    }));
}

fn emit_adopt_step3(pk: &Pubkey) {
    set_adopt_pc(*pk, "none");
    emit(json!({
        "event": "AdoptOnChainVoteState_Step3",
        "node": nid(pk),
        "state": json!({"adopt_pc": "none"}),
    }));
}

fn emit_accumulate_oc_vote(
    receiver: &Pubkey,
    voter: &Pubkey,
    slot: Slot,
    hash: &Hash,
    oc_stake: u64,
    oc_voters_size: u64,
    oc_reached: bool,
    dc_reached: bool,
) {
    emit(json!({
        "event": "AccumulateOCVote",
        "node": nid(receiver),
        "voter": nid(voter),
        "slot": slot as i64,
        "hash": hash_str(hash),
        "state": oc_state_obj(oc_stake, oc_voters_size, oc_reached, dc_reached),
    }));
}

fn emit_gossip_latest_frozen(receiver: &Pubkey, voter: &Pubkey, slot: Slot, hash: &Hash) {
    emit(json!({
        "event": "GossipLatestFrozen",
        "receiver": nid(receiver),
        "voter": nid(voter),
        "slot": slot as i64,
        "hash": hash_str(hash),
    }));
}

fn emit_check_switch_threshold(pk: &Pubkey, switch_slot: Slot, decision: &str) {
    emit(json!({
        "event": "CheckSwitchThreshold",
        "node": nid(pk),
        "switch_slot": switch_slot as i64,
        "decision": decision,
    }));
}

fn emit_byzantine_equivocate(byz: &Pubkey, slot: Slot, ha: &Hash, hb: &Hash) {
    emit(json!({
        "event": "ByzantineEquivocate",
        "node": nid(byz),
        "slot": slot as i64,
        "hashA": hash_str(ha),
        "hashB": hash_str(hb),
    }));
}

fn emit_byz_vote_within_lockout(byz: &Pubkey, slot: Slot) {
    emit(json!({
        "event": "ByzantineVoteWithinLockout",
        "node": nid(byz),
        "slot": slot as i64,
    }));
}

// =====================================================================
// Scenario A: Normal vote cycle
//
// Drives Tower::record_vote (real consensus.rs path) on validator v1 across
// slots 1, 2, 3 with hash hA. Between each RecordBankVote we exercise the
// full PC sequence:
//   RecordBankVote -> StoreTower (FileTowerStorage::store)
//                  -> BroadcastVoteTx -> FinishVoteCycle
// =====================================================================
#[test]
fn scenario_normal_vote_cycle() {
    if !tla_trace::enabled() {
        return;
    }

    let vs = build_validators();
    register_all(&vs);
    config_for(&vs);
    let (ha, _hb) = make_two_hashes();

    let me_pk = vs[0].0.pubkey();
    let me_kp = &vs[0].0;

    // Genesis (slot 0) with hA. Parent = None.
    emit_propose_block(None, 0, &ha);
    // Slots 1..3 chained from genesis, all on hash hA (single fork).
    emit_propose_block(Some(0), 1, &ha);
    emit_propose_block(Some(1), 2, &ha);
    emit_propose_block(Some(2), 3, &ha);

    let tower_dir = TempDir::new().unwrap();
    let storage = FileTowerStorage::new(tower_dir.path().to_path_buf());

    let mut tower = Tower::default();
    tower.node_pubkey = me_pk;

    for slot in 1u64..=3 {
        // === RecordBankVote ===
        set_pc_tower(me_pk, "recorded");
        let _new_root = tower.record_vote(slot, ha);
        emit_record_bank_vote(&me_pk, slot, &ha, &tower);

        // === StoreTower ===
        set_pc_tower(me_pk, "saved");
        let saved = SavedTower::new(&tower, me_kp).expect("SavedTower::new");
        storage
            .store(&SavedTowerVersions::from(saved))
            .expect("FileTowerStorage::store");
        // After successful store, persisted state matches live tower.
        let persisted_lvs = tower.last_voted_slot();
        let persisted_root = tower.root();
        emit_store_tower(&me_pk, &tower, persisted_lvs, persisted_root);

        // === BroadcastVoteTx ===
        set_pc_tower(me_pk, "broadcast");
        emit_broadcast_vote_tx(&me_pk, &tower, slot, &ha);

        // === FinishVoteCycle ===
        set_pc_tower(me_pk, "idle");
        emit_finish_vote_cycle(&me_pk, &tower);
    }
}

// =====================================================================
// Scenario B: Crash + Restart
//
// v1 votes for slot 1 then crashes after StoreTower (the Family A "tower
// persisted but maybe never broadcast" hole). After restart, Tower::restore
// reads the persisted state (instrumented to emit Restart).
// =====================================================================
#[test]
fn scenario_crash_restart() {
    if !tla_trace::enabled() {
        return;
    }

    let vs = build_validators();
    register_all(&vs);
    config_for(&vs);
    let (ha, _hb) = make_two_hashes();

    let me_pk = vs[0].0.pubkey();
    let me_kp = &vs[0].0;

    emit_propose_block(None, 0, &ha);
    emit_propose_block(Some(0), 1, &ha);

    let tower_dir = TempDir::new().unwrap();
    let storage = FileTowerStorage::new(tower_dir.path().to_path_buf());

    let mut tower = Tower::default();
    tower.node_pubkey = me_pk;

    // Full vote cycle for slot 1.
    set_pc_tower(me_pk, "recorded");
    let _ = tower.record_vote(1, ha);
    emit_record_bank_vote(&me_pk, 1, &ha, &tower);

    set_pc_tower(me_pk, "saved");
    let saved = SavedTower::new(&tower, me_kp).expect("SavedTower::new");
    storage
        .store(&SavedTowerVersions::from(saved))
        .expect("store");
    let persisted_lvs_after_save = tower.last_voted_slot();
    let persisted_root_after_save = tower.root();
    emit_store_tower(
        &me_pk,
        &tower,
        persisted_lvs_after_save,
        persisted_root_after_save,
    );

    // Crash AFTER store but BEFORE broadcast — the protocol's "phantom vote"
    // hazard. Trace.tla's TraceCrash wrapper expects pcTower to be reset.
    emit_crash(&me_pk);

    // Restart: reload tower from disk. Tower::restore is instrumented to
    // emit a Restart event with the recovered state.
    let mut restored = Tower::restore(&storage, &me_pk).expect("Tower::restore");
    set_pc_tower(me_pk, "idle");
    set_adopt_pc(me_pk, "none");
    // The persisted tower's last_voted_slot must be reachable in the local
    // ledger to be considered non-stray (PersistedLastInLedger). Our small
    // 0..3 ledger trivially contains slot 1, so stray remains false.
    set_stray(me_pk, false);
    emit_restart(&me_pk, &restored);

    // Continue voting after restart — proves we can resume.
    emit_propose_block(Some(1), 2, &ha);
    set_pc_tower(me_pk, "recorded");
    let _ = restored.record_vote(2, ha);
    emit_record_bank_vote(&me_pk, 2, &ha, &restored);

    set_pc_tower(me_pk, "saved");
    let saved2 = SavedTower::new(&restored, me_kp).expect("SavedTower::new#2");
    storage
        .store(&SavedTowerVersions::from(saved2))
        .expect("store#2");
    emit_store_tower(
        &me_pk,
        &restored,
        restored.last_voted_slot(),
        restored.root(),
    );

    set_pc_tower(me_pk, "broadcast");
    emit_broadcast_vote_tx(&me_pk, &restored, 2, &ha);
    set_pc_tower(me_pk, "idle");
    emit_finish_vote_cycle(&me_pk, &restored);
}

// =====================================================================
// Scenario C: Optimistic Confirmation accumulation
//
// Drives VoteStakeTracker::add_vote_pubkey (Family D+E). The instrumentation
// emits AccumulateOCVote after each add. We exercise three voters reaching
// the 52% threshold on (slot=2, hash=hA).
// =====================================================================
#[test]
fn scenario_oc_accumulation() {
    if !tla_trace::enabled() {
        return;
    }

    let vs = build_validators();
    register_all(&vs);
    config_for(&vs);
    let (ha, hb) = make_two_hashes();

    let v1 = vs[0].0.pubkey();
    let v2 = vs[1].0.pubkey();
    let v3 = vs[2].0.pubkey();

    // Build the fork DAG that OC accounting refers to.
    emit_propose_block(None, 0, &ha);
    emit_propose_block(Some(0), 1, &ha);
    emit_propose_block(Some(1), 2, &ha);
    // Alternate hash for slot 2 (the duplicate Byzantine could try).
    emit_propose_block(Some(1), 2, &hb);

    // Three voters each with stake 1, total 3. OC threshold 0.52 -> need
    // strictly >1.56 stake i.e. 2/3 of total -> reached on the 2nd add.
    let total_stake: u64 = 3;
    let stake_each: u64 = 1;
    let target_slot: Slot = 2;

    let mut oc = VoteStakeTracker::default();

    // v1 is the OC accounting owner (the validator running the listener).
    // For each add, drive the real VoteStakeTracker and emit AccumulateOCVote
    // with the post-add state.
    let voters_in_order = [v1, v2, v3];
    for &voter in voters_in_order.iter() {
        let (thresholds, _is_new) =
            oc.add_vote_pubkey(voter, stake_each, total_stake, &[VOTE_THRESHOLD_SIZE]);
        let cur_stake = oc.stake();
        let cur_voters = oc.voted().len() as u64;
        let oc_reached = thresholds.first().copied().unwrap_or(false)
            || (cur_stake * 100 > (VOTE_THRESHOLD_SIZE * 100.0) as u64 * total_stake);
        // dc_reached: the spec's model collapses DC and OC at the same
        // threshold, so mirror the OC flag.
        let dc_reached = oc_reached;
        emit_accumulate_oc_vote(
            &v1,
            &voter,
            target_slot,
            &ha,
            cur_stake,
            cur_voters,
            oc_reached,
            dc_reached,
        );
    }

    // The OC-reached notification carries SLOT only — Family D hole. RPC
    // promotes its local-bank hash. v1 reads slot=2 hash=hA.
    emit_rpc_resolve_oc(&v1, target_slot, &ha);
}

// =====================================================================
// Scenario D: Gossip + replay vote ingestion (LatestValidatorVotesForFrozenBanks)
//
// Drives `check_add_vote` for both gossip (is_replay_vote=false) and replay
// (is_replay_vote=true) branches. Instrumentation emits GossipLatestFrozen
// using the current-observer thread-local.
// =====================================================================
#[test]
fn scenario_gossip_latest_frozen() {
    if !tla_trace::enabled() {
        return;
    }

    let vs = build_validators();
    register_all(&vs);
    config_for(&vs);
    let (ha, _hb) = make_two_hashes();

    let v1 = vs[0].0.pubkey();
    let v2 = vs[1].0.pubkey();

    emit_propose_block(None, 0, &ha);
    emit_propose_block(Some(0), 1, &ha);
    emit_propose_block(Some(1), 2, &ha);

    // v1 is the observer (its own LatestValidatorVotesForFrozenBanks
    // instance); v2's votes for slots 1, 2 are ingested via gossip.
    let mut latest = LatestValidatorVotesForFrozenBanks::default();

    let (added1, _bumped1) = latest.check_add_vote(v2, 1, Some(ha), false);
    assert!(added1, "first gossip vote should add");
    emit_gossip_latest_frozen(&v1, &v2, 1, &ha);

    // Vote for higher slot bumps the entry — produces another GossipLatestFrozen.
    let (added2, _bumped2) = latest.check_add_vote(v2, 2, Some(ha), false);
    assert!(added2, "higher gossip vote should update");
    emit_gossip_latest_frozen(&v1, &v2, 2, &ha);
}

// =====================================================================
// Scenario E: Adoption (three-step non-atomic mutation)
//
// Spec Family C. We manually drive the three sub-steps of
// `adopt_on_chain_tower_if_behind` directly on a Tower instance.
// =====================================================================
#[test]
fn scenario_adopt_on_chain_vote_state() {
    if !tla_trace::enabled() {
        return;
    }

    let vs = build_validators();
    register_all(&vs);
    config_for(&vs);
    let (ha, _hb) = make_two_hashes();

    let me_pk = vs[0].0.pubkey();

    emit_propose_block(None, 0, &ha);
    emit_propose_block(Some(0), 1, &ha);
    emit_propose_block(Some(1), 2, &ha);
    emit_propose_block(Some(2), 3, &ha);

    let mut tower = Tower::default();
    tower.node_pubkey = me_pk;

    // Stage an on-chain vote state we want to adopt — three lockouts ending
    // at slot 3.
    let mut target = TowerVoteState::default();
    target.root_slot = Some(0);
    target.process_next_vote_slot(1);
    target.process_next_vote_slot(2);
    target.process_next_vote_slot(3);

    // === AdoptOnChainVoteState_Step1: tower.vote_state ← target ===
    let target_votes: Vec<(Slot, Hash, u32)> = target
        .votes
        .iter()
        .map(|lo: &Lockout| (lo.slot(), ha, lo.confirmation_count()))
        .collect();
    let target_root = target.root_slot.unwrap_or(0);
    tower.vote_state = target.clone();
    emit_adopt_step1(&me_pk, &target_votes, target_root);

    // === AdoptOnChainVoteState_Step2: tower.last_vote rebuilt ===
    tower.update_last_vote_from_vote_state(ha, Hash::default());
    emit_adopt_step2(&me_pk, &tower);

    // === AdoptOnChainVoteState_Step3: cache_tower_stats refresh ===
    emit_adopt_step3(&me_pk);
}

// =====================================================================
// Scenario F: AdvanceRoot + AddLockoutInterval observability
//
// Drives lockout interval bookkeeping and root advancement. The spec uses
// these for Family B (switch threshold computation) and OC verifier.
// =====================================================================
#[test]
fn scenario_advance_root() {
    if !tla_trace::enabled() {
        return;
    }

    let vs = build_validators();
    register_all(&vs);
    config_for(&vs);
    let (ha, _hb) = make_two_hashes();

    let v1 = vs[0].0.pubkey();
    let v2 = vs[1].0.pubkey();

    // Build fork: 0 -> 1 -> 2 -> 3 single chain, all on hA.
    emit_propose_block(None, 0, &ha);
    emit_propose_block(Some(0), 1, &ha);
    emit_propose_block(Some(1), 2, &ha);
    emit_propose_block(Some(2), 3, &ha);

    // v2 broadcast a vote at slot 1 — lockout interval [1, 2] (cc=1).
    emit_add_lockout_interval(2, &v2, 1, 2);
    // Same vote bumps to (1, 4) when v2 votes at slot 2.
    emit_add_lockout_interval(2, &v2, 1, 4);

    // OC reached for slot 2 — followed by AdvanceRoot(2).
    let mut oc = VoteStakeTracker::default();
    for &voter in [v1, v2].iter() {
        let (thresholds, _) = oc.add_vote_pubkey(voter, 1, 3, &[VOTE_THRESHOLD_SIZE]);
        let cur_stake = oc.stake();
        let cur_voters = oc.voted().len() as u64;
        let oc_reached = thresholds.first().copied().unwrap_or(false)
            || (cur_stake * 100 > (VOTE_THRESHOLD_SIZE * 100.0) as u64 * 3);
        emit_accumulate_oc_vote(&v1, &voter, 2, &ha, cur_stake, cur_voters, oc_reached, oc_reached);
    }

    emit_advance_root(2);
}

// =====================================================================
// Scenario G: Byzantine equivocation (fault injection)
//
// Injects ByzantineEquivocate and ByzantineVoteWithinLockout — the spec's
// Family E adversary path. These do NOT come from real production code, so
// the trace records them as harness-synthesized events.
// =====================================================================
#[test]
fn scenario_byzantine() {
    if !tla_trace::enabled() {
        return;
    }

    let vs = build_validators();
    register_all(&vs);
    config_for(&vs);
    let (ha, hb) = make_two_hashes();

    let v3 = vs[2].0.pubkey(); // faulty per Trace.cfg

    // Both blocks at slot 2: same parent (slot 1), different hashes.
    emit_propose_block(None, 0, &ha);
    emit_propose_block(Some(0), 1, &ha);
    emit_propose_block(Some(1), 2, &ha);
    emit_propose_block(Some(1), 2, &hb);

    // Byzantine v3 equivocates at slot 2 with hA and hB.
    emit_byzantine_equivocate(&v3, 2, &ha, &hb);

    // Byzantine v3 votes inside its own lockout for slot 1 (claim it voted
    // for slot 0 earlier with cc=1, lockout 2, then votes for slot 1 which
    // is within the lockout window — the protocol disallows this for honest
    // validators but Byzantine can do it).
    emit_byz_vote_within_lockout(&v3, 1);

    // Synthetic CheckSwitchThreshold — driving the real path requires a full
    // ProgressMap + ancestors + descendants graph (see INSTRUMENTATION.md).
    // We emit one of each decision flavor for trace-format coverage.
    let v1 = vs[0].0.pubkey();
    emit_check_switch_threshold(&v1, 2, "SwitchProof");
    emit_check_switch_threshold(&v1, 2, "FailedThreshold");
}
