//! MC-1 reproduction: an older DPU role acknowledgement arrives after the
//! acknowledgement for the latest role write.
//!
//! This is a Level 2 fixture.  The injected starting state mirrors the
//! model-checker state immediately before counterexample transitions 12 -> 13
//! and 13 -> 14: the local control plane is Active with an acknowledged Standby
//! role, while Active and the older SwitchingToActive notifications remain
//! deliverable.  The model abstracts both writes at term 1; the concrete test
//! uses term 2 for the real implementation's final Active write.  All event
//! handling after that precondition uses the unmodified production handlers.

use super::base::HaScopeBase;
use super::npu::NpuHaScopeActor;
use super::TargetState;
use crate::db_structs::{now_in_millis, DpuDashHaScopeState, NpuDashHaScopeState};
use crate::ha_actor_messages::{HaScopeActorState, PeerHeartbeat};
use sonic_common::SonicDbTable;
use sonic_dash_api_proto::ha_scope_config::{DesiredHaState, HaScopeConfig};
use sonic_dash_api_proto::types::{HaOwner, HaState};
use std::sync::Arc;
use std::time::Duration;
use swbus_actor::{ActorMessage, Context, State};
use swbus_edge::simple_client::SimpleSwbusEdgeClient;
use swbus_edge::swbus_proto::swbus::{ConnectionType, ServicePath};
use swbus_edge::SwbusEdgeRuntime;
use swss_common::{KeyOpFieldValues, KeyOperation, Table};
use swss_common_testing::Redis;

const LOCAL_ID: &str = "vdpu0:haset0";
const PEER_ID: &str = "vdpu1:haset0";

fn service_path(actor_id: &str) -> ServicePath {
    ServicePath::from_string(&format!("mc1.local.none/hamgrd/0/ha-scope/{actor_id}")).unwrap()
}

fn configured_actor(id: &str, peer_id: &str, peer_sp: ServicePath) -> NpuHaScopeActor {
    let mut base = HaScopeBase::new(id.to_string()).unwrap();
    base.peer_vdpu_id = Some(peer_id.split(':').next().unwrap().to_string());
    base.peer_sp = Some(peer_sp);
    base.dash_ha_scope_config = Some(HaScopeConfig {
        version: "4".to_string(),
        disabled: false,
        owner: HaOwner::Switch as i32,
        ha_set_id: "haset0".to_string(),
        desired_ha_state: DesiredHaState::Active as i32,
        approved_pending_operation_ids: Vec::new(),
    });

    let mut actor = NpuHaScopeActor::new(base);
    actor.target_ha_scope_state = Some(TargetState::Active);
    actor.peer_connected = true;
    actor
}

fn active_npu_state(initial_ack_role: &str, initial_ack_term: &str) -> NpuDashHaScopeState {
    NpuDashHaScopeState {
        version: Some("4".to_string()),
        local_ha_state: Some(HaState::Active.as_str_name().to_string()),
        local_ha_state_last_updated_time_in_ms: Some(now_in_millis()),
        local_ha_state_last_updated_reason: Some("planned switchover completed".to_string()),
        local_target_asic_ha_state: Some("active".to_string()),
        local_acked_asic_ha_state: Some(initial_ack_role.to_string()),
        local_target_term: Some("2".to_string()),
        local_acked_term: Some(initial_ack_term.to_string()),
        ..Default::default()
    }
}

async fn actor_state(
    edge: Arc<SwbusEdgeRuntime>,
    sp: ServicePath,
    redis: &Redis,
    db_key: &str,
    persisted: &NpuDashHaScopeState,
) -> State {
    let client = Arc::new(SimpleSwbusEdgeClient::new(edge, sp, true, false));
    let mut state = State::new(client);
    let table = Table::new(redis.db_connector(), NpuDashHaScopeState::table_name()).unwrap();
    state
        .internal()
        .add(NpuDashHaScopeState::table_name(), table, db_key)
        .await;
    state
        .internal()
        .get_mut(NpuDashHaScopeState::table_name())
        .clone_from(&swss_serde::to_field_values(persisted).unwrap());
    state
}

fn dpu_notification(role: &str, term: &str) -> ActorMessage {
    let stamp = now_in_millis();
    let state = DpuDashHaScopeState {
        last_updated_time: stamp,
        ha_role: role.to_string(),
        ha_role_start_time: stamp,
        ha_term: Some(term.to_string()),
        ha_state: role.to_string(),
        ha_state_start_time: stamp + 1,
        activate_role_pending: false,
        flow_reconcile_pending: false,
        brainsplit_recover_pending: false,
    };
    let update = KeyOpFieldValues {
        key: "haset0".to_string(),
        operation: KeyOperation::Set,
        field_values: swss_serde::to_field_values(&state).unwrap(),
    };
    ActorMessage::new(DpuDashHaScopeState::table_name(), &update).unwrap()
}

async fn dispatch(
    actor: &mut NpuHaScopeActor,
    state: &mut State,
    context: &mut Context,
    source: ServicePath,
    request_id: u64,
    message: &ActorMessage,
) {
    let key = state
        .incoming()
        .handle_request(request_id, source, &message.serialize())
        .await
        .unwrap();
    actor
        .handle_message_inner(state, &key, context)
        .await
        .unwrap();
}

fn latest_scope_update(state: &State) -> ActorMessage {
    state
        .dump_state()
        .outgoing
        .outgoing_queued
        .iter()
        .rev()
        .find(|queued| HaScopeActorState::is_my_msg(&queued.actor_message.key))
        .expect("production handler did not broadcast an HA-scope state")
        .actor_message
        .clone()
}

fn npu_state(actor: &NpuHaScopeActor, state: &mut State) -> NpuDashHaScopeState {
    actor
        .base
        .get_npu_ha_scope_state(state.internal())
        .expect("fixture has an NPU state entry")
}

#[tokio::test]
async fn late_switching_to_active_ack_regresses_active_scope_and_reaches_peer() {
    let redis = Redis::start_config_db();
    let edge = Arc::new(SwbusEdgeRuntime::new(
        "mc1-reproduction".to_string(),
        ServicePath::from_string("mc1.local.none/hamgrd/0").unwrap(),
        ConnectionType::InNode,
    ));
    let local_sp = service_path(LOCAL_ID);
    let peer_sp = service_path(PEER_ID);
    let bridge_sp = crate::common_bridge_sp::<DpuDashHaScopeState>(&edge);

    println!("MC1_LEVEL=2 counterexample_states=12->13->14");

    // Reachable Level 2 precondition from model state 12: the control plane has
    // completed the switchover and the two DPU notifications may still reorder.
    let mut local_actor = configured_actor(LOCAL_ID, PEER_ID, peer_sp.clone());
    let mut local_state = actor_state(
        edge.clone(),
        local_sp.clone(),
        &redis,
        "vdpu0|haset0",
        &active_npu_state("standby", "1"),
    )
    .await;
    let mut local_context = Context::new(edge.clone());

    // This second actor executes the real peer-side consumer, rather than merely
    // decoding or inspecting the sender's queued message.
    let mut peer_actor = configured_actor(PEER_ID, LOCAL_ID, local_sp.clone());
    let mut peer_state = actor_state(
        edge.clone(),
        peer_sp.clone(),
        &redis,
        "vdpu1|haset0",
        &active_npu_state("active", "2"),
    )
    .await;
    let mut peer_context = Context::new(edge);

    // Counterexample 12 -> 13: the latest Active acknowledgement wins first.
    dispatch(
        &mut local_actor,
        &mut local_state,
        &mut local_context,
        bridge_sp.clone(),
        12013,
        &dpu_notification("active", "2"),
    )
    .await;
    let active = npu_state(&local_actor, &mut local_state);
    assert_eq!(
        active.local_ha_state.as_deref(),
        Some(HaState::Active.as_str_name())
    );
    assert_eq!(active.local_acked_asic_ha_state.as_deref(), Some("active"));
    assert_eq!(active.local_acked_term.as_deref(), Some("2"));
    let active_update = latest_scope_update(&local_state);
    let active_wire: HaScopeActorState = active_update.deserialize_data().unwrap();
    assert_eq!(active_wire.new_state, HaState::Active.as_str_name());
    assert_eq!(active_wire.acked_asic_ha_state, "active");
    dispatch(
        &mut peer_actor,
        &mut peer_state,
        &mut peer_context,
        local_sp.clone(),
        13001,
        &active_update,
    )
    .await;
    println!(
        "MC1_ACTIVE_ACK cp={} target_role={} target_term={} ack_role={} ack_term={}",
        active.local_ha_state.as_deref().unwrap(),
        active.local_target_asic_ha_state.as_deref().unwrap(),
        active.local_target_term.as_deref().unwrap(),
        active.local_acked_asic_ha_state.as_deref().unwrap(),
        active.local_acked_term.as_deref().unwrap(),
    );

    // Counterexample 13 -> 14: the older notification is accepted last.
    dispatch(
        &mut local_actor,
        &mut local_state,
        &mut local_context,
        bridge_sp,
        13014,
        &dpu_notification("switching_to_active", "1"),
    )
    .await;
    let regressed = npu_state(&local_actor, &mut local_state);
    assert_eq!(
        regressed.local_ha_state.as_deref(),
        Some(HaState::Active.as_str_name())
    );
    assert_eq!(
        regressed.local_target_asic_ha_state.as_deref(),
        Some("active")
    );
    assert_eq!(regressed.local_target_term.as_deref(), Some("2"));
    assert_eq!(
        regressed.local_acked_asic_ha_state.as_deref(),
        Some("switching_to_active")
    );
    assert_eq!(regressed.local_acked_term.as_deref(), Some("1"));

    let stale_update = latest_scope_update(&local_state);
    let stale_wire: HaScopeActorState = stale_update.deserialize_data().unwrap();
    assert_eq!(stale_wire.new_state, HaState::Active.as_str_name());
    assert_eq!(stale_wire.term, "2");
    assert_eq!(stale_wire.acked_asic_ha_state, "switching_to_active");
    dispatch(
        &mut peer_actor,
        &mut peer_state,
        &mut peer_context,
        local_sp.clone(),
        14001,
        &stale_update,
    )
    .await;
    let peer_observation = npu_state(&peer_actor, &mut peer_state);
    assert_eq!(
        peer_observation.peer_ha_state.as_deref(),
        Some(HaState::Active.as_str_name())
    );
    assert_eq!(
        peer_observation.peer_acked_asic_ha_state.as_deref(),
        Some("switching_to_active")
    );

    println!(
        "MC1_STALE_ACK_ACCEPTED cp={} target_role={} target_term={} ack_role={} ack_term={}",
        regressed.local_ha_state.as_deref().unwrap(),
        regressed.local_target_asic_ha_state.as_deref().unwrap(),
        regressed.local_target_term.as_deref().unwrap(),
        regressed.local_acked_asic_ha_state.as_deref().unwrap(),
        regressed.local_acked_term.as_deref().unwrap(),
    );
    println!(
        "MC1_REAL_CONSUMER peer_state={} peer_acked_asic_ha_state={}",
        peer_observation.peer_ha_state.as_deref().unwrap(),
        peer_observation
            .peer_acked_asic_ha_state
            .as_deref()
            .unwrap(),
    );

    // A later normal heartbeat is answered from the regressed record.  This
    // demonstrates that the actor has no loopback/resend guard that repairs it.
    tokio::time::sleep(Duration::from_millis(1100)).await;
    let heartbeat = PeerHeartbeat::new_actor_msg(PEER_ID, LOCAL_ID).unwrap();
    dispatch(
        &mut local_actor,
        &mut local_state,
        &mut local_context,
        peer_sp,
        15001,
        &heartbeat,
    )
    .await;
    let heartbeat_reply = latest_scope_update(&local_state);
    let heartbeat_wire: HaScopeActorState = heartbeat_reply.deserialize_data().unwrap();
    assert_eq!(heartbeat_wire.new_state, HaState::Active.as_str_name());
    assert_eq!(heartbeat_wire.acked_asic_ha_state, "switching_to_active");
    let persisted = npu_state(&local_actor, &mut local_state);
    assert_eq!(
        persisted.local_acked_asic_ha_state.as_deref(),
        Some("switching_to_active")
    );
    assert_eq!(persisted.local_acked_term.as_deref(), Some("1"));

    println!(
        "MC1_PERSISTENCE heartbeat_cp={} heartbeat_ack={} stored_ack_term={}",
        heartbeat_wire.new_state,
        heartbeat_wire.acked_asic_ha_state,
        persisted.local_acked_term.as_deref().unwrap(),
    );
    println!("MC1_BUG_TRIGGERED LegalRolePair violated");
}
