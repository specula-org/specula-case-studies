//! Single-threaded owner of real library objects and authentic in-flight messages.
//! This schedules calls and publishes their observations; no VSR transitions live here.
use super::*;

#[derive(Clone, Debug)]
enum Payload {
    Message(Message<i64>),
    Reply(Reply<i64>),
}
#[derive(Clone, Debug)]
struct Packet {
    payload: Payload,
    canonical: Value,
}

pub(super) struct Owner {
    config: Config,
    replicas: Vec<Option<Replica<Accumulator>>>,
    clients: Vec<Client<i64>>,
    durable: Vec<usize>,
    incarnations: Vec<usize>,
    used: Vec<BTreeSet<u64>>,
    nonces: Nonces,
    network: Vec<Packet>,
    issued: BTreeMap<(usize, usize), i64>,
    steps: usize,
    _guard: MutexGuard<'static, ()>,
}

impl Owner {
    pub fn new(name: &str, n: usize, client_count: usize) -> Self {
        assert!(n >= 2 && client_count > 0);
        let guard = initialize(name);
        let mut config = Config::new();
        config.set_primary_timeout(2);
        for _ in 0..n {
            config.add_replica();
        }
        let owner = Self {
            replicas: (0..n)
                .map(|i| Some(Replica::new(i, config.clone(), Accumulator::default())))
                .collect(),
            clients: (0..client_count)
                .map(|i| Client::new(i, config.clone()))
                .collect(),
            config,
            durable: vec![0; n],
            incarnations: vec![0; n],
            used: vec![BTreeSet::new(); n],
            nonces: vec![BTreeMap::from([(0, 0)]); n],
            network: Vec::new(),
            issued: BTreeMap::new(),
            steps: 0,
            _guard: guard,
        };
        owner.snapshot(json!({"event":"Init","schema":1,"system":"vsr-rs","revision":REVISION,
            "category":"A","application":"integer-sum","servers":(0..n).collect::<Vec<_>>(),
            "clientIds":(0..client_count).map(client_name).collect::<Vec<_>>(),"operations":[1,2],"primaryTimeout":2}),vec![]);
        owner
    }
    pub fn state(&self, node: usize) -> Value {
        self.replicas[node]
            .as_ref()
            .map(|r| replica_snapshot(r, &self.nonces))
            .unwrap_or_else(empty_state)
    }
    pub fn client_state(&self, client: usize) -> Value {
        client_snapshot(&self.clients[client])
    }
    pub fn messages(&self) -> Vec<Value> {
        self.network.iter().map(|p| p.canonical.clone()).collect()
    }

    fn snapshot(&self, mut event: Value, outputs: Vec<Value>) {
        let replicas:Vec<_> = (0..self.replicas.len()).map(|i|json!({"id":i,"live":self.replicas[i].is_some(),
            "durableView":self.durable[i],"incarnation":self.incarnations[i],
            "usedNonces":self.used[i].iter().map(|n|nonce_json(&self.nonces,i,*n)).collect::<BTreeSet<_>>(),
            "state":self.state(i)})).collect();
        let clients: Vec<_> = (0..self.clients.len())
            .map(|i| json!({"id":client_name(i),"state":self.client_state(i)}))
            .collect();
        event["replicas"] = json!(replicas);
        event["clients"] = json!(clients);
        event["network"] = json!(self.messages());
        event["outputs"] = json!(outputs);
        emit(event);
    }
    fn record(&mut self, event: Value, outputs: Vec<Value>) {
        self.steps += 1;
        self.snapshot(event, outputs);
    }
    fn enqueue(&mut self, packet: Packet, outputs: &mut Vec<Value>) {
        outputs.push(packet.canonical.clone());
        self.network.push(packet);
    }
    fn publish_replica(&mut self, node: usize) -> Vec<Value> {
        let replica = self.replicas[node].as_mut().unwrap();
        // Conforming owner storage survives destruction of the replica. This models
        // successful publication; it does not claim to test filesystem durability.
        self.durable[node] = replica.view_number();
        let messages: Vec<_> = replica.drain_messages().collect();
        let replies: Vec<_> = replica.drain_replies().collect();
        let mut outputs = Vec::new();
        for (dst, message) in messages {
            let value = canonical(&message, json!(node), dst, &self.nonces);
            self.enqueue(
                Packet {
                    payload: Payload::Message(message),
                    canonical: value,
                },
                &mut outputs,
            );
        }
        for reply in replies {
            let op = self.issued[&(reply.client_id, reply.request_number)];
            let mut value = envelope("Reply", json!(node), json!(client_name(reply.client_id)));
            value["view"] = json!(reply.view_number);
            value["result"] = json!(reply.result);
            value["request"] = request_json(reply.client_id, reply.request_number, op);
            self.enqueue(
                Packet {
                    payload: Payload::Reply(reply),
                    canonical: value,
                },
                &mut outputs,
            );
        }
        outputs
    }
    fn publish_client(&mut self, client: usize) -> Vec<Value> {
        let messages: Vec<_> = self.clients[client].drain().collect();
        let mut outputs = Vec::new();
        for (dst, message) in messages {
            let value = canonical(&message, json!(client_name(client)), dst, &self.nonces);
            self.enqueue(
                Packet {
                    payload: Payload::Message(message),
                    canonical: value,
                },
                &mut outputs,
            );
        }
        outputs
    }

    pub fn request(&mut self, client: usize, op: i64) {
        assert!([1, 2].contains(&op));
        assert!(
            self.clients[client].pending.is_none(),
            "one outstanding request per client"
        );
        let number = self.clients[client].on_request(op);
        check_call("ClientOnRequest", client);
        assert!(self.issued.insert((client, number), op).is_none());
        let outputs = self.publish_client(client);
        self.record(
            json!({"event":"ClientOnRequest","client":client_name(client),"op":op}),
            outputs,
        );
    }
    pub fn client_idle(&mut self, client: usize) {
        self.clients[client].on_idle();
        check_call("ClientOnIdle", client);
        let outputs = self.publish_client(client);
        self.record(
            json!({"event":"ClientOnIdle","client":client_name(client)}),
            outputs,
        );
    }
    pub fn idle(&mut self, node: usize) {
        self.replicas[node]
            .as_mut()
            .expect("cannot tick down node")
            .on_idle();
        check_call("OnIdle", node);
        let outputs = self.publish_replica(node);
        self.record(json!({"event":"OnIdle","node":node}), outputs);
    }
    fn deliverable(&self, packet: &Packet) -> bool {
        match &packet.payload {
            Payload::Message(_) => {
                self.replicas[packet.canonical["dst"].as_u64().unwrap() as usize].is_some()
            }
            Payload::Reply(_) => true,
        }
    }
    fn deliver_index(&mut self, index: usize) {
        assert!(self.deliverable(&self.network[index]));
        let packet = self.network.remove(index);
        match packet.payload {
            Payload::Message(message) => {
                let node = packet.canonical["dst"].as_u64().unwrap() as usize;
                let name = format!("On{}", message_kind(&message));
                self.replicas[node].as_mut().unwrap().on_message(message);
                check_call(&name, node);
                let outputs = self.publish_replica(node);
                self.record(
                    json!({"event":name,"node":node,"message":packet.canonical}),
                    outputs,
                );
            }
            Payload::Reply(reply) => {
                let client = reply.client_id;
                self.clients[client].on_reply(reply.request_number, reply.view_number);
                check_call("ClientOnReply", client);
                let outputs = self.publish_client(client);
                assert!(outputs.is_empty());
                self.record(json!({"event":"ClientOnReply","client":client_name(client),"message":packet.canonical}),outputs);
            }
        }
    }
    pub fn deliver(&mut self, kind: &str, src: Value, dst: Value) {
        self.deliver_where(|m| m["kind"] == kind && m["src"] == src && m["dst"] == dst);
    }
    pub fn deliver_where(&mut self, predicate: impl Fn(&Value) -> bool) {
        let index = self
            .network
            .iter()
            .position(|p| predicate(&p.canonical))
            .expect("missing selected packet");
        self.deliver_index(index);
    }
    pub fn pump(&mut self, limit: usize) {
        for _ in 0..limit {
            let Some(index) = self.network.iter().position(|p| self.deliverable(p)) else {
                return;
            };
            self.deliver_index(index);
        }
        assert!(
            !self.network.iter().any(|p| self.deliverable(p)),
            "delivery budget exhausted"
        );
    }
    pub fn lose_where(&mut self, predicate: impl Fn(&Value) -> bool) {
        let index = self
            .network
            .iter()
            .position(|p| predicate(&p.canonical))
            .expect("missing loss target");
        let packet = self.network.remove(index);
        self.record(json!({"event":"Lose","message":packet.canonical}), vec![]);
    }
    pub fn duplicate_where(&mut self, predicate: impl Fn(&Value) -> bool) {
        let packet = self
            .network
            .iter()
            .find(|p| predicate(&p.canonical))
            .expect("missing duplication target")
            .clone();
        self.network.push(packet.clone());
        self.record(
            json!({"event":"Duplicate","message":packet.canonical}),
            vec![],
        );
    }
    pub fn crash(&mut self, node: usize) {
        let replica = self.replicas[node].take().expect("already down");
        assert_eq!(self.durable[node], replica.view_number());
        drop(replica); // actually destroy protocol state and application
        self.record(json!({"event":"Crash","node":node}), vec![]);
    }
    pub fn recover(&mut self, node: usize, nonce: u64) {
        assert!(
            self.replicas[node].is_none(),
            "recover only destroyed objects"
        );
        let next = self.nonces[node].len();
        self.nonces[node].entry(nonce).or_insert(next); // preserves equality across restarts
        self.replicas[node] = Some(Replica::recover(
            node,
            self.config.clone(),
            Accumulator::default(),
            self.durable[node],
            nonce,
        ));
        self.incarnations[node] += 1;
        self.used[node].insert(nonce); // do not sanitize/reject repeated raw nonces
        let outputs = self.publish_replica(node);
        self.record(
            json!({"event":"Recover","node":node,"nonce":nonce_json(&self.nonces,node,nonce)}),
            outputs,
        );
    }
    pub fn finish(self) {
        shutdown(self.steps);
    }
}
