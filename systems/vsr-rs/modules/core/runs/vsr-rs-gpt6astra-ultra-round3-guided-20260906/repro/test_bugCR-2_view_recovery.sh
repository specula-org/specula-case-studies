#!/usr/bin/env bash
set -euo pipefail

WORKTREE="${WORKTREE:-/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round3-guided-20260906/vsr-rs/.specula-output/confirmation/CR-2/worktree}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/src"
cat > "$TMPDIR/Cargo.toml" <<EOF
[package]
name = "cr2_view_recovery_repro"
version = "0.1.0"
edition = "2021"

[dependencies]
vsr-rs = { path = "$WORKTREE" }
EOF

cat > "$TMPDIR/src/main.rs" <<'EOF'
use std::fmt::Debug;
use vsr_rs::{Client, Config, LogEntry, Message, Replica, ReplicaID, Reply, StateMachine, Status};

#[derive(Clone, Debug, PartialEq, Eq)]
struct Op {
    name: &'static str,
    delta: i64,
}

impl Op {
    fn new(name: &'static str, delta: i64) -> Self {
        Self { name, delta }
    }
}

#[derive(Default, Debug)]
struct Accumulator {
    value: i64,
    applied: Vec<&'static str>,
}

impl StateMachine for Accumulator {
    type Input = Op;
    type Output = i64;

    fn apply(&mut self, input: Self::Input) -> Self::Output {
        self.value += input.delta;
        self.applied.push(input.name);
        self.value
    }
}

#[derive(Clone, Debug)]
struct PeerMessage {
    from: ReplicaID,
    to: ReplicaID,
    message: Message<Op>,
}

struct Cluster {
    config: Config,
    replicas: Vec<Replica<Accumulator>>,
    client: Client<Op>,
    durable_view: Vec<usize>,
}

impl Cluster {
    fn new(replica_count: usize) -> Self {
        let mut config = Config::new();
        for _ in 0..replica_count {
            config.add_replica();
        }
        config.set_primary_timeout(1);
        let replicas = (0..replica_count)
            .map(|id| Replica::new(id, config.clone(), Accumulator::default()))
            .collect();
        Self {
            config: config.clone(),
            replicas,
            client: Client::new(0, config),
            durable_view: vec![0; replica_count],
        }
    }

    fn persist(&mut self, id: ReplicaID) {
        self.durable_view[id] = self.replicas[id].view_number();
    }

    fn on_idle(&mut self, id: ReplicaID) {
        self.replicas[id].on_idle();
        self.persist(id);
    }

    fn deliver(&mut self, to: ReplicaID, message: Message<Op>) {
        self.replicas[to].on_message(message);
        self.persist(to);
    }

    fn drain_from(&mut self, from: ReplicaID) -> Vec<PeerMessage> {
        self.replicas[from]
            .drain_messages()
            .map(|(to, message)| PeerMessage { from, to, message })
            .collect()
    }

    fn drain_replies_from(&mut self, from: ReplicaID) -> Vec<Reply<i64>> {
        self.replicas[from].drain_replies().collect()
    }

    fn reboot(&mut self, id: ReplicaID, nonce: u64) {
        let view = self.durable_view[id];
        self.replicas[id] = Replica::recover(
            id,
            self.config.clone(),
            Accumulator::default(),
            view,
            nonce,
        );
        self.persist(id);
    }

    fn client_send(&mut self, op: Op) -> usize {
        let request_number = self.client.on_request(op);
        let mut outbound: Vec<_> = self.client.drain().collect();
        assert_eq!(outbound.len(), 1, "client should emit one request");
        let (to, request) = outbound.pop().unwrap();
        self.deliver(to, request);
        request_number
    }

    fn commit_a_on_0_and_1_only(&mut self) -> Reply<i64> {
        let request_number = self.client_send(Op::new("A", 10));
        let out0 = self.drain_from(0);
        let prepare_to_1 = take_one(out0.clone(), |m| {
            m.from == 0 && m.to == 1 && matches!(m.message, Message::Prepare { op_number: 1, .. })
        });
        assert!(out0.iter().any(|m| {
            m.from == 0 && m.to == 2 && matches!(m.message, Message::Prepare { op_number: 1, .. })
        }), "primary emitted a Prepare to replica 2; the transport drops it");
        self.deliver(prepare_to_1.to, prepare_to_1.message);

        let out1 = self.drain_from(1);
        let ack_to_0 = take_one(out1, |m| {
            m.from == 1 && m.to == 0 && matches!(m.message, Message::PrepareOk { op_number: 1, replica_id: 1, .. })
        });
        self.deliver(ack_to_0.to, ack_to_0.message);

        let mut replies = self.drain_replies_from(0);
        assert_eq!(replies.len(), 1, "primary should reply once op A commits");
        let reply = replies.remove(0);
        assert_eq!(reply.request_number, request_number);
        assert_eq!(reply.result, 10);
        assert!(self.client.on_reply(reply.request_number, reply.view_number));

        assert_log(self, 0, &["A"], 1, 10);
        assert_eq!(self.replicas[1].log()[0].op.name, "A");
        assert_eq!(self.replicas[1].commit_number(), 0, "backup has A but has not heard commit");
        assert_eq!(self.replicas[2].op_number(), 0, "replica 2 missed A");
        reply
    }

    fn recover_replica_from_current_primary(&mut self, id: ReplicaID, nonce: u64) {
        self.reboot(id, nonce);
        let recovery = self.drain_from(id);
        let mut responses = Vec::new();
        for msg in recovery {
            if msg.to == id {
                panic!("recovery request looped back to recovering replica");
            }
            self.deliver(msg.to, msg.message);
            responses.extend(self.drain_from(msg.to));
        }
        let mut delivered = 0;
        for msg in responses {
            if msg.to == id && matches!(msg.message, Message::RecoveryResponse { nonce: n, .. } if n == nonce) {
                self.deliver(id, msg.message);
                delivered += 1;
            }
        }
        assert!(delivered >= self.config.quorum(), "delivered {delivered} recovery responses");
        assert_eq!(self.replicas[id].status(), Status::Normal, "replica {id} should recover");
    }

    fn force_view1_from_0_and_2_excluding_1(&mut self) -> Vec<Reply<i64>> {
        self.on_idle(2);
        assert!(self.drain_from(2).is_empty(), "first idle only clears heard_from_primary");
        self.on_idle(2);
        let out2 = self.drain_from(2);
        let svc_2_to_0 = take_one(out2.clone(), |m| {
            m.from == 2 && m.to == 0 && matches!(m.message, Message::StartViewChange { view_number: 1, replica_id: 2 })
        });
        assert!(out2.iter().any(|m| {
            m.from == 2 && m.to == 1 && matches!(m.message, Message::StartViewChange { view_number: 1, replica_id: 2 })
        }), "the transport intentionally does not deliver replica 2's StartViewChange to primary 1");

        self.deliver(svc_2_to_0.to, svc_2_to_0.message);
        let out0 = self.drain_from(0);
        let dvc_0_to_1 = take_one(out0.clone(), |m| {
            m.from == 0 && m.to == 1 && matches!(m.message, Message::DoViewChange { view_number: 1, replica_id: 0, .. })
        });
        let svc_0_to_2 = take_one(out0, |m| {
            m.from == 0 && m.to == 2 && matches!(m.message, Message::StartViewChange { view_number: 1, replica_id: 0 })
        });

        self.deliver(svc_0_to_2.to, svc_0_to_2.message);
        let out2_after_svc = self.drain_from(2);
        let dvc_2_to_1 = take_one(out2_after_svc, |m| {
            m.from == 2 && m.to == 1 && matches!(m.message, Message::DoViewChange { view_number: 1, replica_id: 2, .. })
        });

        self.deliver(dvc_0_to_1.to, dvc_0_to_1.message);
        let out1_after_first_dvc = self.drain_from(1);
        assert!(
            !out1_after_first_dvc.iter().any(|m| matches!(m.message, Message::DoViewChange { .. })),
            "new primary must not have emitted its own DoViewChange before quorum"
        );

        self.deliver(dvc_2_to_1.to, dvc_2_to_1.message);
        assert_eq!(self.replicas[1].status(), Status::Normal);
        assert_eq!(self.replicas[1].view_number(), 1);
        let duplicate_replies = self.drain_replies_from(1);
        let start_views = self.drain_from(1);
        assert!(start_views.iter().all(|m| {
            matches!(m.message, Message::StartView { view_number: 1, .. })
                || matches!(m.message, Message::StartViewChange { view_number: 1, replica_id: 1 })
        }));
        for msg in start_views {
            if matches!(msg.message, Message::StartView { view_number: 1, .. }) {
                self.deliver(msg.to, msg.message);
            }
        }
        for id in [0, 2] {
            let _ = self.drain_replies_from(id);
            let _ = self.drain_from(id);
        }
        duplicate_replies
    }

    fn commit_b_in_view1(&mut self) -> Reply<i64> {
        let request_number = self.client.on_request(Op::new("B", 5));
        let mut out1 = Vec::new();
        for attempt in 0..2 {
            let outbound: Vec<_> = self.client.drain().collect();
            for (to, request) in outbound {
                self.deliver(to, request);
                out1.extend(self.drain_from(to));
            }
            if out1.iter().any(|m| {
                matches!(m.message, Message::Prepare { view_number: 1, op_number: 2, .. })
            }) {
                break;
            }
            assert_eq!(attempt, 0, "client resend still did not reach view 1 primary");
            self.client.on_idle();
        }
        let prepare_to_0 = take_one(out1.clone(), |m| {
            m.from == 1 && m.to == 0 && matches!(m.message, Message::Prepare { view_number: 1, op_number: 2, .. })
        });
        let prepare_to_2 = take_one(out1, |m| {
            m.from == 1 && m.to == 2 && matches!(m.message, Message::Prepare { view_number: 1, op_number: 2, .. })
        });
        self.deliver(prepare_to_0.to, prepare_to_0.message);
        self.deliver(prepare_to_2.to, prepare_to_2.message);
        let ack0 = take_one(self.drain_from(0), |m| {
            m.from == 0 && m.to == 1 && matches!(m.message, Message::PrepareOk { view_number: 1, op_number: 2, replica_id: 0 })
        });
        let ack2 = take_one(self.drain_from(2), |m| {
            m.from == 2 && m.to == 1 && matches!(m.message, Message::PrepareOk { view_number: 1, op_number: 2, replica_id: 2 })
        });
        self.deliver(ack0.to, ack0.message);
        self.deliver(ack2.to, ack2.message);
        let mut replies = self.drain_replies_from(1);
        assert_eq!(replies.len(), 1, "view 1 primary should reply once B commits");
        let reply = replies.remove(0);
        assert_eq!(reply.request_number, request_number);
        assert_eq!(reply.view_number, 1);
        assert_eq!(reply.result, 15);
        assert!(self.client.on_reply(reply.request_number, reply.view_number));
        self.on_idle(1);
        for msg in self.drain_from(1) {
            if matches!(msg.message, Message::Commit { view_number: 1, commit_number: 2 }) {
                self.deliver(msg.to, msg.message);
            }
        }
        reply
    }
}

fn take_one(messages: Vec<PeerMessage>, pred: impl Fn(&PeerMessage) -> bool) -> PeerMessage {
    let matches: Vec<_> = messages.into_iter().filter(pred).collect();
    assert_eq!(matches.len(), 1, "expected exactly one matching message, got {matches:?}");
    matches.into_iter().next().unwrap()
}

fn assert_log(cluster: &Cluster, replica_id: ReplicaID, names: &[&str], commit: usize, value: i64) {
    let replica = &cluster.replicas[replica_id];
    let log_names: Vec<&str> = replica.log().iter().map(|entry: &LogEntry<Op>| entry.op.name).collect();
    assert_eq!(log_names, names, "replica {replica_id} log");
    assert_eq!(replica.commit_number(), commit, "replica {replica_id} commit_number");
    assert_eq!(replica.state_machine().value, value, "replica {replica_id} value");
}

fn assert_all_logs(cluster: &Cluster, names: &[&str], commit: usize, value: i64) {
    for id in 0..cluster.replicas.len() {
        assert_log(cluster, id, names, commit, value);
    }
}

fn level0_excluding_primary_dvc_quorum_preserves_committed_op() {
    let mut c = Cluster::new(3);
    let original_reply = c.commit_a_on_0_and_1_only();
    let duplicate_replies = c.force_view1_from_0_and_2_excluding_1();
    assert_all_logs(&c, &["A"], 1, 10);
    assert_eq!(duplicate_replies.len(), 1);
    assert_eq!(duplicate_replies[0].request_number, original_reply.request_number);
    assert_eq!(duplicate_replies[0].view_number, 1);
    assert_eq!(duplicate_replies[0].result, 10);
    let accepted = c.client.on_reply(duplicate_replies[0].request_number, duplicate_replies[0].view_number);
    assert!(!accepted, "duplicate reply for already completed request should only update client view");
    let reply_b = c.commit_b_in_view1();
    assert_eq!(reply_b.result, 15);
    assert_all_logs(&c, &["A", "B"], 2, 15);
    println!("level0: PASS - real public API schedule reached view1 from DoViewChange senders [0, 2], excluding new primary 1; client-completed A stayed at index 0 and B committed after it");
}

fn level1_rolling_recovery_preserves_history() {
    let mut c = Cluster::new(3);
    let original_reply = c.commit_a_on_0_and_1_only();
    c.recover_replica_from_current_primary(1, 101);
    assert_log(&c, 1, &["A"], 1, 10);
    let duplicate_replies = c.force_view1_from_0_and_2_excluding_1();
    assert_all_logs(&c, &["A"], 1, 10);
    assert!(
        duplicate_replies.len() <= 1,
        "view change may emit no duplicate when the recovering primary already executed A"
    );
    if let Some(reply) = duplicate_replies.first() {
        assert_eq!(reply.request_number, original_reply.request_number);
        assert_eq!(reply.result, 10);
        let _ = c.client.on_reply(reply.request_number, reply.view_number);
    }
    c.recover_replica_from_current_primary(0, 102);
    c.recover_replica_from_current_primary(2, 103);
    assert_all_logs(&c, &["A"], 1, 10);
    let reply_b = c.commit_b_in_view1();
    assert_eq!(reply_b.result, 15);
    assert_all_logs(&c, &["A", "B"], 2, 15);
    println!("level1: PASS - with normal recovery of replica 1 before the excluding-primary view change and rolling recovery of replicas 0 and 2 after it, committed/client-observed A stayed recoverable and ordered before B");
}

fn main() {
    println!("CR-2 reproduction attempt against public vsr-rs APIs");
    level0_excluding_primary_dvc_quorum_preserves_committed_op();
    level1_rolling_recovery_preserves_history();
    println!("level2: NOT USED - making the selected DoViewChange log omit committed A would require an inadmissible hand-built state; all DoViewChange messages above were generated by real replicas through on_idle/on_message");
    println!("level3: NOT USED - no race-only source delay is implicated after Level 0/1 reached the suspected mechanism through normal scheduling");
    println!("result: no client-visible loss, reorder, panic, or permanent bad state observed");
}
EOF

cd "$TMPDIR"
timeout 5m cargo run --quiet
