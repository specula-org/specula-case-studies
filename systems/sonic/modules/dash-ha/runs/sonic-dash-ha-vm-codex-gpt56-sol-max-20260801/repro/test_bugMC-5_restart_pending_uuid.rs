//! MC-5 Level-0 reproduction.
//!
//! This is compiled as a test-only child module of `actors::ha_scope`. It uses
//! the production actor driver, Swbus request interface, Redis tables, and DPU
//! consumer rehydration path. The only test accommodation is module wiring;
//! no production logic, state, timing, or UUID generation is patched.

use super::HaScopeActor;
use crate::actors::{
    test::{
        create_actor_runtime, make_dpu_bfd_state, make_dpu_ha_scope_state, make_dpu_pmon_state,
        make_dpu_scope_ha_set_obj, make_local_dpu_actor_state, make_remote_dpu_actor_state,
        make_vdpu_actor_state,
    },
    DbBasedActor,
};
use crate::db_structs::{DashHaScopeTable, DpuDashHaScopeState, NpuDashHaScopeState};
use crate::ha_actor_messages::{HaSetActorState, VDpuActorState};
use serde_json::json;
use sonic_common::SonicDbTable;
use sonic_dash_api_proto::ha_scope_config::{DesiredHaState, HaScopeConfig};
use sonic_dash_api_proto::types::HaOwner;
use std::collections::HashSet;
use std::time::Duration;
use swbus_actor::{ActorMessage, ActorRuntime};
use swbus_edge::simple_client::{
    IncomingMessage, MessageBody, OutgoingMessage, SimpleSwbusEdgeClient,
};
use swbus_edge::swbus_proto::swbus::SwbusErrorCode;
use swss_common::{KeyOpFieldValues, Table};
use swss_common_testing::Redis;
use swss_serde::to_field_values;
use tokio::time::{sleep, timeout};

async fn send_normal_actor_input(
    runtime: &ActorRuntime,
    scope_id: &str,
    step: usize,
    key: &str,
    data: serde_json::Value,
) {
    let source = runtime.sp("mc5-repro", &format!("sender-{step}"));
    let client = SimpleSwbusEdgeClient::new(runtime.get_swbus_edge(), source, true, false);
    let message = ActorMessage::new(key, &data).expect("encode actor input");
    let request_id = client
        .send(OutgoingMessage {
            destination: runtime.sp(HaScopeActor::name(), scope_id),
            body: MessageBody::Request {
                payload: message.serialize(),
            },
        })
        .await
        .expect("send actor input");

    let response = timeout(Duration::from_secs(3), client.recv())
        .await
        .expect("actor response timed out")
        .expect("actor response stream ended");
    match response {
        IncomingMessage {
            body:
                MessageBody::Response {
                    request_id: response_id,
                    error_code,
                    error_message,
                    ..
                },
            ..
        } => {
            assert_eq!(response_id, request_id, "response/request ID mismatch");
            assert_eq!(
                error_code,
                SwbusErrorCode::Ok,
                "actor rejected normal input: {error_message}"
            );
        }
        other => panic!("unexpected actor response: {other:#?}"),
    }
}

async fn start_dpu_scope(
    runtime: &ActorRuntime,
    scope_id: &str,
    ha_set_id: &str,
    ha_set: &crate::db_structs::DashHaSetTable,
    vdpu_id: &str,
    peer_vdpu_id: &str,
    vdpu_state: &VDpuActorState,
    step_base: usize,
) {
    send_normal_actor_input(
        runtime,
        scope_id,
        step_base,
        HaScopeConfig::table_name(),
        json!({
            "key": scope_id,
            "operation": "Set",
            "field_values": {
                "json": format!(
                    r#"{{"version":"1","disabled":false,"desired_ha_state":{},"owner":{},"ha_set_id":"{}","approved_pending_operation_ids":[]}}"#,
                    DesiredHaState::Active as i32,
                    HaOwner::Dpu as i32,
                    ha_set_id
                )
            }
        }),
    )
    .await;

    send_normal_actor_input(
        runtime,
        scope_id,
        step_base + 1,
        &HaSetActorState::msg_key(ha_set_id),
        json!({
            "up": true,
            "ha_set": ha_set,
            "vdpu_ids": [vdpu_id, peer_vdpu_id],
            "pinned_vdpu_bfd_probe_states": [""]
        }),
    )
    .await;

    send_normal_actor_input(
        runtime,
        scope_id,
        step_base + 2,
        &VDpuActorState::msg_key(vdpu_id),
        serde_json::to_value(vdpu_state).expect("serialize vDPU state"),
    )
    .await;
}

async fn wait_for_npu_state<F>(
    table: &Table,
    key: &str,
    label: &str,
    mut predicate: F,
) -> NpuDashHaScopeState
where
    F: FnMut(&NpuDashHaScopeState) -> bool,
{
    let mut last = None;
    for _ in 0..100 {
        if let Ok(state) = swss_serde::from_table::<NpuDashHaScopeState>(table, key) {
            if predicate(&state) {
                return state;
            }
            last = Some(state);
        }
        sleep(Duration::from_millis(20)).await;
    }
    panic!("timed out waiting for {label}; last state: {last:#?}");
}

async fn receive_dpu_write(client: &SimpleSwbusEdgeClient, label: &str) -> DashHaScopeTable {
    let incoming = timeout(Duration::from_secs(3), client.recv())
        .await
        .unwrap_or_else(|_| panic!("timed out waiting for DPU write: {label}"))
        .unwrap_or_else(|| panic!("DPU-write stream ended: {label}"));
    let IncomingMessage {
        id,
        source,
        body: MessageBody::Request { payload },
        ..
    } = incoming
    else {
        panic!("unexpected non-request while waiting for DPU write: {incoming:#?}");
    };

    let message = ActorMessage::deserialize(&payload).expect("decode DPU write ActorMessage");
    let kfv = message
        .deserialize_data::<KeyOpFieldValues>()
        .expect("decode DPU write KeyOpFieldValues");
    let write = swss_serde::from_field_values::<DashHaScopeTable>(&kfv.field_values)
        .expect("decode DASH_HA_SCOPE_TABLE fields");

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
        .expect("ack DPU write");
    write
}

async fn approve_one(
    runtime: &ActorRuntime,
    scope_id: &str,
    ha_set_id: &str,
    operation_id: &str,
    version: usize,
    step: usize,
) {
    send_normal_actor_input(
        runtime,
        scope_id,
        step,
        HaScopeConfig::table_name(),
        json!({
            "key": scope_id,
            "operation": "Set",
            "field_values": {
                "json": format!(
                    r#"{{"version":"{}","disabled":false,"desired_ha_state":{},"owner":{},"ha_set_id":"{}","approved_pending_operation_ids":["{}"]}}"#,
                    version,
                    DesiredHaState::Active as i32,
                    HaOwner::Dpu as i32,
                    ha_set_id,
                    operation_id
                )
            }
        }),
    )
    .await;
}

#[tokio::test]
async fn mc5_restart_duplicates_pending_uuid_and_reissues_dpu_action() {
    sonic_common::log::init_logger_for_test();
    let _redis = Redis::start_config_db();
    let runtime = create_actor_runtime(0, "10.0.0.0", "10::").await;

    let (ha_set_id, ha_set) = make_dpu_scope_ha_set_obj(0, 0);
    let local_dpu = make_local_dpu_actor_state(
        0,
        0,
        true,
        Some(make_dpu_pmon_state(true)),
        Some(make_dpu_bfd_state(Vec::new(), Vec::new())),
    );
    let remote_dpu = make_remote_dpu_actor_state(1, 0);
    let (vdpu_id, vdpu_state) = make_vdpu_actor_state(true, &local_dpu);
    let (peer_vdpu_id, _) = make_vdpu_actor_state(true, &remote_dpu);
    let scope_id = format!("{vdpu_id}:{ha_set_id}");
    let npu_key = format!("{vdpu_id}|{ha_set_id}");

    let dpu_db = crate::db_for_table::<DpuDashHaScopeState>()
        .await
        .expect("connect DPU_STATE_DB");
    let dpu_table = Table::new(dpu_db, DpuDashHaScopeState::table_name())
        .expect("open DPU DASH_HA_SCOPE_STATE_TABLE");
    let npu_db = crate::db_for_table::<NpuDashHaScopeState>()
        .await
        .expect("connect STATE_DB");
    let npu_table = Table::new(npu_db, NpuDashHaScopeState::table_name())
        .expect("open NPU DASH_HA_SCOPE_STATE");

    // A real producer-bridge endpoint observes the command delivered to the DPU.
    let dpu_command_client = SimpleSwbusEdgeClient::new(
        runtime.get_swbus_edge(),
        crate::common_bridge_sp::<DashHaScopeTable>(&runtime.get_swbus_edge()),
        true,
        false,
    );

    // Establish a real false state before the one and only false->true edge.
    let dpu_false = make_dpu_ha_scope_state("dead");
    dpu_table
        .set(
            &ha_set_id,
            to_field_values(&dpu_false).expect("encode initial DPU state"),
        )
        .expect("write initial DPU state");

    let first_actor = HaScopeActor::new(scope_id.clone()).expect("construct first actor");
    let first_handle = runtime.spawn(first_actor, HaScopeActor::name(), &scope_id);
    start_dpu_scope(
        &runtime,
        &scope_id,
        &ha_set_id,
        &ha_set,
        &vdpu_id,
        &peer_vdpu_id,
        &vdpu_state,
        10,
    )
    .await;
    let initial_write = receive_dpu_write(&dpu_command_client, "initial actor setup").await;
    assert_eq!(initial_write.activate_role_requested, Some(false));

    wait_for_npu_state(&npu_table, &npu_key, "initial false DPU state", |state| {
        state.local_ha_state.as_deref() == Some("dead")
    })
    .await;

    let mut dpu_pending = dpu_false.clone();
    dpu_pending.activate_role_pending = true;
    dpu_pending.last_updated_time += 1;
    dpu_table
        .set(
            &ha_set_id,
            to_field_values(&dpu_pending).expect("encode pending DPU state"),
        )
        .expect("write one false-to-true pending edge");

    let before = wait_for_npu_state(&npu_table, &npu_key, "one pending operation", |state| {
        state.pending_operation_ids.as_ref().map(Vec::len) == Some(1)
            && state.pending_operation_types.as_deref() == Some(&["activate_role".to_string()])
    })
    .await;
    let original_id = before.pending_operation_ids.clone().unwrap()[0].clone();
    println!("LEVEL0 before_restart pending_ids=[{original_id}] pending_types=[activate_role]");

    // Unplanned crash: cancel the actor task. This intentionally does not send a
    // config Del and therefore does not invoke production cleanup.
    first_handle.abort();
    let crash_result = first_handle
        .await
        .expect_err("aborted actor unexpectedly completed");
    assert!(
        crash_result.is_cancelled(),
        "actor abort was not a cancellation"
    );

    let second_actor = HaScopeActor::new(scope_id.clone()).expect("construct restarted actor");
    let second_handle = runtime.spawn(second_actor, HaScopeActor::name(), &scope_id);
    start_dpu_scope(
        &runtime,
        &scope_id,
        &ha_set_id,
        &ha_set,
        &vdpu_id,
        &peer_vdpu_id,
        &vdpu_state,
        20,
    )
    .await;
    let restart_write = receive_dpu_write(&dpu_command_client, "restarted actor setup").await;
    assert_eq!(restart_write.activate_role_requested, Some(false));

    // No DPU input is injected here: the production ConsumerBridge rehydrates
    // the still-true DPU Redis row after the fresh actor subscribes.
    let duplicated = wait_for_npu_state(
        &npu_table,
        &npu_key,
        "duplicated pending operation",
        |state| {
            state.pending_operation_ids.as_ref().map(Vec::len) == Some(2)
                && state.pending_operation_types.as_ref().map(|types| {
                    types
                        .iter()
                        .filter(|kind| kind.as_str() == "activate_role")
                        .count()
                }) == Some(2)
        },
    )
    .await;
    let duplicated_ids = duplicated.pending_operation_ids.clone().unwrap();
    let unique_ids: HashSet<_> = duplicated_ids.iter().collect();
    assert_eq!(
        unique_ids.len(),
        2,
        "restart did not create two distinct UUIDs"
    );
    assert!(
        duplicated_ids.contains(&original_id),
        "persisted UUID was not retained"
    );
    let duplicate_id = duplicated_ids
        .iter()
        .find(|id| **id != original_id)
        .unwrap()
        .clone();
    println!(
        "LEVEL0 after_restart live_dpu_pending_flags=1 pending_ids=[{},{}] pending_types=[activate_role,activate_role] unique_ids=2",
        original_id, duplicate_id
    );

    // The controller normally approves IDs from this public STATE_DB list. Each
    // duplicate independently drives the production DPU request output.
    approve_one(&runtime, &scope_id, &ha_set_id, &original_id, 2, 30).await;
    let first_action = receive_dpu_write(&dpu_command_client, "first controller approval").await;
    assert_eq!(first_action.activate_role_requested, Some(true));
    let after_first_approval = wait_for_npu_state(
        &npu_table,
        &npu_key,
        "one UUID after first approval",
        |state| state.pending_operation_ids.as_ref().map(Vec::len) == Some(1),
    )
    .await;
    assert_eq!(
        after_first_approval.pending_operation_ids.as_deref(),
        Some(&[duplicate_id.clone()][..])
    );

    // The one physical DPU request completes and clears its only pending flag.
    // The second UUID is not cleaned up by that completion.
    let mut dpu_completed = make_dpu_ha_scope_state("active");
    dpu_completed.ha_term = Some("2".to_string());
    dpu_completed.activate_role_pending = false;
    dpu_completed.last_updated_time = dpu_pending.last_updated_time + 1;
    dpu_table
        .set(
            &ha_set_id,
            to_field_values(&dpu_completed).expect("encode completed DPU state"),
        )
        .expect("write completed DPU state");
    let after_clear = wait_for_npu_state(
        &npu_table,
        &npu_key,
        "flag clear with stale UUID",
        |state| {
            state.local_ha_state.as_deref() == Some("active")
                && state.pending_operation_ids.as_deref() == Some(&[duplicate_id.clone()])
        },
    )
    .await;
    assert_eq!(
        after_clear.pending_operation_types.as_deref(),
        Some(&["activate_role".to_string()][..])
    );
    sleep(Duration::from_millis(300)).await;
    let settled_after_clear: NpuDashHaScopeState = swss_serde::from_table(&npu_table, &npu_key)
        .expect("read settled NPU state after the real DPU flag cleared");
    assert_eq!(
        settled_after_clear.pending_operation_ids.as_deref(),
        Some(&[duplicate_id.clone()][..]),
        "no downstream cleanup should leave this as a merely transient snapshot"
    );
    println!(
        "LEVEL0 after_dpu_flag_clear_and_settle live_dpu_pending_flags=0 remaining_pending_ids=[{}] remaining_types=[activate_role] auto_cleanup=false",
        duplicate_id
    );

    // Approving the remaining advertised UUID emits a second activate command,
    // despite there having been only one DPU false->true request generation.
    approve_one(&runtime, &scope_id, &ha_set_id, &duplicate_id, 3, 31).await;
    let second_action = receive_dpu_write(&dpu_command_client, "second controller approval").await;
    assert_eq!(second_action.activate_role_requested, Some(true));
    wait_for_npu_state(
        &npu_table,
        &npu_key,
        "all duplicate UUIDs approved",
        |state| {
            state
                .pending_operation_ids
                .as_ref()
                .is_some_and(Vec::is_empty)
        },
    )
    .await;

    println!(
        "BUG_TRIGGERED MC-5 one_false_to_true_edge=1 restart_count=1 distinct_pending_uuids=2 dpu_activate_commands=2"
    );
    println!("EXPECTED distinct_pending_uuids=1 dpu_activate_commands=1");

    second_handle.abort();
    let _ = second_handle.await;
}
