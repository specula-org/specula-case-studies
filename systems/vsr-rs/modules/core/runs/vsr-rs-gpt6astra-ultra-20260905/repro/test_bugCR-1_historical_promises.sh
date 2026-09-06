#!/usr/bin/env bash
set -euo pipefail

WORKTREE="/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-20260905/vsr-rs/.specula-output/confirmation/CR-1/worktree"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/src"

cat > "$TMPDIR/Cargo.toml" <<CARGO
[package]
name = "cr1_historical_promises_repro"
version = "0.1.0"
edition = "2021"

[dependencies]
vsr-rs = { path = "$WORKTREE" }
CARGO

cat > "$TMPDIR/src/main.rs" <<'RS'
use std::collections::{BTreeMap, VecDeque};
use vsr_rs::{Client, Config, Message, Replica, Reply, StateMachine, Status};

#[derive(Clone, Debug, PartialEq, Eq)]
enum Op {
    Add(i32),
}

#[derive(Default, Debug)]
struct Accumulator {
    value: i32,
    applied: Vec<Op>,
}

impl StateMachine for Accumulator {
    type Input = Op;
    type Output = i32;

    fn apply(&mut self, op: Op) -> i32 {
        match op {
            Op::Add(value) => self.value += value,
        }
        self.applied.push(op);
        self.value
    }
}

#[derive(Clone, Debug)]
struct Envelope {
    from: usize,
    to: usize,
    message: Message<Op>,
}

#[derive(Clone, Debug)]
struct ReplyEnvelope {
    to: usize,
    reply: Reply<i32>,
}

struct Cluster {
    config: Config,
    replicas: Vec<Option<Replica<Accumulator>>>,
    clients: BTreeMap<usize, Client<Op>>,
    network: VecDeque<Envelope>,
    reply_channel: VecDeque<ReplyEnvelope>,
    delivered_replies: Vec<Reply<i32>>,
    durable_views: Vec<usize>,
}

impl Cluster {
    fn new(client_ids: &[usize]) -> Self {
        let mut config = Config::new();
        for _ in 0..3 {
            config.add_replica();
        }
        config.set_primary_timeout(3);
        let replicas = (0..3)
            .map(|id| Some(Replica::new(id, config.clone(), Accumulator::default())))
            .collect();
        let clients = client_ids
            .iter()
            .map(|id| (*id, Client::new(*id, config.clone())))
            .collect();
        Self {
            config,
            replicas,
            clients,
            network: VecDeque::new(),
            reply_channel: VecDeque::new(),
            delivered_replies: Vec::new(),
            durable_views: vec![0; 3],
        }
    }

    fn collect_replica(&mut self, id: usize) {
        let Some(replica) = self.replicas[id].as_mut() else {
            return;
        };
        self.durable_views[id] = replica.view_number();
        let messages: Vec<_> = replica.drain_messages().collect();
        for (to, message) in messages {
            self.network.push_back(Envelope { from: id, to, message });
        }
        let replies: Vec<_> = replica.drain_replies().collect();
        for reply in replies {
            self.reply_channel
                .push_back(ReplyEnvelope { to: reply.client_id, reply });
        }
    }

    fn collect_client(&mut self, id: usize) {
        let messages: Vec<_> = self.clients.get_mut(&id).unwrap().drain().collect();
        for (to, message) in messages {
            self.network.push_back(Envelope { from: id, to, message });
        }
    }

    fn collect_all(&mut self) {
        for id in 0..self.replicas.len() {
            self.collect_replica(id);
        }
        let clients: Vec<_> = self.clients.keys().copied().collect();
        for id in clients {
            self.collect_client(id);
        }
    }

    fn request(&mut self, client: usize, op: Op) -> usize {
        let request = self.clients.get_mut(&client).unwrap().on_request(op);
        self.collect_client(client);
        request
    }

    fn client_idle(&mut self, client: usize) {
        self.clients.get_mut(&client).unwrap().on_idle();
        self.collect_client(client);
    }

    fn idle(&mut self, replica: usize) {
        self.replicas[replica].as_mut().unwrap().on_idle();
        self.collect_replica(replica);
    }

    fn crash(&mut self, replica: usize) {
        self.replicas[replica] = None;
    }

    fn recover(&mut self, replica: usize, nonce: u64) {
        let view = self.durable_views[replica];
        self.replicas[replica] = Some(Replica::recover(
            replica,
            self.config.clone(),
            Accumulator::default(),
            view,
            nonce,
        ));
        self.collect_replica(replica);
    }

    fn deliver_where(&mut self, predicate: impl Fn(&Envelope) -> bool) -> bool {
        self.collect_all();
        let Some(pos) = self.network.iter().position(predicate) else {
            return false;
        };
        let envelope = self.network.remove(pos).unwrap();
        if let Some(replica) = self.replicas[envelope.to].as_mut() {
            replica.on_message(envelope.message);
            self.collect_replica(envelope.to);
        }
        true
    }

    fn lose_where(&mut self, predicate: impl Fn(&Envelope) -> bool) -> bool {
        self.collect_all();
        let Some(pos) = self.network.iter().position(predicate) else {
            return false;
        };
        self.network.remove(pos);
        true
    }

    fn deliver_reply_where(&mut self, predicate: impl Fn(&ReplyEnvelope) -> bool) -> bool {
        self.collect_all();
        let Some(pos) = self.reply_channel.iter().position(predicate) else {
            return false;
        };
        let envelope = self.reply_channel.remove(pos).unwrap();
        let accepted = self.clients.get_mut(&envelope.to).unwrap().on_reply(
            envelope.reply.request_number,
            envelope.reply.view_number,
        );
        if accepted {
            self.delivered_replies.push(envelope.reply);
        }
        true
    }

    fn settle(&mut self) {
        for _ in 0..1000 {
            if self.deliver_where(|_| true) {
                continue;
            }
            if self.deliver_reply_where(|_| true) {
                continue;
            }
            return;
        }
        panic!("settle did not quiesce");
    }

    fn settle_partitioned_from_zero(&mut self) {
        for _ in 0..1000 {
            if self.deliver_where(|envelope| envelope.from != 0 && envelope.to != 0) {
                continue;
            }
            if self.deliver_reply_where(|_| true) {
                continue;
            }
            if self.lose_where(|envelope| envelope.from == 0 || envelope.to == 0) {
                continue;
            }
            return;
        }
        panic!("partitioned settle did not quiesce");
    }

    fn values(&self) -> Vec<i32> {
        self.replicas
            .iter()
            .map(|replica| replica.as_ref().map_or(-1, |r| r.state_machine().value))
            .collect()
    }

    fn log_values(&self, replica: usize) -> Vec<i32> {
        self.replicas[replica]
            .as_ref()
            .unwrap()
            .log()
            .iter()
            .map(|entry| match entry.op {
                Op::Add(value) => value,
            })
            .collect()
    }

    fn assert_replica(&self, replica: usize, view: usize, commit: usize, value: i32, log: &[i32]) {
        let replica = self.replicas[replica].as_ref().unwrap();
        assert_eq!(replica.status(), Status::Normal, "replica {} status", replica.id());
        assert_eq!(replica.view_number(), view, "replica {} view", replica.id());
        assert_eq!(replica.commit_number(), commit, "replica {} commit", replica.id());
        assert_eq!(replica.state_machine().value, value, "replica {} value", replica.id());
        assert_eq!(self.log_values(replica.id()), log, "replica {} log", replica.id());
    }

    fn assert_reply(&self, client: usize, request: usize, result: i32) {
        assert!(
            self.delivered_replies.iter().any(|reply| {
                reply.client_id == client
                    && reply.request_number == request
                    && reply.result == result
            }),
            "missing reply for client {client} request {request} result {result}; replies: {:?}",
            self.delivered_replies
        );
    }
}

fn is_request(envelope: &Envelope, client: usize, to: usize, request: usize) -> bool {
    envelope.from == client
        && envelope.to == to
        && matches!(
            envelope.message,
            Message::Request {
                client_id,
                request_number,
                ..
            } if client_id == client && request_number == request
        )
}

fn is_prepare(envelope: &Envelope, from: usize, to: usize, op_number: usize) -> bool {
    envelope.from == from
        && envelope.to == to
        && matches!(envelope.message, Message::Prepare { op_number: n, .. } if n == op_number)
}

fn is_prepare_ok(envelope: &Envelope, from: usize, to: usize, op_number: usize) -> bool {
    envelope.from == from
        && envelope.to == to
        && matches!(
            envelope.message,
            Message::PrepareOk {
                op_number: n,
                replica_id,
                ..
            } if n == op_number && replica_id == from
        )
}

fn is_commit(envelope: &Envelope, from: usize, to: usize, view: usize, commit: usize) -> bool {
    envelope.from == from
        && envelope.to == to
        && matches!(
            envelope.message,
            Message::Commit {
                view_number,
                commit_number,
            } if view_number == view && commit_number == commit
        )
}

fn is_get_state(envelope: &Envelope, from: usize, to: usize, view: usize, start: usize) -> bool {
    envelope.from == from
        && envelope.to == to
        && matches!(
            envelope.message,
            Message::GetState {
                replica_id,
                view_number,
                op_number,
            } if replica_id == from && view_number == view && op_number == start
        )
}

fn is_new_state(envelope: &Envelope, from: usize, to: usize, view: usize, start: usize, commit: usize) -> bool {
    envelope.from == from
        && envelope.to == to
        && matches!(
            envelope.message,
            Message::NewState {
                view_number,
                op_number_start,
                commit_number,
                ..
            } if view_number == view && op_number_start == start && commit_number == commit
        )
}

fn is_recovery(envelope: &Envelope, from: usize) -> bool {
    envelope.from == from && matches!(envelope.message, Message::Recovery { replica_id, .. } if replica_id == from)
}

fn is_recovery_to(envelope: &Envelope, from: usize, to: usize) -> bool {
    envelope.from == from
        && envelope.to == to
        && matches!(envelope.message, Message::Recovery { replica_id, .. } if replica_id == from)
}

fn is_recovery_response(envelope: &Envelope, from: usize, to: usize) -> bool {
    envelope.from == from
        && envelope.to == to
        && matches!(envelope.message, Message::RecoveryResponse { replica_id, .. } if replica_id == from)
}

fn same_view_state_transfer_preserves_history() {
    let mut cluster = Cluster::new(&[3, 4, 5]);
    cluster.request(3, Op::Add(10));
    cluster.settle();
    cluster.assert_reply(3, 0, 10);

    cluster.request(4, Op::Add(20));
    cluster.request(5, Op::Add(30));
    assert!(cluster.deliver_where(|m| is_request(m, 4, 0, 0)));
    assert!(cluster.deliver_where(|m| is_request(m, 5, 0, 0)));

    assert!(cluster.deliver_where(|m| is_prepare(m, 0, 2, 2)));
    assert!(cluster.deliver_where(|m| is_prepare_ok(m, 2, 0, 2)));
    assert!(cluster.deliver_where(|m| is_prepare(m, 0, 2, 3)));
    assert!(cluster.deliver_where(|m| is_prepare_ok(m, 2, 0, 3)));

    assert!(cluster.lose_where(|m| is_prepare(m, 0, 1, 2)));
    assert!(cluster.deliver_where(|m| is_prepare(m, 0, 1, 3)));
    assert!(cluster.deliver_where(|m| is_get_state(m, 1, 0, 0, 1)));
    assert!(cluster.deliver_where(|m| is_new_state(m, 0, 1, 0, 1, 3)));

    cluster.idle(0);
    cluster.settle();
    for id in 0..3 {
        cluster.assert_replica(id, 0, 3, 60, &[10, 20, 30]);
    }
    cluster.assert_reply(4, 0, 30);
    cluster.assert_reply(5, 0, 60);
    println!("level0 same-view NewState: ok; replicas={:?}", cluster.values());
}

fn retained_primary_suffix_replacement_then_retry() {
    let mut cluster = Cluster::new(&[3, 4]);
    cluster.request(3, Op::Add(10));
    cluster.settle();
    cluster.assert_reply(3, 0, 10);
    cluster.idle(0);
    cluster.settle();
    for id in 0..3 {
        cluster.assert_replica(id, 0, 1, 10, &[10]);
    }

    let pending = cluster.request(3, Op::Add(20));
    assert_eq!(pending, 1);
    assert!(cluster.deliver_where(|m| is_request(m, 3, 0, 1)));
    assert_eq!(cluster.log_values(0), vec![10, 20]);
    assert_eq!(cluster.replicas[0].as_ref().unwrap().commit_number(), 1);
    while cluster.lose_where(|m| is_prepare(m, 0, 1, 2) || is_prepare(m, 0, 2, 2)) {}

    for _ in 0..4 {
        cluster.idle(1);
        cluster.idle(2);
        cluster.settle_partitioned_from_zero();
    }
    cluster.assert_replica(1, 1, 1, 10, &[10]);
    cluster.assert_replica(2, 1, 1, 10, &[10]);

    cluster.request(4, Op::Add(30));
    assert!(cluster.lose_where(|m| is_request(m, 4, 0, 0)));
    cluster.client_idle(4);
    assert!(cluster.deliver_where(|m| is_request(m, 4, 1, 0)));
    cluster.settle_partitioned_from_zero();
    cluster.idle(1);
    cluster.settle_partitioned_from_zero();
    cluster.assert_replica(1, 1, 2, 40, &[10, 30]);
    cluster.assert_replica(2, 1, 2, 40, &[10, 30]);
    cluster.assert_reply(4, 0, 40);

    while cluster.lose_where(|m| matches!(m.message, Message::StartView { .. }) && m.to == 0) {}
    cluster.idle(1);
    assert!(cluster.deliver_where(|m| is_commit(m, 1, 0, 1, 2)));
    assert_eq!(cluster.replicas[0].as_ref().unwrap().status(), Status::ViewChange);
    assert_eq!(cluster.log_values(0), vec![10, 20]);
    assert!(cluster.deliver_where(|m| is_get_state(m, 0, 1, 1, 1)));
    assert!(cluster.deliver_where(|m| is_new_state(m, 1, 0, 1, 1, 2)));
    cluster.assert_replica(0, 1, 2, 40, &[10, 30]);

    cluster.client_idle(3);
    assert!(cluster.deliver_where(|m| is_request(m, 3, 1, 1)));
    cluster.settle();
    cluster.idle(1);
    cluster.settle();
    for id in 0..3 {
        cluster.assert_replica(id, 1, 3, 60, &[10, 30, 20]);
    }
    cluster.assert_reply(3, 1, 60);
    println!(
        "level0 retained catch-up: ok; old primary replaced [10,20] with {:?} and pending retry committed",
        cluster.log_values(0)
    );
}

fn reboot_recovery_reconstructs_committed_history() {
    let mut cluster = Cluster::new(&[3, 4, 5]);
    cluster.request(3, Op::Add(10));
    cluster.settle();
    cluster.request(4, Op::Add(20));
    cluster.settle();

    cluster.crash(1);
    cluster.recover(1, 42);
    while cluster.lose_where(|m| is_recovery(m, 1)) {}

    cluster.request(5, Op::Add(30));
    cluster.settle();
    assert_eq!(cluster.replicas[1].as_ref().unwrap().status(), Status::Recovering);
    assert_eq!(cluster.replicas[1].as_ref().unwrap().state_machine().value, 0);
    cluster.assert_reply(5, 0, 60);

    cluster.idle(1);
    assert!(cluster.deliver_where(|m| is_recovery_to(m, 1, 0)));
    assert!(cluster.deliver_where(|m| is_recovery_to(m, 1, 2)));
    assert!(cluster.deliver_where(|m| is_recovery_response(m, 0, 1)));
    assert!(cluster.deliver_where(|m| is_recovery_response(m, 2, 1)));
    cluster.assert_replica(1, 0, 3, 60, &[10, 20, 30]);
    assert_eq!(
        cluster.replicas[1].as_ref().unwrap().state_machine().applied,
        vec![Op::Add(10), Op::Add(20), Op::Add(30)]
    );
    println!(
        "level0 recovery: ok; rebooted replica reconstructed committed log {:?}",
        cluster.log_values(1)
    );
}

fn main() {
    println!("CR-1 reproduction attempt against public vsr-rs APIs");
    same_view_state_transfer_preserves_history();
    retained_primary_suffix_replacement_then_retry();
    reboot_recovery_reconstructs_committed_history();
    println!("Level 0 result: no committed-prefix divergence, wrong reply, crash, or lost pending request was observed.");
    println!("Level 1 result: not escalated; deterministic message loss/reorder/replay scheduling already controls timing without source changes.");
    println!("Level 2 result: not used; injecting a broken committed prefix or forged peer state would bypass the real producer paths exercised above.");
    println!("Level 3 result: not used; source patching was unnecessary and would not be sound for this code-review candidate.");
}
RS

echo "command: timeout 120s cargo run --quiet --manifest-path $TMPDIR/Cargo.toml"
timeout 120s cargo run --quiet --manifest-path "$TMPDIR/Cargo.toml"
