//! Controlled caller for the real library, adapted from tests/cluster.rs.
//! This module schedules public methods; it contains no replica algorithm.
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::fs::{self, File, OpenOptions};
use std::io::{BufWriter, Write};
use std::path::PathBuf;
use std::sync::{Mutex, MutexGuard};
use std::time::{SystemTime, UNIX_EPOCH};
use vsr_rs::tla_trace::{entry, reply_wire, wire, Input, Register};
use vsr_rs::{Client, Config, LogEntry, Message, Replica, Reply};

const REVISION: &str = "3ac0104a567092139534c9022205d02281a2da41";
static SCENARIO: Mutex<()> = Mutex::new(());
static WRITER: Mutex<Option<BufWriter<File>>> = Mutex::new(None);

fn timestamp() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
}

#[derive(Clone)]
enum Payload {
    Message(Message<Input>),
    Reply(Reply<usize>),
}

#[derive(Clone)]
struct Packet {
    envelope: Value,
    payload: Payload,
}

fn envelopes(packets: &VecDeque<Packet>) -> Vec<Value> {
    packets.iter().map(|p| p.envelope.clone()).collect()
}

fn bag(packets: &[Packet]) -> Vec<Value> {
    let mut rows: Vec<Value> = Vec::new();
    for packet in packets {
        if let Some(row) = rows.iter_mut().find(|r| r["message"] == packet.envelope) {
            row["count"] = json!(row["count"].as_u64().unwrap() + 1);
        } else {
            rows.push(json!({"message":packet.envelope,"count":1}));
        }
    }
    rows
}

pub struct Cluster {
    config: Config,
    replicas: Vec<Option<Replica<Register>>>,
    empty: Vec<Value>,
    clients: BTreeMap<usize, Option<Client<Input>>>,
    retired_snapshots: BTreeMap<usize, Value>,
    outputs: Vec<VecDeque<Packet>>,
    replies: Vec<VecDeque<Packet>>,
    client_outputs: BTreeMap<usize, VecDeque<Packet>>,
    network: Vec<Packet>,
    reply_channel: Vec<Packet>,
    released: Vec<Packet>,
    durable: Vec<usize>,
    lives: Vec<&'static str>,
    phases: Vec<&'static str>,
    incarnations: Vec<usize>,
    nonce_epochs: Vec<BTreeMap<u64, usize>>,
    retired: BTreeSet<usize>,
    invocations: Vec<Value>,
    accepted: Vec<Value>,
    applications: BTreeMap<(usize, usize), Vec<Value>>,
    storage: PathBuf,
    _scenario: MutexGuard<'static, ()>,
}

impl Cluster {
    pub fn new(name: &str, client_ids: &[usize]) -> Self {
        let scenario = SCENARIO.lock().unwrap();
        assert!(!name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'));
        assert!(!client_ids.is_empty() && client_ids.iter().all(|c| *c >= 3));
        assert_eq!(client_ids.len(), client_ids.iter().collect::<BTreeSet<_>>().len());
        let trace_dir = PathBuf::from(std::env::var("VSR_TRACE_DIR").expect("VSR_TRACE_DIR required"));
        let runtime = PathBuf::from(std::env::var("VSR_TRACE_RUNTIME").expect("VSR_TRACE_RUNTIME required"));
        fs::create_dir_all(&trace_dir).unwrap();
        let storage = runtime.join(format!("{name}-{}", timestamp()));
        fs::create_dir_all(&storage).unwrap();
        let mut config = Config::new();
        for _ in 0..3 { config.add_replica(); }
        config.set_primary_timeout(3);
        let replicas: Vec<_> = (0..3).map(|i| Some(Replica::new(i, config.clone(), Register::default()))).collect();
        let empty = replicas.iter().map(|r| r.as_ref().unwrap().trace_snapshot(&[], &[], 0)).collect();
        let clients = client_ids.iter().map(|c| (*c, Some(Client::new(*c, config.clone())))).collect();
        let cluster = Self {
            config, replicas, empty, clients, storage, _scenario: scenario,
            retired_snapshots: BTreeMap::new(),
            outputs: vec![VecDeque::new(); 3], replies: vec![VecDeque::new(); 3],
            client_outputs: client_ids.iter().map(|c| (*c, VecDeque::new())).collect(),
            network: vec![], reply_channel: vec![], released: vec![],
            durable: vec![0; 3], lives: vec!["Running"; 3], phases: vec!["Release"; 3],
            incarnations: vec![0; 3], nonce_epochs: vec![BTreeMap::new(); 3],
            retired: BTreeSet::new(), invocations: vec![], accepted: vec![],
            applications: (0..3).map(|i| ((i, 0), vec![])).collect(),
        };
        for i in 0..3 { cluster.write_view(i, 0); }
        File::open(&cluster.storage).unwrap().sync_all().unwrap();
        *WRITER.lock().unwrap() = Some(BufWriter::new(File::create(trace_dir.join(format!("{name}.ndjson"))).unwrap()));
        cluster.write(json!({"event":"Init","revision":REVISION,"workload":"register-put-old-v1",
            "replicas":[0,1,2],"clients":client_ids,"values":[0,1,2],"primaryTimeout":3,"state":cluster.snapshot()}));
        cluster
    }

    fn write(&self, mut event: Value) {
        event["tag"] = json!("trace");
        event["ts"] = json!(timestamp().to_string());
        let mut lock = WRITER.lock().unwrap();
        let writer = lock.as_mut().unwrap();
        serde_json::to_writer(&mut *writer, &event).unwrap();
        writer.write_all(b"\n").unwrap();
        writer.flush().unwrap();
    }

    fn emit(&self, mut event: Value, applies: Vec<Value>) {
        event["state"] = self.snapshot();
        event["applies"] = json!(applies);
        self.write(event);
    }

    pub fn snapshot(&self) -> Value {
        let replicas: Vec<_> = (0..3).map(|i| match &self.replicas[i] {
            Some(replica) => replica.trace_snapshot(&envelopes(&self.outputs[i]), &envelopes(&self.replies[i]),
                self.normalize_nonce(i, replica.trace_raw_nonce())),
            None => self.empty[i].clone(),
        }).collect();
        let clients: Vec<_> = self.clients.iter().map(|(c, client)| json!({"id":c,"state": match client {
            Some(client) => client.trace_snapshot(&envelopes(&self.client_outputs[c])),
            None => self.retired_snapshots[c].clone(),
        }})).collect();
        let applications: Vec<_> = self.applications.iter().map(|((i, epoch), entries)|
            json!({"replica":i,"incarnation":epoch,"entries":entries})).collect();
        json!({"replicas":replicas,"durableViews":self.durable,"lives":self.lives,
            "phases":self.phases,"incarnations":self.incarnations,"clients":clients,
            "retiredClients":self.retired,"invocations":self.invocations,"acceptedReplies":self.accepted,
            "network":bag(&self.network),"replyChannel":bag(&self.reply_channel),
            "released":self.released.iter().map(|p| p.envelope.clone()).collect::<Vec<_>>(),
            "applications":applications})
    }

    fn normalize_nonce(&self, node: usize, raw: u64) -> usize {
        if raw == 0 { 0 } else { *self.nonce_epochs[node].get(&raw).expect("unknown raw recovery nonce") }
    }

    fn packet(&self, src: usize, dst: usize, message: Message<Input>, proof: Vec<LogEntry<Input>>) -> Packet {
        let nonce = match &message {
            Message::Recovery { nonce, replica_id, .. } => {
                assert_eq!(*replica_id, src); self.normalize_nonce(src, *nonce)
            }
            Message::RecoveryResponse { nonce, replica_id, .. } => {
                assert_eq!(*replica_id, src); self.normalize_nonce(dst, *nonce)
            }
            Message::PrepareOk { replica_id, .. } | Message::GetState { replica_id, .. } |
            Message::StartViewChange { replica_id, .. } | Message::DoViewChange { replica_id, .. } => {
                assert_eq!(*replica_id, src); 0
            }
            Message::Request { client_id, .. } => { assert_eq!(*client_id, src); 0 }
            _ => 0,
        };
        let incarnation = if src < 3 { self.incarnations[src] } else { 0 };
        Packet { envelope: json!({"src":src,"dst":dst,"wire":wire(&message,nonce),
            "incarnation":incarnation,"proof":proof.iter().map(entry).collect::<Vec<_>>()}), payload: Payload::Message(message) }
    }

    // Vec::drain is representation-only: everything stays in an unpublished FIFO.
    fn stage_replica(&mut self, i: usize) -> Vec<Value> {
        let replica = self.replicas[i].as_mut().unwrap();
        let messages = replica.trace_drain_messages();
        let replies: Vec<_> = replica.drain_replies().collect();
        let applies = replica.trace_take_applies();
        for (dst, message, proof) in messages {
            let packet = self.packet(i, dst, message, proof);
            self.outputs[i].push_back(packet);
        }
        for reply in replies {
            let packet = Packet { envelope: json!({"src":i,"dst":reply.client_id,"wire":reply_wire(&reply),
                "incarnation":self.incarnations[i],"proof":[]}), payload: Payload::Reply(reply) };
            self.replies[i].push_back(packet);
        }
        let history = self.applications.get_mut(&(i, self.incarnations[i])).unwrap();
        for apply in &applies { history.push(apply["entry"].clone()); }
        applies
    }

    fn stage_client(&mut self, c: usize) {
        let messages: Vec<_> = self.clients.get_mut(&c).unwrap().as_mut().unwrap().drain().collect();
        for (dst, message) in messages {
            let packet = self.packet(c, dst, message, vec![]);
            self.client_outputs.get_mut(&c).unwrap().push_back(packet);
        }
    }

    fn ready(&self, i: usize) -> bool { self.lives[i] == "Running" && self.phases[i] == "Release" }

    fn write_view(&self, i: usize, view: usize) {
        let mut file = OpenOptions::new().create(true).truncate(true).write(true)
            .open(self.storage.join(format!("replica-{i}.view"))).unwrap();
        writeln!(file, "{view}").unwrap();
        file.sync_all().unwrap();
    }

    pub fn persist(&mut self, i: usize) {
        assert_eq!(self.lives[i], "Running");
        assert_eq!(self.phases[i], "Persist");
        let view = self.replicas[i].as_ref().unwrap().view_number();
        self.write_view(i, view);
        self.durable[i] = view;
        self.phases[i] = "Release";
        self.emit(json!({"event":"PersistView","node":i}), vec![]);
    }

    fn publish(&mut self, packet: Packet, reply: bool) {
        if !self.released.iter().any(|p| p.envelope == packet.envelope) { self.released.push(packet.clone()); }
        if reply { self.reply_channel.push(packet); } else { self.network.push(packet); }
    }

    pub fn release_message(&mut self, i: usize) -> bool {
        assert!(self.ready(i));
        if let Some(packet) = self.outputs[i].pop_front() {
            let envelope = packet.envelope.clone();
            self.publish(packet, false);
            self.emit(json!({"event":"ReleaseMessage","node":i,"message":envelope}), vec![]);
            true
        } else { false }
    }

    pub fn release_reply(&mut self, i: usize) -> bool {
        assert!(self.ready(i));
        if let Some(packet) = self.replies[i].pop_front() {
            let envelope = packet.envelope.clone();
            self.publish(packet, true);
            self.emit(json!({"event":"ReleaseReply","node":i,"message":envelope}), vec![]);
            true
        } else { false }
    }

    pub fn release_all(&mut self, i: usize) {
        while self.release_message(i) {}
        while self.release_reply(i) {}
    }

    pub fn request(&mut self, c: usize, input: Input) -> usize {
        assert!(!self.retired.contains(&c));
        assert!(self.clients[&c].as_ref().unwrap().trace_snapshot(&[])["pending"].as_array().unwrap().is_empty());
        let request = self.clients.get_mut(&c).unwrap().as_mut().unwrap().on_request(input.clone());
        self.invocations.push(json!({"client":c,"request":request,"input":input}));
        self.stage_client(c);
        self.emit(json!({"event":"ClientOnRequest","client":c,"input":input,"request":request}), vec![]);
        request
    }

    pub fn client_idle(&mut self, c: usize) {
        assert!(!self.retired.contains(&c));
        assert!(!self.clients[&c].as_ref().unwrap().trace_snapshot(&[])["pending"].as_array().unwrap().is_empty());
        self.clients.get_mut(&c).unwrap().as_mut().unwrap().on_idle();
        self.stage_client(c);
        self.emit(json!({"event":"ClientOnIdle","client":c}), vec![]);
    }

    pub fn client_drain(&mut self, c: usize) {
        assert!(!self.retired.contains(&c));
        while let Some(packet) = self.client_outputs.get_mut(&c).unwrap().pop_front() {
            let envelope = packet.envelope.clone();
            self.publish(packet, false);
            self.emit(json!({"event":"ClientDrain","client":c,"message":envelope}), vec![]);
        }
    }

    pub fn idle(&mut self, i: usize) {
        assert!(self.ready(i));
        let replica = self.replicas[i].as_mut().unwrap();
        let branch = replica.trace_idle_branch();
        replica.on_idle();
        let applies = self.stage_replica(i);
        self.phases[i] = "Persist";
        self.emit(json!({"event":"ReplicaOnIdle","node":i,"branch":branch}), applies);
    }

    /// One real receive call, stopping before the persist/publication boundary.
    pub fn receive_where(&mut self, predicate: impl Fn(&Value) -> bool) -> Option<usize> {
        let pos = self.network.iter().position(|p| {
            let dst = p.envelope["dst"].as_u64().unwrap() as usize;
            self.ready(dst) && predicate(&p.envelope)
        })?;
        let packet = self.network.remove(pos);
        let i = packet.envelope["dst"].as_u64().unwrap() as usize;
        let Payload::Message(message) = packet.payload else { unreachable!() };
        let replica = self.replicas[i].as_mut().unwrap();
        let branch = replica.trace_message_branch(&message);
        replica.on_message(message);
        let applies = self.stage_replica(i);
        self.phases[i] = "Persist";
        self.emit(json!({"event":"ReplicaOnMessage","node":i,"message":packet.envelope,"branch":branch}), applies);
        Some(i)
    }

    pub fn deliver_where(&mut self, predicate: impl Fn(&Value) -> bool) -> bool {
        if let Some(i) = self.receive_where(predicate) {
            self.persist(i); self.release_all(i); true
        } else { false }
    }

    pub fn deliver_reply_where(&mut self, predicate: impl Fn(&Value) -> bool) -> bool {
        let Some(pos) = self.reply_channel.iter().position(|p| {
            let dst = p.envelope["dst"].as_u64().unwrap() as usize;
            !self.retired.contains(&dst) && predicate(&p.envelope)
        }) else { return false; };
        let packet = self.reply_channel.remove(pos);
        let Payload::Reply(reply) = packet.payload else { unreachable!() };
        let c = reply.client_id;
        assert_eq!(packet.envelope["dst"], json!(c));
        let accepted = self.clients.get_mut(&c).unwrap().as_mut().unwrap().on_reply(reply.request_number, reply.view_number);
        if accepted && !self.accepted.contains(&packet.envelope) { self.accepted.push(packet.envelope.clone()); }
        self.emit(json!({"event":"ClientOnReply","client":c,"message":packet.envelope,"accepted":accepted}), vec![]);
        true
    }

    pub fn settle(&mut self) {
        for c in self.clients.keys().copied().collect::<Vec<_>>() {
            if !self.retired.contains(&c) { self.client_drain(c); }
        }
        for i in 0..3 { if self.ready(i) { self.release_all(i); } }
        for _ in 0..1000 {
            if self.deliver_where(|_| true) { continue; }
            if self.deliver_reply_where(|_| true) { continue; }
            return;
        }
        panic!("controlled delivery did not quiesce after 1000 events");
    }

    pub fn pause(&mut self, i: usize) {
        assert_eq!(self.lives[i], "Running"); self.lives[i] = "Paused";
        self.emit(json!({"event":"Pause","node":i}), vec![]);
    }

    pub fn resume(&mut self, i: usize) {
        assert_eq!(self.lives[i], "Paused"); self.lives[i] = "Running";
        self.emit(json!({"event":"Resume","node":i}), vec![]);
    }

    pub fn crash(&mut self, i: usize) {
        assert_ne!(self.lives[i], "Down");
        self.replicas[i] = None;
        self.outputs[i].clear(); self.replies[i].clear();
        self.lives[i] = "Down"; self.phases[i] = "Release";
        self.emit(json!({"event":"Crash","node":i}), vec![]);
    }

    pub fn recover(&mut self, i: usize) {
        assert_eq!(self.lives[i], "Down");
        let view: usize = fs::read_to_string(self.storage.join(format!("replica-{i}.view"))).unwrap().trim().parse().unwrap();
        assert_eq!(view, self.durable[i]);
        let raw = u64::try_from(timestamp()).unwrap();
        assert_ne!(raw, 0);
        assert!(!self.nonce_epochs[i].contains_key(&raw), "raw recovery nonce reused");
        self.incarnations[i] += 1;
        self.nonce_epochs[i].insert(raw, self.incarnations[i]);
        self.applications.insert((i, self.incarnations[i]), vec![]);
        self.replicas[i] = Some(Replica::recover(i, self.config.clone(), Register::default(), view, raw));
        self.lives[i] = "Running"; self.phases[i] = "Persist";
        let applies = self.stage_replica(i);
        assert!(applies.is_empty());
        self.emit(json!({"event":"Recover","node":i}), applies);
    }

    pub fn retire(&mut self, c: usize) {
        assert!(self.retired.insert(c));
        let client = self.clients.get_mut(&c).unwrap().take().unwrap();
        let mut snapshot = client.trace_snapshot(&[]);
        snapshot["pending"] = json!([]); snapshot["out"] = json!([]);
        self.retired_snapshots.insert(c, snapshot);
        self.client_outputs.get_mut(&c).unwrap().clear();
        self.emit(json!({"event":"ClientRetire","client":c}), vec![]);
    }

    pub fn lose_where(&mut self, predicate: impl Fn(&Value) -> bool) -> bool {
        if let Some(pos) = self.network.iter().position(|p| predicate(&p.envelope)) {
            let packet = self.network.remove(pos);
            self.emit(json!({"event":"LoseMessage","message":packet.envelope}), vec![]); true
        } else { false }
    }

    pub fn lose_reply_where(&mut self, predicate: impl Fn(&Value) -> bool) -> bool {
        if let Some(pos) = self.reply_channel.iter().position(|p| predicate(&p.envelope)) {
            let packet = self.reply_channel.remove(pos);
            self.emit(json!({"event":"LoseReply","message":packet.envelope}), vec![]); true
        } else { false }
    }

    pub fn replay_message(&mut self, envelope: &Value) { self.replay(envelope, false); }
    pub fn replay_reply(&mut self, envelope: &Value) { self.replay(envelope, true); }

    fn replay(&mut self, envelope: &Value, reply: bool) {
        let packet = self.released.iter().find(|p| p.envelope == *envelope).expect("replay must be authentic").clone();
        assert_eq!(matches!(packet.payload, Payload::Reply(_)), reply);
        if reply { self.reply_channel.push(packet); } else { self.network.push(packet); }
        self.emit(json!({"event":if reply {"ReplayReply"} else {"ReplayMessage"},"message":envelope}), vec![]);
    }
}

impl Drop for Cluster {
    fn drop(&mut self) {
        if let Some(mut writer) = WRITER.lock().unwrap().take() {
            writer.flush().unwrap();
            writer.get_ref().sync_all().unwrap();
        }
    }
}
