// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

//! TLA+ trace emission for Mysticeti consensus.
//!
//! This module emits NDJSON trace events that are validated against the
//! Trace.tla spec in `case-studies/sui/.specula-output/spec/`.
//!
//! Activation: set the `TLA_TRACE_FILE` environment variable to a path before
//! the consensus code runs. Without it, every emit call is a no-op.
//!
//! Each line follows the envelope:
//!   {"tag":"trace","ts":<unix_nanos>,"event":{"name":..,"nid":..,"state":..,...}}
//!
//! Server-ID mapping: AuthorityIndex `i` maps to `"s{i+1}"` (matching
//! `Server = {s1, s2, s3, s4}` in Trace.cfg).

use std::{
    collections::BTreeSet,
    fs::{File, OpenOptions},
    io::{BufWriter, Write},
    sync::{Mutex, OnceLock},
    time::{SystemTime, UNIX_EPOCH},
};

use consensus_config::AuthorityIndex;
use consensus_types::block::{BlockRef, Round};

use crate::block::{BlockAPI, VerifiedBlock};

/// Global trace writer, initialized once.
static WRITER: OnceLock<Option<Mutex<BufWriter<File>>>> = OnceLock::new();

/// Shadow `signedHistory[s]`: set of (authority_index, round, digest_u64) tuples.
/// The spec's `signedHistory[s]` survives Crash (HSM-backed), so we never clear it.
static SIGNED_HISTORY: OnceLock<Mutex<BTreeSet<(u32, u32, u64)>>> = OnceLock::new();

fn signed_history() -> &'static Mutex<BTreeSet<(u32, u32, u64)>> {
    SIGNED_HISTORY.get_or_init(|| Mutex::new(BTreeSet::new()))
}

/// Record a signed (round, digest) for `author`. Mirrors the spec's
/// `signedHistory' = [signedHistory EXCEPT ![s] = @ \cup {(r, d)}]`.
pub fn record_signed(author: AuthorityIndex, round: Round, digest_u64: u64) {
    let mut h = signed_history().lock().expect("signed history poisoned");
    h.insert((author.value() as u32, round, digest_u64));
}

/// Return `Cardinality(signedHistory[s])` for the given validator.
pub fn signed_history_size(author: AuthorityIndex) -> usize {
    let h = signed_history().lock().expect("signed history poisoned");
    let target = author.value() as u32;
    h.iter().filter(|(a, _, _)| *a == target).count()
}

/// Returns the global writer, initializing from `TLA_TRACE_FILE` env var on first use.
fn writer() -> &'static Option<Mutex<BufWriter<File>>> {
    WRITER.get_or_init(|| {
        // The env var is read once per process. Tests that want different output
        // files per scenario should set the env var before any consensus code
        // runs, and run scenarios in separate processes (e.g. via separate test
        // binaries or by configuring tests to fork).
        match std::env::var("TLA_TRACE_FILE") {
            Ok(path) if !path.is_empty() => {
                // Truncate any previous content so each scenario starts clean.
                let f = OpenOptions::new()
                    .create(true)
                    .write(true)
                    .truncate(true)
                    .open(&path)
                    .unwrap_or_else(|e| panic!("TLA_TRACE_FILE open {}: {}", path, e));
                Some(Mutex::new(BufWriter::new(f)))
            }
            _ => None,
        }
    })
}

/// True when tracing is active (file is open).
pub fn enabled() -> bool {
    writer().is_some()
}

/// Map AuthorityIndex (0-indexed) to TLA+ Server name (1-indexed).
pub fn nid(authority: AuthorityIndex) -> String {
    format!("s{}", authority.value() + 1)
}

fn now_nanos() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0)
}

/// Convert a `[u8; 32]` `BlockDigest` to the first-8-byte u64 used in spec/digest fields.
fn block_digest_to_u64(d: &consensus_types::block::BlockDigest) -> u64 {
    let mut bytes = [0u8; 8];
    bytes.copy_from_slice(&d.0[..8]);
    u64::from_le_bytes(bytes)
}

/// Same compression for `CommitDigest` (commit-vote field).
fn commit_digest_to_u64(d: &crate::commit::CommitDigest) -> u64 {
    let inner = d.into_inner();
    let mut bytes = [0u8; 8];
    bytes.copy_from_slice(&inner[..8]);
    u64::from_le_bytes(bytes)
}

/// Serialize a BlockRef to JSON: `{"author":"sN","round":R,"digest":D}`.
fn block_ref_json(r: &BlockRef) -> String {
    format!(
        r#"{{"author":"{}","round":{},"digest":{}}}"#,
        nid(r.author),
        r.round,
        block_digest_to_u64(&r.digest),
    )
}

fn refs_array_json(refs: &[BlockRef]) -> String {
    let parts: Vec<String> = refs.iter().map(block_ref_json).collect();
    format!("[{}]", parts.join(","))
}

/// Serialize a full block to JSON: schema matches Trace.tla::TraceBlock.
fn verified_block_json(b: &VerifiedBlock) -> String {
    let r = b.reference();
    let ancestors = refs_array_json(b.ancestors());
    // commit_votes carry an index + digest; we surface them so Family 5 has data.
    let commit_votes: Vec<String> = b
        .commit_votes()
        .iter()
        .map(|cv| {
            // CommitVote = CommitRef = (index, CommitDigest).
            format!(
                r#"{{"index":{},"digest":{}}}"#,
                cv.index,
                commit_digest_to_u64(&cv.digest)
            )
        })
        .collect();
    format!(
        r#"{{"author":"{author}","round":{round},"digest":{digest},"ancestors":{ancestors},"timestamp":{ts},"commitVotes":[{cv}]}}"#,
        author = nid(r.author),
        round = r.round,
        digest = block_digest_to_u64(&r.digest),
        ancestors = ancestors,
        ts = b.timestamp_ms(),
        cv = commit_votes.join(","),
    )
}

fn slot_json(author: AuthorityIndex, round: Round) -> String {
    format!(r#"{{"author":"{}","round":{}}}"#, nid(author), round)
}

/// Internal: write a complete NDJSON line.
fn write_line(line: String) {
    if let Some(m) = writer().as_ref() {
        let mut guard = m.lock().expect("TLA trace writer poisoned");
        // Best-effort writes: a failed write should not crash a consensus test.
        let _ = guard.write_all(line.as_bytes());
        let _ = guard.write_all(b"\n");
        let _ = guard.flush();
    }
}

/// Emit a `HonestPropose` or `ForcePropose` event. Also updates the shadow
/// `signedHistory[author]` because the block was signed as part of proposal.
pub fn emit_propose(
    force: bool,
    author: AuthorityIndex,
    block: &VerifiedBlock,
    clock_round: Round,
    gc_round: Round,
    last_proposed_round: Round,
) {
    let r = block.reference();
    let digest_u64 = block_digest_to_u64(&r.digest);
    record_signed(author, r.round, digest_u64);
    if !enabled() {
        return;
    }
    let name = if force { "ForcePropose" } else { "HonestPropose" };
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"event":{{"name":"{name}","nid":"{nid}","block":{block},"state":{{"clockRound":{cr},"gcRound":{gc},"lastProposedRound":{lpr},"signedHistorySize":{shs}}}}}}}"#,
        ts = now_nanos(),
        name = name,
        nid = nid(author),
        block = verified_block_json(block),
        cr = clock_round,
        gc = gc_round,
        lpr = last_proposed_round,
        shs = signed_history_size(author),
    );
    write_line(line);
}

/// Emit a `DeliverBlock` event for validator `observer` accepting `block`.
pub fn emit_deliver_block(
    observer: AuthorityIndex,
    block: &VerifiedBlock,
    clock_round: Round,
    gc_round: Round,
) {
    if !enabled() {
        return;
    }
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"event":{{"name":"DeliverBlock","nid":"{nid}","block":{block},"state":{{"clockRound":{cr},"gcRound":{gc}}}}}}}"#,
        ts = now_nanos(),
        nid = nid(observer),
        block = verified_block_json(block),
        cr = clock_round,
        gc = gc_round,
    );
    write_line(line);
}

/// Emit a `TryDirectDecide` event.
pub fn emit_try_direct_decide(
    observer: AuthorityIndex,
    leader_author: AuthorityIndex,
    leader_round: Round,
    outcome: &str,
    commit_ref: Option<&BlockRef>,
    clock_round: Round,
    gc_round: Round,
) {
    if !enabled() {
        return;
    }
    let commit_field = match commit_ref {
        Some(r) => format!(r#","commitRef":{}"#, block_ref_json(r)),
        None => String::new(),
    };
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"event":{{"name":"TryDirectDecide","nid":"{nid}","slot":{slot},"outcome":"{outcome}"{commit_field},"state":{{"clockRound":{cr},"gcRound":{gc}}}}}}}"#,
        ts = now_nanos(),
        nid = nid(observer),
        slot = slot_json(leader_author, leader_round),
        outcome = outcome,
        commit_field = commit_field,
        cr = clock_round,
        gc = gc_round,
    );
    write_line(line);
}

/// Emit a `TryIndirectDecide` event.
pub fn emit_try_indirect_decide(
    observer: AuthorityIndex,
    leader_author: AuthorityIndex,
    leader_round: Round,
    anchor: &BlockRef,
    outcome: &str,
    clock_round: Round,
    gc_round: Round,
) {
    if !enabled() {
        return;
    }
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"event":{{"name":"TryIndirectDecide","nid":"{nid}","slot":{slot},"anchor":{anchor},"outcome":"{outcome}","state":{{"clockRound":{cr},"gcRound":{gc}}}}}}}"#,
        ts = now_nanos(),
        nid = nid(observer),
        slot = slot_json(leader_author, leader_round),
        anchor = block_ref_json(anchor),
        outcome = outcome,
        cr = clock_round,
        gc = gc_round,
    );
    write_line(line);
}

/// Emit a `Linearize` event after a commit has been added to dag state.
pub fn emit_linearize(
    observer: AuthorityIndex,
    leader: &BlockRef,
    commit_seq_len: u64,
    gc_round: Round,
    sub_dag_block_count: usize,
) {
    if !enabled() {
        return;
    }
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"event":{{"name":"Linearize","nid":"{nid}","leader":{leader},"state":{{"commitSeqLen":{csl},"gcRound":{gc}}},"subDagBlockCount":{sdbc}}}}}"#,
        ts = now_nanos(),
        nid = nid(observer),
        leader = block_ref_json(leader),
        csl = commit_seq_len,
        gc = gc_round,
        sdbc = sub_dag_block_count,
    );
    write_line(line);
}

/// Emit a `Crash` event (test-harness-only).
pub fn emit_crash(author: AuthorityIndex) {
    if !enabled() {
        return;
    }
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"event":{{"name":"Crash","nid":"{nid}"}}}}"#,
        ts = now_nanos(),
        nid = nid(author),
    );
    write_line(line);
}

/// Emit a `RecoverAmnesia` event (test-harness-only).
pub fn emit_recover_amnesia(author: AuthorityIndex, last_known_proposed: Round) {
    if !enabled() {
        return;
    }
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"event":{{"name":"RecoverAmnesia","nid":"{nid}","state":{{"lastKnownProposed":{lkp}}}}}}}"#,
        ts = now_nanos(),
        nid = nid(author),
        lkp = last_known_proposed,
    );
    write_line(line);
}

/// Emit an `AddCertifiedCommit` event.
pub fn emit_add_certified_commit(
    author: AuthorityIndex,
    round: Round,
    clock_round: Round,
    certified_commit_round: Round,
) {
    if !enabled() {
        return;
    }
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"event":{{"name":"AddCertifiedCommit","nid":"{nid}","round":{round},"state":{{"clockRound":{cr},"certifiedCommitRound":{ccr}}}}}}}"#,
        ts = now_nanos(),
        nid = nid(author),
        round = round,
        cr = clock_round,
        ccr = certified_commit_round,
    );
    write_line(line);
}

/// Emit a `ByzPropose` event (test-harness-only — simulated Byzantine).
pub fn emit_byz_propose(author: AuthorityIndex, block: &VerifiedBlock) {
    let r = block.reference();
    let digest_u64 = block_digest_to_u64(&r.digest);
    record_signed(author, r.round, digest_u64);
    if !enabled() {
        return;
    }
    let line = format!(
        r#"{{"tag":"trace","ts":{ts},"event":{{"name":"ByzPropose","nid":"{nid}","block":{block},"state":{{"signedHistorySize":{shs}}}}}}}"#,
        ts = now_nanos(),
        nid = nid(author),
        block = verified_block_json(block),
        shs = signed_history_size(author),
    );
    write_line(line);
}
