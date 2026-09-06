//! Deterministic public-API observations of revision
//! 3ac0104a567092139534c9022205d02281a2da41. No simulator or random seed.
//! Assertions describe current defects; turn them into expected-correctness
//! regressions when implementing a fix. Source dependency is unmodified.
use vsr_rs::{Config, Message, Replica, StateMachine, Status};

#[derive(Default)]
struct Counter(i64);
impl StateMachine for Counter {
    type Input = i64;
    type Output = i64;
    fn apply(&mut self, op: i64) -> i64 { self.0 += op; self.0 }
}
fn config(n: usize) -> Config {
    let mut c = Config::new();
    for _ in 0..n { c.add_replica(); }
    c
}
fn request(client_id: usize, op: i64) -> Message<i64> {
    Message::Request { client_id, request_number: 0, op }
}
fn deliver_all(rs: &mut [Replica<Counter>]) {
    for _ in 0..100 {
        let q: Vec<_> = rs.iter_mut().flat_map(|r| r.drain_messages()).collect();
        if q.is_empty() { return; }
        for (to, msg) in q { rs[to].on_message(msg); }
    }
    panic!("delivery did not quiesce");
}
#[test]
fn singleton_accepts_request_but_never_commits_in_fault_free_idle_loop() {
    let c = config(1);
    assert_eq!(c.quorum(), 1);
    let mut r = Replica::new(0, c, Counter::default());
    r.on_message(request(10, 7));
    for _ in 0..1000 {
        r.on_idle();
        r.on_message(request(10, 7));
        assert_eq!(r.drain_messages().count(), 0);
        assert_eq!(r.drain_replies().count(), 0);
    }
    assert_eq!((r.op_number(), r.commit_number(), r.state_machine().0), (1, 0, 0));
    println!("LIB-SINGLE: n=1, quorum=1, 1000 idle/retry rounds, op=1, commit=0, replies=0");
}
#[test]
fn reusing_new_after_old_primary_crash_commits_conflicting_slot() {
    let c = config(3);
    let mut rs: Vec<_> = (0..3).map(|id| Replica::new(id, c.clone(), Counter::default())).collect();
    rs[0].on_message(request(10, 7));
    deliver_all(&mut rs);
    let old_reply: Vec<_> = rs[0].drain_replies().collect();
    assert_eq!(old_reply[0].result, 7);
    rs[0].on_idle();
    deliver_all(&mut rs);
    assert!(rs.iter().all(|r| r.commit_number() == 1));
    // Exactly the constructor selected by kvstore lines 687-699 after
    // an existing view file fails to parse. Other replicas remain alive.
    rs[0] = Replica::new(0, c, Counter::default());
    rs[0].on_message(request(11, 9));
    deliver_all(&mut rs);
    let new_reply: Vec<_> = rs[0].drain_replies().collect();
    assert_eq!(new_reply[0].result, 9);
    assert_eq!(rs[0].commit_number(), 1);
    assert_eq!(rs[1].commit_number(), 1);
    assert_ne!(rs[0].log()[0], rs[1].log()[0]);
    println!("EX-START: two replies at slot 1, old op=7, restarted primary op=9; peer committed op=7; all view=0");
}
#[test]
fn recover_control_does_not_accept_client_request_as_fresh_primary() {
    let mut r = Replica::recover(0, config(3), Counter::default(), 0, 42);
    r.on_message(request(11, 9));
    assert_eq!(r.status(), Status::Recovering);
    assert_eq!(r.op_number(), 0);
    assert_eq!(r.drain_replies().count(), 0);
    println!("EX-START control: recover(0) ignores client request until valid recovery quorum");
}
