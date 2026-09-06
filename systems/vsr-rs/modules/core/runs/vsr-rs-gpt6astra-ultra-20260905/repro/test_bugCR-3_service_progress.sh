#!/usr/bin/env bash
set -euo pipefail

SRC="/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-20260905/vsr-rs/.specula-output/confirmation/CR-3/worktree"
TMP="$(mktemp -d)"
cleanup() {
    rm -rf "$TMP"
}
trap cleanup EXIT

REPO="$TMP/vsr-rs"
mkdir -p "$REPO"
git -C "$SRC" archive HEAD | tar -x -C "$REPO"
mkdir -p "$REPO/tests"
mkdir -p "$REPO/simulator/tests"

cat > "$REPO/tests/cr3_service_progress.rs" <<'RS'
use std::collections::VecDeque;
use vsr_rs::{Client, Config, Message, Replica, ReplicaID, Reply, RequestNumber, StateMachine, Status};

#[derive(Clone, Debug)]
enum Op {
    Add(i32),
}

#[derive(Default, Debug)]
struct Accumulator {
    value: i32,
}

impl StateMachine for Accumulator {
    type Input = Op;
    type Output = i32;

    fn apply(&mut self, op: Op) -> i32 {
        match op {
            Op::Add(value) => {
                self.value += value;
                self.value
            }
        }
    }
}

struct Cluster {
    config: Config,
    replicas: Vec<Replica<Accumulator>>,
    client: Client<Op>,
    queue: VecDeque<(ReplicaID, Message<Op>)>,
    all_replies: Vec<Reply<i32>>,
    completed_replies: Vec<Reply<i32>>,
}

impl Cluster {
    fn new(replica_count: usize, primary_timeout: usize) -> Self {
        let mut config = Config::new();
        for _ in 0..replica_count {
            config.add_replica();
        }
        config.set_primary_timeout(primary_timeout);
        let replicas = (0..replica_count)
            .map(|id| Replica::new(id, config.clone(), Accumulator::default()))
            .collect();
        Self {
            config: config.clone(),
            replicas,
            client: Client::new(0, config),
            queue: VecDeque::new(),
            all_replies: Vec::new(),
            completed_replies: Vec::new(),
        }
    }

    fn request(&mut self, op: Op) -> RequestNumber {
        self.client.on_request(op)
    }

    fn collect(&mut self) {
        for replica in &mut self.replicas {
            self.queue.extend(replica.drain_messages());
            for reply in replica.drain_replies() {
                if self
                    .client
                    .on_reply(reply.request_number, reply.view_number)
                {
                    self.completed_replies.push(reply.clone());
                }
                self.all_replies.push(reply);
            }
        }
        self.queue.extend(self.client.drain());
    }

    fn tick_with<F>(&mut self, mut deliver: F)
    where
        F: FnMut(ReplicaID, &Message<Op>) -> bool,
    {
        for _ in 0..1000 {
            self.collect();
            if self.queue.is_empty() {
                return;
            }
            for (replica_id, message) in std::mem::take(&mut self.queue) {
                if deliver(replica_id, &message) {
                    self.replicas[replica_id].on_message(message);
                }
            }
        }
        panic!("message delivery did not quiesce");
    }

    fn tick(&mut self) {
        self.tick_with(|_, _| true);
    }

    fn idle_all(&mut self) {
        for replica in &mut self.replicas {
            replica.on_idle();
        }
        self.client.on_idle();
    }

    fn step_one_tick(&mut self) -> bool {
        self.idle_all();
        self.collect();
        for (replica_id, message) in std::mem::take(&mut self.queue) {
            self.replicas[replica_id].on_message(message);
        }
        self.collect();
        !self.queue.is_empty()
    }

    fn run_stable_ticks(&mut self, limit: usize) {
        for _ in 0..limit {
            self.idle_all();
            self.tick();
        }
    }

    fn value(&self, replica_id: ReplicaID) -> i32 {
        self.replicas[replica_id].state_machine().value
    }

    fn has_completed(&self, request_number: RequestNumber) -> bool {
        self.completed_replies
            .iter()
            .any(|reply| reply.request_number == request_number)
    }

    fn normal_same_view(&self) -> bool {
        let view = self.replicas[0].view_number();
        self.replicas
            .iter()
            .all(|replica| replica.status() == Status::Normal && replica.view_number() == view)
    }
}

#[test]
fn level0_client_request_and_recovery_complete_after_stabilization() {
    let mut cluster = Cluster::new(3, 3);

    let baseline = cluster.request(Op::Add(10));
    cluster.tick();
    cluster.run_stable_ticks(2);
    assert!(cluster.has_completed(baseline));
    for id in 0..3 {
        assert_eq!(cluster.value(id), 10);
        assert_eq!(cluster.replicas[id].commit_number(), 1);
    }

    let persisted_view = cluster.replicas[1].view_number();
    cluster.replicas[1] = Replica::recover(
        1,
        cluster.config.clone(),
        Accumulator::default(),
        persisted_view,
        42,
    );

    let mut dropped_recovery = 0;
    cluster.tick_with(|_, message| {
        if matches!(message, Message::Recovery { .. }) {
            dropped_recovery += 1;
            false
        } else {
            true
        }
    });
    assert_eq!(dropped_recovery, 2);
    assert!(cluster.replicas[1].is_recovering());

    let later = cluster.request(Op::Add(20));
    cluster.run_stable_ticks(20);

    assert!(cluster.has_completed(later));
    assert!(!cluster.replicas[1].is_recovering());
    for id in 0..3 {
        assert_eq!(cluster.value(id), 30);
        assert_eq!(cluster.replicas[id].commit_number(), 2);
    }
    println!("LEVEL 0 PASS: public Client/Replica APIs completed a pending request and reboot recovery after transient Recovery loss");
}

#[test]
fn level1_persisted_future_view_recovery_does_not_deadlock() {
    let mut cluster = Cluster::new(3, 2);

    let baseline = cluster.request(Op::Add(1));
    cluster.tick();
    cluster.run_stable_ticks(2);
    assert!(cluster.has_completed(baseline));

    for _ in 0..3 {
        cluster.replicas[1].on_idle();
    }
    assert_eq!(cluster.replicas[1].view_number(), 1);
    assert_eq!(cluster.replicas[1].status(), Status::ViewChange);

    let persisted_view = cluster.replicas[1].view_number();
    cluster.replicas[1] = Replica::recover(
        1,
        cluster.config.clone(),
        Accumulator::default(),
        persisted_view,
        77,
    );

    let mut recovered = false;
    for _ in 0..200 {
        cluster.idle_all();
        cluster.tick();
        if !cluster.replicas[1].is_recovering() && cluster.normal_same_view() {
            recovered = true;
            break;
        }
    }
    assert!(recovered, "replica with persisted future view did not recover");
    assert!(cluster.replicas[1].view_number() >= persisted_view);

    let after_recovery = cluster.request(Op::Add(2));
    cluster.run_stable_ticks(20);
    assert!(cluster.has_completed(after_recovery));
    for id in 0..3 {
        assert_eq!(cluster.value(id), 3);
        assert_eq!(cluster.replicas[id].commit_number(), 2);
    }
    println!("LEVEL 1 PASS: timing-assisted future-view recovery advanced through view change and completed a later request");
}

#[test]
fn level1_synchronized_idle_delivery_schedule_settles() {
    let mut cluster = Cluster::new(3, 2);
    let baseline = cluster.request(Op::Add(10));
    cluster.tick();
    cluster.run_stable_ticks(2);
    assert!(cluster.has_completed(baseline));

    for _ in 0..3 {
        cluster.replicas[2].on_idle();
    }
    assert_eq!(cluster.replicas[2].status(), Status::ViewChange);

    let mut quiet = 0;
    for _ in 0..500 {
        let busy = cluster.step_one_tick();
        if !busy && cluster.normal_same_view() {
            quiet += 1;
            if quiet == 10 {
                break;
            }
        } else {
            quiet = 0;
        }
    }
    let views: Vec<_> = cluster
        .replicas
        .iter()
        .map(|replica| replica.view_number())
        .collect();
    assert_eq!(
        quiet, 10,
        "synchronized idle/delivery schedule did not settle; views={views:?}"
    );
    println!("LEVEL 1 PASS: synchronized one-tick idle/delivery schedule settled instead of livelocking");
}
RS

cat > "$REPO/simulator/tests/cr3_simulator_progress.rs" <<'RS'
use rand::SeedableRng;
use rand_chacha::ChaCha8Rng;
use vsr_rs::Status;
use vsr_simulator::{parse_script, Limits, NetworkOptions, Options, Simulator};

#[test]
fn simulator_liveness_replies_and_converges_after_reboot_and_partition() {
    let mut option_prng = ChaCha8Rng::seed_from_u64(7008082073273156606);
    let mut options = Options::lite(&mut option_prng);
    options.network = NetworkOptions::perfect();
    options.replica_crash_probability = 0.0;
    options.request_probability = 1.0;
    options.request_idle_on_probability = 0.0;
    options.request_idle_off_probability = 1.0;
    options.requests_max = 200;
    options.primary_timeout = 3;
    options.full_core = true;

    let script = parse_script(
        "20 crash 0\n\
         40 restart 0\n\
         60 crash 1\n\
         61 reboot 1\n\
         80 partition 2\n\
         120 heal-all\n",
    )
    .unwrap();

    let mut simulator = Simulator::init(7008082073273156606, options).unwrap();
    simulator
        .run_script(
            &script,
            Limits {
                ticks_max_requests: 50_000,
                ticks_max_convergence: 50_000,
            },
        )
        .unwrap();

    let snapshot = simulator.snapshot();
    assert_eq!(snapshot.requests_sent, snapshot.requests_max);
    assert_eq!(snapshot.requests_replied, snapshot.requests_max);
    assert_eq!(snapshot.reboots, 1);
    assert!(snapshot.replicas.iter().all(|replica| replica.up));
    assert!(snapshot.replicas.iter().all(|replica| !replica.partitioned));
    assert!(snapshot
        .replicas
        .iter()
        .all(|replica| replica.status == Status::Normal));
    let first = &snapshot.replicas[0];
    assert!(snapshot.replicas.iter().all(|replica| {
        replica.view_number == first.view_number
            && replica.op_number == first.op_number
            && replica.commit_number == first.commit_number
            && replica.value == first.value
    }));
    println!(
        "SIMULATOR PASS: requests={}/{} reboots={} final_view={} final_commit={} value={}",
        snapshot.requests_replied,
        snapshot.requests_max,
        snapshot.reboots,
        first.view_number,
        first.commit_number,
        first.value
    );
}
RS

echo "CR-3 reproduction test"
echo "source_commit=$(git -C "$SRC" rev-parse HEAD)"
echo "test_repo=$REPO"
echo "LEVEL 0: pure public Client/Replica APIs with transient message loss and stable timing"
echo "LEVEL 1: public APIs with adversarial timing schedules for future-view recovery and synchronized delivery"
echo "LEVEL 2: not used; the relevant recovery preconditions are produced through public API sequences in the tests"
echo "LEVEL 3: not used; no source patch was needed or applied"

cargo test --manifest-path "$REPO/Cargo.toml" --test cr3_service_progress -- --nocapture --test-threads=1
cargo test --manifest-path "$REPO/simulator/Cargo.toml" --test cr3_simulator_progress -- --nocapture --test-threads=1

echo "CR-3 result: no service/recovery progress failure was observed by the CR-3 reproducer"
