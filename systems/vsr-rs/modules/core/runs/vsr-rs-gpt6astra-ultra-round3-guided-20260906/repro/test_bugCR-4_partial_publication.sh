#!/usr/bin/env bash
set -euo pipefail

WORKTREE="/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round3-guided-20260906/vsr-rs/.specula-output/confirmation/CR-4/worktree"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/src"
cat >"$TMPDIR/Cargo.toml" <<EOF
[package]
name = "cr4-partial-publication-repro"
version = "0.1.0"
edition = "2021"

[dependencies]
vsr_rs = { package = "vsr-rs", path = "$WORKTREE" }
EOF

cat >"$TMPDIR/src/main.rs" <<'EOF'
use std::collections::VecDeque;
use vsr_rs::{Client, Config, Message, Replica, ReplicaID, Reply, RequestNumber, StateMachine, Status};

#[derive(Clone, Debug, PartialEq, Eq)]
enum Op {
    Add(i64),
}

#[derive(Default, Debug)]
struct Counter {
    value: i64,
}

impl StateMachine for Counter {
    type Input = Op;
    type Output = i64;

    fn apply(&mut self, op: Op) -> i64 {
        match op {
            Op::Add(value) => {
                self.value += value;
                self.value
            }
        }
    }
}

struct Harness {
    config: Config,
    replicas: Vec<Replica<Counter>>,
    replica_up: Vec<bool>,
    clients: Vec<Client<Op>>,
    durable_view: Vec<usize>,
    pending: Vec<Option<RequestNumber>>,
    queue: VecDeque<(ReplicaID, Message<Op>)>,
    observed_replies: Vec<Reply<i64>>,
    lost_replies: Vec<Reply<i64>>,
}

impl Harness {
    fn new(client_count: usize) -> Self {
        let mut config = Config::new();
        for _ in 0..3 {
            config.add_replica();
        }
        config.set_primary_timeout(2);

        let replicas = (0..3)
            .map(|id| Replica::new(id, config.clone(), Counter::default()))
            .collect();
        let clients = (0..client_count)
            .map(|id| Client::new(id, config.clone()))
            .collect();

        Self {
            config,
            replicas,
            replica_up: vec![true; 3],
            clients,
            durable_view: vec![0; 3],
            pending: vec![None; client_count],
            queue: VecDeque::new(),
            observed_replies: Vec::new(),
            lost_replies: Vec::new(),
        }
    }

    fn persist(&mut self, id: ReplicaID) {
        self.durable_view[id] = self.replicas[id].view_number();
    }

    fn deliver_to(&mut self, dst: ReplicaID, message: Message<Op>) {
        assert!(self.replica_up[dst], "attempted delivery to crashed replica {dst}");
        self.replicas[dst].on_message(message);
        self.persist(dst);
    }

    fn drain_messages(&mut self, id: ReplicaID) -> Vec<(ReplicaID, Message<Op>)> {
        if !self.replica_up[id] {
            return Vec::new();
        }
        self.persist(id);
        self.replicas[id].drain_messages().collect()
    }

    fn drain_replies(&mut self, id: ReplicaID) -> Vec<Reply<i64>> {
        if !self.replica_up[id] {
            return Vec::new();
        }
        self.persist(id);
        self.replicas[id].drain_replies().collect()
    }

    fn deliver_reply(&mut self, reply: Reply<i64>) -> bool {
        let client_id = reply.client_id;
        let matched = self.clients[client_id].on_reply(reply.request_number, reply.view_number);
        if matched {
            self.pending[client_id] = None;
        }
        self.observed_replies.push(reply);
        matched
    }

    fn lose_reply(&mut self, reply: Reply<i64>) {
        self.lost_replies.push(reply);
    }

    fn submit(&mut self, client_id: usize, op: Op) -> RequestNumber {
        let request_number = self.clients[client_id].on_request(op);
        self.pending[client_id] = Some(request_number);
        let outbound: Vec<_> = self.clients[client_id].drain().collect();
        assert_eq!(outbound.len(), 1);
        let (dst, message) = outbound.into_iter().next().unwrap();
        self.deliver_to(dst, message);
        request_number
    }

    fn commit_on_old_primary_via_replica2(&mut self, client_id: usize, op: Op) -> RequestNumber {
        let request_number = self.submit(client_id, op);
        let prepares = self.drain_messages(0);
        assert_eq!(prepares.len(), 2, "primary should prepare to both backups");
        for (dst, message) in prepares {
            if dst == 2 {
                self.deliver_to(dst, message);
            }
        }

        let prepare_oks = self.drain_messages(2);
        assert_eq!(prepare_oks.len(), 1, "replica 2 should acknowledge the prepare");
        for (dst, message) in prepare_oks {
            assert_eq!(dst, 0);
            self.deliver_to(dst, message);
        }

        let replies = self.drain_replies(0);
        assert_eq!(replies.len(), 1, "old primary should commit and reply");
        for reply in replies {
            self.lose_reply(reply);
        }
        request_number
    }

    fn start_view1_on_replica1_from_real_messages(&mut self) -> (Vec<(ReplicaID, Message<Op>)>, Vec<Reply<i64>>) {
        for _ in 0..3 {
            self.replicas[1].on_idle();
            self.persist(1);
        }
        let r1_view_change_messages = self.drain_messages(1);
        assert_eq!(self.replicas[1].status(), Status::ViewChange);
        assert_eq!(self.replicas[1].view_number(), 1);

        for _ in 0..3 {
            self.replicas[2].on_idle();
            self.persist(2);
        }
        let r2_view_change_messages = self.drain_messages(2);
        assert_eq!(self.replicas[2].status(), Status::ViewChange);
        assert_eq!(self.replicas[2].view_number(), 1);

        let r2_to_r1 = r2_view_change_messages
            .iter()
            .find(|(dst, message)| {
                *dst == 1 && matches!(message, Message::StartViewChange { view_number: 1, replica_id: 2 })
            })
            .cloned()
            .expect("replica 2 should ask replica 1 to enter view 1");
        self.deliver_to(r2_to_r1.0, r2_to_r1.1);
        assert!(self.drain_messages(1).is_empty(), "self DoViewChange is recorded locally");

        let r1_to_r0 = r1_view_change_messages
            .iter()
            .find(|(dst, message)| {
                *dst == 0 && matches!(message, Message::StartViewChange { view_number: 1, replica_id: 1 })
            })
            .cloned()
            .expect("replica 1 should ask old primary to enter view 1");
        self.deliver_to(r1_to_r0.0, r1_to_r0.1);

        let r0_outputs = self.drain_messages(0);
        let dvc_to_r1 = r0_outputs
            .into_iter()
            .find(|(dst, message)| {
                *dst == 1 && matches!(message, Message::DoViewChange { view_number: 1, replica_id: 0, .. })
            })
            .expect("old primary should send its committed log in DoViewChange");
        self.deliver_to(dvc_to_r1.0, dvc_to_r1.1);

        assert_eq!(self.replicas[1].status(), Status::Normal);
        assert_eq!(self.replicas[1].view_number(), 1);
        assert!(self.replicas[1].is_primary());
        assert_eq!(self.replicas[1].commit_number(), 2);
        assert_eq!(self.replicas[1].state_machine().value, 30);

        let start_views = self.drain_messages(1);
        let replies = self.drain_replies(1);
        assert_eq!(start_views.len(), 2, "new primary should send StartView to replicas 0 and 2");
        assert_eq!(replies.len(), 2, "new primary should regenerate the two lost commit replies");
        (start_views, replies)
    }

    fn reboot_replica1_after_partial_publication(&mut self) {
        let persisted = self.durable_view[1];
        assert_eq!(persisted, 1, "owner must have persisted view 1 before publishing outputs");
        self.replica_up[1] = false;
        self.replicas[1] = Replica::recover(1, self.config.clone(), Counter::default(), persisted, 99);
        self.replica_up[1] = true;
        self.persist(1);
        assert_eq!(self.replicas[1].status(), Status::Recovering);
        assert_eq!(self.replicas[1].view_number(), 1);
        assert_eq!(self.replicas[1].op_number(), 0);
    }

    fn enqueue_all_outputs(&mut self) {
        for id in 0..self.replicas.len() {
            for item in self.drain_messages(id) {
                self.queue.push_back(item);
            }
            for reply in self.drain_replies(id) {
                self.deliver_reply(reply);
            }
        }
        for id in 0..self.clients.len() {
            for item in self.clients[id].drain() {
                self.queue.push_back(item);
            }
        }
    }

    fn pump_until_settled(&mut self, rounds: usize) {
        for _ in 0..rounds {
            for id in 0..self.replicas.len() {
                if self.replica_up[id] {
                    self.replicas[id].on_idle();
                    self.persist(id);
                }
            }
            for client in &mut self.clients {
                client.on_idle();
            }

            loop {
                self.enqueue_all_outputs();
                if self.queue.is_empty() {
                    break;
                }
                while let Some((dst, message)) = self.queue.pop_front() {
                    if self.replica_up[dst] {
                        self.deliver_to(dst, message);
                    }
                }
            }

            let view = self.replicas[0].view_number();
            let commit = self.replicas[0].commit_number();
            let value = self.replicas[0].state_machine().value;
            let settled = self
                .replicas
                .iter()
                .all(|replica| {
                    replica.status() == Status::Normal
                        && replica.view_number() == view
                        && replica.commit_number() == commit
                        && replica.state_machine().value == value
                });
            let no_pending = self.pending.iter().all(Option::is_none);
            if settled && no_pending {
                return;
            }
        }

        panic!(
            "cluster did not settle: views={:?} statuses={:?} commits={:?} values={:?} pending={:?}",
            self.replicas.iter().map(Replica::view_number).collect::<Vec<_>>(),
            self.replicas.iter().map(Replica::status).collect::<Vec<_>>(),
            self.replicas.iter().map(Replica::commit_number).collect::<Vec<_>>(),
            self.replicas.iter().map(|r| r.state_machine().value).collect::<Vec<_>>(),
            self.pending
        );
    }

    fn assert_all_replicas(&self, view: usize, commit: usize, value: i64) {
        for (id, replica) in self.replicas.iter().enumerate() {
            assert_eq!(replica.status(), Status::Normal, "replica {id} status");
            assert_eq!(replica.view_number(), view, "replica {id} view");
            assert_eq!(replica.commit_number(), commit, "replica {id} commit");
            assert_eq!(replica.state_machine().value, value, "replica {id} value");
        }
    }
}

fn case_startview_prefix_only() {
    let mut h = Harness::new(2);
    h.commit_on_old_primary_via_replica2(0, Op::Add(10));
    h.commit_on_old_primary_via_replica2(1, Op::Add(20));

    let (start_views, replies) = h.start_view1_on_replica1_from_real_messages();
    assert_eq!(h.lost_replies.len(), 2, "old primary replies were lost before the view change");
    assert_eq!(h.observed_replies.len(), 0, "no client has observed completion yet");

    let (first_dst, first_start_view) = start_views[0].clone();
    h.deliver_to(first_dst, first_start_view);
    for reply in replies {
        h.lose_reply(reply);
    }
    h.reboot_replica1_after_partial_publication();
    h.pump_until_settled(80);

    let mut observed = h
        .observed_replies
        .iter()
        .map(|reply| (reply.client_id, reply.request_number, reply.view_number, reply.result))
        .collect::<Vec<_>>();
    observed.sort();
    assert!(observed.contains(&(0, 0, 2, 10)), "client 0 eventually receives the committed reply in view 2: {observed:?}");
    assert!(observed.contains(&(1, 0, 2, 30)), "client 1 eventually receives the committed reply in view 2: {observed:?}");
    h.assert_all_replicas(2, 2, 30);

    println!(
        "case startview-prefix-only: PASS; published 1/2 StartView messages and 0/2 new-primary replies, rebooted replica 1 with durable_view=1, then all replicas settled in view 2 at commit=2 value=30; observed replies={observed:?}"
    );
}

fn case_reply_suffix_lost_then_later_request() {
    let mut h = Harness::new(2);
    h.commit_on_old_primary_via_replica2(0, Op::Add(10));
    h.commit_on_old_primary_via_replica2(1, Op::Add(20));

    let (start_views, replies) = h.start_view1_on_replica1_from_real_messages();
    for (dst, message) in start_views {
        h.deliver_to(dst, message);
    }

    let first_reply = replies[0].clone();
    let second_reply = replies[1].clone();
    assert_eq!(first_reply.client_id, 0);
    assert_eq!(first_reply.result, 10);
    assert!(h.deliver_reply(first_reply), "first reply should complete client 0 request");
    h.lose_reply(second_reply);

    h.reboot_replica1_after_partial_publication();

    let later_request = h.submit(0, Op::Add(5));
    assert_eq!(later_request, 1, "client 0's later operation should be request 1");

    h.pump_until_settled(80);

    let observed = h
        .observed_replies
        .iter()
        .map(|reply| (reply.client_id, reply.request_number, reply.view_number, reply.result))
        .collect::<Vec<_>>();
    assert!(observed.contains(&(0, 0, 1, 10)), "client 0 observed the prefix reply before the crash: {observed:?}");
    assert!(observed.contains(&(1, 0, 2, 30)), "client 1's dropped suffix reply is regenerated after the later view change: {observed:?}");
    assert!(observed.contains(&(0, 1, 2, 35)), "client 0's later request sees the committed prefix in order: {observed:?}");
    h.assert_all_replicas(2, 3, 35);

    println!(
        "case reply-suffix-lost-then-later-request: PASS; published both StartView messages and only the first of two replies, rebooted replica 1 with durable_view=1, then client 1's reply was regenerated and client 0's later request returned 35; observed replies={observed:?}"
    );
}

fn main() {
    println!("CR-4 reproduction attempt: Level 0 public API schedule with real Client/Replica calls, message loss, partial publication, and Replica::recover.");
    case_startview_prefix_only();
    case_reply_suffix_lost_then_later_request();
    println!("Level 1 timing assistance: not needed for nondeterminism; the exact crash window is exposed deterministically by draining only a prefix after the required durable view write.");
    println!("Level 2 state injection: not used; the precondition was reached by real requests, Prepare/PrepareOk, StartViewChange, DoViewChange, StartView, and Recovery messages.");
    println!("Level 3 source patch: not used; no source delay or logic patch is required to hit the publication boundary.");
    println!("RESULT: no safety or client-linearizability violation observed; recovery/view-change plus client resend regenerated lost suffix replies and preserved committed order.");
}
EOF

timeout 5m cargo run --quiet --manifest-path "$TMPDIR/Cargo.toml"
