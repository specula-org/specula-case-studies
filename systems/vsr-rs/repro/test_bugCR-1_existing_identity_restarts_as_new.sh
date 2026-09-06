#!/usr/bin/env bash
set -euo pipefail

WORKTREE=${SOURCE_REPO:?Set SOURCE_REPO to a clean vsr-rs source directory}
BUILD_TARGET=${BUILD_TARGET:-$(mktemp -d)}

echo "CR-1 reproduction: existing identity silently restarts as new"
echo "worktree: ${WORKTREE}"
echo "build target: ${BUILD_TARGET}"

echo
echo "== Level 0A: actual kvstore startup with existing invalid view file =="
timeout 5m env CARGO_TARGET_DIR="${BUILD_TARGET}" cargo build --manifest-path "${WORKTREE}/Cargo.toml" --example kvstore

RUN_DIR=$(mktemp -d)
printf '\xff\n' > "${RUN_DIR}/kvstore-node-1.view"
echo "view file before startup: $(od -An -tx1 "${RUN_DIR}/kvstore-node-1.view" | tr -s ' ' | sed 's/^ //')"

set +e
(
  cd "${RUN_DIR}"
  timeout --kill-after=1s 2s "${BUILD_TARGET}/debug/examples/kvstore" \
    --id 1 \
    --replicas 127.0.0.1:0,127.0.0.1:0,127.0.0.1:0 \
    --listen 127.0.0.1:0
) >"${RUN_DIR}/stdout.log" 2>"${RUN_DIR}/stderr.log"
kv_status=$?
set -e

echo "kvstore process status: ${kv_status} (124 means timeout stopped the long-running server)"
echo "kvstore stdout:"
sed -n '1,20p' "${RUN_DIR}/stdout.log"
echo "kvstore stderr:"
sed -n '1,20p' "${RUN_DIR}/stderr.log"
echo "view file after startup: $(od -An -tx1 "${RUN_DIR}/kvstore-node-1.view" | tr -s ' ' | sed 's/^ //')"

if [[ "${kv_status}" -ne 124 ]]; then
  echo "expected kvstore to keep running until timeout" >&2
  exit 1
fi
if grep -q "recovering from view" "${RUN_DIR}/stdout.log"; then
  echo "expected malformed existing view file not to enter the recovery branch" >&2
  exit 1
fi
if ! grep -q "node 1 of 3:" "${RUN_DIR}/stdout.log"; then
  echo "expected kvstore to complete startup as a normal node" >&2
  exit 1
fi
if ! grep -Eq '^[0-9]+$' <(tr -d '\r\n' < "${RUN_DIR}/kvstore-node-1.view"); then
  echo "expected malformed existing view file to be overwritten with a numeric fresh-start view" >&2
  exit 1
fi

echo "observed: the example accepted an existing invalid view file, skipped recovery, and rewrote it with a normal numeric view"

echo
echo "== Level 0B: public Replica API consequence after that constructor choice =="
CASE_DIR=$(mktemp -d)
mkdir -p "${CASE_DIR}/src"
cat > "${CASE_DIR}/Cargo.toml" <<EOF
[package]
name = "cr1_repro"
version = "0.1.0"
edition = "2021"

[dependencies]
vsr-rs = { path = "${WORKTREE}" }
EOF

cat > "${CASE_DIR}/src/main.rs" <<'RS'
use vsr_rs::{Config, Message, Replica, ReplicaID, Reply, StateMachine, Status};

#[derive(Clone, Debug, PartialEq, Eq)]
enum Op {
    X,
    Y,
}

#[derive(Default)]
struct Recorder {
    applied: Vec<Op>,
}

impl StateMachine for Recorder {
    type Input = Op;
    type Output = &'static str;

    fn apply(&mut self, op: Op) -> &'static str {
        let result = match op {
            Op::X => "X",
            Op::Y => "Y",
        };
        self.applied.push(op);
        result
    }
}

fn new_config() -> Config {
    let mut config = Config::new();
    for _ in 0..3 {
        config.add_replica();
    }
    config
}

fn new_replicas(config: &Config) -> Vec<Replica<Recorder>> {
    (0..3)
        .map(|id| Replica::new(id, config.clone(), Recorder::default()))
        .collect()
}

fn pump_until_idle<F>(replicas: &mut [Replica<Recorder>], deliver: F, max_rounds: usize)
where
    F: Fn(ReplicaID, &Message<Op>) -> bool,
{
    for _ in 0..max_rounds {
        let mut batch = Vec::new();
        for replica in replicas.iter_mut() {
            batch.extend(replica.drain_messages());
        }
        if batch.is_empty() {
            return;
        }
        for (dst, message) in batch {
            if deliver(dst, &message) {
                replicas[dst].on_message(message);
            }
        }
    }
    panic!("message pump did not quiesce");
}

fn take_replies(replicas: &mut [Replica<Recorder>]) -> Vec<Reply<&'static str>> {
    let mut replies = Vec::new();
    for replica in replicas.iter_mut() {
        replies.extend(replica.drain_replies());
    }
    replies
}

fn advance_replicas_1_and_2_to_view_1(replicas: &mut [Replica<Recorder>]) {
    for _ in 0..10 {
        replicas[1].on_idle();
        replicas[2].on_idle();
        pump_until_idle(replicas, |dst, _| dst != 0, 20);
        if replicas[1].view_number() == 1
            && replicas[2].view_number() == 1
            && replicas[1].status() == Status::Normal
            && replicas[2].status() == Status::Normal
        {
            return;
        }
    }
    panic!("replicas 1 and 2 did not form view 1");
}

fn build_split_brain_prefix(config: &Config) -> Vec<Replica<Recorder>> {
    let mut replicas = new_replicas(config);

    replicas[0].on_message(Message::Request {
        client_id: 100,
        request_number: 0,
        op: Op::X,
    });
    pump_until_idle(&mut replicas, |_, _| false, 5);
    assert_eq!(0, replicas[0].commit_number());
    assert_eq!(1, replicas[0].op_number());
    println!("view 0 primary has uncommitted slot 1 op X");

    advance_replicas_1_and_2_to_view_1(&mut replicas);
    println!(
        "replicas 1 and 2 formed view {} with primary {}",
        replicas[1].view_number(),
        replicas[1].primary_id()
    );

    replicas[1].on_message(Message::Request {
        client_id: 200,
        request_number: 0,
        op: Op::Y,
    });
    pump_until_idle(&mut replicas, |dst, _| dst != 0, 20);
    let replies = take_replies(&mut replicas);
    assert_eq!(1, replies.len());
    assert_eq!(1, replies[0].view_number);
    assert_eq!("Y", replies[0].result);
    println!(
        "new-view client reply: view={} client={} request={} result={}",
        replies[0].view_number, replies[0].client_id, replies[0].request_number, replies[0].result
    );

    replicas[1].on_idle();
    pump_until_idle(&mut replicas, |dst, _| dst != 0, 20);
    assert_eq!(1, replicas[1].commit_number());
    assert_eq!(1, replicas[2].commit_number());
    assert_eq!(Op::Y, replicas[1].log()[0].op);
    assert_eq!(Op::Y, replicas[2].log()[0].op);
    println!("replica 2 has committed slot 1 op Y in view 1");

    replicas
}

fn run_bug_path(config: &Config) {
    let mut replicas = build_split_brain_prefix(config);

    let view_that_should_have_been_recovered = replicas[1].view_number();
    assert_eq!(1, view_that_should_have_been_recovered);

    replicas[1] = Replica::new(1, config.clone(), Recorder::default());
    println!(
        "malformed-view restart selected Replica::new: previous persisted view should be {}, restarted status {:?}, view {}",
        view_that_should_have_been_recovered,
        replicas[1].status(),
        replicas[1].view_number()
    );

    replicas[0].on_idle();
    pump_until_idle(&mut replicas, |dst, _| dst == 0 || dst == 1, 20);
    let replies = take_replies(&mut replicas);
    assert_eq!(1, replies.len());
    assert_eq!(0, replies[0].view_number);
    assert_eq!("X", replies[0].result);
    println!(
        "old-view client reply: view={} client={} request={} result={}",
        replies[0].view_number, replies[0].client_id, replies[0].request_number, replies[0].result
    );

    assert_eq!(1, replicas[0].commit_number());
    assert_eq!(1, replicas[2].commit_number());
    assert_eq!(Op::X, replicas[0].log()[0].op);
    assert_eq!(Op::Y, replicas[2].log()[0].op);
    assert_ne!(replicas[0].log()[0].op, replicas[2].log()[0].op);
    println!(
        "BUG TRIGGERED: committed slot 1 differs: replica0={:?}, replica2={:?}",
        replicas[0].log()[0].op,
        replicas[2].log()[0].op
    );
}

fn run_recover_control(config: &Config) {
    let mut replicas = build_split_brain_prefix(config);

    replicas[1] = Replica::recover(1, config.clone(), Recorder::default(), 1, 99);
    assert!(replicas[1].is_recovering());

    pump_until_idle(&mut replicas, |dst, _| dst == 0 || dst == 1, 20);
    replicas[0].on_idle();
    pump_until_idle(&mut replicas, |dst, _| dst == 0 || dst == 1, 20);
    let replies = take_replies(&mut replicas);
    assert!(
        replies.is_empty(),
        "recovering restart must not acknowledge the old view, but got {replies:?}"
    );
    println!(
        "control with Replica::recover(view=1): old view produced {} replies; replica0 status {:?}, view {}",
        replies.len(),
        replicas[0].status(),
        replicas[0].view_number()
    );
}

fn main() {
    let config = new_config();
    run_bug_path(&config);
    run_recover_control(&config);
    println!("CR-1 reproduction completed");
}
RS

timeout 5m env CARGO_TARGET_DIR="${BUILD_TARGET}/case-target" cargo run --manifest-path "${CASE_DIR}/Cargo.toml" --quiet
