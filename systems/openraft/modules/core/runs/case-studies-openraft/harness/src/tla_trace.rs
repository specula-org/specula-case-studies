//! TLA+ Trace emission for openraft.
//!
//! Emits NDJSON trace events compatible with Trace.tla.
//! Activated by calling `init(path)` at test setup.
//!
//! Usage:
//!   1. Call `openraft::tla_trace::init(path)` in test setup.
//!   2. Instrumentation points in Engine call `emit_*()` functions.
//!   3. Events written as NDJSON lines to the trace file.

use std::fs::File;
use std::io::BufWriter;
use std::io::Write;
use std::sync::Mutex;
use std::sync::OnceLock;
use std::time::SystemTime;
use std::time::UNIX_EPOCH;

use serde_json::json;
use serde_json::Value;

use crate::RaftTypeConfig;
use crate::raft_state::LogStateReader;
use crate::raft_state::RaftState;
use crate::vote::RaftTerm;
use crate::vote::raft_vote::RaftVoteExt;

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------

static WRITER: OnceLock<Mutex<TraceWriter>> = OnceLock::new();

struct TraceWriter {
    file: BufWriter<File>,
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Initialize the trace writer. Call once before any `emit` calls.
pub fn init(path: &str) {
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(path)
        .unwrap_or_else(|e| panic!("tla_trace: cannot open {}: {}", path, e));
    let _ = WRITER.set(Mutex::new(TraceWriter {
        file: BufWriter::new(file),
    }));
}

/// Returns `true` if tracing is active.
pub fn is_active() -> bool {
    WRITER.get().is_some()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn now_nanos() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos() as u64
}

fn write_line(value: &Value) {
    if let Some(w) = WRITER.get() {
        if let Ok(mut guard) = w.lock() {
            let _ = serde_json::to_writer(&mut guard.file, value);
            let _ = guard.file.write_all(b"\n");
            let _ = guard.file.flush();
        }
    }
}

/// Convert a Display-able node ID to u64 for TLA+.
/// Adds 1 to map openraft's 0-based IDs to TLA+'s 1-based Server set.
fn node_to_tla(id: &impl std::fmt::Display) -> u64 {
    let raw: u64 = format!("{}", id).parse().unwrap_or(0);
    raw + 1
}

/// Parse term from a committed leader ID's Display output.
fn clid_term(clid: &impl std::fmt::Display) -> u64 {
    format!("{}", clid).parse().unwrap_or(0)
}

// ---------------------------------------------------------------------------
// State extraction
// ---------------------------------------------------------------------------

fn server_state_str(ss: &crate::core::ServerState) -> &'static str {
    match ss {
        crate::core::ServerState::Leader => "Leader",
        crate::core::ServerState::Candidate => "Candidate",
        crate::core::ServerState::Follower => "Follower",
        _ => "Follower", // Learner/Shutdown map to Follower
    }
}

fn strong_post<C>(state: &RaftState<C>) -> Value
where C: RaftTypeConfig
{
    json!({
        "term": state.vote_ref().term().as_u64().unwrap_or(0),
        "state": server_state_str(&state.server_state),
        "commitIndex": state.committed().map(|l| l.index()).unwrap_or(0),
        "lastLogIndex": state.last_log_id().map(|l| l.index()).unwrap_or(0),
        "lastLogTerm": state.last_log_id()
            .map(|l| clid_term(l.committed_leader_id()))
            .unwrap_or(0),
    })
}

fn weak_post<C>(state: &RaftState<C>) -> Value
where C: RaftTypeConfig
{
    json!({
        "term": state.vote_ref().term().as_u64().unwrap_or(0),
        "state": server_state_str(&state.server_state),
    })
}

fn term_post<C>(state: &RaftState<C>) -> Value
where C: RaftTypeConfig
{
    json!({
        "term": state.vote_ref().term().as_u64().unwrap_or(0),
    })
}

// ---------------------------------------------------------------------------
// Emit functions — called from instrumented Engine code
// ---------------------------------------------------------------------------

/// Emit with strong post-state (term, state, commitIndex, lastLogIndex, lastLogTerm).
pub fn emit_strong<C>(
    event: &str,
    node_id: &C::NodeId,
    state: &RaftState<C>,
) where
    C: RaftTypeConfig,
{
    if !is_active() {
        return;
    }
    let line = json!({
        "tag": "trace",
        "ts": now_nanos(),
        "event": event,
        "node": node_to_tla(node_id),
        "post": strong_post::<C>(state),
    });
    write_line(&line);
}

/// Emit with weak post-state (term, state only).
pub fn emit_weak<C>(
    event: &str,
    node_id: &C::NodeId,
    state: &RaftState<C>,
) where
    C: RaftTypeConfig,
{
    if !is_active() {
        return;
    }
    let line = json!({
        "tag": "trace",
        "ts": now_nanos(),
        "event": event,
        "node": node_to_tla(node_id),
        "post": weak_post::<C>(state),
    });
    write_line(&line);
}

/// Emit with term-only post-state.
pub fn emit_term<C>(
    event: &str,
    node_id: &C::NodeId,
    state: &RaftState<C>,
) where
    C: RaftTypeConfig,
{
    if !is_active() {
        return;
    }
    let line = json!({
        "tag": "trace",
        "ts": now_nanos(),
        "event": event,
        "node": node_to_tla(node_id),
        "post": term_post::<C>(state),
    });
    write_line(&line);
}

/// Emit a message event with source + weak post-state.
pub fn emit_msg_weak<C>(
    event: &str,
    node_id: &C::NodeId,
    source: &C::NodeId,
    state: &RaftState<C>,
) where
    C: RaftTypeConfig,
{
    if !is_active() {
        return;
    }
    let line = json!({
        "tag": "trace",
        "ts": now_nanos(),
        "event": event,
        "node": node_to_tla(node_id),
        "source": node_to_tla(source),
        "post": weak_post::<C>(state),
    });
    write_line(&line);
}

/// Emit a replication event with target + term-only post-state.
pub fn emit_target_term<C>(
    event: &str,
    node_id: &C::NodeId,
    target: &C::NodeId,
    state: &RaftState<C>,
) where
    C: RaftTypeConfig,
{
    if !is_active() {
        return;
    }
    let line = json!({
        "tag": "trace",
        "ts": now_nanos(),
        "event": event,
        "node": node_to_tla(node_id),
        "target": node_to_tla(target),
        "post": term_post::<C>(state),
    });
    write_line(&line);
}

/// Emit a bare event (no post-state), e.g., Crash.
pub fn emit_bare<C>(
    event: &str,
    node_id: &C::NodeId,
) where
    C: RaftTypeConfig,
{
    if !is_active() {
        return;
    }
    let line = json!({
        "tag": "trace",
        "ts": now_nanos(),
        "event": event,
        "node": node_to_tla(node_id),
    });
    write_line(&line);
}
