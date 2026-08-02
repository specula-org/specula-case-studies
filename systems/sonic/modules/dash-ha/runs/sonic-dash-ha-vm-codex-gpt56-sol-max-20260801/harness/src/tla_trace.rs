//! Specula trace sink and observation-only dash-ha shadow state.
//!
//! This module is copied into `swbus-actor`, the lowest crate shared by
//! HAMgrD and both SWSS bridge crates.  Tracing is disabled unless
//! `SPECULA_TRACE_FILE` is set.  Category A uses one mutex-protected NDJSON
//! writer so the file order is the observed global order.

use serde::Serialize;
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs::{File, OpenOptions};
use std::io::{BufWriter, Write};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

const MAX_EPOCH: u64 = 2;
const MAX_GENERATION: u64 = 2;
const MAX_REQUEST_ID: u64 = 3;
const MAX_OPERATION_ID: u64 = 3;
const MAX_MESSAGE_AGE: u64 = 2;
const MAX_RETRY: u64 = 2;

static TRACE: OnceLock<Mutex<Option<TraceState>>> = OnceLock::new();

fn trace_slot() -> &'static Mutex<Option<TraceState>> {
    TRACE.get_or_init(|| Mutex::new(None))
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct RoleWrite {
    node: String,
    epoch: u64,
    term: u64,
    role: String,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct PendingOperation {
    id: u64,
    epoch: u64,
}

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct MessageRecord {
    id: u64,
    kind: String,
    source_peer: String,
    destination: String,
    epoch: u64,
    generation: u64,
    term: u64,
    peer_state: String,
    acked_role: String,
    owner: String,
    age: u64,
}

impl MessageRecord {
    fn sentinel() -> Self {
        Self {
            id: 0,
            kind: "HaScopeState".into(),
            source_peer: "NoPeer".into(),
            destination: "NoOwner".into(),
            epoch: 0,
            generation: 0,
            term: 0,
            peer_state: "Dead".into(),
            acked_role: "None".into(),
            owner: "NoOwner".into(),
            age: 0,
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct NodeState {
    process_up: bool,
    accepted: u64,
    actor_applied: u64,
    actor_committed: u64,
    ha_set_issued: u64,
    ha_set_applied: u64,
    prereq_ready: u64,
    scope_issued: u64,
    scope_applied: u64,

    queued_ha_set_write: u64,
    queued_ha_set_state: u64,
    ha_set_state_in_flight: u64,
    producer_ha_set_pending: u64,
    queued_scope_write: u64,
    queued_scope_role: String,
    queued_scope_term: u64,
    queued_scope_pair_epoch: u64,
    producer_scope_pending: u64,
    producer_scope_role: String,
    producer_scope_term: u64,
    producer_scope_pair_epoch: u64,

    cp_state: String,
    asic_role: String,
    acked_role: String,
    term: u64,
    acked_term: u64,
    acked_pair_epoch: u64,

    current_peer: String,
    pair_epoch: u64,
    peer_connected: bool,
    last_peer_event: String,
    peer_generation: u64,
    max_peer_generation: u64,
    peer_term: u64,
    peer_cached_state: String,
    peer_cached_ack_role: String,
    peer_cached_owner: String,
    peer_cache_epoch: u64,
    peer_cache_source: String,
    foreign_applied: bool,

    transition_authorized: bool,
    authorization_term: u64,
    authorization_epoch: u64,

    persisted_phase: String,
    durable_intent: BTreeSet<String>,
    queued_actions: BTreeSet<String>,
    completed_actions: BTreeSet<String>,
    rehydration_needed: bool,

    pending_flag_epoch: u64,
    cached_pending_flag_epoch: u64,
    pending_ops: Vec<PendingOperation>,

    config_present: bool,
    config_epoch: u64,
    bridge_cache_epoch: u64,
    config_delivery_pending: u64,
    actor_phase: String,
    exact_route_epoch: u64,
    registrations: u64,
    parent_cache_epoch: u64,
    ignored_set: bool,
    queued_ha_set_delete: bool,
    producer_ha_set_delete_pending: bool,

    shared_retry: u64,
    retry_by_protocol: BTreeMap<String, u64>,
    retry_isolation_broken: bool,
    peer_lost: bool,
}

impl NodeState {
    fn initial(preferred: bool) -> Self {
        let phase = if preferred { "Active" } else { "Standby" };
        let mut retry_by_protocol = BTreeMap::new();
        retry_by_protocol.insert("Connect".into(), 0);
        retry_by_protocol.insert("Vote".into(), 0);
        retry_by_protocol.insert("Switchover".into(), 0);
        Self {
            process_up: true,
            accepted: 1,
            actor_applied: 1,
            actor_committed: 1,
            ha_set_issued: 1,
            ha_set_applied: 1,
            prereq_ready: 1,
            scope_issued: 1,
            scope_applied: 1,
            queued_ha_set_write: 0,
            queued_ha_set_state: 0,
            ha_set_state_in_flight: 0,
            producer_ha_set_pending: 0,
            queued_scope_write: 0,
            queued_scope_role: "None".into(),
            queued_scope_term: 1,
            queued_scope_pair_epoch: 1,
            producer_scope_pending: 0,
            producer_scope_role: "None".into(),
            producer_scope_term: 1,
            producer_scope_pair_epoch: 1,
            cp_state: phase.into(),
            asic_role: phase.into(),
            acked_role: phase.into(),
            term: 1,
            acked_term: 1,
            acked_pair_epoch: 1,
            current_peer: "peer-a".into(),
            pair_epoch: 1,
            peer_connected: false,
            last_peer_event: "None".into(),
            peer_generation: 0,
            max_peer_generation: 0,
            peer_term: 0,
            peer_cached_state: "Dead".into(),
            peer_cached_ack_role: "None".into(),
            peer_cached_owner: "NoOwner".into(),
            peer_cache_epoch: 0,
            peer_cache_source: "NoPeer".into(),
            foreign_applied: false,
            transition_authorized: false,
            authorization_term: 0,
            authorization_epoch: 0,
            persisted_phase: phase.into(),
            durable_intent: recoverable_actions(phase),
            queued_actions: BTreeSet::new(),
            completed_actions: required_actions(phase),
            rehydration_needed: false,
            pending_flag_epoch: 0,
            cached_pending_flag_epoch: 0,
            pending_ops: Vec::new(),
            config_present: true,
            config_epoch: 1,
            bridge_cache_epoch: 1,
            config_delivery_pending: 0,
            actor_phase: "Live".into(),
            exact_route_epoch: 1,
            registrations: 1,
            parent_cache_epoch: 1,
            ignored_set: false,
            queued_ha_set_delete: false,
            producer_ha_set_delete_pending: false,
            shared_retry: 0,
            retry_by_protocol,
            retry_isolation_broken: false,
            peer_lost: false,
        }
    }
}

struct TraceState {
    writer: BufWriter<File>,
    allowed: Option<BTreeSet<String>>,
    nodes: BTreeMap<String, NodeState>,
    raw_nodes: HashMap<String, String>,
    request_ids: HashMap<String, u64>,
    next_request_id: u64,
    operation_ids: HashMap<String, u64>,
    next_operation_id: u64,
    pending_role_writes: Vec<RoleWrite>,
    ha_owner: String,
    route_candidate: String,
    route_candidate_epoch: u64,
    route_candidate_term: u64,
    route_pending: bool,
    route_owner: String,
    route_epoch: u64,
    route_term: u64,
    last_route_writer: String,
    messages: Vec<MessageRecord>,
    ack_pending: BTreeSet<u64>,
    inbox: BTreeMap<String, MessageRecord>,
    event_count: usize,
    max_events: usize,
}

impl TraceState {
    fn new(writer: BufWriter<File>, allowed: Option<BTreeSet<String>>, max_events: usize) -> Self {
        let mut nodes = BTreeMap::new();
        nodes.insert("n1".into(), NodeState::initial(true));
        nodes.insert("n2".into(), NodeState::initial(false));
        let mut inbox = BTreeMap::new();
        inbox.insert("n1".into(), MessageRecord::sentinel());
        inbox.insert("n2".into(), MessageRecord::sentinel());
        Self {
            writer,
            allowed,
            nodes,
            raw_nodes: HashMap::new(),
            request_ids: HashMap::new(),
            next_request_id: 1,
            operation_ids: HashMap::new(),
            next_operation_id: 1,
            pending_role_writes: Vec::new(),
            ha_owner: "Switch".into(),
            route_candidate: "n1".into(),
            route_candidate_epoch: 1,
            route_candidate_term: 1,
            route_pending: false,
            route_owner: "n1".into(),
            route_epoch: 1,
            route_term: 1,
            last_route_writer: "ScopeState".into(),
            messages: Vec::new(),
            ack_pending: BTreeSet::new(),
            inbox,
            event_count: 0,
            max_events,
        }
    }

    fn enabled(&self, name: &str) -> bool {
        self.allowed.as_ref().is_none_or(|events| events.contains(name)) && self.event_count < self.max_events
    }

    fn node_id(&mut self, raw: &str) -> Result<String, String> {
        if raw == "n1" || raw == "n2" {
            return Ok(raw.to_string());
        }
        if let Some(node) = self.raw_nodes.get(raw) {
            return Ok(node.clone());
        }
        let hinted = if raw.contains("vdpu0") || raw.contains("dpu0") {
            Some("n1")
        } else if raw.contains("vdpu1") || raw.contains("dpu1") {
            Some("n2")
        } else {
            None
        };
        // HA-set/bridge/global service paths do not carry a vDPU identifier.
        // They belong to the single participant selected by each focused
        // scenario, so alias unknown global IDs to n1 instead of manufacturing
        // extra modeled nodes.
        let node = hinted.unwrap_or("n1").to_string();
        if !self.nodes.contains_key(&node) {
            return Err(format!("more than two modeled nodes: raw={raw}, mapped={node}"));
        }
        self.raw_nodes.insert(raw.to_string(), node.clone());
        Ok(node)
    }

    fn request_id(&mut self, raw: &str) -> Result<u64, String> {
        if let Some(id) = self.request_ids.get(raw) {
            return Ok(*id);
        }
        if self.next_request_id > MAX_REQUEST_ID {
            return Err(format!("request-id bound exceeded by {raw}"));
        }
        let id = self.next_request_id;
        self.next_request_id += 1;
        self.request_ids.insert(raw.to_string(), id);
        Ok(id)
    }

    fn operation_id(&mut self, raw: &str) -> Result<u64, String> {
        if let Some(id) = self.operation_ids.get(raw) {
            return Ok(*id);
        }
        if self.next_operation_id > MAX_OPERATION_ID {
            return Err(format!("operation-id bound exceeded by {raw}"));
        }
        let id = self.next_operation_id;
        self.next_operation_id += 1;
        self.operation_ids.insert(raw.to_string(), id);
        Ok(id)
    }

    fn post(&self, node: &str) -> Value {
        json!({
            "nodeState": self.nodes.get(node).expect("mapped node exists"),
            "pendingRoleWrites": self.pending_role_writes,
            "haOwner": self.ha_owner,
            "routeCandidate": self.route_candidate,
            "routeCandidateEpoch": self.route_candidate_epoch,
            "routeCandidateTerm": self.route_candidate_term,
            "routePending": self.route_pending,
            "routeOwner": self.route_owner,
            "routeEpoch": self.route_epoch,
            "routeTerm": self.route_term,
            "lastRouteWriter": self.last_route_writer,
            "messages": self.messages,
            "ackPending": self.ack_pending,
            "inbox": self.inbox.get(node).expect("mapped inbox exists"),
        })
    }
}

fn required_actions(state: &str) -> BTreeSet<String> {
    let actions: &[&str] = match state {
        "Connecting" => &["Heartbeat", "CheckPeerConnection"],
        "Connected" => &["VoteRequest"],
        "PendingActiveActivation" | "PendingStandbyActivation" => &["PendingOperation"],
        "Active" => &["ActivateRole", "BulkSyncCompleted"],
        "Standby" => &["ActivateRole", "SwitchoverFin"],
        "Standalone" => &["ActivateRole"],
        "SwitchingToActive" => &["ActivateRole", "SwitchoverRequest"],
        "SwitchingToStandby" => &["ActivateRole"],
        "SwitchingToStandalone" => &["FailoverRequest"],
        "Destroying" => &["ActivateRole", "ShutdownIntent"],
        _ => &[],
    };
    actions.iter().map(|value| (*value).to_string()).collect()
}

fn recoverable_actions(state: &str) -> BTreeSet<String> {
    let actions: &[&str] = match state {
        "Connecting" => &["Heartbeat", "CheckPeerConnection"],
        "Connected" => &["Heartbeat", "VoteRequest"],
        "InitializingToActive" | "InitializingToStandby" => &["Heartbeat", "ActivateRole"],
        "PendingActiveActivation" | "PendingStandbyActivation" => &["Heartbeat"],
        "Active" | "Standby" | "Standalone" => &["Heartbeat", "ActivateRole"],
        "SwitchingToActive" => &["Heartbeat", "ActivateRole", "SwitchoverRequest"],
        "SwitchingToStandby" => &["Heartbeat", "ActivateRole"],
        "Destroying" => &["ActivateRole"],
        _ => &[],
    };
    actions.iter().map(|value| (*value).to_string()).collect()
}

fn role_for_state(state: &str) -> &'static str {
    match state {
        "Active" => "Active",
        "Standby" => "Standby",
        "Standalone" => "Standalone",
        "SwitchingToActive" => "SwitchingToActive",
        "Dead" | "Destroying" => "Dead",
        _ => "None",
    }
}

fn value_u64(extras: &Value, key: &str, default: u64) -> u64 {
    extras.get(key).and_then(Value::as_u64).unwrap_or(default)
}

fn value_str<'a>(extras: &'a Value, key: &str, default: &'a str) -> &'a str {
    extras.get(key).and_then(Value::as_str).unwrap_or(default)
}

fn unix_nanos() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock precedes Unix epoch")
        .as_nanos()
        .to_string()
}

/// Initialize the trace sink from the environment, resetting shadows to the
/// exact epoch-1 state in `base.Init`. Safe to call more than once after
/// `finish()`; a second call while active is a no-op.
pub fn start_from_env() {
    let Ok(path) = std::env::var("SPECULA_TRACE_FILE") else {
        return;
    };
    let mut slot = trace_slot().lock().expect("Specula trace mutex poisoned");
    if slot.is_some() {
        return;
    }
    let file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(&path)
        .unwrap_or_else(|error| panic!("cannot open SPECULA_TRACE_FILE={path}: {error}"));
    let allowed = std::env::var("SPECULA_TRACE_EVENTS").ok().map(|raw| {
        raw.split(',')
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .map(str::to_string)
            .collect::<BTreeSet<_>>()
    });
    let max_events = std::env::var("SPECULA_TRACE_MAX_EVENTS")
        .ok()
        .and_then(|raw| raw.parse::<usize>().ok())
        .unwrap_or(300)
        .min(300);
    *slot = Some(TraceState::new(BufWriter::new(file), allowed, max_events));
}

/// Flush and close the active trace. Tests call this before returning so a
/// failed test cannot leave buffered JSON behind.
pub fn finish() {
    let mut slot = trace_slot().lock().expect("Specula trace mutex poisoned");
    if let Some(state) = slot.as_mut() {
        state.writer.flush().expect("flush Specula trace");
    }
    *slot = None;
}

pub fn is_active() -> bool {
    trace_slot().lock().expect("Specula trace mutex poisoned").is_some()
}

/// Emit a named action after its real implementation trigger completed.
/// `raw_node` is an implementation actor/resource ID; it is mapped to n1/n2.
/// `extras` carries action arguments and actual values observed at the hook.
pub fn emit(name: &str, raw_node: &str, extras: Value) {
    if !is_active() {
        start_from_env();
    }
    let mut slot = trace_slot().lock().expect("Specula trace mutex poisoned");
    let Some(state) = slot.as_mut() else { return };
    if !state.enabled(name) {
        return;
    }
    if let Err(error) = emit_locked(state, name, raw_node, extras) {
        panic!("Specula trace event {name} failed: {error}");
    }
}

fn emit_locked(state: &mut TraceState, name: &str, raw_node: &str, extras: Value) -> Result<(), String> {
    let node = state.node_id(raw_node)?;
    let mut fields = Map::new();
    fields.insert("name".into(), Value::String(name.to_string()));
    fields.insert("node".into(), Value::String(node.clone()));

    match name {
        "ConsumerBridgeConfigSet" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            let epoch = value_u64(&extras, "epoch", ns.bridge_cache_epoch + 1);
            if epoch == 0 || epoch > MAX_EPOCH { return Err(format!("invalid config epoch {epoch}")); }
            ns.config_present = true;
            ns.config_epoch = epoch;
            ns.bridge_cache_epoch = epoch;
            ns.config_delivery_pending = epoch;
            fields.insert("epoch".into(), json!(epoch));
        }
        "ActorCreatorHandleReceivedMessage" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.actor_phase = "Live".into();
            ns.exact_route_epoch = ns.config_epoch;
            ns.accepted = ns.config_epoch;
            ns.config_delivery_pending = 0;
            ns.ignored_set = false;
        }
        "ActorDriverHandleSwbusMessage" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.accepted = ns.config_epoch;
            ns.config_delivery_pending = 0;
            ns.ignored_set = false;
        }
        "ActorDriverHandleSetWhileDeleting" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.accepted = ns.config_epoch;
            ns.config_delivery_pending = 0;
            ns.ignored_set = true;
        }
        "ActorDriverHandleActorMessage" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.actor_applied = ns.accepted;
        }
        "HaSetActorUpdateDashHaSetTable" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.ha_set_issued = ns.actor_applied;
            ns.queued_ha_set_write = ns.actor_applied;
            ns.queued_ha_set_state = ns.actor_applied;
        }
        "ActorDriverCommitChanges" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.actor_committed = ns.actor_applied;
            ns.persisted_phase = ns.cp_state.clone();
            ns.durable_intent = recoverable_actions(&ns.cp_state);
        }
        "ActorDriverSendQueuedHaSetWrite" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.producer_ha_set_pending = ns.queued_ha_set_write;
            ns.queued_ha_set_write = 0;
        }
        "ActorDriverSendQueuedHaSetState" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.ha_set_state_in_flight = ns.queued_ha_set_state;
            ns.queued_ha_set_state = 0;
        }
        "ProducerBridgeApplyHaSet" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.ha_set_applied = ns.producer_ha_set_pending;
            ns.producer_ha_set_pending = 0;
        }
        "HaScopeHandleHaSetState" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.prereq_ready = ns.ha_set_state_in_flight;
            ns.parent_cache_epoch = ns.ha_set_state_in_flight;
            ns.ha_set_state_in_flight = 0;
        }
        "ActorRegistrationHandle" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.registrations = ns.config_epoch;
        }
        "NpuUpdateDpuHaScopeTable" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.scope_issued = ns.parent_cache_epoch;
            ns.queued_scope_write = ns.parent_cache_epoch;
            ns.queued_scope_role = role_for_state(&ns.cp_state).into();
            ns.queued_scope_term = ns.term;
            ns.queued_scope_pair_epoch = ns.pair_epoch;
            ns.queued_actions.remove("ActivateRole");
        }
        "ActorDriverSendQueuedScopeWrite" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.producer_scope_pending = ns.queued_scope_write;
            ns.producer_scope_role = ns.queued_scope_role.clone();
            ns.producer_scope_term = ns.queued_scope_term;
            ns.producer_scope_pair_epoch = ns.queued_scope_pair_epoch;
            ns.queued_scope_write = 0;
            ns.queued_scope_role = "None".into();
        }
        "ProducerBridgeApplyScope" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            let write = RoleWrite {
                node: node.clone(),
                epoch: ns.producer_scope_pair_epoch,
                term: ns.producer_scope_term,
                role: ns.producer_scope_role.clone(),
            };
            ns.scope_applied = ns.producer_scope_pending;
            ns.producer_scope_pending = 0;
            ns.producer_scope_role = "None".into();
            if !state.pending_role_writes.contains(&write) { state.pending_role_writes.push(write); }
        }
        "DpuAsicAcknowledgeRole" => {
            let write = state.pending_role_writes.first().cloned().ok_or("no pending role write")?;
            state.pending_role_writes.remove(0);
            let ns = state.nodes.get_mut(&write.node).unwrap();
            ns.asic_role = write.role.clone();
            ns.acked_role = write.role.clone();
            ns.acked_term = write.term;
            ns.acked_pair_epoch = write.epoch;
            ns.completed_actions.insert("ActivateRole".into());
            fields.insert("write".into(), serde_json::to_value(write).unwrap());
        }
        "ConsumerBridgeConfigDelete" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.config_present = false;
            ns.config_delivery_pending = ns.config_epoch;
        }
        "HaSetActorDoCleanup" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.actor_phase = "Deleting".into();
            ns.config_delivery_pending = 0;
            ns.registrations = 0;
            ns.queued_ha_set_delete = true;
        }
        "ActorDriverSendQueuedHaSetDelete" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.queued_ha_set_delete = false;
            ns.producer_ha_set_delete_pending = true;
        }
        "ProducerBridgeApplyHaSetDelete" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.ha_set_applied = 0;
            ns.producer_ha_set_delete_pending = false;
        }
        "ActorDriverFinishDelete" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.actor_phase = "Absent".into();
            ns.exact_route_epoch = 0;
        }
        "ActorDriverCleanupTimeout" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.queued_ha_set_delete = false;
            ns.producer_ha_set_delete_pending = false;
        }
        "OutgoingSendHaScopeState" => {
            let raw_id = value_str(&extras, "requestIdRaw", value_str(&extras, "requestId", "request"));
            let id = state.request_id(raw_id)?;
            let ns = state.nodes.get(&node).unwrap();
            let generation = value_u64(&extras, "generation", 1).clamp(1, MAX_GENERATION);
            let source_peer = value_str(&extras, "sourcePeer", &ns.current_peer).to_string();
            let message = MessageRecord {
                id,
                kind: "HaScopeState".into(),
                source_peer: source_peer.clone(),
                destination: node.clone(),
                epoch: ns.pair_epoch,
                generation,
                term: generation,
                peer_state: value_str(&extras, "peerState", "Dead").into(),
                acked_role: value_str(&extras, "ackedRole", "None").into(),
                owner: value_str(&extras, "owner", "NoOwner").into(),
                age: 0,
            };
            state.messages.push(message);
            fields.insert("requestId".into(), json!(id));
            fields.insert("sourcePeer".into(), json!(source_peer));
            fields.insert("generation".into(), json!(generation));
            fields.insert("peerState".into(), json!(value_str(&extras, "peerState", "Dead")));
            fields.insert("ackedRole".into(), json!(value_str(&extras, "ackedRole", "None")));
            fields.insert("owner".into(), json!(value_str(&extras, "owner", "NoOwner")));
        }
        "IncomingHandleRequest" => {
            let id = state.request_id(value_str(&extras, "requestIdRaw", value_str(&extras, "requestId", "request")))?;
            let msg = state.messages.iter().find(|msg| msg.id == id).cloned().ok_or("incoming ID not retained")?;
            state.inbox.insert(node.clone(), msg);
            state.ack_pending.insert(id);
            fields.insert("requestId".into(), json!(id));
        }
        "NpuHandleHaStateChange" => {
            let msg = state.inbox.get(&node).cloned().ok_or("missing inbox")?;
            if msg.id == 0 { return Err("empty inbox".into()); }
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.peer_generation = msg.generation;
            ns.max_peer_generation = ns.max_peer_generation.max(msg.generation);
            ns.peer_term = msg.term;
            ns.peer_cached_state = msg.peer_state.clone();
            ns.peer_cached_ack_role = msg.acked_role.clone();
            ns.peer_cached_owner = msg.owner.clone();
            ns.peer_cache_epoch = msg.epoch;
            ns.peer_cache_source = msg.source_peer.clone();
            ns.foreign_applied |= msg.source_peer != ns.current_peer || msg.epoch != ns.pair_epoch;
            ns.last_peer_event = if ns.peer_connected { "PeerStateChanged" } else { "PeerConnected" }.into();
            ns.peer_connected = true;
            state.inbox.insert(node.clone(), MessageRecord::sentinel());
        }
        "OutgoingHandleResponse" | "OutgoingHandleLateResponse" | "NetworkLoseAck" => {
            let id = state.request_id(value_str(&extras, "requestIdRaw", value_str(&extras, "requestId", "request")))?;
            state.ack_pending.remove(&id);
            if name == "OutgoingHandleResponse" { state.messages.retain(|msg| msg.id != id); }
            fields.insert("requestId".into(), json!(id));
        }
        "OutgoingDriveMaintenanceLoop" => {
            let id = state.request_id(value_str(&extras, "requestIdRaw", value_str(&extras, "requestId", "request")))?;
            let msg = state.messages.iter_mut().find(|msg| msg.id == id).ok_or("resend ID not retained")?;
            if msg.age >= MAX_MESSAGE_AGE { return Err("message age bound reached".into()); }
            msg.age += 1;
            fields.insert("requestId".into(), json!(id));
        }
        "OutgoingDropExpired" => {
            let id = state.request_id(value_str(&extras, "requestIdRaw", value_str(&extras, "requestId", "request")))?;
            state.messages.retain(|msg| msg.id != id);
            fields.insert("requestId".into(), json!(id));
        }
        "NpuHandleHaSetStateUpdateRePairResolved" | "NpuHandleHaSetStateUpdateRePairUnresolved" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            if ns.pair_epoch >= MAX_EPOCH { return Err("pair epoch bound reached".into()); }
            ns.current_peer = if ns.current_peer == "peer-a" { "peer-b" } else { "peer-a" }.into();
            ns.pair_epoch += 1;
            if name.ends_with("Unresolved") { ns.peer_connected = false; }
        }
        "NpuDriveStateMachinePeerAck" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.cp_state = if ns.cp_state == "InitializingToActive" { "PendingActiveActivation" } else { "Active" }.into();
            ns.transition_authorized = true;
            ns.authorization_term = ns.peer_term;
            ns.authorization_epoch = ns.peer_cache_epoch;
            ns.queued_actions.extend(required_actions(&ns.cp_state));
        }
        "NpuDriveStateMachine" => {
            let next = value_str(&extras, "nextState", "Connecting").to_string();
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.cp_state = next.clone();
            if next == "Active" || next == "Standalone" { ns.term += 1; }
            ns.queued_actions.extend(required_actions(&next));
            fields.insert("nextState".into(), json!(next));
        }
        "ActorDriverSendQueuedAction" => {
            let action = value_str(&extras, "action", "Heartbeat").to_string();
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.queued_actions.remove(&action);
            ns.completed_actions.insert(action.clone());
            fields.insert("action".into(), json!(action));
        }
        "Crash" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.process_up = false;
            ns.queued_ha_set_write = 0;
            ns.queued_ha_set_state = 0;
            ns.queued_scope_write = 0;
            ns.queued_scope_role = "None".into();
            ns.queued_actions.clear();
            ns.cp_state = ns.persisted_phase.clone();
            ns.rehydration_needed = false;
            ns.cached_pending_flag_epoch = 0;
            ns.prereq_ready = 0;
            ns.parent_cache_epoch = 0;
            ns.registrations = 0;
            ns.peer_connected = false;
            ns.actor_phase = "Absent".into();
            ns.exact_route_epoch = 0;
            ns.queued_ha_set_delete = false;
            state.inbox.insert(node.clone(), MessageRecord::sentinel());
        }
        "Recover" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.process_up = true;
            ns.actor_phase = "Live".into();
            ns.exact_route_epoch = ns.config_epoch;
            ns.cp_state = ns.persisted_phase.clone();
            ns.rehydration_needed = ns.persisted_phase != "Dead";
        }
        "NpuApplyRehydrationSideEffects" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.queued_actions.extend(ns.durable_intent.clone());
            ns.rehydration_needed = false;
        }
        "DpuHandlePendingOperation" => {
            let raw = value_str(&extras, "operationIdRaw", value_str(&extras, "operationId", "operation"));
            let id = state.operation_id(raw)?;
            let ns = state.nodes.get_mut(&node).unwrap();
            let epoch = value_u64(&extras, "epoch", if ns.cached_pending_flag_epoch == 0 { 1 } else { 2 });
            if epoch == 0 || epoch > MAX_EPOCH { return Err(format!("invalid pending epoch {epoch}")); }
            ns.pending_flag_epoch = epoch;
            ns.cached_pending_flag_epoch = epoch;
            ns.pending_ops.push(PendingOperation { id, epoch });
            ns.completed_actions.insert("PendingOperation".into());
            fields.insert("epoch".into(), json!(epoch));
            fields.insert("operationId".into(), json!(id));
        }
        "NpuApprovePendingOperation" => {
            let raw = value_str(&extras, "operationIdRaw", value_str(&extras, "operationId", "operation"));
            let id = state.operation_id(raw)?;
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.pending_ops.retain(|op| op.id != id);
            if ns.pending_ops.is_empty() {
                ns.pending_flag_epoch = 0;
                ns.cached_pending_flag_epoch = 0;
            }
            fields.insert("operationId".into(), json!(id));
        }
        "HaSetComputeRouteFromScope" => {
            let ns = state.nodes.get(&node).unwrap();
            state.route_candidate = node.clone();
            state.route_candidate_epoch = ns.pair_epoch;
            state.route_candidate_term = ns.term;
            state.route_pending = true;
            state.last_route_writer = "ScopeState".into();
        }
        "HaSetComputeRouteFromConfig" => {
            let ns = state.nodes.get("n1").unwrap();
            state.route_candidate = "n1".into();
            state.route_candidate_epoch = ns.pair_epoch;
            state.route_candidate_term = ns.term;
            state.route_pending = true;
            state.last_route_writer = "Config".into();
        }
        "HaSetComputeRouteFromReplay" => {
            let ns = state.nodes.get(&node).unwrap();
            state.route_candidate = ns.peer_cached_owner.clone();
            state.route_candidate_epoch = ns.peer_cache_epoch;
            state.route_candidate_term = ns.peer_term;
            state.route_pending = true;
            state.last_route_writer = "Replay".into();
        }
        "ProducerBridgeApplyRoute" => {
            state.route_owner = state.route_candidate.clone();
            state.route_epoch = state.route_candidate_epoch;
            state.route_term = state.route_candidate_term;
            state.route_pending = false;
        }
        "NpuHandleVoteRequestRetry" | "NpuHandleSwitchoverRst" | "NpuCheckPeerConnectionAndRetry" => {
            let protocol = match name {
                "NpuHandleVoteRequestRetry" => "Vote",
                "NpuHandleSwitchoverRst" => "Switchover",
                _ => "Connect",
            };
            let ns = state.nodes.get_mut(&node).unwrap();
            if ns.shared_retry >= MAX_RETRY || ns.retry_by_protocol[protocol] >= MAX_RETRY {
                return Err(format!("{protocol} retry bound reached"));
            }
            ns.shared_retry += 1;
            *ns.retry_by_protocol.get_mut(protocol).unwrap() += 1;
        }
        "NpuHandleVoteRequestFinal" | "NpuHandleSwitchoverFin" => {
            let protocol = if name == "NpuHandleVoteRequestFinal" { "Vote" } else { "Switchover" };
            let ns = state.nodes.get_mut(&node).unwrap();
            let other_live = match protocol {
                "Vote" => ns.retry_by_protocol["Connect"] > 0 || ns.retry_by_protocol["Switchover"] > 0,
                _ => ns.retry_by_protocol["Connect"] > 0 || ns.retry_by_protocol["Vote"] > 0,
            };
            ns.retry_isolation_broken |= other_live;
            ns.shared_retry = 0;
            *ns.retry_by_protocol.get_mut(protocol).unwrap() = 0;
        }
        "NpuCheckPeerConnectionLost" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.retry_isolation_broken |= ns.retry_by_protocol["Connect"] < MAX_RETRY;
            ns.peer_lost = true;
            ns.shared_retry = 0;
            *ns.retry_by_protocol.get_mut("Connect").unwrap() = 0;
        }
        "NpuPeerConnectedReset" => {
            let ns = state.nodes.get_mut(&node).unwrap();
            ns.retry_isolation_broken |= ns.retry_by_protocol["Vote"] > 0 || ns.retry_by_protocol["Switchover"] > 0;
            ns.shared_retry = 0;
            *ns.retry_by_protocol.get_mut("Connect").unwrap() = 0;
        }
        other => return Err(format!("unknown event name {other}")),
    }

    fields.insert("post".into(), state.post(&node));
    let envelope = json!({
        "tag": "trace",
        "ts": unix_nanos(),
        "event": Value::Object(fields),
    });
    serde_json::to_writer(&mut state.writer, &envelope).map_err(|error| error.to_string())?;
    state.writer.write_all(b"\n").map_err(|error| error.to_string())?;
    state.writer.flush().map_err(|error| error.to_string())?;
    state.event_count += 1;
    Ok(())
}

/// Harness-only process/fault hooks named by instrumentation-spec.md.
pub fn crash(raw_node: &str) {
    emit("Crash", raw_node, json!({}));
}

pub fn recover(raw_node: &str) {
    emit("Recover", raw_node, json!({}));
}

pub fn network_lose_ack(raw_node: &str, raw_request_id: impl ToString) {
    emit(
        "NetworkLoseAck",
        raw_node,
        json!({"requestIdRaw": raw_request_id.to_string()}),
    );
}
