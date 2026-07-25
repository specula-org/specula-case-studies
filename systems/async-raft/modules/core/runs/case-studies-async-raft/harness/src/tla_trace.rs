//! TLA+ trace emission module for async-raft.
//!
//! Emits NDJSON trace events compatible with Trace.tla.
//! Activated by the `TLA_TRACE_FILE` environment variable.

use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{BufWriter, Write};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

/// Global trace writer, initialized once.
static WRITER: OnceLock<Mutex<TraceWriter>> = OnceLock::new();

/// Server ID mapping: NodeId (u64) -> TLA+ name ("s1", "s2", ...)
static SERVER_MAP: OnceLock<HashMap<u64, String>> = OnceLock::new();

struct TraceWriter {
    writer: BufWriter<File>,
}

/// Initialize the trace system. Must be called once before any emit calls.
/// `path`: path to the output NDJSON file.
/// `server_map`: mapping from NodeId to TLA+ server names.
pub fn init(path: &str, server_map: HashMap<u64, String>) {
    let file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(path)
        .unwrap_or_else(|e| panic!("tla_trace: failed to open {}: {}", path, e));
    let writer = TraceWriter {
        writer: BufWriter::new(file),
    };
    WRITER
        .set(Mutex::new(writer))
        .unwrap_or_else(|_| panic!("tla_trace: already initialized"));
    SERVER_MAP
        .set(server_map)
        .unwrap_or_else(|_| panic!("tla_trace: server map already set"));
}

/// Returns true if the trace system has been initialized.
pub fn is_active() -> bool {
    WRITER.get().is_some()
}

/// Map a NodeId to a TLA+ server name (e.g., 0 -> "s1").
pub fn nid(id: u64) -> String {
    SERVER_MAP
        .get()
        .and_then(|m| m.get(&id))
        .cloned()
        .unwrap_or_else(|| format!("s{}", id + 1))
}

/// Get a real timestamp in nanoseconds since epoch.
fn timestamp_nanos() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos() as u64
}

/// State snapshot for a raft node.
pub struct RaftState {
    pub term: u64,
    pub role: &'static str, // "Follower", "Candidate", "Leader"
    pub voted_for: Option<u64>,
    pub commit_index: u64,
    pub last_log_index: u64,
    pub last_log_term: u64,
}

impl RaftState {
    /// Serialize state to JSON fragment.
    fn to_json(&self) -> String {
        let voted_for_str = match self.voted_for {
            Some(id) => nid(id),
            None => String::new(),
        };
        format!(
            r#"{{"term":{},"role":"{}","votedFor":"{}","commitIndex":{},"lastLogIndex":{},"lastLogTerm":{}}}"#,
            self.term, self.role, voted_for_str, self.commit_index, self.last_log_index, self.last_log_term
        )
    }
}

/// Weak state snapshot (only term and role).
pub struct RaftStateWeak {
    pub term: u64,
    pub role: &'static str,
}

impl RaftStateWeak {
    fn to_json(&self) -> String {
        format!(
            r#"{{"term":{},"role":"{}","votedFor":"","commitIndex":0,"lastLogIndex":0,"lastLogTerm":0}}"#,
            self.term, self.role
        )
    }
}

/// Commit-level state snapshot (term, role, commitIndex).
pub struct RaftStateCommit {
    pub term: u64,
    pub role: &'static str,
    pub commit_index: u64,
}

impl RaftStateCommit {
    fn to_json(&self) -> String {
        format!(
            r#"{{"term":{},"role":"{}","votedFor":"","commitIndex":{},"lastLogIndex":0,"lastLogTerm":0}}"#,
            self.term, self.role, self.commit_index
        )
    }
}

/// Emit a trace event with full state and optional message fields.
pub fn emit_event(name: &str, node_id: u64, state_json: &str, msg_json: Option<&str>) {
    let guard = match WRITER.get() {
        Some(w) => w,
        None => return,
    };
    let mut w = guard.lock().unwrap();
    let ts = timestamp_nanos();
    let nid_str = nid(node_id);

    let msg_part = match msg_json {
        Some(m) => format!(r#","msg":{}"#, m),
        None => String::new(),
    };

    let line = format!(
        r#"{{"tag":"trace","ts":{},"event":{{"name":"{}","nid":"{}","state":{}{}}}}}"#,
        ts, name, nid_str, state_json, msg_part
    );

    writeln!(w.writer, "{}", line).unwrap();
    w.writer.flush().unwrap();
}

/// Emit with full RaftState.
pub fn emit_full(name: &str, node_id: u64, state: &RaftState, msg_json: Option<&str>) {
    emit_event(name, node_id, &state.to_json(), msg_json);
}

/// Emit with weak state (term + role only).
pub fn emit_weak(name: &str, node_id: u64, state: &RaftStateWeak, msg_json: Option<&str>) {
    emit_event(name, node_id, &state.to_json(), msg_json);
}

/// Emit with commit-level state.
pub fn emit_commit(name: &str, node_id: u64, state: &RaftStateCommit, msg_json: Option<&str>) {
    emit_event(name, node_id, &state.to_json(), msg_json);
}

// ---- Helper: map State enum to role string ----

/// Emit a config line (optional, for documenting cluster topology).
pub fn emit_config(servers: &[u64]) {
    let guard = match WRITER.get() {
        Some(w) => w,
        None => return,
    };
    let mut w = guard.lock().unwrap();
    let ts = timestamp_nanos();
    let server_list: Vec<String> = servers.iter().map(|id| format!("\"{}\"", nid(*id))).collect();
    let line = format!(
        r#"{{"tag":"config","ts":{},"config":{{"servers":[{}]}}}}"#,
        ts,
        server_list.join(",")
    );
    writeln!(w.writer, "{}", line).unwrap();
    w.writer.flush().unwrap();
}

/// Convert async-raft's State enum to a role string for trace events.
pub fn role_str(state: &crate::core::State) -> &'static str {
    match state {
        crate::core::State::Follower | crate::core::State::NonVoter => "Follower",
        crate::core::State::Candidate => "Candidate",
        crate::core::State::Leader => "Leader",
        crate::core::State::Shutdown => "Follower",
    }
}
