//! TLA+ Trace emission for sonic-dash-ha (hamgrd HA state machine).
//!
//! Emits NDJSON trace events compatible with Trace.tla.
//! Activated by setting the `HA_TRACE_FILE` environment variable.
//!
//! Category A (distributed/message-passing): single-file, mutex-protected writer.
//!
//! Each event line uses the envelope:
//!   {"tag": "ha", "event": "<name>", "node": "<nid>", ..., "ts": <epoch_ms>}
//!
//! Trace.tla filters on `tag = "ha"`.

use serde_json::json;
use std::collections::HashMap;
use std::fs::File;
use std::io::{BufWriter, Write};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------

static STATE: OnceLock<Mutex<TraceState>> = OnceLock::new();

struct TraceState {
    file: BufWriter<File>,
    nodes: HashMap<String, NodeState>,
    node_map: HashMap<String, String>, // vdpu_id → "n1", "n2", ...
    next_nid: usize,
}

struct NodeState {
    config_received: bool,
    vdpu_received: bool,
    haset_received: bool,
    last_dpu_up: bool,
    last_desired: String,
    /// True after start_connecting emitted (spec haState left Dead)
    started: bool,
}

impl NodeState {
    fn new() -> Self {
        NodeState {
            config_received: false,
            vdpu_received: false,
            haset_received: false,
            last_dpu_up: false,
            last_desired: "unspecified".to_string(),
            started: false,
        }
    }
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Try to initialize tracing from the `HA_TRACE_FILE` environment variable.
/// Call once at startup. No-op if env var is not set or already initialized.
pub fn try_init() {
    if STATE.get().is_some() {
        return;
    }
    if let Ok(path) = std::env::var("HA_TRACE_FILE") {
        let file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&path)
            .unwrap_or_else(|e| panic!("tla_trace: failed to open {}: {}", path, e));
        let _ = STATE.set(Mutex::new(TraceState {
            file: BufWriter::new(file),
            nodes: HashMap::new(),
            node_map: HashMap::new(),
            next_nid: 1,
        }));
        eprintln!("[tla_trace] Tracing to: {}", path);
    }
}

/// Returns true if tracing is active.
pub fn is_active() -> bool {
    STATE.get().is_some()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64
}

/// Convert protobuf DesiredHaState i32 to trace string.
/// Proto: UNSPECIFIED=0, DEAD=1, ACTIVE=2, STANDALONE=3
/// (from sonic-dash-api/proto/ha_scope_config.proto)
fn desired_state_str(val: i32) -> &'static str {
    match val {
        0 => "unspecified",
        1 => "dead",
        2 => "active",
        3 => "standalone",
        _ => "unknown",
    }
}

impl TraceState {
    /// Map vdpu_id to TLA+ node name (n1, n2, ...) in order of first encounter.
    fn nid(&mut self, vdpu_id: &str) -> String {
        if let Some(name) = self.node_map.get(vdpu_id) {
            return name.clone();
        }
        let name = format!("n{}", self.next_nid);
        self.next_nid += 1;
        self.node_map.insert(vdpu_id.to_string(), name.clone());
        name
    }

    fn node(&mut self, vdpu_id: &str) -> &mut NodeState {
        if !self.nodes.contains_key(vdpu_id) {
            self.nodes.insert(vdpu_id.to_string(), NodeState::new());
        }
        self.nodes.get_mut(vdpu_id).unwrap()
    }

    fn emit(&mut self, event: serde_json::Value) {
        let line = serde_json::to_string(&event).unwrap();
        writeln!(self.file, "{}", line).unwrap();
        self.file.flush().unwrap();
    }
}

// ---------------------------------------------------------------------------
// Event emitters — called from instrumented ha_scope.rs
// ---------------------------------------------------------------------------

/// Called when DASH_HA_SCOPE_CONFIG_TABLE Set message is processed.
/// Emits `receive_config` (first time only) and `change_desired_state` (on change).
pub fn on_config_set(vdpu_id: &str, desired_ha_state: i32, ha_set_id: &str) {
    let Some(state) = STATE.get() else { return };
    let Ok(mut s) = state.lock() else { return };

    let nid = s.nid(vdpu_id);
    let ts = now_ms();
    let desired_str = desired_state_str(desired_ha_state);

    // Emit receive_config only on first config (spec: ~configReady[n])
    let first_config = !s.node(vdpu_id).config_received;
    if first_config {
        s.node(vdpu_id).config_received = true;
        let event = json!({
            "tag": "ha",
            "event": "receive_config",
            "node": nid,
            "desired_state": desired_str,
            "ha_set_id": ha_set_id,
            "ts": ts,
        });
        s.emit(event);
    }

    // Emit change_desired_state if desired changed (spec: desiredState[n] /= ds)
    let desired_changed = s.node(vdpu_id).last_desired != desired_str;
    if desired_changed {
        s.node(vdpu_id).last_desired = desired_str.to_string();
        let event = json!({
            "tag": "ha",
            "event": "change_desired_state",
            "node": nid,
            "desired_state": desired_str,
            "ts": ts + 1, // +1ms to guarantee ordering after receive_config
        });
        s.emit(event);
    }
}

/// Called when VDpuActorState is received and vDPU is managed.
/// Emits `dpu_health_change` (on change) and `receive_vdpu_state` (first time only).
pub fn on_vdpu_state(vdpu_id: &str, dpu_up: bool) {
    let Some(state) = STATE.get() else { return };
    let Ok(mut s) = state.lock() else { return };

    let nid = s.nid(vdpu_id);
    let ts = now_ms();

    // Emit dpu_health_change if health changed (spec: dpuUp[n] /= newUp)
    let health_changed = s.node(vdpu_id).last_dpu_up != dpu_up;
    if health_changed {
        s.node(vdpu_id).last_dpu_up = dpu_up;
        let event = json!({
            "tag": "ha",
            "event": "dpu_health_change",
            "node": nid,
            "dpu_up": dpu_up,
            "ts": ts,
        });
        s.emit(event);
    }

    // Emit receive_vdpu_state only on first managed vDPU (spec: ~vdpuReady[n])
    let first_vdpu = !s.node(vdpu_id).vdpu_received;
    if first_vdpu {
        s.node(vdpu_id).vdpu_received = true;
        let event = json!({
            "tag": "ha",
            "event": "receive_vdpu_state",
            "node": nid,
            "dpu_up": dpu_up,
            "ts": ts + 1,
        });
        s.emit(event);
    }
}

/// Called when first vDPU managed state triggers lazy initialization (bridge creation).
/// Emits `start_connecting`.
/// Spec: StartConnecting(n) — Dead → Connecting.
pub fn on_start_connecting(vdpu_id: &str) {
    let Some(state) = STATE.get() else { return };
    let Ok(mut s) = state.lock() else { return };

    let nid = s.nid(vdpu_id);
    let ts = now_ms();

    s.node(vdpu_id).started = true;
    let event = json!({
        "tag": "ha",
        "event": "start_connecting",
        "node": nid,
        "ts": ts,
    });
    s.emit(event);
}

/// Called when HaSetActorState is received (first time only).
/// Emits `receive_haset_state`.
pub fn on_haset_state(vdpu_id: &str) {
    let Some(state) = STATE.get() else { return };
    let Ok(mut s) = state.lock() else { return };

    if s.node(vdpu_id).haset_received {
        return;
    }

    let nid = s.nid(vdpu_id);
    let ts = now_ms();

    s.node(vdpu_id).haset_received = true;
    let event = json!({
        "tag": "ha",
        "event": "receive_haset_state",
        "node": nid,
        "ts": ts,
    });
    s.emit(event);
}

/// Called when DASH_HA_SCOPE_CONFIG_TABLE Del message is processed.
/// Emits `go_to_dead` only if the state machine has left Dead state.
pub fn on_config_del(vdpu_id: &str) {
    let Some(state) = STATE.get() else { return };
    let Ok(mut s) = state.lock() else { return };

    let nid = s.nid(vdpu_id);
    let ts = now_ms();

    // Only emit go_to_dead if the state machine has started
    // (spec: GoToDead requires haState ∉ {Dead, Destroying})
    if s.node(vdpu_id).started {
        let event = json!({
            "tag": "ha",
            "event": "go_to_dead",
            "node": nid,
            "dpu_up": s.node(vdpu_id).last_dpu_up,
            "ts": ts,
        });
        s.emit(event);
    }

    // Reset node state
    let ns = s.node(vdpu_id);
    *ns = NodeState::new();
}
