//! MC-6 regression reproduction.
//!
//! This module is included from `ha_set.rs` under `cfg(test)`.  It drives the
//! real HA-set and NPU HA-scope actors exclusively through actor messages that
//! correspond to CONFIG_DB, vDPU-state, and DPU-state updates.

use super::HaSetActor;
use crate::{
    actors::{
        ha_scope::HaScopeActor,
        test::{self, *},
        vdpu::VDpuActor,
        DbBasedActor,
    },
    db_structs::{
        BfdSessionTable, DashHaGlobalConfig, DashHaScopeTable, DashHaSetTable, DpuDashHaSetState,
        VnetRouteTunnelTable,
    },
    ha_actor_messages::{ActorRegistration, RegistrationType, VDpuActorState},
};
use sonic_common::SonicDbTable;
use sonic_dash_api_proto::{
    ha_scope_config::{DesiredHaState, HaScopeConfig},
    ha_set_config::HaSetConfig,
    types::HaOwner,
};
use std::{collections::HashMap, time::Duration};
use swbus_actor::{ActorMessage, ActorRuntime};
use swbus_edge::{
    simple_client::{IncomingMessage, MessageBody, OutgoingMessage, SimpleSwbusEdgeClient},
    swbus_proto::swbus::{ServicePath, SwbusErrorCode},
};
use swss_common::{CxxString, KeyOpFieldValues, KeyOperation};
use swss_common_testing::Redis;
use tokio::sync::mpsc::{unbounded_channel, UnboundedReceiver};

fn protobuf_fields(cfg: &HaSetConfig) -> HashMap<String, CxxString> {
    let mut fields = HashMap::new();
    fields.insert(
        "json".to_string(),
        serde_json::to_string(cfg).unwrap().into(),
    );
    fields
}

fn spawn_ack_sink(
    runtime: &ActorRuntime,
    service_path: ServicePath,
) -> UnboundedReceiver<KeyOpFieldValues> {
    let client = SimpleSwbusEdgeClient::new(runtime.get_swbus_edge(), service_path, true, false);
    let (tx, rx) = unbounded_channel();

    tokio::spawn(async move {
        while let Some(IncomingMessage {
            id,
            source,
            body: MessageBody::Request { payload },
            ..
        }) = client.recv().await
        {
            let actor_message = ActorMessage::deserialize(&payload).unwrap();
            let kfv: KeyOpFieldValues = actor_message.deserialize_data().unwrap();
            let _ = tx.send(kfv);
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
                .unwrap();
        }
    });

    rx
}

fn spawn_message_ack_sink(runtime: &ActorRuntime, service_path: ServicePath) {
    let client = SimpleSwbusEdgeClient::new(runtime.get_swbus_edge(), service_path, true, false);
    tokio::spawn(async move {
        while let Some(IncomingMessage {
            id,
            source,
            body: MessageBody::Request { .. },
            ..
        }) = client.recv().await
        {
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
                .unwrap();
        }
    });
}

async fn wait_for_operation(
    rx: &mut UnboundedReceiver<KeyOpFieldValues>,
    operation: KeyOperation,
) -> KeyOpFieldValues {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let kfv = rx.recv().await.expect("table sink closed");
            if kfv.operation == operation {
                return kfv;
            }
        }
    })
    .await
    .expect("timed out waiting for table operation")
}

async fn wait_for_scope_role(
    rx: &mut UnboundedReceiver<KeyOpFieldValues>,
    role: &str,
) -> (KeyOpFieldValues, DashHaScopeTable) {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let kfv = rx.recv().await.expect("scope-table sink closed");
            if kfv.operation != KeyOperation::Set {
                continue;
            }
            let scope: DashHaScopeTable = swss_serde::from_field_values(&kfv.field_values).unwrap();
            if scope.ha_role == role {
                return (kfv, scope);
            }
        }
    })
    .await
    .expect("timed out waiting for HA-scope role")
}

#[tokio::test]
async fn parent_config_delete_leaves_npu_scope_using_cached_parent() {
    sonic_common::log::init_logger_for_test();
    let _redis = Redis::start_config_db();
    test::setup_remote_dpu_in_db(1, 0);
    let runtime = test::create_actor_runtime(0, "10.0.0.0", "10::").await;
    test::setup_mock_swbusd_resolve_peer_sp(&runtime.get_swbus_edge());

    let (ha_set_id, ha_set_config) = make_dpu_scope_ha_set_config(0, 0);
    let ha_set_config_fields = protobuf_fields(&ha_set_config);
    let global_config = make_dash_ha_global_config();
    let global_config_fields =
        serde_json::to_value(swss_serde::to_field_values(&global_config).unwrap()).unwrap();

    let local_dpu = make_local_dpu_actor_state(
        0,
        0,
        true,
        Some(make_dpu_pmon_state(true)),
        Some(make_dpu_bfd_state(Vec::new(), Vec::new())),
    );
    let remote_dpu = make_remote_dpu_actor_state(1, 0);
    let (local_vdpu_id, local_vdpu_state) = make_vdpu_actor_state(true, &local_dpu);
    let (remote_vdpu_id, remote_vdpu_state) = make_vdpu_actor_state(true, &remote_dpu);
    let local_vdpu_state_json = serde_json::to_value(&local_vdpu_state).unwrap();
    let remote_vdpu_state_json = serde_json::to_value(&remote_vdpu_state).unwrap();

    let scope_id = format!("{local_vdpu_id}:{ha_set_id}");
    let peer_scope_id = format!("{remote_vdpu_id}:{ha_set_id}");

    // These are the real producer-facing endpoints.  The sinks perform the
    // producer acknowledgement and retain the emitted KFV for assertions.
    let mut ha_set_table_rx = spawn_ack_sink(
        &runtime,
        crate::common_bridge_sp::<DashHaSetTable>(&runtime.get_swbus_edge()),
    );
    let mut scope_table_rx = spawn_ack_sink(
        &runtime,
        crate::common_bridge_sp::<DashHaScopeTable>(&runtime.get_swbus_edge()),
    );
    let _bfd_table_rx = spawn_ack_sink(
        &runtime,
        crate::common_bridge_sp::<BfdSessionTable>(&runtime.get_swbus_edge()),
    );
    let _route_table_rx = spawn_ack_sink(
        &runtime,
        crate::common_bridge_sp::<VnetRouteTunnelTable>(&runtime.get_swbus_edge()),
    );
    spawn_message_ack_sink(&runtime, runtime.sp(HaScopeActor::name(), &peer_scope_id));

    let parent = HaSetActor::new(ha_set_id.clone()).unwrap();
    let child = HaScopeActor::new(scope_id.clone()).unwrap();
    let parent_handle = runtime.spawn(parent, HaSetActor::name(), &ha_set_id);
    let _child_handle = runtime.spawn(child, HaScopeActor::name(), &scope_id);

    // Normal child creation: CONFIG_DB config followed by its real vDPU-state
    // prerequisite. Registration and state messages go to the real parent actor.
    #[rustfmt::skip]
    let child_create = [
        send! { key: HaScopeConfig::table_name(), data: {
                "key": &scope_id, "operation": "Set",
                "field_values": {"json": format!(r#"{{"version":"1","disabled":false,"desired_ha_state":{},"owner":{},"ha_set_id":"{ha_set_id}","approved_pending_operation_ids":[]}}"#, DesiredHaState::Active as i32, HaOwner::Switch as i32)}
            }, addr: crate::common_bridge_sp::<HaScopeConfig>(&runtime.get_swbus_edge()) },
        recv! { key: ActorRegistration::msg_key(RegistrationType::VDPUState, &scope_id), data: {"active": true}, addr: runtime.sp(VDpuActor::name(), &local_vdpu_id) },
        send! { key: VDpuActorState::msg_key(&local_vdpu_id), data: local_vdpu_state_json, addr: runtime.sp(VDpuActor::name(), &local_vdpu_id) },
    ];
    test::run_commands(
        &runtime,
        runtime.sp(HaScopeActor::name(), &scope_id),
        &child_create,
    )
    .await;

    // Normal parent creation and its ordinary prerequisites.
    #[rustfmt::skip]
    let parent_create = [
        send! { key: HaSetActor::table_name(), data: {"key": HaSetActor::table_name(), "operation": "Set", "field_values": ha_set_config_fields.clone()}, addr: crate::common_bridge_sp::<HaSetConfig>(&runtime.get_swbus_edge()) },
        recv! { key: ActorRegistration::msg_key(RegistrationType::VDPUState, &ha_set_id), data: {"active": true}, addr: runtime.sp(VDpuActor::name(), &local_vdpu_id) },
        recv! { key: ActorRegistration::msg_key(RegistrationType::VDPUState, &ha_set_id), data: {"active": true}, addr: runtime.sp(VDpuActor::name(), &remote_vdpu_id) },
        send! { key: DashHaGlobalConfig::table_name(), data: {"key": DashHaGlobalConfig::table_name(), "operation": "Set", "field_values": global_config_fields} },
        send! { key: VDpuActorState::msg_key(&local_vdpu_id), data: local_vdpu_state_json, addr: runtime.sp(VDpuActor::name(), &local_vdpu_id) },
        send! { key: VDpuActorState::msg_key(&remote_vdpu_id), data: remote_vdpu_state_json, addr: runtime.sp(VDpuActor::name(), &remote_vdpu_id) },
    ];
    test::run_commands(
        &runtime,
        runtime.sp(HaSetActor::name(), &ha_set_id),
        &parent_create,
    )
    .await;
    let initial_parent_set = wait_for_operation(&mut ha_set_table_rx, KeyOperation::Set).await;
    assert_eq!(initial_parent_set.key, ha_set_id);

    // The real DPU state channel first reports up, then down.  The down edge is
    // a normal event that moves the NPU-driven scope into its applied standalone
    // role without injecting internal actor state.
    let state_up = DpuDashHaSetState {
        last_updated_time: 1000,
        dp_channel_is_alive: "up".to_string(),
    };
    let state_down = DpuDashHaSetState {
        last_updated_time: 2000,
        dp_channel_is_alive: "down".to_string(),
    };
    let state_up_fields =
        serde_json::to_value(swss_serde::to_field_values(&state_up).unwrap()).unwrap();
    let state_down_fields =
        serde_json::to_value(swss_serde::to_field_values(&state_down).unwrap()).unwrap();

    #[rustfmt::skip]
    let parent_up = [
        send! { key: DpuDashHaSetState::table_name(), data: {"key": &ha_set_id, "operation": "Set", "field_values": state_up_fields} },
    ];
    test::run_commands(
        &runtime,
        runtime.sp(HaSetActor::name(), &ha_set_id),
        &parent_up,
    )
    .await;
    #[rustfmt::skip]
    let parent_down = [
        send! { key: DpuDashHaSetState::table_name(), data: {"key": &ha_set_id, "operation": "Set", "field_values": state_down_fields} },
    ];
    test::run_commands(
        &runtime,
        runtime.sp(HaSetActor::name(), &ha_set_id),
        &parent_down,
    )
    .await;

    let (applied_kfv, applied_scope) = wait_for_scope_role(&mut scope_table_rx, "standalone").await;
    assert_eq!(applied_kfv.key, ha_set_id);
    assert_eq!(applied_scope.ha_set_id, ha_set_id);
    println!(
        "MC-6 PRECONDITION: child emitted DASH_HA_SCOPE_TABLE Set role={} ha_set_id={} version={}",
        applied_scope.ha_role, applied_scope.ha_set_id, applied_scope.version
    );

    // The trigger from the counterexample: a normal CONFIG_DB delete of the
    // parent while the child config remains present.
    #[rustfmt::skip]
    let parent_delete = [
        send! { key: HaSetActor::table_name(), data: {"key": HaSetActor::table_name(), "operation": "Del", "field_values": ha_set_config_fields}, addr: crate::common_bridge_sp::<HaSetConfig>(&runtime.get_swbus_edge()) },
        recv! { key: ActorRegistration::msg_key(RegistrationType::VDPUState, &ha_set_id), data: {"active": false}, addr: runtime.sp(VDpuActor::name(), &local_vdpu_id) },
        recv! { key: ActorRegistration::msg_key(RegistrationType::VDPUState, &ha_set_id), data: {"active": false}, addr: runtime.sp(VDpuActor::name(), &remote_vdpu_id) },
    ];
    test::run_commands(
        &runtime,
        runtime.sp(HaSetActor::name(), &ha_set_id),
        &parent_delete,
    )
    .await;
    let parent_delete_kfv = wait_for_operation(&mut ha_set_table_rx, KeyOperation::Del).await;
    assert_eq!(parent_delete_kfv.key, ha_set_id);
    tokio::time::timeout(Duration::from_secs(3), parent_handle)
        .await
        .expect("parent actor did not terminate")
        .expect("parent actor task failed");
    println!("MC-6 TRIGGER: parent emitted DASH_HA_SET_TABLE Del and its actor terminated");

    // No child deletion or invalidation is emitted after the completed parent
    // cleanup. This is not the trigger; it is an observation window.
    assert!(
        tokio::time::timeout(Duration::from_millis(500), scope_table_rx.recv())
            .await
            .is_err(),
        "parent cleanup unexpectedly caused a child table operation"
    );
    println!("MC-6 OBSERVED: no child Del/invalidation followed parent termination");

    // A subsequent ordinary CONFIG_DB update proves the live child still trusts
    // the cached HaSetActorState after the parent actor and table entry are gone.
    #[rustfmt::skip]
    let child_update_after_parent_delete = [
        send! { key: HaScopeConfig::table_name(), data: {
                "key": &scope_id, "operation": "Set",
                "field_values": {"json": format!(r#"{{"version":"2","disabled":true,"desired_ha_state":{},"owner":{},"ha_set_id":"{ha_set_id}","approved_pending_operation_ids":[]}}"#, DesiredHaState::Active as i32, HaOwner::Switch as i32)}
            }, addr: crate::common_bridge_sp::<HaScopeConfig>(&runtime.get_swbus_edge()) },
    ];
    test::run_commands(
        &runtime,
        runtime.sp(HaScopeActor::name(), &scope_id),
        &child_update_after_parent_delete,
    )
    .await;

    let (stale_kfv, stale_scope) = wait_for_scope_role(&mut scope_table_rx, "dead").await;
    assert_eq!(stale_kfv.key, ha_set_id);
    assert_eq!(stale_scope.ha_set_id, ha_set_id);
    assert_eq!(stale_scope.version, 2);
    println!(
        "MC-6 STALE CACHE: live child emitted another Set role={} ha_set_id={} version={} after parent termination",
        stale_scope.ha_role, stale_scope.ha_set_id, stale_scope.version
    );
}
