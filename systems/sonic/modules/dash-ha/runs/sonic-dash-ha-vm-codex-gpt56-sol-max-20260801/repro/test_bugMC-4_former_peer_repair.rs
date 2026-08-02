//! MC-4 reproduction: a valid old-peer HA state message is transport-delayed
//! across a normal HA-set re-pair and then accepted as state for the new peer.
//!
//! This file is compiled as a child of the existing `npu_driven` test module,
//! so it uses the repository's real ActorRuntime, SWBus clients, message types,
//! state machine, and STATE_DB bridge.

use super::*;
use swbus_actor::ActorMessage;
use swbus_edge::simple_client::{IncomingMessage, MessageBody, OutgoingMessage, SimpleSwbusEdgeClient};
use swbus_edge::swbus_proto::swbus::{ServicePath, SwbusErrorCode};

async fn receive_with_timeout(client: &SimpleSwbusEdgeClient) -> IncomingMessage {
    tokio::time::timeout(Duration::from_secs(5), client.recv())
        .await
        .expect("timed out waiting for SWBus message")
        .expect("SWBus client closed")
}

async fn receive_request_and_ack(client: &SimpleSwbusEdgeClient, actor_sp: &ServicePath) -> ActorMessage {
    let incoming = receive_with_timeout(client).await;
    let request_id = incoming.id;
    let MessageBody::Request { payload } = incoming.body else {
        panic!("expected actor request, got {:?}", incoming.body);
    };
    let actor_message = ActorMessage::deserialize(&payload).expect("invalid ActorMessage from actor");
    client
        .send(OutgoingMessage {
            destination: actor_sp.clone(),
            body: MessageBody::Response {
                request_id,
                error_code: SwbusErrorCode::Ok,
                error_message: String::new(),
                response_body: None,
            },
        })
        .await
        .expect("failed to acknowledge actor request");
    actor_message
}

#[tokio::test]
async fn test_bugmc_4_former_peer_message_contaminates_repair() {
    sonic_common::log::init_logger_for_test();
    let _redis = Redis::start_config_db();
    test::setup_remote_dpu_in_db(1, 0);
    test::setup_remote_dpu_in_db(3, 0);
    let runtime = test::create_actor_runtime(18, "10.0.18.0", "10:0:18::").await;
    test::setup_mock_swbusd_resolve_peer_sp(&runtime.get_swbus_edge());

    let (ha_set_id, ha_set_obj) = make_dpu_scope_ha_set_obj(18, 0);
    let dpu_mon = make_dpu_pmon_state(true);
    let bfd_state = make_dpu_bfd_state(Vec::new(), Vec::new());
    let local_dpu = make_local_dpu_actor_state(0, 0, true, Some(dpu_mon), Some(bfd_state));
    let old_dpu = make_remote_dpu_actor_state(1, 0);
    let new_dpu = make_remote_dpu_actor_state(3, 0);
    let (local_vdpu_id, local_vdpu_state) = make_vdpu_actor_state(true, &local_dpu);
    let (old_vdpu_id, _) = make_vdpu_actor_state(true, &old_dpu);
    let (new_vdpu_id, _) = make_vdpu_actor_state(true, &new_dpu);

    let scope_id = format!("{local_vdpu_id}:{ha_set_id}");
    let scope_id_in_state = format!("{local_vdpu_id}|{ha_set_id}");
    let old_peer_scope_id = format!("{old_vdpu_id}:{ha_set_id}");
    let new_peer_scope_id = format!("{new_vdpu_id}:{ha_set_id}");
    let actor_sp = runtime.sp(HaScopeActor::name(), &scope_id);
    let old_peer_sp = runtime.sp(HaScopeActor::name(), &old_peer_scope_id);
    let new_peer_sp = runtime.sp(HaScopeActor::name(), &new_peer_scope_id);

    let actor = HaScopeActor::new(scope_id.clone()).unwrap();
    let actor_handle = runtime.spawn(actor, HaScopeActor::name(), &scope_id);

    // Level 0: only normal config/state operations. Establish the old pairing
    // and leave the actor in Connecting, then perform an orderly re-pair.
    #[rustfmt::skip]
    let commands = [
        send! { key: HaScopeConfig::table_name(), data: { "key": &scope_id, "operation": "Set",
                "field_values": {"json": format!(r#"{{"version":"1","disabled":false,"desired_ha_state":{},"owner":{},"ha_set_id":"{ha_set_id}","approved_pending_operation_ids":[]}}"#, DesiredHaState::Active as i32, HaOwner::Switch as i32)},
                },
                addr: crate::common_bridge_sp::<HaScopeConfig>(&runtime.get_swbus_edge()) },
        recv! { key: ActorRegistration::msg_key(RegistrationType::VDPUState, &scope_id), data: { "active": true }, addr: runtime.sp(VDpuActor::name(), &local_vdpu_id) },
        recv! { key: ActorRegistration::msg_key(RegistrationType::HaSetState, &scope_id), data: { "active": true }, addr: runtime.sp(HaSetActor::name(), &ha_set_id) },
        recv! { key: HaScopeActorState::msg_key(&scope_id), data: { "owner": HaOwner::Switch as i32, "new_state": HaState::Unspecified.as_str_name(), "term": "0", "vdpu_id": &local_vdpu_id, "peer_vdpu_id": "" }, addr: runtime.sp(HaSetActor::name(), &ha_set_id), exclude: "timestamp" },
        send! { key: VDpuActorState::msg_key(&local_vdpu_id), data: local_vdpu_state, addr: runtime.sp(VDpuActor::name(), &local_vdpu_id) },
        send! { key: HaSetActorState::msg_key(&ha_set_id), data: { "up": true, "ha_set": &ha_set_obj, "vdpu_ids": vec![local_vdpu_id.clone(), old_vdpu_id.clone()], "pinned_vdpu_bfd_probe_states": vec!["".to_string()] }, addr: runtime.sp(HaSetActor::name(), &ha_set_id) },
        recv! { key: PeerHeartbeat::msg_key(&scope_id), data: { "dst_actor_id": &old_peer_scope_id }, addr: old_peer_sp.clone() },
        recv! { key: HaScopeActorState::msg_key(&scope_id), data: { "owner": HaOwner::Switch as i32, "new_state": HaState::Connecting.as_str_name(), "term": "0", "vdpu_id": &local_vdpu_id, "peer_vdpu_id": &old_vdpu_id }, addr: old_peer_sp.clone(), exclude: "timestamp" },
        recv! { key: HaScopeActorState::msg_key(&scope_id), data: { "owner": HaOwner::Switch as i32, "new_state": HaState::Connecting.as_str_name(), "term": "0", "vdpu_id": &local_vdpu_id, "peer_vdpu_id": &old_vdpu_id }, addr: runtime.sp(HaSetActor::name(), &ha_set_id), exclude: "timestamp" },
    ];
    test::run_commands(&runtime, actor_sp.clone(), &commands).await;

    // Level 1 timing assistance: the old peer creates a completely normal
    // protocol message and places its serialized SWBus envelope in a transport
    // queue before re-pair. The test controls only when that queue is released.
    let old_peer_client = SimpleSwbusEdgeClient::new(runtime.get_swbus_edge(), old_peer_sp.clone(), true, false);
    let stale_state = HaScopeActorState::new_actor_msg(
        &old_peer_scope_id,
        HaOwner::Switch as i32,
        HaState::InitializingToStandby.as_str_name(),
        111,
        "41",
        &old_vdpu_id,
        &local_vdpu_id,
        "standby",
    )
    .unwrap();
    let (stale_request_id, stale_wire_message) = old_peer_client.outgoing_message_to_swbus_message(OutgoingMessage {
        destination: actor_sp.clone(),
        body: MessageBody::Request {
            payload: stale_state.serialize(),
        },
    });
    let (transport_tx, mut transport_rx) = tokio::sync::mpsc::channel(1);
    transport_tx.send(stale_wire_message).await.unwrap();
    println!(
        "LEVEL 1 STAGED: request_id={stale_request_id} source={old_peer_scope_id} state={} term=41 before re-pair",
        HaState::InitializingToStandby.as_str_name()
    );

    #[rustfmt::skip]
    let repair = [
        send! { key: HaSetActorState::msg_key(&ha_set_id), data: { "up": true, "ha_set": &ha_set_obj, "vdpu_ids": vec![local_vdpu_id.clone(), new_vdpu_id.clone()], "pinned_vdpu_bfd_probe_states": vec!["".to_string()] }, addr: runtime.sp(HaSetActor::name(), &ha_set_id) },
    ];
    test::run_commands(&runtime, actor_sp.clone(), &repair).await;

    let db = crate::db_for_table::<NpuDashHaScopeState>().await.unwrap();
    let table = Table::new(db, NpuDashHaScopeState::table_name()).unwrap();
    let before_delivery: NpuDashHaScopeState = swss_serde::from_table(&table, &scope_id_in_state).unwrap();
    assert_eq!(
        before_delivery.local_ha_state.as_deref(),
        Some(HaState::Connecting.as_str_name())
    );
    assert_eq!(before_delivery.peer_ha_state, None);
    println!(
        "LEVEL 0 RESULT: orderly re-pair selected new_peer={new_peer_scope_id}; local_state={} and no peer state was applied",
        before_delivery.local_ha_state.as_deref().unwrap()
    );

    // Register the real new-peer endpoint, then release the old peer's already
    // queued envelope. No actor state or private handler is called directly.
    let new_peer_client = SimpleSwbusEdgeClient::new(runtime.get_swbus_edge(), new_peer_sp, true, false);
    let delayed = transport_rx.recv().await.unwrap();
    old_peer_client.send_raw(delayed).await.unwrap();
    println!("LEVEL 1 RELEASED: old request delivered only after current peer became {new_peer_scope_id}");

    let old_response = receive_with_timeout(&old_peer_client).await;
    match old_response.body {
        MessageBody::Response {
            request_id,
            error_code: SwbusErrorCode::Ok,
            ..
        } => assert_eq!(request_id, stale_request_id),
        other => panic!("old peer message was not accepted: {other:?}"),
    }

    // The state machine is a real consumer: the foreign message changes local
    // state to Connected and queues a VoteRequest to the newly configured peer.
    let mut vote_request = None;
    let mut connected_broadcast = None;
    for _ in 0..2 {
        let message = receive_request_and_ack(&new_peer_client, &actor_sp).await;
        if VoteRequest::is_my_msg(&message.key) {
            vote_request = Some(message.deserialize_data::<VoteRequest>().unwrap());
        } else if HaScopeActorState::is_my_msg(&message.key) {
            connected_broadcast = Some(message.deserialize_data::<HaScopeActorState>().unwrap());
        } else {
            panic!("unexpected new-peer output {}", message.key);
        }
    }

    let vote_request = vote_request.expect("foreign message did not drive a VoteRequest");
    let connected_broadcast = connected_broadcast.expect("foreign message did not drive Connected broadcast");
    assert_eq!(vote_request.dst_actor_id, new_peer_scope_id);
    assert_eq!(connected_broadcast.new_state, HaState::Connected.as_str_name());
    assert_eq!(connected_broadcast.peer_vdpu_id, new_vdpu_id);

    let after_delivery: NpuDashHaScopeState = swss_serde::from_table(&table, &scope_id_in_state).unwrap();
    assert_eq!(
        after_delivery.local_ha_state.as_deref(),
        Some(HaState::Connected.as_str_name())
    );
    assert_eq!(
        after_delivery.peer_ha_state.as_deref(),
        Some(HaState::InitializingToStandby.as_str_name())
    );
    assert_eq!(after_delivery.peer_term.as_deref(), Some("41"));
    assert_eq!(after_delivery.peer_acked_asic_ha_state.as_deref(), Some("standby"));

    println!(
        "BUG TRIGGERED: former_peer={old_peer_scope_id} supplied peer_state={} peer_term={} peer_acked_role={}; current_peer={new_peer_scope_id} was advertised Connected and received VoteRequest",
        after_delivery.peer_ha_state.as_deref().unwrap(),
        after_delivery.peer_term.as_deref().unwrap(),
        after_delivery.peer_acked_asic_ha_state.as_deref().unwrap(),
    );
    println!(
        "OBSERVED CONSUMER: NpuHaScopeActor::next_state persisted local_state={} in STATE_DB and send_vote_request_to_peer targeted {}",
        after_delivery.local_ha_state.as_deref().unwrap(),
        vote_request.dst_actor_id
    );

    actor_handle.abort();
}

