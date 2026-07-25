// TLA+ trace emission module for Aptos Quorum Store harness.
//
// Writes NDJSON lines (one JSON record per line) to a trace file selected
// either via the APTOS_QS_TLA_TRACE env var or by calling `init(path)`.
// If neither is set the emit functions are no-ops so unrelated unit tests
// can still link without producing trace output.
//
// Every record follows the envelope:
//   {"tag":"trace","ts_us":<int>,"event":{"name":<str>,"nid":<str>,
//                                          "state":{...},"msg":{...}}}
//
// Validator IDs ("nid") are mapped to spec names ("v1","v2","v3","v4") via
// `register_validator`. Unregistered peers fall back to their PeerId
// short-hex prefix.

use aptos_consensus_types::proof_of_store::{BatchInfo, BatchInfoExt, TBatchInfo};
use aptos_crypto::HashValue;
use aptos_short_hex_str::AsShortHexStr;
use aptos_types::PeerId;
use once_cell::sync::Lazy;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::env;
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

struct TraceState {
    file: Option<File>,
    name_map: HashMap<PeerId, String>,
    digest_map: HashMap<HashValue, String>,
    initialized_from_env: bool,
}

static STATE: Lazy<Mutex<TraceState>> = Lazy::new(|| {
    Mutex::new(TraceState {
        file: None,
        name_map: HashMap::new(),
        digest_map: HashMap::new(),
        initialized_from_env: false,
    })
});

fn ensure_env_initialized(state: &mut TraceState) {
    if state.initialized_from_env {
        return;
    }
    state.initialized_from_env = true;
    if let Ok(path) = env::var("APTOS_QS_TLA_TRACE") {
        if !path.is_empty() {
            state.file = OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
                .ok();
        }
    }
}

/// Open (truncate + create) the given path as the active trace file. Resets
/// the validator name map. Subsequent emits write here until init is called
/// again (or the process exits).
pub fn init(path: &str) {
    let mut s = STATE.lock().expect("trace state mutex poisoned");
    s.file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(path)
        .ok();
    s.name_map.clear();
    s.digest_map.clear();
    s.initialized_from_env = true;
}

pub fn register_validator(peer: PeerId, spec_name: &str) {
    let mut s = STATE.lock().expect("trace state mutex poisoned");
    ensure_env_initialized(&mut s);
    s.name_map.insert(peer, spec_name.to_string());
}

pub fn register_digest(d: HashValue, spec_name: &str) {
    let mut s = STATE.lock().expect("trace state mutex poisoned");
    ensure_env_initialized(&mut s);
    s.digest_map.insert(d, spec_name.to_string());
}

fn nid_locked(state: &TraceState, peer: PeerId) -> String {
    state
        .name_map
        .get(&peer)
        .cloned()
        .unwrap_or_else(|| peer.short_str().to_string())
}

pub fn nid(peer: PeerId) -> String {
    let s = STATE.lock().expect("trace state mutex poisoned");
    nid_locked(&s, peer)
}

fn now_us() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_micros() as u64)
        .unwrap_or(0)
}

pub fn enabled() -> bool {
    let mut s = match STATE.lock() {
        Ok(g) => g,
        Err(_) => return false,
    };
    ensure_env_initialized(&mut s);
    s.file.is_some()
}

pub fn emit(event_name: &str, peer: PeerId, state_fields: Value, msg_fields: Value) {
    let mut s = match STATE.lock() {
        Ok(g) => g,
        Err(_) => return,
    };
    ensure_env_initialized(&mut s);
    if s.file.is_none() {
        return;
    }
    let nid = nid_locked(&s, peer);
    let line = json!({
        "tag": "trace",
        "ts_us": now_us(),
        "event": {
            "name": event_name,
            "nid": nid,
            "state": state_fields,
            "msg": msg_fields,
        }
    });
    if let Some(file) = s.file.as_mut() {
        let _ = writeln!(file, "{}", line);
        let _ = file.flush();
    }
}

pub fn emit_no_msg(event_name: &str, peer: PeerId, state_fields: Value) {
    emit(event_name, peer, state_fields, json!({}));
}

pub fn emit_config(config: Value) {
    let mut s = match STATE.lock() {
        Ok(g) => g,
        Err(_) => return,
    };
    ensure_env_initialized(&mut s);
    if let Some(file) = s.file.as_mut() {
        let line = json!({
            "tag": "config",
            "ts_us": now_us(),
            "config": config,
        });
        let _ = writeln!(file, "{}", line);
        let _ = file.flush();
    }
}

pub fn digest_str(d: &HashValue) -> String {
    let s = STATE.lock().expect("trace state mutex poisoned");
    s.digest_map
        .get(d)
        .cloned()
        .unwrap_or_else(|| d.to_hex())
}

pub fn batch_info_msg(info: &BatchInfo) -> Value {
    json!({
        "author": nid(info.author()),
        "batchId": info.batch_id().id,
        "digest": digest_str(info.digest()),
        "epoch": info.epoch(),
        "expiration": info.expiration(),
    })
}

pub fn batch_info_ext_msg(info: &BatchInfoExt) -> Value {
    json!({
        "author": nid(info.author()),
        "batchId": info.batch_id().id,
        "digest": digest_str(info.digest()),
        "epoch": info.epoch(),
        "expiration": info.expiration(),
    })
}

// Convenience constructors for the actions in instrumentation-spec.md.

pub fn emit_reserve_batch_id(
    self_peer: PeerId,
    persisted_batch_id: u64,
    in_flight_batch_id: u64,
    info: &BatchInfoExt,
) {
    emit(
        "ReserveBatchId",
        self_peer,
        json!({
            "persistedBatchId": persisted_batch_id,
            "inFlightBatchId": in_flight_batch_id,
        }),
        batch_info_ext_msg(info),
    );
}

pub fn emit_persist_payload(self_peer: PeerId, info: &BatchInfoExt) {
    emit(
        "PersistPayload",
        self_peer,
        json!({
            "persistedDigest": digest_str(info.digest()),
        }),
        json!({}),
    );
}

pub fn emit_broadcast_batch_msg(self_peer: PeerId, info: &BatchInfoExt) {
    emit(
        "BroadcastBatchMsg",
        self_peer,
        json!({
            "inFlightBatchId": info.batch_id().id,
        }),
        batch_info_ext_msg(info),
    );
}

pub fn emit_handle_batches_msg(self_peer: PeerId, info: &BatchInfoExt) {
    emit(
        "HandleBatchesMsg",
        self_peer,
        json!({
            "handledDigest": digest_str(info.digest()),
        }),
        batch_info_ext_msg(info),
    );
}

pub fn emit_receive_signed_batch_info(
    self_peer: PeerId,
    info: &BatchInfoExt,
    signer: PeerId,
) {
    emit(
        "ReceiveSignedBatchInfo",
        self_peer,
        json!({
            "signedDigest": digest_str(info.digest()),
            "signer": nid(signer),
        }),
        json!({
            "signer": nid(signer),
            "digest": digest_str(info.digest()),
            "batchId": info.batch_id().id,
            "author": nid(info.author()),
        }),
    );
}

pub fn emit_aggregate_proof(self_peer: PeerId, info: &BatchInfoExt) {
    emit(
        "AggregateProof",
        self_peer,
        json!({
            "aggregatedDigest": digest_str(info.digest()),
        }),
        json!({
            "digest": digest_str(info.digest()),
            "batchId": info.batch_id().id,
            "author": nid(info.author()),
        }),
    );
}

pub fn emit_handle_proof_msg(self_peer: PeerId, info: &BatchInfoExt) {
    let msg = json!({
        "digest": digest_str(info.digest()),
        "author": nid(info.author()),
        "batchId": info.batch_id().id,
    });
    emit(
        "HandleProofMsg",
        self_peer,
        json!({
            "proofDigest": digest_str(info.digest()),
            "proofAuthor": nid(info.author()),
            "proofBatchId": info.batch_id().id,
        }),
        msg,
    );
}

pub fn emit_advance_certified_time(self_peer: PeerId, certified_time: u64) {
    emit(
        "AdvanceCertifiedTime",
        self_peer,
        json!({
            "certifiedTime": certified_time,
        }),
        json!({}),
    );
}

pub fn emit_crash(self_peer: PeerId) {
    emit("Crash", self_peer, json!({}), json!({}));
}

pub fn emit_recover(self_peer: PeerId) {
    emit("Recover", self_peer, json!({}), json!({}));
}

pub fn emit_epoch_transition(self_peer: PeerId, epoch: u64) {
    emit(
        "EpochTransition",
        self_peer,
        json!({
            "epoch": epoch,
        }),
        json!({}),
    );
}

pub fn emit_build_proposal(self_peer: PeerId, proposal_size: usize) {
    emit(
        "BuildProposal",
        self_peer,
        json!({
            "proposalSize": proposal_size,
        }),
        json!({}),
    );
}

pub fn emit_commit_proposal(self_peer: PeerId, proposer: PeerId) {
    emit(
        "CommitProposal",
        self_peer,
        json!({
            "proposer": nid(proposer),
        }),
        json!({}),
    );
}

pub fn emit_fetch_batch_success(self_peer: PeerId, digest: &HashValue) {
    emit(
        "FetchBatchSuccess",
        self_peer,
        json!({
            "fetchedDigest": digest_str(digest),
        }),
        json!({
            "digest": digest_str(digest),
        }),
    );
}
