#!/usr/bin/env bash
set -euo pipefail

WORKTREE="${WORKTREE:-/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round3-guided-20260906/vsr-rs/.specula-output/confirmation/CR-5/worktree}"
TMPROOT="${TMPDIR:-/tmp}"
TMP="$(mktemp -d "$TMPROOT/cr5-repro.XXXXXX")"
cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/src"
cat > "$TMP/Cargo.toml" <<EOF
[package]
name = "cr5-repro"
version = "0.1.0"
edition = "2021"

[dependencies]
vsr-rs = { path = "$WORKTREE" }
EOF

cat > "$TMP/src/main.rs" <<'RS'
use std::collections::VecDeque;
use vsr_rs::{Client, Config, Message, Replica, Reply, StateMachine, Status};

#[derive(Clone, Debug)]
enum Op {
    Add(i32),
    Read,
}

#[derive(Default)]
struct Counter {
    value: i32,
}

impl StateMachine for Counter {
    type Input = Op;
    type Output = i32;

    fn apply(&mut self, op: Op) -> i32 {
        match op {
            Op::Add(delta) => {
                self.value += delta;
                self.value
            }
            Op::Read => self.value,
        }
    }
}

struct Cluster {
    config: Config,
    replicas: Vec<Option<Replica<Counter>>>,
    client: Client<Op>,
    queue: VecDeque<(usize, Message<Op>)>,
    completions: Vec<Reply<i32>>,
}

impl Cluster {
    fn new(replica_count: usize, primary_timeout: usize) -> Cluster {
        let mut config = Config::new();
        for _ in 0..replica_count {
            config.add_replica();
        }
        config.set_primary_timeout(primary_timeout);
        let replicas = (0..replica_count)
            .map(|id| Some(Replica::new(id, config.clone(), Counter::default())))
            .collect();
        Cluster {
            client: Client::new(0, config.clone()),
            config,
            replicas,
            queue: VecDeque::new(),
            completions: Vec::new(),
        }
    }

    fn crash(&mut self, replica_id: usize) {
        self.replicas[replica_id] = None;
    }

    fn alive(&self, replica_id: usize) -> bool {
        self.replicas[replica_id].is_some()
    }

    fn replica(&self, replica_id: usize) -> &Replica<Counter> {
        self.replicas[replica_id].as_ref().expect("replica is down")
    }

    fn status(&self, replica_id: usize) -> Status {
        self.replica(replica_id).status()
    }

    fn view(&self, replica_id: usize) -> usize {
        self.replica(replica_id).view_number()
    }

    fn request(&mut self, op: Op) -> usize {
        let request_number = self.client.on_request(op);
        self.queue.extend(self.client.drain());
        request_number
    }

    fn client_idle(&mut self) {
        self.client.on_idle();
        self.queue.extend(self.client.drain());
    }

    fn idle_replica(&mut self, replica_id: usize) {
        if let Some(replica) = self.replicas[replica_id].as_mut() {
            replica.on_idle();
        }
        self.collect_replica_outputs();
    }

    fn collect_replica_outputs(&mut self) {
        for replica in self.replicas.iter_mut().flatten() {
            self.queue.extend(replica.drain_messages());
            for reply in replica.drain_replies() {
                if self.client.on_reply(reply.request_number, reply.view_number) {
                    self.completions.push(reply);
                }
            }
        }
    }

    fn deliver_one(&mut self) {
        let (dst, message) = self.queue.pop_front().expect("queue is empty");
        if let Some(replica) = self.replicas[dst].as_mut() {
            replica.on_message(message);
        }
        self.collect_replica_outputs();
    }

    fn drain_all(&mut self, limit: usize) {
        self.collect_replica_outputs();
        for _ in 0..limit {
            if self.queue.is_empty() {
                return;
            }
            self.deliver_one();
        }
        panic!("drain_all exhausted with {} messages still queued; {}", self.queue.len(), self.describe());
    }

    fn fair_round_immediate(&mut self) {
        self.client_idle();
        for replica_id in 0..self.replicas.len() {
            self.idle_replica(replica_id);
        }
        self.drain_all(1000);
    }

    fn fair_round_delayed(&mut self) {
        self.client_idle();
        for replica_id in 0..self.replicas.len() {
            self.idle_replica(replica_id);
        }
        let batch = self.queue.len();
        for _ in 0..batch {
            if self.queue.is_empty() {
                break;
            }
            self.deliver_one();
        }
    }

    fn complete_request(&mut self, request_number: usize, max_rounds: usize, delayed: bool) -> Reply<i32> {
        for round in 0..max_rounds {
            if delayed {
                self.fair_round_delayed();
            } else {
                self.fair_round_immediate();
            }
            if let Some(reply) = self
                .completions
                .iter()
                .find(|reply| reply.client_id == 0 && reply.request_number == request_number)
                .cloned()
            {
                println!(
                    "request {request_number} completed after {} fair rounds in view {} with result {}",
                    round + 1,
                    reply.view_number,
                    reply.result
                );
                return reply;
            }
        }
        panic!(
            "request {request_number} did not complete after {max_rounds} fair rounds; {}",
            self.describe()
        );
    }

    fn all_normal_same_view(&self, nodes: &[usize]) -> bool {
        let view = self.view(nodes[0]);
        nodes
            .iter()
            .all(|&node| self.status(node) == Status::Normal && self.view(node) == view)
    }

    fn settle_healthy(&mut self, nodes: &[usize], rounds: usize) {
        for _ in 0..rounds {
            self.client_idle();
            for &replica_id in nodes {
                self.idle_replica(replica_id);
            }
            self.drain_all(1000);
        }
    }

    fn commits(&self, nodes: &[usize]) -> Vec<usize> {
        nodes
            .iter()
            .map(|&node| self.replica(node).commit_number())
            .collect()
    }

    fn values(&self, nodes: &[usize]) -> Vec<i32> {
        nodes
            .iter()
            .map(|&node| self.replica(node).state_machine().value)
            .collect()
    }

    fn describe(&self) -> String {
        let mut parts = Vec::new();
        for replica_id in 0..self.replicas.len() {
            if self.alive(replica_id) {
                let replica = self.replica(replica_id);
                parts.push(format!(
                    "r{replica_id}=view:{} status:{:?} commit:{} value:{} primary:{}",
                    replica.view_number(),
                    replica.status(),
                    replica.commit_number(),
                    replica.state_machine().value,
                    replica.primary_id()
                ));
            } else {
                parts.push(format!("r{replica_id}=down"));
            }
        }
        format!("{}; queue={}", parts.join(", "), self.queue.len())
    }
}

fn level0_initial_primary_down() {
    let mut cluster = Cluster::new(3, 2);
    cluster.crash(0);
    let request = cluster.request(Op::Add(7));
    println!("level0 initial-primary-down: request {request} first targets unavailable primary 0");
    let reply = cluster.complete_request(request, 40, false);
    assert_eq!(reply.result, 7);
    cluster.settle_healthy(&[1, 2], 3);
    assert!(cluster.all_normal_same_view(&[1, 2]), "{}", cluster.describe());
    assert!(cluster.view(1) >= 1, "{}", cluster.describe());
    assert_eq!(cluster.commits(&[1, 2]), vec![1, 1], "{}", cluster.describe());
    assert_eq!(cluster.values(&[1, 2]), vec![7, 7], "{}", cluster.describe());
    println!(
        "level0 initial-primary-down: healthy nodes settled, commits={:?}, values={:?}, {}",
        cluster.commits(&[1, 2]),
        cluster.values(&[1, 2]),
        cluster.describe()
    );
}

fn force_view_with_dead_primary_one(cluster: &mut Cluster) {
    cluster.crash(1);
    for _ in 0..8 {
        cluster.idle_replica(2);
        cluster.drain_all(1000);
        if cluster.view(0) == 1
            && cluster.view(2) == 1
            && cluster.status(0) == Status::ViewChange
            && cluster.status(2) == Status::ViewChange
        {
            break;
        }
    }
    assert_eq!(cluster.config.primary_id(1), 1);
    assert_eq!(cluster.view(0), 1, "{}", cluster.describe());
    assert_eq!(cluster.view(2), 1, "{}", cluster.describe());
    assert_eq!(cluster.status(0), Status::ViewChange, "{}", cluster.describe());
    assert_eq!(cluster.status(2), Status::ViewChange, "{}", cluster.describe());
    println!(
        "finite prefix reached view 1 with unavailable primary {}; {}",
        cluster.config.primary_id(1),
        cluster.describe()
    );
}

fn level0_skipped_round_robin_primary() {
    let mut cluster = Cluster::new(3, 2);
    let warmup = cluster.request(Op::Add(10));
    let warmup_reply = cluster.complete_request(warmup, 20, false);
    assert_eq!(warmup_reply.result, 10);
    cluster.idle_replica(0);
    cluster.drain_all(1000);

    force_view_with_dead_primary_one(&mut cluster);
    let read = cluster.request(Op::Read);
    println!("level0 skipped-primary: request {read} issued while healthy replicas are in view-change for dead primary 1");
    let read_reply = cluster.complete_request(read, 60, false);
    assert_eq!(read_reply.result, 10);
    assert!(cluster.all_normal_same_view(&[0, 2]), "{}", cluster.describe());
    assert!(cluster.view(2) >= 2, "{}", cluster.describe());

    let add = cluster.request(Op::Add(5));
    let add_reply = cluster.complete_request(add, 20, false);
    assert_eq!(add_reply.result, 15);
    let read_again = cluster.request(Op::Read);
    let read_again_reply = cluster.complete_request(read_again, 20, false);
    assert_eq!(read_again_reply.result, 15);
    cluster.settle_healthy(&[0, 2], 3);
    assert_eq!(cluster.commits(&[0, 2]), vec![4, 4], "{}", cluster.describe());
    assert_eq!(cluster.values(&[0, 2]), vec![15, 15], "{}", cluster.describe());
    println!(
        "level0 skipped-primary: follow-up service continued, commits={:?}, values={:?}, {}",
        cluster.commits(&[0, 2]),
        cluster.values(&[0, 2]),
        cluster.describe()
    );
}

fn level1_delayed_delivery_same_scenario() {
    let mut cluster = Cluster::new(3, 2);
    let warmup = cluster.request(Op::Add(11));
    let warmup_reply = cluster.complete_request(warmup, 30, true);
    assert_eq!(warmup_reply.result, 11);
    for _ in 0..4 {
        cluster.fair_round_delayed();
    }

    force_view_with_dead_primary_one(&mut cluster);
    let read = cluster.request(Op::Read);
    println!("level1 delayed-delivery: request {read} waits through the unavailable-primary view");
    let reply = cluster.complete_request(read, 80, true);
    assert_eq!(reply.result, 11);
    cluster.settle_healthy(&[0, 2], 3);
    assert!(cluster.all_normal_same_view(&[0, 2]), "{}", cluster.describe());
    assert!(cluster.view(2) >= 2, "{}", cluster.describe());
    assert_eq!(cluster.commits(&[0, 2]), vec![2, 2], "{}", cluster.describe());
    assert_eq!(cluster.values(&[0, 2]), vec![11, 11], "{}", cluster.describe());
    println!(
        "level1 delayed-delivery: completed under one-tick delivery, commits={:?}, values={:?}, {}",
        cluster.commits(&[0, 2]),
        cluster.values(&[0, 2]),
        cluster.describe()
    );
}

fn main() {
    println!("CR-5 reproduction test using public vsr-rs Client/Replica APIs");
    println!("Level 0: pure public API with one permanently unavailable replica and fair delivery among a healthy majority");
    level0_initial_primary_down();
    level0_skipped_round_robin_primary();
    println!("Level 1: timing-assisted one-tick delivery/retry schedule, no source changes");
    level1_delayed_delivery_same_scenario();
    println!("Level 2: not used; public API scenarios reached the alleged precondition and observed completion, so state injection would only manufacture non-progress");
    println!("Level 3: not used; no source patch is needed or sound after Level 0/1 reachability and completion");
    println!("CR-5 reproduction result: no permanent non-progress observed; pending client requests completed after healthy-majority timers and retries");
}
RS

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$WORKTREE/target}"
cd "$TMP"
cargo run --quiet
