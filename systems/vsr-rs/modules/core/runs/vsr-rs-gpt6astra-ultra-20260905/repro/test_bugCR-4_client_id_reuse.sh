#!/usr/bin/env bash
set -euo pipefail

WORKTREE="/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-20260905/vsr-rs/.specula-output/confirmation/CR-4/worktree"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/src"
cat > "$TMPDIR/Cargo.toml" <<EOF
[package]
name = "cr4_client_id_reuse_repro"
version = "0.1.0"
edition = "2021"

[dependencies]
vsr-rs = { path = "$WORKTREE" }
EOF

cat > "$TMPDIR/src/main.rs" <<'EOF'
use std::collections::HashMap;
use vsr_rs::{Client, ClientID, Config, Message, Replica, Reply, StateMachine};

#[derive(Clone, Debug, PartialEq, Eq)]
enum Op {
    Put(String, String),
    Get(String),
}

#[derive(Default)]
struct Store {
    map: HashMap<String, String>,
}

impl StateMachine for Store {
    type Input = Op;
    type Output = Option<String>;

    fn apply(&mut self, op: Op) -> Option<String> {
        match op {
            Op::Put(key, value) => {
                self.map.insert(key, value);
                None
            }
            Op::Get(key) => self.map.get(&key).cloned(),
        }
    }
}

fn config3() -> Config {
    let mut config = Config::new();
    for _ in 0..3 {
        config.add_replica();
    }
    config
}

fn kvstore_connection_id(node_id: u64, started_secs_low24: u64, accept_counter: u64) -> ClientID {
    (((node_id as u64) << 56) | ((started_secs_low24 & 0xFF_FFFF) << 32) | accept_counter)
        as ClientID
}

fn deliver_to_replica(replicas: &mut [Replica<Store>], dst: usize, message: Message<Op>) {
    replicas[dst].on_message(message);
}

fn drain_client(client: &mut Client<Op>, replicas: &mut [Replica<Store>]) {
    let outgoing: Vec<_> = client.drain().collect();
    for (dst, message) in outgoing {
        deliver_to_replica(replicas, dst, message);
    }
}

fn drain_replica_messages(src: usize, replicas: &mut [Replica<Store>]) {
    let outgoing: Vec<_> = replicas[src].drain_messages().collect();
    for (dst, message) in outgoing {
        deliver_to_replica(replicas, dst, message);
    }
}

fn drain_replica_replies(src: usize, replicas: &mut [Replica<Store>]) -> Vec<Reply<Option<String>>> {
    replicas[src].drain_replies().collect()
}

fn main() {
    let config = config3();
    let mut replicas = vec![
        Replica::new(0, config.clone(), Store::default()),
        Replica::new(1, config.clone(), Store::default()),
        Replica::new(2, config.clone(), Store::default()),
    ];

    let started = 0x00ab_cdef;
    let first_connection = kvstore_connection_id(0, started, 0);
    let restarted_first_connection = kvstore_connection_id(0, started, 0);
    assert_eq!(first_connection, restarted_first_connection);
    println!(
        "kvstore restart-within-one-second id: first={} restarted_first={}",
        first_connection, restarted_first_connection
    );

    let mut first_client = Client::new(first_connection, config.clone());
    let first_req = first_client.on_request(Op::Put("k".to_string(), "old".to_string()));
    assert_eq!(first_req, 0);
    drain_client(&mut first_client, &mut replicas);
    drain_replica_messages(0, &mut replicas);
    drain_replica_messages(1, &mut replicas);
    drain_replica_messages(2, &mut replicas);

    let first_replies = drain_replica_replies(0, &mut replicas);
    assert_eq!(first_replies.len(), 1);
    assert_eq!(first_replies[0].client_id, first_connection);
    assert_eq!(first_replies[0].request_number, 0);
    assert_eq!(first_replies[0].result, None);
    println!(
        "first command SET k old: reply client={} request={} result={:?}",
        first_replies[0].client_id, first_replies[0].request_number, first_replies[0].result
    );

    replicas[0].on_idle();
    drain_replica_messages(0, &mut replicas);

    let mut restarted_client = Client::new(restarted_first_connection, config.clone());
    let restarted_req = restarted_client.on_request(Op::Get("k".to_string()));
    assert_eq!(restarted_req, 0);
    drain_client(&mut restarted_client, &mut replicas);

    let duplicate_replies = drain_replica_replies(0, &mut replicas);
    assert_eq!(duplicate_replies.len(), 1);
    let duplicate = &duplicate_replies[0];
    println!(
        "restarted first command GET k: reply client={} request={} result={:?}",
        duplicate.client_id, duplicate.request_number, duplicate.result
    );
    println!("expected GET k result after committed SET: Some(\"old\")");

    assert_eq!(duplicate.client_id, restarted_first_connection);
    assert_eq!(duplicate.request_number, 0);
    assert_eq!(duplicate.result, None);
    assert_ne!(duplicate.result, Some("old".to_string()));

    println!(
        "BUG OBSERVED: duplicate client id/request number was answered from the old SET cache; \
         the kvstore connection code would format this GET reply as $-1 instead of returning old"
    );
}
EOF

cd "$TMPDIR"
cargo run --quiet
