//! Controlled deliveries adapted from the existing `tests/cluster.rs` tests.
//! The Owner invokes the real Client and Replica APIs once per recorded event.

use super::*;
use serde_json::{json, Value};

/// Drain selected authentic queued messages, recording each delivery separately.
/// Callers explicitly exclude down destinations; held packets remain in network.
fn pump_matching(owner: &mut Owner, predicate: impl Fn(&Value) -> bool) {
    for _ in 0..256 {
        if !owner.messages().iter().any(&predicate) {
            return;
        }
        owner.deliver_where(|message| predicate(message));
    }
    panic!("scenario exceeded its bounded selective delivery budget");
}

fn assert_applied(owner: &Owner, nodes: &[usize], count: usize, sum: i64) {
    for &node in nodes {
        let state = owner.state(node);
        assert_eq!(state["status"], "Normal", "replica {node}");
        assert_eq!(state["commit"], json!(count), "replica {node}");
        assert_eq!(state["app"], json!(sum), "replica {node}");
        assert_eq!(state["applied"].as_array().unwrap().len(), count);
        assert_eq!(state["log"].as_array().unwrap().len(), count);
    }
}

/// Reuses test_duplicate_prepare_ok_is_not_a_quorum,
/// test_duplicate_request_executes_once, test_lost_request_resent_on_idle,
/// and test_prepare_resent_on_idle_when_prepare_lost.
#[test]
fn trace_normal_retry_duplicates() {
    let mut owner = Owner::new("normal_retry_duplicates", 4, 2);
    owner.client_idle(0); // Also capture the no-pending callback.
    owner.request(0, 1);
    owner.lose_where(|m| m["kind"] == "Request");
    assert_eq!(owner.state(0)["log"], json!([]));
    owner.client_idle(0);
    owner.duplicate_where(|m| m["kind"] == "Request" && m["dst"] == 0);
    owner.deliver("Request", json!("c0"), json!(0));
    owner.deliver("Request", json!("c0"), json!(0));
    assert_eq!(owner.state(0)["log"].as_array().unwrap().len(), 1);
    for node in 1..4 {
        owner.deliver("Request", json!("c0"), json!(node));
    }

    // With four members, self plus one backup is insufficient even when replayed.
    owner.deliver("Prepare", json!(0), json!(3));
    owner.duplicate_where(|m| m["kind"] == "PrepareOk" && m["src"] == 3);
    owner.deliver("PrepareOk", json!(3), json!(0));
    owner.deliver("PrepareOk", json!(3), json!(0));
    assert_eq!(owner.state(0)["commit"], 0);
    assert_eq!(owner.state(0)["app"], 0);
    owner.lose_where(|m| m["kind"] == "Prepare" && m["dst"] == 1);
    owner.lose_where(|m| m["kind"] == "Prepare" && m["dst"] == 2);
    owner.idle(0); // Real timer retries the uncommitted prepare.
    owner.pump(256);
    assert_eq!(owner.client_state(0)["pending"], json!([]));
    owner.idle(0);
    owner.pump(256);
    assert_applied(&owner, &[0, 1, 2, 3], 1, 1);

    // Replies share the fault network: lose one, retry, and replay its replacement.
    owner.request(1, 2);
    owner.deliver("Request", json!("c1"), json!(0));
    owner.deliver("Prepare", json!(0), json!(1));
    owner.deliver("Prepare", json!(0), json!(2));
    owner.deliver("PrepareOk", json!(1), json!(0));
    assert_eq!(owner.state(0)["commit"], 1);
    owner.deliver("PrepareOk", json!(2), json!(0));
    owner.lose_where(|m| m["kind"] == "Reply" && m["dst"] == "c1");
    assert_eq!(
        owner.client_state(1)["pending"].as_array().unwrap().len(),
        1
    );
    owner.client_idle(1);
    owner.deliver("Request", json!("c1"), json!(0));
    owner.duplicate_where(|m| m["kind"] == "Reply" && m["dst"] == "c1");
    owner.deliver("Reply", json!(0), json!("c1"));
    owner.deliver("Reply", json!(0), json!("c1"));
    owner.pump(256);
    owner.client_idle(0);
    owner.idle(0);
    owner.pump(256);
    assert_applied(&owner, &[0, 1, 2, 3], 2, 3);
    assert_eq!(owner.client_state(0)["pending"], json!([]));
    assert_eq!(owner.client_state(1)["pending"], json!([]));
    owner.finish();
}

/// Reuses test_prepare_reordered_during_state_transfer,
/// test_stale_new_state_during_state_transfer, and test_get_state_retried_on_idle.
/// One outstanding request per client is maintained throughout this adaptation.
#[test]
fn trace_state_transfer_reordering() {
    let mut owner = Owner::new("state_transfer_reordering", 3, 1);
    owner.request(0, 1);
    owner.pump(256);

    owner.request(0, 2);
    owner.deliver("Request", json!("c0"), json!(0));
    pump_matching(&mut owner, |m| {
        !(m["kind"] == "Prepare" && m["dst"] == 1 && m["opnum"] == 2)
    });
    assert_eq!(owner.state(1)["log"].as_array().unwrap().len(), 1);

    owner.request(0, 1);
    owner.deliver("Request", json!("c0"), json!(0));
    owner.deliver_where(|m| m["kind"] == "Prepare" && m["dst"] == 1 && m["opnum"] == 3);
    assert_eq!(owner.state(1)["status"], "StateTransfer");
    owner.deliver_where(|m| m["kind"] == "Prepare" && m["dst"] == 1 && m["opnum"] == 2);
    assert_eq!(owner.state(1)["log"].as_array().unwrap().len(), 1);
    owner.duplicate_where(|m| m["kind"] == "GetState" && m["src"] == 1);
    owner.deliver("GetState", json!(1), json!(0));
    owner.deliver("NewState", json!(0), json!(1));
    pump_matching(&mut owner, |m| m["kind"] != "GetState");
    owner.idle(0);
    pump_matching(&mut owner, |m| m["kind"] != "GetState");
    assert_applied(&owner, &[0, 1, 2], 3, 4);

    owner.request(0, 2);
    owner.deliver("Request", json!("c0"), json!(0));
    owner.lose_where(|m| m["kind"] == "Prepare" && m["dst"] == 1);
    pump_matching(&mut owner, |m| m["kind"] != "GetState");

    owner.request(0, 1);
    owner.deliver("Request", json!("c0"), json!(0));
    owner.deliver("Prepare", json!(0), json!(1));
    owner.lose_where(|m| m["kind"] == "GetState" && m["opnum"] == 3);
    assert_eq!(owner.state(1)["status"], "StateTransfer");
    owner.idle(1); // Retry is observable even though the old authentic request wins.
    assert!(owner
        .messages()
        .iter()
        .any(|m| m["kind"] == "GetState" && m["opnum"] == 3));
    owner.deliver_where(|m| m["kind"] == "GetState" && m["opnum"] == 1);
    assert!(owner
        .messages()
        .iter()
        .any(|m| { m["kind"] == "NewState" && m["start"] == 1 && m["opnum"] == 5 }));
    owner.deliver("NewState", json!(0), json!(1));
    assert_eq!(owner.state(1)["log"].as_array().unwrap().len(), 5);
    owner.pump(256);
    owner.idle(0);
    owner.pump(256);
    assert_applied(&owner, &[0, 1, 2], 5, 7);
    assert_eq!(owner.client_state(0)["pending"], json!([]));
    owner.finish();
}

/// Reuses test_view_change_after_primary_crash, with an actual owner destruction
/// and explicit retained packets; also delivers an old equal-view StartView.
#[test]
fn trace_view_change_after_crash() {
    let mut owner = Owner::new("view_change_after_crash", 3, 1);
    owner.request(0, 1);
    owner.pump(256);
    owner.idle(0);
    owner.pump(256);
    assert_applied(&owner, &[0, 1, 2], 1, 1);

    owner.request(0, 2);
    owner.deliver("Request", json!("c0"), json!(0));
    owner.deliver("Prepare", json!(0), json!(1));
    owner.deliver("Prepare", json!(0), json!(2));
    assert_eq!(owner.state(0)["commit"], 1);
    owner.crash(0); // The PrepareOk messages stay in the tracked network.
    for _ in 0..3 {
        owner.idle(1);
    }
    assert_eq!(owner.state(1)["status"], "ViewChange");
    owner.deliver("StartViewChange", json!(1), json!(2));
    owner.deliver("StartViewChange", json!(2), json!(1));
    owner.deliver("DoViewChange", json!(2), json!(1));
    owner.duplicate_where(|m| m["kind"] == "StartView" && m["dst"] == 2);
    owner.deliver("StartView", json!(1), json!(2));
    pump_matching(&mut owner, |m| {
        m["dst"] != 0 && !(m["kind"] == "StartView" && m["dst"] == 2)
    });
    assert_eq!(owner.state(1)["view"], 1);
    assert_eq!(owner.state(1)["commit"], 2);
    assert_eq!(owner.state(1)["app"], 3);
    assert_eq!(owner.client_state(0)["view"], 1);
    assert_eq!(owner.client_state(0)["pending"], json!([]));
    owner.idle(1);
    pump_matching(&mut owner, |m| {
        m["dst"] != 0 && !(m["kind"] == "StartView" && m["dst"] == 2)
    });
    assert_applied(&owner, &[1, 2], 2, 3);

    owner.request(0, 1); // The real client targets the primary learned from its reply.
    pump_matching(&mut owner, |m| {
        m["dst"] != 0 && !(m["kind"] == "StartView" && m["dst"] == 2)
    });
    assert_eq!(owner.state(2)["log"].as_array().unwrap().len(), 3);
    owner.deliver("StartView", json!(1), json!(2));
    assert_eq!(owner.state(2)["log"].as_array().unwrap().len(), 3);
    owner.idle(1);
    owner.pump(256);
    assert_applied(&owner, &[1, 2], 3, 4);
    assert_eq!(owner.client_state(0)["pending"], json!([]));
    assert!(owner.messages().iter().all(|m| m["dst"] == 0));
    owner.finish();
}

/// Reuses test_recovery_after_reboot. A retained authentic response from the
/// first recovery is delivered during the next recovery, with a fresh nonce.
#[test]
fn trace_recovery_stale_responses() {
    let mut owner = Owner::new("recovery_stale_responses", 3, 1);
    owner.request(0, 1);
    owner.pump(256);
    owner.idle(0);
    owner.pump(256);
    assert_applied(&owner, &[0, 1, 2], 1, 1);

    owner.crash(1);
    owner.recover(1, 101); // Canonical nonce 1 in replica 1's whole-trace mapping.
    owner.request(0, 2);
    pump_matching(&mut owner, |m| m["kind"] != "Recovery");
    assert_eq!(owner.state(1)["status"], "Recovering");
    assert_eq!(owner.state(1)["log"], json!([]));
    assert_eq!(owner.state(0)["app"], 3);

    owner.deliver("Recovery", json!(1), json!(0));
    owner.duplicate_where(|m| m["kind"] == "RecoveryResponse" && m["src"] == 0);
    owner.deliver("RecoveryResponse", json!(0), json!(1));
    assert_eq!(owner.state(1)["status"], "Recovering");
    owner.deliver("Recovery", json!(1), json!(2));
    owner.deliver("RecoveryResponse", json!(2), json!(1));
    assert_applied(&owner, &[1], 2, 3);

    owner.crash(1);
    owner.recover(1, 202); // Canonical nonce 2; never relabel the retained response.
    owner.deliver_where(|m| m["kind"] == "RecoveryResponse" && m["nonce"] == 1);
    assert_eq!(owner.state(1)["status"], "Recovering");
    assert_eq!(owner.state(1)["responses"], json!([]));
    assert_eq!(owner.state(1)["app"], 0);
    owner.idle(1); // Recovering timer retries the real constructor's request.
    owner.lose_where(|m| m["kind"] == "Recovery" && m["dst"] == 0 && m["nonce"] == 2);
    owner.deliver("Recovery", json!(1), json!(2));
    owner.deliver("Recovery", json!(1), json!(2));
    owner.deliver("RecoveryResponse", json!(2), json!(1));
    owner.duplicate_where(|m| m["kind"] == "RecoveryResponse" && m["src"] == 2);
    owner.deliver("RecoveryResponse", json!(2), json!(1));
    owner.deliver("RecoveryResponse", json!(2), json!(1));
    assert_eq!(owner.state(1)["status"], "Recovering");
    assert_eq!(owner.state(1)["responses"].as_array().unwrap().len(), 1);
    owner.deliver("Recovery", json!(1), json!(0));
    owner.deliver("RecoveryResponse", json!(0), json!(1));
    assert_applied(&owner, &[1], 2, 3);
    owner.pump(256);

    owner.request(0, 1);
    owner.pump(256);
    owner.idle(0);
    owner.pump(256);
    assert_applied(&owner, &[0, 1, 2], 3, 4);
    assert_eq!(owner.client_state(0)["pending"], json!([]));
    owner.finish();
}
