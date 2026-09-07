#!/usr/bin/env bash
set -euo pipefail

WORKTREE="${VSR_RS_WORKTREE:-/home/ubuntu/specula-vsr-runner-20260905/runs/vsr-rs-gpt6astra-ultra-round3-guided-20260906/vsr-rs/.specula-output/confirmation/CR-3/worktree}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/src"
cat > "$TMPDIR/Cargo.toml" <<CARGO
[package]
name = "cr3_recovery_response_overwrite_repro"
version = "0.1.0"
edition = "2021"

[dependencies]
vsr-rs = { path = "$WORKTREE" }
CARGO

cat > "$TMPDIR/src/main.rs" <<'RUST'
use std::collections::{BTreeMap, VecDeque};
use vsr_rs::{Client, Config, LogEntry, Message, Replica, Reply, StateMachine, Status};

#[derive(Clone, Debug, PartialEq, Eq)]
enum Op {
    Put(String),
    Get,
}

#[derive(Default, Debug)]
struct Store {
    value: Option<String>,
}

impl StateMachine for Store {
    type Input = Op;
    type Output = Option<String>;

    fn apply(&mut self, op: Op) -> Option<String> {
        match op {
            Op::Put(value) => std::mem::replace(&mut self.value, Some(value)),
            Op::Get => self.value.clone(),
        }
    }
}

#[derive(Clone, Debug)]
enum Payload {
    Msg(Message<Op>),
    Reply(Reply<Option<String>>),
}

#[derive(Clone, Debug)]
struct Envelope {
    src: usize,
    dst: usize,
    payload: Payload,
}

impl Envelope {
    fn describe(&self) -> String {
        match &self.payload {
            Payload::Msg(Message::Request {
                client_id,
                request_number,
                op,
            }) => format!(
                "Request src={} dst={} client={} req={} op={:?}",
                self.src, self.dst, client_id, request_number, op
            ),
            Payload::Msg(Message::Prepare {
                view_number,
                op_number,
                commit_number,
                ..
            }) => format!(
                "Prepare src={} dst={} view={} op={} commit={}",
                self.src, self.dst, view_number, op_number, commit_number
            ),
            Payload::Msg(Message::PrepareOk {
                view_number,
                op_number,
                replica_id,
            }) => format!(
                "PrepareOk src={} dst={} view={} op={} replica={}",
                self.src, self.dst, view_number, op_number, replica_id
            ),
            Payload::Msg(Message::Commit {
                view_number,
                commit_number,
            }) => format!(
                "Commit src={} dst={} view={} commit={}",
                self.src, self.dst, view_number, commit_number
            ),
            Payload::Msg(Message::GetState {
                view_number,
                op_number,
                replica_id,
            }) => format!(
                "GetState src={} dst={} view={} op_start={} replica={}",
                self.src, self.dst, view_number, op_number, replica_id
            ),
            Payload::Msg(Message::NewState {
                view_number,
                op_number_start,
                op_number_end,
                commit_number,
                ..
            }) => format!(
                "NewState src={} dst={} view={} range={}..{} commit={}",
                self.src, self.dst, view_number, op_number_start, op_number_end, commit_number
            ),
            Payload::Msg(Message::StartViewChange {
                view_number,
                replica_id,
            }) => format!(
                "StartViewChange src={} dst={} view={} replica={}",
                self.src, self.dst, view_number, replica_id
            ),
            Payload::Msg(Message::DoViewChange {
                view_number,
                replica_id,
                last_normal_view,
                op_number,
                commit_number,
                ..
            }) => format!(
                "DoViewChange src={} dst={} view={} replica={} last_normal={} op={} commit={}",
                self.src, self.dst, view_number, replica_id, last_normal_view, op_number, commit_number
            ),
            Payload::Msg(Message::StartView {
                view_number,
                op_number,
                commit_number,
                ..
            }) => format!(
                "StartView src={} dst={} view={} op={} commit={}",
                self.src, self.dst, view_number, op_number, commit_number
            ),
            Payload::Msg(Message::Recovery {
                replica_id,
                nonce,
                view_number,
            }) => format!(
                "Recovery src={} dst={} replica={} nonce={} persisted_view={}",
                self.src, self.dst, replica_id, nonce, view_number
            ),
            Payload::Msg(Message::RecoveryResponse {
                view_number,
                nonce,
                replica_id,
                state,
            }) => format!(
                "RecoveryResponse src={} dst={} view={} nonce={} replica={} state={}",
                self.src,
                self.dst,
                view_number,
                nonce,
                replica_id,
                if let Some(state) = state {
                    format!("Some(log={}, commit={})", state.log.len(), state.commit_number)
                } else {
                    "None".to_string()
                }
            ),
            Payload::Reply(reply) => format!(
                "Reply src={} dst={} view={} client={} req={} result={:?}",
                self.src,
                self.dst,
                reply.view_number,
                reply.client_id,
                reply.request_number,
                reply.result
            ),
        }
    }
}

struct Cluster {
    config: Config,
    replicas: Vec<Option<Replica<Store>>>,
    durable_views: Vec<usize>,
    clients: BTreeMap<usize, Client<Op>>,
    queue: VecDeque<Envelope>,
    accepted: Vec<Reply<Option<String>>>,
}

impl Cluster {
    fn new() -> Self {
        let mut config = Config::new();
        for _ in 0..3 {
            config.add_replica();
        }
        let replicas = (0..3)
            .map(|id| Some(Replica::new(id, config.clone(), Store::default())))
            .collect();
        let clients = [100_usize, 101_usize]
            .into_iter()
            .map(|id| (id, Client::new(id, config.clone())))
            .collect();
        Self {
            config,
            replicas,
            durable_views: vec![0; 3],
            clients,
            queue: VecDeque::new(),
            accepted: Vec::new(),
        }
    }

    fn replica(&self, id: usize) -> &Replica<Store> {
        self.replicas[id].as_ref().expect("replica is down")
    }

    fn value(&self, id: usize) -> Option<String> {
        self.replica(id).state_machine().value.clone()
    }

    fn persist_view(&mut self, id: usize) {
        self.durable_views[id] = self.replica(id).view_number();
    }

    fn drain_replica(&mut self, id: usize) {
        let replica = self.replicas[id].as_mut().expect("replica is down");
        let messages: Vec<_> = replica.drain_messages().collect();
        let replies: Vec<_> = replica.drain_replies().collect();
        for (dst, msg) in messages {
            self.queue.push_back(Envelope {
                src: id,
                dst,
                payload: Payload::Msg(msg),
            });
        }
        for reply in replies {
            self.queue.push_back(Envelope {
                src: id,
                dst: reply.client_id,
                payload: Payload::Reply(reply),
            });
        }
    }

    fn drain_client(&mut self, id: usize) {
        let client = self.clients.get_mut(&id).expect("missing client");
        let messages: Vec<_> = client.drain().collect();
        for (dst, msg) in messages {
            self.queue.push_back(Envelope {
                src: id,
                dst,
                payload: Payload::Msg(msg),
            });
        }
    }

    fn request(&mut self, id: usize, op: Op) -> usize {
        let request_number = self
            .clients
            .get_mut(&id)
            .expect("missing client")
            .on_request(op);
        self.drain_client(id);
        request_number
    }

    fn client_idle(&mut self, id: usize) {
        self.clients.get_mut(&id).expect("missing client").on_idle();
        self.drain_client(id);
    }

    fn idle(&mut self, id: usize) {
        self.replicas[id]
            .as_mut()
            .expect("replica is down")
            .on_idle();
        self.persist_view(id);
        self.drain_replica(id);
    }

    fn crash(&mut self, id: usize) {
        self.replicas[id] = None;
        println!("crash replica {id}; durable_view={}", self.durable_views[id]);
    }

    fn recover(&mut self, id: usize, nonce: u64) {
        let persisted = self.durable_views[id];
        self.replicas[id] = Some(Replica::recover(
            id,
            self.config.clone(),
            Store::default(),
            persisted,
            nonce,
        ));
        self.persist_view(id);
        self.drain_replica(id);
        println!("recover replica {id}; nonce={nonce}; persisted_view={persisted}");
    }

    fn deliver_where(
        &mut self,
        label: &str,
        predicate: impl Fn(&Envelope) -> bool,
    ) -> Envelope {
        let idx = self
            .queue
            .iter()
            .position(predicate)
            .unwrap_or_else(|| panic!("missing message for {label}; queue={:#?}", self.queue));
        let env = self.queue.remove(idx).expect("message disappeared");
        println!("{label}: {}", env.describe());
        match env.payload.clone() {
            Payload::Msg(msg) => {
                if let Some(replica) = self.replicas[env.dst].as_mut() {
                    replica.on_message(msg);
                    self.persist_view(env.dst);
                    self.drain_replica(env.dst);
                } else {
                    println!("  dropped because replica {} is down", env.dst);
                }
            }
            Payload::Reply(reply) => {
                let accepted = self
                    .clients
                    .get_mut(&env.dst)
                    .expect("reply for unknown client")
                    .on_reply(reply.request_number, reply.view_number);
                println!("  client accepted reply: {accepted}");
                if accepted {
                    self.accepted.push(reply);
                }
            }
        }
        env
    }

    fn pump_all(&mut self, label: &str) {
        let mut delivered = 0;
        while !self.queue.is_empty() {
            self.deliver_where(label, |_| true);
            delivered += 1;
            assert!(delivered < 1000, "pump_all bound exceeded");
        }
    }
}

fn is_recovery(e: &Envelope, src: usize, dst: usize, nonce: u64) -> bool {
    matches!(
        &e.payload,
        Payload::Msg(Message::Recovery {
            replica_id,
            nonce: n,
            ..
        }) if e.src == src && e.dst == dst && *replica_id == src && *n == nonce
    )
}

fn is_recovery_response(
    e: &Envelope,
    src: usize,
    dst: usize,
    view: usize,
    state_some: bool,
) -> bool {
    matches!(
        &e.payload,
        Payload::Msg(Message::RecoveryResponse {
            view_number,
            replica_id,
            state,
            ..
        }) if e.src == src
            && e.dst == dst
            && *replica_id == src
            && *view_number == view
            && state.is_some() == state_some
    )
}

fn is_request(e: &Envelope, src: usize, dst: usize, client: usize, request: usize) -> bool {
    matches!(
        &e.payload,
        Payload::Msg(Message::Request {
            client_id,
            request_number,
            ..
        }) if e.src == src
            && e.dst == dst
            && *client_id == client
            && *request_number == request
    )
}

fn is_prepare(e: &Envelope, src: usize, dst: usize, view: usize, op: usize) -> bool {
    matches!(
        &e.payload,
        Payload::Msg(Message::Prepare {
            view_number,
            op_number,
            ..
        }) if e.src == src && e.dst == dst && *view_number == view && *op_number == op
    )
}

fn is_prepare_ok(e: &Envelope, src: usize, dst: usize, view: usize, op: usize) -> bool {
    matches!(
        &e.payload,
        Payload::Msg(Message::PrepareOk {
            view_number,
            op_number,
            replica_id,
        }) if e.src == src
            && e.dst == dst
            && *replica_id == src
            && *view_number == view
            && *op_number == op
    )
}

fn is_commit(e: &Envelope, src: usize, dst: usize, view: usize, commit: usize) -> bool {
    matches!(
        &e.payload,
        Payload::Msg(Message::Commit {
            view_number,
            commit_number,
        }) if e.src == src && e.dst == dst && *view_number == view && *commit_number == commit
    )
}

fn is_get_state(e: &Envelope, src: usize, dst: usize, view: usize, start: usize) -> bool {
    matches!(
        &e.payload,
        Payload::Msg(Message::GetState {
            view_number,
            op_number,
            replica_id,
        }) if e.src == src
            && e.dst == dst
            && *replica_id == src
            && *view_number == view
            && *op_number == start
    )
}

fn is_new_state(
    e: &Envelope,
    src: usize,
    dst: usize,
    view: usize,
    start: usize,
    end: usize,
    commit: usize,
) -> bool {
    matches!(
        &e.payload,
        Payload::Msg(Message::NewState {
            view_number,
            op_number_start,
            op_number_end,
            commit_number,
            ..
        }) if e.src == src
            && e.dst == dst
            && *view_number == view
            && *op_number_start == start
            && *op_number_end == end
            && *commit_number == commit
    )
}

fn is_start_view_change(e: &Envelope, src: usize, dst: usize, view: usize) -> bool {
    matches!(
        &e.payload,
        Payload::Msg(Message::StartViewChange {
            view_number,
            replica_id,
        }) if e.src == src && e.dst == dst && *replica_id == src && *view_number == view
    )
}

fn is_do_view_change(e: &Envelope, src: usize, dst: usize, view: usize) -> bool {
    matches!(
        &e.payload,
        Payload::Msg(Message::DoViewChange {
            view_number,
            replica_id,
            ..
        }) if e.src == src && e.dst == dst && *replica_id == src && *view_number == view
    )
}

fn is_start_view(e: &Envelope, src: usize, dst: usize, view: usize) -> bool {
    matches!(
        &e.payload,
        Payload::Msg(Message::StartView { view_number, .. })
            if e.src == src && e.dst == dst && *view_number == view
    )
}

fn is_reply(
    e: &Envelope,
    src: usize,
    dst: usize,
    view: usize,
    client: usize,
    request: usize,
    result: Option<&str>,
) -> bool {
    matches!(
        &e.payload,
        Payload::Reply(Reply {
            view_number,
            client_id,
            request_number,
            result: actual,
        }) if e.src == src
            && e.dst == dst
            && *view_number == view
            && *client_id == client
            && *request_number == request
            && actual.as_deref() == result
    )
}

fn committed_prefix(replica: &Replica<Store>) -> &[LogEntry<Op>] {
    &replica.log()[..replica.commit_number()]
}

fn main() {
    println!("LEVEL 0: public Replica/Client APIs, real messages, adversarial delivery order only");
    let mut c = Cluster::new();

    let put_a = c.request(100, Op::Put("A".to_string()));
    c.pump_all("initial put A");
    c.idle(0);
    c.pump_all("commit heartbeat for A");
    assert_eq!(put_a, 0);
    for id in 0..3 {
        assert_eq!(c.replica(id).commit_number(), 1);
        assert_eq!(c.value(id).as_deref(), Some("A"));
    }
    assert!(c
        .accepted
        .iter()
        .any(|r| r.client_id == 100 && r.request_number == 0 && r.result.is_none()));
    println!("baseline: view0 committed Put(A) on all replicas");

    c.crash(2);
    c.recover(2, 7);
    assert_eq!(c.replica(2).status(), Status::Recovering);

    c.deliver_where("old recovery reaches view0 primary r0", |e| {
        is_recovery(e, 2, 0, 7)
    });
    c.deliver_where("old recovery reaches view0 backup r1", |e| {
        is_recovery(e, 2, 1, 7)
    });
    println!("held in network: r0 view0 state response and r1 view0 non-state response");

    for _ in 0..5 {
        if c.replica(1).status() == Status::ViewChange {
            break;
        }
        c.idle(1);
    }
    assert_eq!(c.replica(1).status(), Status::ViewChange);
    c.deliver_where("r1 starts view1 by notifying r0", |e| {
        is_start_view_change(e, 1, 0, 1)
    });
    c.deliver_where("r0 joins view1 by notifying r1", |e| {
        is_start_view_change(e, 0, 1, 1)
    });
    c.deliver_where("r0 sends DoViewChange to new primary r1", |e| {
        is_do_view_change(e, 0, 1, 1)
    });
    c.deliver_where("r1 StartView installs view1 on r0", |e| {
        is_start_view(e, 1, 0, 1)
    });
    c.deliver_where("r0 acknowledges view1 start", |e| {
        is_prepare_ok(e, 0, 1, 1, 1)
    });
    assert_eq!(c.replica(0).status(), Status::Normal);
    assert_eq!(c.replica(1).status(), Status::Normal);
    assert_eq!(c.replica(0).view_number(), 1);
    assert_eq!(c.replica(1).view_number(), 1);
    println!("view change: r0 and r1 are normal in view1 while r2 is still recovering");

    let put_b = c.request(101, Op::Put("B".to_string()));
    c.deliver_where("client101 initial Put(B) reaches old primary r0 and is ignored", |e| {
        is_request(e, 101, 0, 101, put_b)
    });
    c.client_idle(101);
    c.deliver_where("client101 resend reaches new primary r1", |e| {
        is_request(e, 101, 1, 101, put_b)
    });
    c.deliver_where("r1 prepares Put(B) to r0", |e| {
        is_prepare(e, 1, 0, 1, 2)
    });
    c.deliver_where("r0 acknowledges Put(B)", |e| {
        is_prepare_ok(e, 0, 1, 1, 2)
    });
    c.deliver_where("client101 receives committed Put(B) reply", |e| {
        is_reply(e, 1, 101, 1, 101, put_b, Some("A"))
    });
    assert_eq!(c.replica(1).commit_number(), 2);
    assert_eq!(c.value(1).as_deref(), Some("B"));
    println!("view1 committed Put(B) at primary r1 before r2 processes old responses");

    c.idle(2);
    c.deliver_where("resent recovery reaches view1 primary r1", |e| {
        is_recovery(e, 2, 1, 7)
    });
    c.deliver_where("new r1 view1 state response reaches recovering r2 first", |e| {
        is_recovery_response(e, 1, 2, 1, true)
    });
    c.deliver_where("old r1 view0 non-state response arrives later and overwrites r1", |e| {
        is_recovery_response(e, 1, 2, 0, false)
    });
    c.deliver_where("old r0 view0 state response completes quorum", |e| {
        is_recovery_response(e, 0, 2, 0, true)
    });
    assert_eq!(c.replica(2).status(), Status::Normal);
    assert_eq!(c.replica(2).view_number(), 0);
    assert_eq!(c.replica(2).commit_number(), 1);
    assert_eq!(c.value(2).as_deref(), Some("A"));
    println!(
        "OBSERVED: r2 recovered into stale view0 commit1 after receiving r1's newer view1 commit2 response"
    );

    c.idle(1);
    c.deliver_where("mask: view1 Commit from primary reaches stale r2", |e| {
        is_commit(e, 1, 2, 1, 2)
    });
    assert_eq!(c.replica(2).status(), Status::ViewChange);
    assert_eq!(c.replica(2).view_number(), 1);
    c.deliver_where("mask: r2 asks r1 for suffix after committed prefix", |e| {
        is_get_state(e, 2, 1, 1, 1)
    });
    c.deliver_where("mask: r1 NewState restores committed Put(B)", |e| {
        is_new_state(e, 1, 2, 1, 1, 2, 2)
    });
    assert_eq!(c.replica(2).status(), Status::Normal);
    assert_eq!(c.replica(2).view_number(), 1);
    assert_eq!(c.replica(2).commit_number(), 2);
    assert_eq!(c.value(2).as_deref(), Some("B"));
    println!("MASK: higher-view Commit plus GetState/NewState catch-up repaired r2 to view1 commit2");

    let get_b = c.request(100, Op::Get);
    c.deliver_where("client100 initial Get reaches old primary r0 and is ignored", |e| {
        is_request(e, 100, 0, 100, get_b)
    });
    c.client_idle(100);
    c.deliver_where("client100 resend reaches current primary r1", |e| {
        is_request(e, 100, 1, 100, get_b)
    });
    c.deliver_where("r1 prepares Get to r0", |e| is_prepare(e, 1, 0, 1, 3));
    c.deliver_where("r1 prepares Get to r2", |e| is_prepare(e, 1, 2, 1, 3));
    c.deliver_where("r0 acknowledges Get", |e| is_prepare_ok(e, 0, 1, 1, 3));
    c.deliver_where("client100 receives Get result B", |e| {
        is_reply(e, 1, 100, 1, 100, get_b, Some("B"))
    });
    c.idle(1);
    c.deliver_where("final commit reaches r0", |e| is_commit(e, 1, 0, 1, 3));
    c.deliver_where("final commit reaches r2", |e| is_commit(e, 1, 2, 1, 3));

    let expected = committed_prefix(c.replica(1)).to_vec();
    for id in 0..3 {
        assert_eq!(c.replica(id).status(), Status::Normal);
        assert_eq!(c.replica(id).view_number(), 1);
        assert_eq!(c.replica(id).commit_number(), 3);
        assert_eq!(committed_prefix(c.replica(id)), expected.as_slice());
        assert_eq!(c.value(id).as_deref(), Some("B"));
    }
    assert!(c
        .accepted
        .iter()
        .any(|r| r.client_id == 100 && r.request_number == get_b && r.result.as_deref() == Some("B")));
    println!("RESULT: no client-visible inconsistency; final Get returned B and committed prefixes agree");
    println!("LEVEL 1: not needed for triggering; Level 0 already reached the overwrite and the mask deterministically");
    println!("LEVEL 2: not used; no state injection");
    println!("LEVEL 3: not used; no source patch");
}
RUST

timeout 5m cargo run --quiet --manifest-path "$TMPDIR/Cargo.toml"
