#!/usr/bin/env bash
set -euo pipefail

REPO="/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-20260905/vsr-rs/.specula-output/confirmation/CR-2/worktree"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/Cargo.toml" <<MANIFEST
[package]
name = "cr2-request-recovery-reconstruction"
version = "0.1.0"
edition = "2021"

[dependencies]
vsr-rs = { path = "$REPO" }
MANIFEST

mkdir -p "$TMP/src"
cat >"$TMP/src/main.rs" <<'RS'
use std::collections::VecDeque;
use vsr_rs::{Client, Config, Message, Replica, ReplicaID, Reply, StateMachine};

#[derive(Clone, Debug, PartialEq, Eq)]
enum Op {
    Add(i32),
}

#[derive(Debug, Default)]
struct Counter {
    value: i32,
    applied: Vec<Op>,
}

impl StateMachine for Counter {
    type Input = Op;
    type Output = i32;

    fn apply(&mut self, op: Op) -> i32 {
        match op {
            Op::Add(delta) => self.value += delta,
        }
        self.applied.push(op);
        self.value
    }
}

struct Cluster {
    config: Config,
    replicas: Vec<Option<Replica<Counter>>>,
    client: Client<Op>,
    network: VecDeque<(ReplicaID, Message<Op>)>,
    replies: Vec<Reply<i32>>,
    durable_view: Vec<usize>,
}

impl Cluster {
    fn new() -> Cluster {
        let mut config = Config::new();
        for _ in 0..3 {
            config.add_replica();
        }
        config.set_primary_timeout(2);
        let replicas = (0..3)
            .map(|id| Some(Replica::new(id, config.clone(), Counter::default())))
            .collect();
        Cluster {
            config: config.clone(),
            replicas,
            client: Client::new(0, config),
            network: VecDeque::new(),
            replies: Vec::new(),
            durable_view: vec![0; 3],
        }
    }

    fn replica(&self, id: usize) -> &Replica<Counter> {
        self.replicas[id].as_ref().expect("replica is up")
    }

    fn replica_mut(&mut self, id: usize) -> &mut Replica<Counter> {
        self.replicas[id].as_mut().expect("replica is up")
    }

    fn collect(&mut self) {
        for (id, replica) in self.replicas.iter_mut().enumerate() {
            if let Some(replica) = replica {
                self.durable_view[id] = replica.view_number();
                self.network.extend(replica.drain_messages());
                self.replies.extend(replica.drain_replies());
            }
        }
        self.network.extend(self.client.drain());
    }

    fn deliver_all_network(&mut self) {
        for _ in 0..100 {
            self.collect();
            if self.network.is_empty() {
                return;
            }
            let batch = std::mem::take(&mut self.network);
            for (dst, message) in batch {
                if let Some(replica) = self.replicas[dst].as_mut() {
                    replica.on_message(message);
                }
            }
        }
        panic!("network did not drain");
    }

    fn take_replies(&mut self) -> Vec<Reply<i32>> {
        self.collect();
        std::mem::take(&mut self.replies)
    }

    fn idle_up_replicas(&mut self) {
        for replica in &mut self.replicas {
            if let Some(replica) = replica {
                replica.on_idle();
            }
        }
    }

    fn crash(&mut self, id: usize) {
        self.replicas[id] = None;
    }

    fn recover(&mut self, id: usize, nonce: u64) {
        let view = self.durable_view[id];
        self.replicas[id] = Some(Replica::recover(
            id,
            self.config.clone(),
            Counter::default(),
            view,
            nonce,
        ));
    }
}

fn level0_duplicate_reply_cache() {
    let mut cluster = Cluster::new();
    let request = cluster.client.on_request(Op::Add(10));
    assert_eq!(request, 0);

    cluster.deliver_all_network();
    let lost = cluster.take_replies();
    assert_eq!(lost.len(), 1);
    assert_eq!(lost[0].request_number, request);
    assert_eq!(lost[0].result, 10);
    assert_eq!(cluster.replica(0).state_machine().applied.len(), 1);

    cluster.client.on_idle();
    cluster.deliver_all_network();
    let retry = cluster.take_replies();
    assert_eq!(retry.len(), 1);
    assert_eq!(retry[0].request_number, request);
    assert_eq!(retry[0].result, 10);
    assert!(cluster
        .client
        .on_reply(retry[0].request_number, retry[0].view_number));
    assert_eq!(cluster.replica(0).state_machine().applied.len(), 1);

    println!(
        "Level 0 public API duplicate request: cached retry reply result={}, primary_applied={}",
        retry[0].result,
        cluster.replica(0).state_machine().applied.len()
    );
}

fn level1_recovery_reconstructs_latest_reply_for_future_primary() {
    let mut cluster = Cluster::new();
    let request = cluster.client.on_request(Op::Add(7));
    assert_eq!(request, 0);

    cluster.deliver_all_network();
    let lost = cluster.take_replies();
    assert_eq!(lost.len(), 1);
    assert_eq!(lost[0].request_number, request);
    assert_eq!(lost[0].result, 7);

    cluster.replica_mut(0).on_idle();
    cluster.deliver_all_network();
    assert!(cluster.take_replies().is_empty());
    for id in 0..3 {
        assert_eq!(cluster.replica(id).commit_number(), 1);
        assert_eq!(cluster.replica(id).state_machine().value, 7);
    }

    cluster.recover(1, 1001);
    cluster.deliver_all_network();
    assert!(!cluster.replica(1).is_recovering());
    assert_eq!(cluster.replica(1).commit_number(), 1);
    assert_eq!(cluster.replica(1).state_machine().value, 7);
    assert_eq!(cluster.replica(1).state_machine().applied.len(), 1);
    assert!(
        cluster.take_replies().is_empty(),
        "recovery must reconstruct state without emitting client replies"
    );

    cluster.crash(0);
    for _ in 0..8 {
        cluster.idle_up_replicas();
        cluster.deliver_all_network();
    }
    assert_eq!(cluster.replica(1).view_number(), 1);
    assert!(cluster.replica(1).is_primary());
    assert_eq!(cluster.replica(1).commit_number(), 1);
    let applied_before_retry = cluster.replica(1).state_machine().applied.len();

    cluster.client.on_idle();
    cluster.deliver_all_network();
    let retry = cluster.take_replies();
    assert_eq!(retry.len(), 1);
    assert_eq!(retry[0].request_number, request);
    assert_eq!(retry[0].view_number, 1);
    assert_eq!(retry[0].result, 7);
    assert!(cluster
        .client
        .on_reply(retry[0].request_number, retry[0].view_number));
    assert_eq!(
        cluster.replica(1).state_machine().applied.len(),
        applied_before_retry,
        "cached duplicate reply must not reapply the operation"
    );

    println!(
        "Level 1 timed recovery/view-change: recovered primary reply result={}, view={}, applied_before={}, applied_after={}",
        retry[0].result,
        retry[0].view_number,
        applied_before_retry,
        cluster.replica(1).state_machine().applied.len()
    );
}

fn main() {
    level0_duplicate_reply_cache();
    level1_recovery_reconstructs_latest_reply_for_future_primary();
    println!(
        "Level 2 state injection: not used; the remaining suspicious stale-client-table preconditions require violating the documented one-outstanding-request/client-identity contract."
    );
    println!(
        "Level 3 source patch: not used; no public-API timing window produced a wrong reply, duplicate application, or permanent bad state."
    );
    println!("CR-2 RESULT: no wrong client-visible reply and no duplicate application under the documented public contract");
}
RS

cargo run --quiet --manifest-path "$TMP/Cargo.toml"
