#!/usr/bin/env bash
set -eu

REPO="/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/vsr-rs/.specula-output/confirmation/CR-2/worktree"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cr2-singleton.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/src"
cat > "$TMP/Cargo.toml" <<EOF
[package]
name = "cr2_singleton_repro"
version = "0.1.0"
edition = "2021"

[dependencies]
vsr-rs = { path = "$REPO" }
EOF

cat > "$TMP/src/main.rs" <<'EOF'
use vsr_rs::{Client, Config, Message, Replica, ReplicaID, Reply, StateMachine};

#[derive(Clone, Debug)]
enum Op {
    Add(i32),
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
        }
    }
}

fn config_with_replicas(replica_count: usize) -> Config {
    let mut config = Config::new();
    for _ in 0..replica_count {
        config.add_replica();
    }
    config
}

fn collect_and_deliver(
    replicas: &mut [Replica<Counter>],
    client: &mut Client<Op>,
    replies: &mut Vec<Reply<i32>>,
) -> usize {
    let mut queue: Vec<(ReplicaID, Message<Op>)> = client.drain().collect();
    for replica in replicas.iter_mut() {
        queue.extend(replica.drain_messages());
        replies.extend(replica.drain_replies());
    }

    let delivered = queue.len();
    for (to, message) in queue {
        replicas[to].on_message(message);
    }
    delivered
}

fn run_until_quiescent(
    replicas: &mut [Replica<Counter>],
    client: &mut Client<Op>,
    replies: &mut Vec<Reply<i32>>,
    max_rounds: usize,
) {
    for _ in 0..max_rounds {
        if collect_and_deliver(replicas, client, replies) == 0 {
            collect_and_deliver(replicas, client, replies);
            break;
        }
    }
}

fn main() {
    let control_config = config_with_replicas(3);
    let mut control_replicas: Vec<_> = (0..3)
        .map(|id| Replica::new(id, control_config.clone(), Counter::default()))
        .collect();
    let mut control_client = Client::new(0, control_config);
    let mut control_replies = Vec::new();
    control_client.on_request(Op::Add(7));
    run_until_quiescent(
        &mut control_replicas,
        &mut control_client,
        &mut control_replies,
        20,
    );
    println!(
        "control_three_replicas: op={} commit={} value={} replies={}",
        control_replicas[0].op_number(),
        control_replicas[0].commit_number(),
        control_replicas[0].state_machine().value,
        control_replies.len()
    );
    assert_eq!(control_replicas[0].op_number(), 1);
    assert_eq!(control_replicas[0].commit_number(), 1);
    assert_eq!(control_replicas[0].state_machine().value, 7);
    assert_eq!(control_replies.len(), 1);

    let singleton_config = config_with_replicas(1);
    println!(
        "singleton_config: replicas={:?} quorum={}",
        singleton_config.replicas(),
        singleton_config.quorum()
    );
    let mut singleton_replicas =
        vec![Replica::new(0, singleton_config.clone(), Counter::default())];
    let mut singleton_client = Client::new(0, singleton_config);
    let mut singleton_replies = Vec::new();

    let request_number = singleton_client.on_request(Op::Add(7));
    println!("singleton_request: request_number={request_number}");

    for round in 0..8 {
        let delivered_before_idle = collect_and_deliver(
            &mut singleton_replicas,
            &mut singleton_client,
            &mut singleton_replies,
        );
        for replica in singleton_replicas.iter_mut() {
            replica.on_idle();
        }
        singleton_client.on_idle();
        let delivered_after_idle = collect_and_deliver(
            &mut singleton_replicas,
            &mut singleton_client,
            &mut singleton_replies,
        );
        println!(
            "singleton_round_{round}: delivered_before_idle={} delivered_after_idle={} op={} commit={} value={} replies={}",
            delivered_before_idle,
            delivered_after_idle,
            singleton_replicas[0].op_number(),
            singleton_replicas[0].commit_number(),
            singleton_replicas[0].state_machine().value,
            singleton_replies.len()
        );
    }

    let no_replica_messages_left = singleton_replicas[0].drain_messages().count() == 0;
    let no_replies_left = singleton_replicas[0].drain_replies().count() == 0;
    println!(
        "singleton_final: op={} commit={} value={} replies={} no_replica_messages_left={} no_replies_left={}",
        singleton_replicas[0].op_number(),
        singleton_replicas[0].commit_number(),
        singleton_replicas[0].state_machine().value,
        singleton_replies.len(),
        no_replica_messages_left,
        no_replies_left
    );

    if singleton_replicas[0].op_number() == 1
        && singleton_replicas[0].commit_number() == 0
        && singleton_replicas[0].state_machine().value == 0
        && singleton_replies.is_empty()
        && no_replica_messages_left
        && no_replies_left
    {
        println!(
            "BUG REPRODUCED: singleton accepts quorum=1 and records the request, but no public owner-loop step commits it or returns a reply"
        );
        return;
    }

    eprintln!(
        "BUG NOT REPRODUCED: singleton progressed to op={} commit={} value={} replies={}",
        singleton_replicas[0].op_number(),
        singleton_replicas[0].commit_number(),
        singleton_replicas[0].state_machine().value,
        singleton_replies.len()
    );
    std::process::exit(1);
}
EOF

cd "$TMP"
cargo run --quiet
