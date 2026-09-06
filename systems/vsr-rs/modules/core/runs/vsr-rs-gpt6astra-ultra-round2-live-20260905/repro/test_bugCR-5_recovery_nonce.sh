#!/usr/bin/env bash
set -euo pipefail

WORKTREE="${WORKTREE:-/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round2-live-20260905/vsr-rs/.specula-output/confirmation/CR-5/worktree}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "CR-5 recovery nonce confirmation"
echo "worktree=$WORKTREE"
echo "source_head=$(git -C "$WORKTREE" rev-parse HEAD)"

git -C "$WORKTREE" archive --format=tar HEAD | tar -x -C "$TMPDIR"
cd "$TMPDIR"
mkdir -p tests

cat > tests/cr5_recovery_nonce.rs <<'RS'
use std::collections::VecDeque;
use vsr_rs::{Client, Config, Message, Replica, ReplicaID, Reply, StateMachine, Status};

#[derive(Clone, Debug, PartialEq, Eq)]
enum Op {
    Add(i32),
}

#[derive(Default)]
struct Accumulator {
    value: i32,
}

impl StateMachine for Accumulator {
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

fn config3() -> Config {
    let mut config = Config::new();
    for _ in 0..3 {
        config.add_replica();
    }
    config
}

fn drive_network(
    replicas: &mut [Replica<Accumulator>],
    client: &mut Client<Op>,
    down: Option<ReplicaID>,
) -> Vec<Reply<i32>> {
    let mut queue = VecDeque::new();
    let mut replies = Vec::new();
    loop {
        for (id, replica) in replicas.iter_mut().enumerate() {
            if Some(id) == down {
                continue;
            }
            queue.extend(replica.drain_messages());
            for reply in replica.drain_replies() {
                client.on_reply(reply.request_number, reply.view_number);
                replies.push(reply);
            }
        }
        queue.extend(client.drain());
        if queue.is_empty() {
            break;
        }
        for (dst, message) in std::mem::take(&mut queue) {
            if Some(dst) != down {
                replicas[dst].on_message(message);
            }
        }
    }
    replies
}

fn submit_and_settle(
    replicas: &mut [Replica<Accumulator>],
    client: &mut Client<Op>,
    op: Op,
    down: Option<ReplicaID>,
) -> Vec<Reply<i32>> {
    client.on_request(op);
    let mut replies = drive_network(replicas, client, down);
    for (id, replica) in replicas.iter_mut().enumerate() {
        if Some(id) != down {
            replica.on_idle();
        }
    }
    replies.extend(drive_network(replicas, client, down));
    replies
}

fn capture_recovery_responses(
    replicas: &mut [Replica<Accumulator>],
    recovering: ReplicaID,
) -> Vec<Message<Op>> {
    let recovery_requests: Vec<_> = replicas[recovering].drain_messages().collect();
    assert_eq!(
        recovery_requests.len(),
        2,
        "recovering replica should ask the two other replicas"
    );
    for (dst, message) in recovery_requests {
        assert_ne!(dst, recovering);
        assert!(matches!(message, Message::Recovery { .. }));
        replicas[dst].on_message(message);
    }

    let mut responses = Vec::new();
    for (id, replica) in replicas.iter_mut().enumerate() {
        if id == recovering {
            continue;
        }
        for (dst, message) in replica.drain_messages() {
            if dst == recovering {
                assert!(matches!(message, Message::RecoveryResponse { .. }));
                responses.push(message);
            }
        }
    }
    assert_eq!(responses.len(), 2, "quorum of recovery responses captured");
    responses
}

fn deliver_current_commit_and_state_transfer(
    replicas: &mut [Replica<Accumulator>],
    recovering: ReplicaID,
) {
    replicas[0].on_idle();
    let primary_messages: Vec<_> = replicas[0].drain_messages().collect();
    let commit_to_recovering = primary_messages
        .into_iter()
        .find(|(dst, message)| {
            *dst == recovering
                && matches!(
                    message,
                    Message::Commit {
                        view_number: 0,
                        commit_number: 2
                    }
                )
        })
        .expect("primary should heartbeat the current commit number to replica 1");

    println!("mask: delivering current Commit(view=0, commit=2) to stale backup");
    replicas[recovering].on_message(commit_to_recovering.1);
    assert_eq!(replicas[recovering].status(), Status::StateTransfer);

    let get_state = replicas[recovering]
        .drain_messages()
        .find(|(dst, message)| {
            *dst == 0
                && matches!(
                    message,
                    Message::GetState {
                        replica_id: 1,
                        view_number: 0,
                        op_number: 1
                    }
                )
        })
        .expect("stale backup should ask the primary for the missing suffix");

    println!("mask: stale backup requested GetState(op_number=1)");
    replicas[0].on_message(get_state.1);

    let new_state = replicas[0]
        .drain_messages()
        .find(|(dst, message)| {
            *dst == recovering
                && matches!(
                    message,
                    Message::NewState {
                        view_number: 0,
                        op_number_start: 1,
                        op_number_end: 2,
                        commit_number: 2,
                        ..
                    }
                )
        })
        .expect("primary should return the missing committed suffix");

    println!("mask: delivering NewState(start=1,end=2,commit=2)");
    replicas[recovering].on_message(new_state.1);
}

#[test]
fn stale_same_nonce_recovery_response_is_accepted_but_caught_up() {
    println!("Level 0: use normal public Replica/Client APIs and message delivery.");
    let config = config3();
    let mut replicas: Vec<_> = (0..3)
        .map(|id| Replica::new(id, config.clone(), Accumulator::default()))
        .collect();
    let mut client = Client::new(0, config.clone());

    let replies = submit_and_settle(&mut replicas, &mut client, Op::Add(10), None);
    assert!(replies.iter().any(|reply| reply.result == 10));
    assert_eq!(replicas[0].state_machine().value, 10);
    assert_eq!(replicas[1].state_machine().value, 10);
    assert_eq!(replicas[2].state_machine().value, 10);
    println!("initial cluster committed Add(10) on all replicas");

    let repeated_nonce = 4242;
    replicas[1] = Replica::recover(1, config.clone(), Accumulator::default(), 0, repeated_nonce);
    let stale_responses = capture_recovery_responses(&mut replicas, 1);
    println!(
        "captured {} stale RecoveryResponse messages for nonce {} before second crash",
        stale_responses.len(),
        repeated_nonce
    );

    let replies = submit_and_settle(&mut replicas, &mut client, Op::Add(20), Some(1));
    assert!(replies.iter().any(|reply| reply.result == 30));
    assert_eq!(replicas[0].commit_number(), 2);
    assert_eq!(replicas[0].state_machine().value, 30);
    assert_eq!(replicas[2].op_number(), 2);
    println!("while replica 1 is down, replicas 0 and 2 commit Add(20)");

    let mut fresh_probe =
        Replica::recover(1, config.clone(), Accumulator::default(), 0, repeated_nonce + 1);
    let _: Vec<_> = fresh_probe.drain_messages().collect();
    for message in stale_responses.clone() {
        fresh_probe.on_message(message);
    }
    assert!(fresh_probe.is_recovering());
    assert_eq!(fresh_probe.op_number(), 0);
    println!("fresh nonce control: stale responses are rejected and recovery continues");

    println!("Level 1: delayed-message ordering already models the timing window; no source changes.");
    println!("Level 2: instantiate the reachable same-nonce precondition and replay real peer responses.");
    replicas[1] = Replica::recover(1, config.clone(), Accumulator::default(), 0, repeated_nonce);
    let dropped_current_requests: Vec<_> = replicas[1].drain_messages().collect();
    assert_eq!(dropped_current_requests.len(), 2);
    for message in stale_responses {
        replicas[1].on_message(message);
    }

    assert_eq!(replicas[1].status(), Status::Normal);
    assert!(!replicas[1].is_recovering());
    assert_eq!(replicas[1].op_number(), 1);
    assert_eq!(replicas[1].commit_number(), 1);
    assert_eq!(replicas[1].state_machine().value, 10);
    println!(
        "same nonce fault: replica 1 left recovery with stale value={}, op_number={}, commit_number={}",
        replicas[1].state_machine().value,
        replicas[1].op_number(),
        replicas[1].commit_number()
    );

    deliver_current_commit_and_state_transfer(&mut replicas, 1);

    assert_eq!(replicas[1].status(), Status::Normal);
    assert_eq!(replicas[1].op_number(), 2);
    assert_eq!(replicas[1].commit_number(), 2);
    assert_eq!(replicas[1].state_machine().value, 30);
    println!(
        "after mask: replica 1 caught up to value={}, op_number={}, commit_number={}",
        replicas[1].state_machine().value,
        replicas[1].op_number(),
        replicas[1].commit_number()
    );
    println!("Level 3: not needed; Level 2 already proves the stale-response path and the mask.");
}
RS

echo "command=timeout 5m cargo test --test cr5_recovery_nonce -- --nocapture"
timeout 5m cargo test --test cr5_recovery_nonce -- --nocapture
