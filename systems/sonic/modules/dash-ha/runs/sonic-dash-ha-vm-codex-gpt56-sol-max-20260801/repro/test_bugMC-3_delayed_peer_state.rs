use super::*;
use swbus_edge::simple_client::{IncomingMessage, MessageBody, OutgoingMessage, SimpleSwbusEdgeClient};
use swbus_edge::swbus_proto::swbus::SwbusErrorCode;
use swss_common_bridge::producer::ProducerBridge;

const WAIT_LIMIT: Duration = Duration::from_secs(5);

async fn wait_for_npu_terms(
    table: &Table,
    key: &str,
    peer_term: &str,
    local_target_term: &str,
    peer_timestamp: i64,
) -> NpuDashHaScopeState {
    let deadline = tokio::time::Instant::now() + WAIT_LIMIT;

    loop {
        let last = match swss_serde::from_table::<NpuDashHaScopeState>(table, key) {
            Ok(state) => {
                let matches = state.peer_term.as_deref() == Some(peer_term)
                    && state.local_target_term.as_deref() == Some(local_target_term)
                    && state.peer_ha_state_last_updated_time_in_ms == Some(peer_timestamp);
                if matches {
                    return state;
                }
                format!(
                    "peer_term={:?}, local_target_term={:?}, peer_timestamp={:?}",
                    state.peer_term, state.local_target_term, state.peer_ha_state_last_updated_time_in_ms
                )
            }
            Err(error) => format!("read error: {error:#}"),
        };

        assert!(tokio::time::Instant::now() < deadline, "timed out waiting for NPU state: {last}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

async fn wait_for_pending_operation(table: &Table, key: &str) -> String {
    let deadline = tokio::time::Instant::now() + WAIT_LIMIT;

    loop {
        if let Ok(state) = swss_serde::from_table::<NpuDashHaScopeState>(table, key) {
            if let Some(operation_id) = state.pending_operation_ids.and_then(|ids| ids.into_iter().next()) {
                return operation_id;
            }
        }

        assert!(
            tokio::time::Instant::now() < deadline,
            "timed out waiting for the reachable standby-activation operation"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

async fn wait_for_response(
    client: &SimpleSwbusEdgeClient,
    expected_request_id: u64,
    drop_request_id: Option<u64>,
) -> bool {
    let deadline = tokio::time::Instant::now() + WAIT_LIMIT;
    let mut dropped = false;

    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        assert!(!remaining.is_zero(), "timed out waiting for response to request {expected_request_id}");
        let message = tokio::time::timeout(remaining, client.recv())
            .await
            .expect("timed out receiving SWBus response")
            .expect("SWBus client closed while waiting for response");

        match message {
            IncomingMessage {
                body:
                    MessageBody::Response {
                        request_id,
                        error_code,
                        error_message,
                        ..
                    },
                ..
            } if Some(request_id) == drop_request_id => {
                assert_eq!(error_code, SwbusErrorCode::Ok, "old request failed: {error_message}");
                dropped = true;
                println!("LEVEL 1 FAULT: dropped_ack_for_old_request_id={request_id}");
            }
            IncomingMessage {
                body:
                    MessageBody::Response {
                        request_id,
                        error_code,
                        error_message,
                        ..
                    },
                ..
            } if request_id == expected_request_id => {
                assert_eq!(error_code, SwbusErrorCode::Ok, "request failed: {error_message}");
                return dropped;
            }
            IncomingMessage {
                id,
                source,
                body: MessageBody::Request { .. },
                ..
            } => {
                client
                    .send(OutgoingMessage {
                        destination: source,
                        body: MessageBody::Response {
                            request_id: id,
                            error_code: SwbusErrorCode::Ok,
                            error_message: String::new(),
                            response_body: None,
                        },
                    })
                    .await
                    .expect("acking incidental peer request");
            }
            other => panic!("unexpected SWBus message while waiting for response: {other:#?}"),
        }
    }
}

#[tokio::test]
async fn delayed_old_peer_state_regresses_term_and_reaches_dpu() {
    sonic_common::log::init_logger_for_test();
    let _redis = Redis::start_config_db();
    test::setup_remote_dpu_in_db(1, 0);
    let runtime = test::create_actor_runtime(4, "10.0.4.0", "10:0:4::").await;
    test::setup_mock_swbusd_resolve_peer_sp(&runtime.get_swbus_edge());

    let (ha_set_id, ha_set_obj) = make_dpu_scope_ha_set_obj(4, 0);
    let dpu_mon = make_dpu_pmon_state(true);
    let bfd_state = make_dpu_bfd_state(Vec::new(), Vec::new());
    let dpu0 = make_local_dpu_actor_state(0, 0, true, Some(dpu_mon), Some(bfd_state));
    let dpu1 = make_remote_dpu_actor_state(1, 0);
    let (vdpu0_id, vdpu0_state_obj) = make_vdpu_actor_state(true, &dpu0);
    let (vdpu1_id, _vdpu1_state_obj) = make_vdpu_actor_state(true, &dpu1);

    let scope_id = format!("{vdpu0_id}:{ha_set_id}");
    let scope_id_in_state = format!("{vdpu0_id}|{ha_set_id}");
    let peer_scope_id = format!("{vdpu1_id}:{ha_set_id}");
    let destination = runtime.sp(HaScopeActor::name(), &scope_id);

    let ha_scope_actor = HaScopeActor::new(scope_id.clone()).unwrap();
    let _actor_handle = runtime.spawn(ha_scope_actor, HaScopeActor::name(), &scope_id);

    // Reach Standby through the same configuration, registration, election, bulk-sync, and
    // approval interfaces used by hamgrd's normal NPU-driven test.
    #[rustfmt::skip]
    let commands = [
        send! { key: HaScopeConfig::table_name(), data: { "key": &scope_id, "operation": "Set",
                "field_values": {"json": format!(r#"{{"version":"1","disabled":false,"desired_ha_state":{},"owner":{},"ha_set_id":"{ha_set_id}","approved_pending_operation_ids":[]}}"#, DesiredHaState::Unspecified as i32, HaOwner::Switch as i32)},
                },
                addr: crate::common_bridge_sp::<HaScopeConfig>(&runtime.get_swbus_edge()) },

        recv! { key: ActorRegistration::msg_key(RegistrationType::VDPUState, &scope_id), data: { "active": true }, addr: runtime.sp(VDpuActor::name(), &vdpu0_id) },
        recv! { key: ActorRegistration::msg_key(RegistrationType::HaSetState, &scope_id), data: { "active": true }, addr: runtime.sp(HaSetActor::name(), &ha_set_id) },
        recv! { key: HaScopeActorState::msg_key(&scope_id), data: { "owner": HaOwner::Switch as i32, "new_state": HaState::Unspecified.as_str_name(), "term": "0", "vdpu_id": &vdpu0_id, "peer_vdpu_id": "" }, addr: runtime.sp(HaSetActor::name(), &ha_set_id), exclude: "timestamp" },

        send! { key: VDpuActorState::msg_key(&vdpu0_id), data: vdpu0_state_obj, addr: runtime.sp(VDpuActor::name(), &vdpu0_id) },
        send! { key: HaSetActorState::msg_key(&ha_set_id), data: { "up": true, "ha_set": &ha_set_obj, "vdpu_ids": vec![vdpu0_id.clone(), vdpu1_id.clone()], "pinned_vdpu_bfd_probe_states": vec!["".to_string()] }, addr: runtime.sp(HaSetActor::name(), &ha_set_id) },

        recv! { key: PeerHeartbeat::msg_key(&scope_id), data: { "dst_actor_id": &peer_scope_id }, addr: runtime.sp(HaScopeActor::name(), &peer_scope_id) },
        recv! { key: HaScopeActorState::msg_key(&scope_id), data: { "owner": HaOwner::Switch as i32, "new_state": HaState::Connecting.as_str_name(), "term": "0", "vdpu_id": &vdpu0_id, "peer_vdpu_id": &vdpu1_id }, addr: runtime.sp(HaScopeActor::name(), &peer_scope_id), exclude: "timestamp" },
        recv! { key: HaScopeActorState::msg_key(&scope_id), data: { "owner": HaOwner::Switch as i32, "new_state": HaState::Connecting.as_str_name(), "term": "0", "vdpu_id": &vdpu0_id, "peer_vdpu_id": &vdpu1_id }, addr: runtime.sp(HaSetActor::name(), &ha_set_id), exclude: "timestamp" },

        send! { key: HaScopeActorState::msg_key(&peer_scope_id), data: { "timestamp": 0, "owner": HaOwner::Switch as i32, "new_state": HaState::Dead.as_str_name(), "term": "0", "vdpu_id": &vdpu1_id, "peer_vdpu_id": &vdpu0_id } },
        recv! { key: VoteRequest::msg_key(&scope_id), data: { "dst_actor_id": &peer_scope_id, "term": "0", "state": HaState::Connecting.as_str_name(), "desired_state": DesiredHaState::Unspecified.as_str_name() }, addr: runtime.sp(HaScopeActor::name(), &peer_scope_id) },
        recv! { key: HaScopeActorState::msg_key(&scope_id), data: { "owner": HaOwner::Switch as i32, "new_state": HaState::Connected.as_str_name(), "term": "0", "vdpu_id": &vdpu0_id, "peer_vdpu_id": &vdpu1_id }, addr: runtime.sp(HaScopeActor::name(), &peer_scope_id), exclude: "timestamp" },
        recv! { key: HaScopeActorState::msg_key(&scope_id), data: { "owner": HaOwner::Switch as i32, "new_state": HaState::Connected.as_str_name(), "term": "0", "vdpu_id": &vdpu0_id, "peer_vdpu_id": &vdpu1_id }, addr: runtime.sp(HaSetActor::name(), &ha_set_id), exclude: "timestamp" },

        send! { key: VoteReply::msg_key(&peer_scope_id), data: { "dst_actor_id": &scope_id, "response": "BecomeStandby" } },
        recv! { key: &ha_set_id, data: { "key": &ha_set_id, "operation": "Set", "field_values": { "version": "1", "ha_role": "standby", "ha_term": "0", "ha_set_id": &ha_set_id } }, addr: crate::common_bridge_sp::<DashHaScopeTable>(&runtime.get_swbus_edge()) },
        recv! { key: HaScopeActorState::msg_key(&scope_id), data: { "owner": HaOwner::Switch as i32, "new_state": HaState::InitializingToStandby.as_str_name(), "term": "0", "vdpu_id": &vdpu0_id, "peer_vdpu_id": &vdpu1_id }, addr: runtime.sp(HaScopeActor::name(), &peer_scope_id), exclude: "timestamp" },
        recv! { key: HaScopeActorState::msg_key(&scope_id), data: { "owner": HaOwner::Switch as i32, "new_state": HaState::InitializingToStandby.as_str_name(), "term": "0", "vdpu_id": &vdpu0_id, "peer_vdpu_id": &vdpu1_id }, addr: runtime.sp(HaSetActor::name(), &ha_set_id), exclude: "timestamp" },

        send! { key: BulkSyncUpdate::msg_key(&peer_scope_id), data: { "dst_actor_id": &scope_id, "finished": true }},
        recv! { key: HaScopeActorState::msg_key(&scope_id), data: { "owner": HaOwner::Switch as i32, "new_state": HaState::PendingStandbyActivation.as_str_name(), "term": "0", "vdpu_id": &vdpu0_id, "peer_vdpu_id": &vdpu1_id }, addr: runtime.sp(HaScopeActor::name(), &peer_scope_id), exclude: "timestamp" },
        recv! { key: HaScopeActorState::msg_key(&scope_id), data: { "owner": HaOwner::Switch as i32, "new_state": HaState::PendingStandbyActivation.as_str_name(), "term": "0", "vdpu_id": &vdpu0_id, "peer_vdpu_id": &vdpu1_id }, addr: runtime.sp(HaSetActor::name(), &ha_set_id), exclude: "timestamp" },
        send! { key: HaScopeActorState::msg_key(&peer_scope_id), data: { "timestamp": 0, "owner": HaOwner::Switch as i32, "new_state": HaState::Active.as_str_name(), "term": "1", "vdpu_id": &vdpu1_id, "peer_vdpu_id": &vdpu0_id, "acked_asic_ha_state": "active" } },
    ];
    test::run_commands(&runtime, destination.clone(), &commands).await;

    let state_db = crate::db_for_table::<NpuDashHaScopeState>().await.unwrap();
    let state_table = Table::new(state_db, NpuDashHaScopeState::table_name()).unwrap();
    let op_id = wait_for_pending_operation(&state_table, &scope_id_in_state).await;

    #[rustfmt::skip]
    let commands = [
        send! { key: HaScopeConfig::table_name(), data: { "key": &scope_id, "operation": "Set",
                "field_values": {"json": format!(r#"{{"version":"2","disabled":false,"desired_ha_state":{},"owner":{},"ha_set_id":"{ha_set_id}","approved_pending_operation_ids":["{op_id}"]}}"#, DesiredHaState::Unspecified as i32, HaOwner::Switch as i32)},
                },
                addr: crate::common_bridge_sp::<HaScopeConfig>(&runtime.get_swbus_edge()) },
        recv! { key: &ha_set_id, data: { "key": &ha_set_id, "operation": "Set", "field_values": { "version": "2", "ha_role": "standby", "ha_term": "1", "ha_set_id": &ha_set_id } }, addr: crate::common_bridge_sp::<DashHaScopeTable>(&runtime.get_swbus_edge()) },
        recv! { key: HaScopeActorState::msg_key(&scope_id), data: { "owner": HaOwner::Switch as i32, "new_state": HaState::Standby.as_str_name(), "term": "1", "vdpu_id": &vdpu0_id, "peer_vdpu_id": &vdpu1_id }, addr: runtime.sp(HaScopeActor::name(), &peer_scope_id), exclude: "timestamp" },
        recv! { key: HaScopeActorState::msg_key(&scope_id), data: { "owner": HaOwner::Switch as i32, "new_state": HaState::Standby.as_str_name(), "term": "1", "vdpu_id": &vdpu0_id, "peer_vdpu_id": &vdpu1_id }, addr: runtime.sp(HaSetActor::name(), &ha_set_id), exclude: "timestamp" },
    ];
    test::run_commands(&runtime, destination.clone(), &commands).await;
    wait_for_npu_terms(&state_table, &scope_id_in_state, "1", "1", 0).await;
    println!("REACHABLE PRECONDITION: public config/election/bulk-sync/approval -> local_state=standby peer_term=1 local_target_term=1");

    // Build two ordinary peer messages once. Reusing old_raw later is the documented public
    // send_raw resend operation and preserves the original request ID exactly as Outgoing does.
    let peer_client = SimpleSwbusEdgeClient::new(
        runtime.get_swbus_edge(),
        runtime.sp(HaScopeActor::name(), &peer_scope_id),
        true,
        false,
    );
    let old_state = HaScopeActorState::new_actor_msg(
        &peer_scope_id,
        HaOwner::Switch as i32,
        HaState::Active.as_str_name(),
        100,
        "1",
        &vdpu1_id,
        &vdpu0_id,
        "active",
    )
    .unwrap();
    let new_state = HaScopeActorState::new_actor_msg(
        &peer_scope_id,
        HaOwner::Switch as i32,
        HaState::Active.as_str_name(),
        200,
        "2",
        &vdpu1_id,
        &vdpu0_id,
        "active",
    )
    .unwrap();
    let (old_id, old_raw) = peer_client.outgoing_message_to_swbus_message(OutgoingMessage {
        destination: destination.clone(),
        body: MessageBody::Request {
            payload: old_state.serialize(),
        },
    });
    let (new_id, new_raw) = peer_client.outgoing_message_to_swbus_message(OutgoingMessage {
        destination: destination.clone(),
        body: MessageBody::Request {
            payload: new_state.serialize(),
        },
    });

    peer_client.send_raw(old_raw.clone()).await.unwrap();
    wait_for_npu_terms(&state_table, &scope_id_in_state, "1", "1", 100).await;
    peer_client.send_raw(new_raw).await.unwrap();
    let dropped_old_ack = wait_for_response(&peer_client, new_id, Some(old_id)).await;
    assert!(dropped_old_ack, "the Level 1 lost-ack condition was not established");
    wait_for_npu_terms(&state_table, &scope_id_in_state, "2", "2", 200).await;
    println!("LEVEL 0 CONTROL: in_order_terms=1->2 accepted_peer_term=2 local_target_term=2");

    tokio::time::sleep(Duration::from_millis(25)).await;
    peer_client.send_raw(old_raw).await.unwrap();
    wait_for_response(&peer_client, old_id, None).await;
    wait_for_npu_terms(&state_table, &scope_id_in_state, "1", "1", 100).await;
    println!("LEVEL 1 TRIGGER: resent_old_request_id={old_id} after_new_request_id={new_id} peer_term=2->1 local_target_term=2->1");

    tokio::time::sleep(Duration::from_millis(500)).await;
    wait_for_npu_terms(&state_table, &scope_id_in_state, "1", "1", 100).await;
    println!("NO AUTO-REPAIR: after_500ms peer_term=1 local_target_term=1");
    drop(peer_client);

    // Attach the real producer bridge at the production DPU table service path. A normal admin
    // update now consumes local_target_term and commits it into DPU_APPL_DB.
    let dpu_db = crate::db_for_table::<DashHaScopeTable>().await.unwrap();
    let dpu_table = Table::new(dpu_db, DashHaScopeTable::table_name()).unwrap();
    let _producer_bridge = ProducerBridge::spawn(
        runtime.get_swbus_edge(),
        crate::common_bridge_sp::<DashHaScopeTable>(&runtime.get_swbus_edge()),
        dpu_table,
    );
    tokio::task::yield_now().await;

    #[rustfmt::skip]
    let commands = [
        send! { key: HaScopeConfig::table_name(), data: { "key": &scope_id, "operation": "Set",
                "field_values": {"json": format!(r#"{{"version":"3","disabled":true,"desired_ha_state":{},"owner":{},"ha_set_id":"{ha_set_id}","approved_pending_operation_ids":[]}}"#, DesiredHaState::Unspecified as i32, HaOwner::Switch as i32)},
                },
                addr: crate::common_bridge_sp::<HaScopeConfig>(&runtime.get_swbus_edge()) },
        recv! { key: HaScopeActorState::msg_key(&scope_id), data: { "owner": HaOwner::Switch as i32, "new_state": HaState::Dead.as_str_name(), "term": "1", "vdpu_id": &vdpu0_id, "peer_vdpu_id": &vdpu1_id }, addr: runtime.sp(HaScopeActor::name(), &peer_scope_id), exclude: "timestamp" },
        recv! { key: HaScopeActorState::msg_key(&scope_id), data: { "owner": HaOwner::Switch as i32, "new_state": HaState::Dead.as_str_name(), "term": "1", "vdpu_id": &vdpu0_id, "peer_vdpu_id": &vdpu1_id }, addr: runtime.sp(HaSetActor::name(), &ha_set_id), exclude: "timestamp" },
        chkdb! { type: DashHaScopeTable, key: &ha_set_id, data: { "version": "3", "ha_role": "dead", "ha_term": "1", "ha_set_id": &ha_set_id } },
    ];
    test::run_commands(&runtime, destination, &commands).await;

    let dpu_db = crate::db_for_table::<DashHaScopeTable>().await.unwrap();
    let dpu_table = Table::new(dpu_db, DashHaScopeTable::table_name()).unwrap();
    let applied: DashHaScopeTable = swss_serde::from_table(&dpu_table, &ha_set_id).unwrap();
    assert_eq!(applied.ha_term, "1");
    assert_ne!(applied.ha_term, "2", "DPU unexpectedly retained the accepted term");
    println!("BUG TRIGGERED: accepted_peer_term=2 replayed_peer_term=1 persisted_local_target_term=1 dpu_dash_ha_scope_term={} expected_dpu_term=2", applied.ha_term);
}
