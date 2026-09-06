//! Controlled schedules adapted from the real `tests/cluster.rs` regressions.
//! Each scenario calls the library through the owner/transport controller;
//! selected/replayed packets are immutable outputs of actual library calls.

use crate::controller::Cluster;
use serde_json::Value;
use vsr_rs::tla_trace::Input;

fn packet(message: &Value, kind: &str, dst: usize) -> bool {
    message["wire"]["kind"] == kind && message["dst"].as_u64() == Some(dst as u64)
}

fn from(message: &Value, src: usize) -> bool {
    message["src"].as_u64() == Some(src as u64)
}

fn op(message: &Value, slot: usize) -> bool {
    message["wire"]["opn"].as_u64() == Some(slot as u64)
}

fn released(cluster: &Cluster, predicate: impl Fn(&Value) -> bool) -> Value {
    cluster.snapshot()["released"]
        .as_array()
        .unwrap()
        .iter()
        .rev()
        .find(|message| predicate(message))
        .expect("the schedule must select a packet actually released by the library")
        .clone()
}

fn messages(cluster: &mut Cluster, predicate: impl Fn(&Value) -> bool) {
    let mut delivered = 0;
    while cluster.deliver_where(|message| predicate(message)) {
        delivered += 1;
        assert!(delivered < 1000, "unexpected unbounded message cascade");
    }
}

fn replies(cluster: &mut Cluster) {
    while cluster.deliver_reply_where(|_| true) {}
}

fn idle(cluster: &mut Cluster, node: usize) {
    cluster.idle(node);
    cluster.persist(node);
    cluster.release_all(node);
}

fn heartbeat(cluster: &mut Cluster, primary: usize) {
    idle(cluster, primary);
    cluster.settle();
}

fn reply(cluster: &Cluster, client: usize, request: usize, result: usize) {
    assert!(cluster.snapshot()["acceptedReplies"]
        .as_array()
        .unwrap()
        .iter()
        .any(|message| packet(message, "Reply", client)
            && message["wire"]["request"].as_u64() == Some(request as u64)
            && message["wire"]["result"].as_u64() == Some(result as u64)));
}

fn all_applied(cluster: &Cluster, value: usize, results: &[usize]) {
    for replica in cluster.snapshot()["replicas"].as_array().unwrap() {
        assert_eq!(replica["status"], "Normal");
        assert_eq!(replica["app"].as_u64(), Some(value as u64));
        assert_eq!(replica["commit"].as_u64(), Some(results.len() as u64));
        assert_eq!(replica["applied"].as_array().unwrap().len(), results.len());
        assert_eq!(replica["results"], serde_json::json!(results));
    }
}

/// Extends lost-request and duplicate-request regressions with the independent
/// reply channel, order-sensitive Get/Put results, and client lifetime changes.
#[test]
fn trace_requests_replies_and_lifetimes() {
    let mut cluster = Cluster::new("requests_replies_and_lifetimes", &[3, 4, 5]);
    cluster.request(3, Input::Put(1));
    cluster.client_drain(3);
    let request = released(&cluster, |message| packet(message, "Request", 0));
    assert!(cluster.lose_where(|message| message == &request));

    cluster.client_idle(3);
    cluster.client_drain(3);
    assert!(cluster.deliver_where(|message| packet(message, "Request", 0)));
    cluster.replay_message(&request);
    assert!(cluster.deliver_where(|message| message == &request));
    messages(&mut cluster, |_| true);
    let old_reply = released(&cluster, |message| packet(message, "Reply", 3));
    assert!(cluster.lose_reply_where(|message| message == &old_reply));

    // The retry after commit must resend the cached old register value.
    cluster.client_idle(3);
    cluster.settle();
    reply(&cluster, 3, 0, 0);
    cluster.replay_reply(&old_reply);
    assert!(cluster.deliver_reply_where(|message| message == &old_reply));

    cluster.request(3, Input::Get);
    cluster.replay_reply(&old_reply);
    assert!(cluster.deliver_reply_where(|message| message == &old_reply));
    let state = cluster.snapshot();
    assert_eq!(state["clients"].as_array().unwrap().iter()
        .find(|row| row["id"] == 3).unwrap()["state"]["pending"]
        .as_array().unwrap().len(), 1);
    cluster.settle();
    reply(&cluster, 3, 1, 1);

    cluster.request(4, Input::Put(2));
    cluster.settle();
    reply(&cluster, 4, 0, 1);
    cluster.retire(3);
    cluster.request(5, Input::Get);
    cluster.settle();
    reply(&cluster, 5, 0, 2);
    heartbeat(&mut cluster, 0);
    all_applied(&cluster, 2, &[0, 1, 1, 2]);
}

/// Adapts reordered-Prepare and stale-NewState regressions. Concurrent requests
/// belong to distinct clients, preserving the one-outstanding-request contract.
#[test]
fn trace_reordered_state_transfer() {
    let mut cluster = Cluster::new("reordered_state_transfer", &[3, 4, 5]);
    for (client, input) in [(3, Input::Put(1)), (4, Input::Put(2)), (5, Input::Get)] {
        cluster.request(client, input);
        cluster.client_drain(client);
        assert!(cluster.deliver_where(|message| packet(message, "Request", 0) && from(message, client)));
    }

    assert!(cluster.deliver_where(|message| packet(message, "Prepare", 1) && op(message, 3)));
    let old_get_state = released(&cluster, |message| packet(message, "GetState", 0) && from(message, 1));
    // The earlier Prepare arrives while transfer is active. It must not append.
    assert!(cluster.deliver_where(|message| packet(message, "Prepare", 1) && op(message, 1)));
    assert!(cluster.lose_where(|message| packet(message, "Prepare", 1) && op(message, 2)));
    messages(&mut cluster, |message| !packet(message, "NewState", 1));
    assert_eq!(cluster.snapshot()["replicas"][1]["log"].as_array().unwrap().len(), 0);
    assert!(cluster.deliver_where(|message| packet(message, "NewState", 1)));
    cluster.settle();
    heartbeat(&mut cluster, 0);
    all_applied(&cluster, 2, &[0, 1, 2]);

    for (client, input) in [(3, Input::Put(0)), (4, Input::Put(1))] {
        cluster.request(client, input);
        cluster.client_drain(client);
        assert!(cluster.deliver_where(|message| packet(message, "Request", 0) && from(message, client)));
    }
    assert!(cluster.lose_where(|message| packet(message, "Prepare", 1) && op(message, 4)));
    assert!(cluster.deliver_where(|message| packet(message, "Prepare", 1) && op(message, 5)));
    assert!(cluster.lose_where(|message| packet(message, "GetState", 0) && from(message, 1)));
    messages(&mut cluster, |_| true);
    replies(&mut cluster);
    assert_eq!(cluster.snapshot()["replicas"][1]["log"].as_array().unwrap().len(), 3);

    // This authentic old request asks from offset 0, while the recipient now
    // needs offset 3. The real primary constructs the overlapping suffix reply.
    cluster.replay_message(&old_get_state);
    assert!(cluster.deliver_where(|message| message == &old_get_state));
    assert!(cluster.deliver_where(|message| packet(message, "NewState", 1)));
    cluster.settle();
    heartbeat(&mut cluster, 0);
    all_applied(&cluster, 1, &[0, 1, 2, 2, 0]);
    reply(&cluster, 3, 1, 2);
    reply(&cluster, 4, 1, 0);
}

/// Adapts the primary-loss regression using a retained pause. The old primary
/// resumes through the public handlers and catches up before its StartView.
#[test]
fn trace_view_change_and_retained_resume() {
    let mut cluster = Cluster::new("view_change_and_retained_resume", &[3, 4]);
    cluster.request(3, Input::Put(1));
    cluster.settle();
    heartbeat(&mut cluster, 0);

    cluster.request(4, Input::Put(2));
    cluster.client_drain(4);
    assert!(cluster.deliver_where(|message| packet(message, "Request", 0)));
    messages(&mut cluster, |message| message["wire"]["kind"] != "PrepareOk");
    assert_eq!(cluster.snapshot()["replicas"][0]["commit"], 1);
    cluster.pause(0);
    for _ in 0..4 {
        idle(&mut cluster, 1);
        idle(&mut cluster, 2);
        // Hold the view-change packets until both backup timers have expired.
    }
    assert_eq!(cluster.snapshot()["replicas"][1]["status"], "ViewChange");
    idle(&mut cluster, 1); // Exercise the real view-change retransmission arm.
    cluster.settle();
    assert_eq!(cluster.snapshot()["replicas"][1]["view"], 1);
    assert_eq!(cluster.snapshot()["replicas"][1]["app"], 2);
    reply(&cluster, 4, 0, 1);

    cluster.request(4, Input::Get);
    cluster.settle();
    reply(&cluster, 4, 1, 2);
    cluster.resume(0);
    idle(&mut cluster, 1);
    // Deliver the latest heartbeat ahead of delayed StartView and old acks.
    assert!(cluster.deliver_where(|message| packet(message, "Commit", 0) && message["wire"]["view"] == 1));
    assert!(cluster.deliver_where(|message| packet(message, "GetState", 1) && from(message, 0)));
    assert!(cluster.deliver_where(|message| packet(message, "NewState", 0)));
    cluster.settle();
    heartbeat(&mut cluster, 1);
    all_applied(&cluster, 2, &[0, 1, 2]);
}

/// Extends reboot recovery with a crash before persistence/publication, retry,
/// old-incarnation acknowledgements, and a stale authentic recovery response.
#[test]
fn trace_recovery_epochs_and_reconstruction() {
    let mut cluster = Cluster::new("recovery_epochs_and_reconstruction", &[3, 4]);
    cluster.request(3, Input::Put(1));
    cluster.settle();
    cluster.request(3, Input::Put(2));
    cluster.settle();
    heartbeat(&mut cluster, 0);
    let old_ack = released(&cluster, |message| packet(message, "PrepareOk", 0) && from(message, 1));

    cluster.crash(1);
    cluster.recover(1);
    // The first constructor's Recovery broadcasts remain volatile and never
    // reach transport; a second constructor must select a new raw nonce.
    cluster.crash(1);
    cluster.recover(1);
    cluster.persist(1);
    cluster.release_all(1);
    while cluster.lose_where(|message| message["wire"]["kind"] == "Recovery" && from(message, 1)) {}

    cluster.request(4, Input::Get);
    cluster.client_drain(4);
    messages(&mut cluster, |_| true);
    replies(&mut cluster);
    assert_eq!(cluster.snapshot()["replicas"][1]["status"], "Recovering");
    assert_eq!(cluster.snapshot()["replicas"][1]["app"], 0);
    reply(&cluster, 4, 0, 2);

    idle(&mut cluster, 1);
    cluster.settle();
    heartbeat(&mut cluster, 0);
    all_applied(&cluster, 2, &[0, 1, 2]);
    assert_eq!(cluster.snapshot()["incarnations"][1], 2);
    cluster.replay_message(&old_ack);
    assert!(cluster.deliver_where(|message| message == &old_ack));
    let old_response = released(&cluster, |message| packet(message, "RecoveryResponse", 1));

    cluster.crash(1);
    cluster.recover(1);
    cluster.persist(1);
    cluster.release_all(1);
    cluster.replay_message(&old_response);
    assert!(cluster.deliver_where(|message| message == &old_response));
    assert_eq!(cluster.snapshot()["replicas"][1]["responses"].as_array().unwrap().len(), 0);
    assert_eq!(cluster.snapshot()["replicas"][1]["status"], "Recovering");
    cluster.settle();
    heartbeat(&mut cluster, 0);
    all_applied(&cluster, 2, &[0, 1, 2]);
    assert_eq!(cluster.snapshot()["incarnations"][1], 3);
    let snapshot = cluster.snapshot();
    let histories = snapshot["applications"].as_array().unwrap();
    for (incarnation, count) in [(0, 2), (1, 0), (2, 3), (3, 3)] {
        let history = histories.iter().find(|row| row["replica"] == 1 && row["incarnation"] == incarnation).unwrap();
        assert_eq!(history["entries"].as_array().unwrap().len(), count);
    }
}
