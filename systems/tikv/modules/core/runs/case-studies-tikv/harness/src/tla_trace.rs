//! TLA+ trace emission for raft-rs.
//!
//! Writes NDJSON trace lines to a file specified by `RAFT_TRACE_FILE` env var.
//! If the env var is not set, all emit calls are no-ops.
//!
//! Thread-safe via `OnceLock<Mutex<...>>`.

use std::fs::OpenOptions;
use std::io::{BufWriter, Write};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::StateRole;

static WRITER: OnceLock<Mutex<BufWriter<std::fs::File>>> = OnceLock::new();

/// Initialize trace writer from `RAFT_TRACE_FILE` environment variable.
/// If the env var is not set, tracing remains disabled (all emit calls are no-ops).
pub fn init_from_env() {
    if let Ok(path) = std::env::var("RAFT_TRACE_FILE") {
        init(&path);
    }
}

/// Initialize trace writer with an explicit file path.
pub fn init(path: &str) {
    let file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(path)
        .unwrap_or_else(|e| panic!("Failed to create trace file {}: {}", path, e));
    WRITER.set(Mutex::new(BufWriter::new(file))).ok();
}

/// Returns true if tracing is active.
#[inline]
pub fn is_active() -> bool {
    WRITER.get().is_some()
}

fn role_str(role: StateRole) -> &'static str {
    match role {
        StateRole::Follower => "Follower",
        StateRole::Candidate => "Candidate",
        StateRole::Leader => "Leader",
        StateRole::PreCandidate => "PreCandidate",
    }
}

fn now_nanos() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos() as u64
}

fn write_line(line: &str) {
    if let Some(writer) = WRITER.get() {
        if let Ok(mut w) = writer.lock() {
            let _ = writeln!(w, "{}", line);
            let _ = w.flush();
        }
    }
}

/// Emit a trace event with full state snapshot and optional extra JSON fields.
///
/// `extra` should be a pre-formatted JSON fragment starting with a comma,
/// e.g. `r#","from":2,"accepted":true"#`. Pass `""` for no extra fields.
pub fn emit_state(
    event: &str,
    node: u64,
    term: u64,
    role: StateRole,
    commit: u64,
    last_index: u64,
    last_term: u64,
    persisted: u64,
    vote: u64,
    leader_id: u64,
    extra: &str,
) {
    if !is_active() {
        return;
    }
    // Use 0 for "no value" — TLA+ JSON parser doesn't support null.
    // INVALID_ID = 0 in raft-rs, Nil in spec. Trace.tla doesn't validate these fields.
    let voted_for = vote;
    let leader = leader_id;
    let line = format!(
        r#"{{"tag":"trace","event":"{}","node":{},"state":{{"term":{},"role":"{}","commit":{},"lastLogIndex":{},"lastLogTerm":{},"persisted":{},"votedFor":{},"leaderId":{}}},"ts":{}{}}}"#,
        event,
        node,
        term,
        role_str(role),
        commit,
        last_index,
        last_term,
        persisted,
        voted_for,
        leader,
        now_nanos(),
        extra
    );
    write_line(&line);
}

/// Emit a minimal event with no state (e.g., Crash).
pub fn emit_minimal(event: &str, node: u64) {
    if !is_active() {
        return;
    }
    let line = format!(
        r#"{{"tag":"trace","event":"{}","node":{},"ts":{}}}"#,
        event,
        node,
        now_nanos()
    );
    write_line(&line);
}

/// Convenience macro for emitting trace events from within raft.rs.
///
/// Usage:
///   `tla_trace_event!("EventName", self);`                         — state only
///   `tla_trace_event!("EventName", self, &format!(...));`          — state + extra fields
#[macro_export]
macro_rules! tla_trace_event {
    ($event:expr, $raft:expr) => {
        if $crate::tla_trace::is_active() {
            $crate::tla_trace::emit_state(
                $event,
                $raft.id,
                $raft.term,
                $raft.state,
                $raft.raft_log.committed,
                $raft.raft_log.last_index(),
                $raft.raft_log.last_term(),
                $raft.raft_log.persisted,
                $raft.vote,
                $raft.leader_id,
                "",
            );
        }
    };
    ($event:expr, $raft:expr, $extra:expr) => {
        if $crate::tla_trace::is_active() {
            $crate::tla_trace::emit_state(
                $event,
                $raft.id,
                $raft.term,
                $raft.state,
                $raft.raft_log.committed,
                $raft.raft_log.last_index(),
                $raft.raft_log.last_term(),
                $raft.raft_log.persisted,
                $raft.vote,
                $raft.leader_id,
                $extra,
            );
        }
    };
}
