// TLA+ trace emission module for Autobahn BFT — Category A (distributed).
// Single NDJSON file, mutex-protected global writer.
//
// Usage:
//   tla_trace::init(path, &[(pk, "n1"), (pk2, "n2"), ...]);
//   tla_trace::emit("SendPrepare", &args);

use crypto::PublicKey;
use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::Write as IoWrite;
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

// -----------------------------------------------------------------------
// Global state

static WRITER: OnceLock<Mutex<File>> = OnceLock::new();
static NODE_MAP: OnceLock<HashMap<[u8; 32], String>> = OnceLock::new();

// -----------------------------------------------------------------------
// Init / registration

/// Open trace file and register node-ID mappings.  Call once at test startup.
pub fn init(path: &str, nodes: &[(PublicKey, &str)]) {
    let file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(path)
        .expect("tla_trace: cannot open trace file");

    // OnceLock: silently ignore if already initialised (supports multiple tests
    // in the same process that each call init with a different path).
    let _ = WRITER.set(Mutex::new(file));

    let mut map = HashMap::new();
    for (pk, name) in nodes {
        map.insert(pk.0, name.to_string());
    }
    let _ = NODE_MAP.set(map);
}

// -----------------------------------------------------------------------
// Helpers

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

/// Map a PublicKey to its short TLA+ name ("n1", "n2", …).
pub fn node_id(pk: &PublicKey) -> String {
    if let Some(map) = NODE_MAP.get() {
        if let Some(name) = map.get(&pk.0) {
            return name.clone();
        }
    }
    format!("n{}", pk.0[..4].iter().map(|b| format!("{:02x}", b)).collect::<String>())
}

fn write_line(line: &str) {
    if let Some(writer) = WRITER.get() {
        if let Ok(mut f) = writer.lock() {
            let _ = writeln!(f, "{}", line);
        }
    }
}

// -----------------------------------------------------------------------
// JSON helpers (no serde_json dependency)

pub fn opt_int(v: Option<u64>) -> String {
    v.map(|x| x.to_string()).unwrap_or_else(|| "null".to_string())
}

pub fn opt_str(v: Option<&str>) -> String {
    v.map(|s| {
        // Escape backslashes and double-quotes.
        let escaped = s.replace('\\', "\\\\").replace('"', "\\\"");
        format!("\"{}\"", escaped)
    })
    .unwrap_or_else(|| "null".to_string())
}

pub fn voters_json(voters: &[String]) -> String {
    let inner: Vec<String> = voters.iter().map(|s| format!("\"{}\"", s)).collect();
    format!("[{}]", inner.join(","))
}

// -----------------------------------------------------------------------
// State snapshot

pub struct State {
    pub node_view: u64,
    pub prepare_voted: bool,
    pub confirm_voted: bool,
    pub committed: Option<String>,
    pub hs_voted_round: u64,
    pub hs_vote_count: u64,
}

impl Default for State {
    fn default() -> Self {
        State {
            node_view: 0,
            prepare_voted: false,
            confirm_voted: false,
            committed: None,
            hs_voted_round: 0,
            hs_vote_count: 0,
        }
    }
}

fn state_json(s: &State) -> String {
    format!(
        r#"{{"nodeView":{},"prepareVoted":{},"confirmVoted":{},"committed":{},"hsVotedRound":{},"hsVoteCount":{}}}"#,
        s.node_view,
        if s.prepare_voted { "true" } else { "false" },
        if s.confirm_voted { "true" } else { "false" },
        opt_str(s.committed.as_deref()),
        s.hs_voted_round,
        s.hs_vote_count,
    )
}

// -----------------------------------------------------------------------
// Primary emit function

#[allow(clippy::too_many_arguments)]
pub fn emit(
    event: &str,
    node: &str,
    slot: Option<u64>,
    view: Option<u64>,
    proposals: Option<&str>,
    voters: Option<&[String]>,
    high_qc_view: Option<u64>,
    win_proposals: Option<&str>,
    round: Option<u64>,
    parent_round: Option<u64>,
    state: &State,
) {
    let voters_val = voters
        .map(|v| voters_json(v))
        .unwrap_or_else(|| "null".to_string());

    let line = format!(
        r#"{{"tag":"trace","ts":{},"event":"{}","node":"{}","slot":{},"view":{},"proposals":{},"voters":{},"highQCView":{},"winProposals":{},"round":{},"parentRound":{},"state":{}}}"#,
        now_ms(),
        event,
        node,
        opt_int(slot),
        opt_int(view),
        opt_str(proposals),
        voters_val,
        opt_int(high_qc_view),
        opt_str(win_proposals),
        opt_int(round),
        opt_int(parent_round),
        state_json(state),
    );
    write_line(&line);
}
