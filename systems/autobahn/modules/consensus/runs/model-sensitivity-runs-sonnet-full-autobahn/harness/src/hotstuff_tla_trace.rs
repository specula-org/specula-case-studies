// tla_trace.rs — trace emission for hotstuff crate.

use crypto::PublicKey;
use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::Write as IoWrite;
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

static WRITER: OnceLock<Mutex<Option<File>>> = OnceLock::new();
static NODE_MAP: OnceLock<Mutex<HashMap<[u8; 32], String>>> = OnceLock::new();

fn writer() -> &'static Mutex<Option<File>> { WRITER.get_or_init(|| Mutex::new(None)) }
fn node_map() -> &'static Mutex<HashMap<[u8; 32], String>> { NODE_MAP.get_or_init(|| Mutex::new(HashMap::new())) }

pub fn init(path: &str, nodes: &[(PublicKey, &str)]) {
    let file = OpenOptions::new().create(true).truncate(true).write(true).open(path).expect("tla_trace: cannot open trace file");
    *writer().lock().unwrap() = Some(file);
    let mut map = node_map().lock().unwrap();
    map.clear();
    for (pk, name) in nodes { map.insert(pk.0, name.to_string()); }
}

pub fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64
}

pub fn node_id(pk: &PublicKey) -> String {
    if let Ok(map) = node_map().lock() {
        if let Some(name) = map.get(&pk.0) { return name.clone(); }
    }
    pk.0[..4].iter().map(|b| format!("{:02x}", b)).collect()
}

fn write_line(line: &str) {
    if let Ok(mut guard) = writer().lock() {
        if let Some(f) = guard.as_mut() { let _ = writeln!(f, "{}", line); }
    }
}

fn opt_int(v: Option<u64>) -> String { v.map(|x| x.to_string()).unwrap_or_else(|| "null".to_string()) }
fn opt_str(v: Option<&str>) -> String {
    v.map(|s| format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))).unwrap_or_else(|| "null".to_string())
}

pub struct State {
    pub node_view: u64, pub prepare_voted: bool, pub confirm_voted: bool,
    pub committed: Option<String>, pub hs_voted_round: u64, pub hs_vote_count: u64,
}

impl Default for State {
    fn default() -> Self { State { node_view: 0, prepare_voted: false, confirm_voted: false, committed: None, hs_voted_round: 0, hs_vote_count: 0 } }
}

fn state_json(s: &State) -> String {
    format!(
        r#"{{"nodeView":{},"prepareVoted":{},"confirmVoted":{},"committed":{},"hsVotedRound":{},"hsVoteCount":{}}}"#,
        s.node_view, if s.prepare_voted { "true" } else { "false" },
        if s.confirm_voted { "true" } else { "false" },
        opt_str(s.committed.as_deref()), s.hs_voted_round, s.hs_vote_count,
    )
}

#[allow(clippy::too_many_arguments)]
pub fn emit(event: &str, node: &str, slot: Option<u64>, view: Option<u64>,
    proposals: Option<&str>, voters: Option<&[String]>, high_qc_view: Option<u64>,
    win_proposals: Option<&str>, round: Option<u64>, parent_round: Option<u64>, state: &State) {
    let voters_val = voters.map(|v| { let i: Vec<_> = v.iter().map(|s| format!("\"{}\"", s)).collect(); format!("[{}]", i.join(",")) }).unwrap_or_else(|| "null".to_string());
    let line = format!(
        r#"{{"tag":"trace","ts":{},"event":"{}","node":"{}","slot":{},"view":{},"proposals":{},"voters":{},"highQCView":{},"winProposals":{},"round":{},"parentRound":{},"state":{}}}"#,
        now_ms(), event, node, opt_int(slot), opt_int(view), opt_str(proposals), voters_val,
        opt_int(high_qc_view), opt_str(win_proposals), opt_int(round), opt_int(parent_round), state_json(state),
    );
    write_line(&line);
}
