// TLA+ trace emission module for Autobahn consensus protocol
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use std::fs::OpenOptions;
use std::io::Write;
use std::time::{SystemTime, UNIX_EPOCH};
use std::collections::HashMap;

pub struct TraceEmitter {
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    node_map: HashMap<Vec<u8>, String>,
    next_node_id: usize,
}

impl TraceEmitter {
    pub fn new(path: &str) -> std::io::Result<Self> {
        let file = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(path)?;

        Ok(TraceEmitter {
            writer: Arc::new(Mutex::new(Box::new(file))),
            node_map: HashMap::new(),
            next_node_id: 0,
        })
    }

    pub fn node_id_str(&mut self, key: Vec<u8>) -> String {
        if let Some(id) = self.node_map.get(&key) {
            id.clone()
        } else {
            let id = format!("s{}", self.next_node_id + 1);
            self.next_node_id += 1;
            self.node_map.insert(key, id.clone());
            id
        }
    }

    fn current_timestamp_nanos() -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos() as u64
    }

    pub fn emit(&self, event_name: &str, node: String, state: Value, msg: Option<Value>) {
        let timestamp = Self::current_timestamp_nanos();

        let mut event_obj = json!({
            "name": event_name,
            "nid": node,
            "state": state,
        });

        if let Some(m) = msg {
            event_obj["msg"] = m;
        }

        let trace_line = json!({
            "tag": "trace",
            "ts": timestamp.to_string(),
            "event": event_obj
        });

        if let Ok(mut writer) = self.writer.lock() {
            let _ = writeln!(writer, "{}", trace_line.to_string());
            let _ = writer.flush();
        }
    }

    pub fn emit_config(&self, servers: Vec<String>) {
        let timestamp = Self::current_timestamp_nanos();
        let config_line = json!({
            "tag": "config",
            "ts": timestamp.to_string(),
            "config": {
                "servers": servers,
            }
        });

        if let Ok(mut writer) = self.writer.lock() {
            let _ = writeln!(writer, "{}", config_line.to_string());
            let _ = writer.flush();
        }
    }
}

lazy_static::lazy_static! {
    pub static ref TRACE: Mutex<Option<TraceEmitter>> = Mutex::new(None);
}

pub fn init_trace(path: &str) -> std::io::Result<()> {
    let emitter = TraceEmitter::new(path)?;
    *TRACE.lock().unwrap() = Some(emitter);
    Ok(())
}

pub fn emit_event(event_name: &str, node: String, state: Value, msg: Option<Value>) {
    if let Ok(trace_lock) = TRACE.lock() {
        if let Some(emitter) = trace_lock.as_ref() {
            emitter.emit(event_name, node, state, msg);
        }
    }
}

// Helper to capture state snapshot
pub fn capture_state(
    round: u64,
    last_voted_round: u64,
    persistent_voted_round: u64,
    high_qc_round: u64,
) -> Value {
    json!({
        "round": round,
        "lastVotedRound": last_voted_round,
        "persistentLastVotedRound": persistent_voted_round,
        "highQCRound": high_qc_round,
    })
}
