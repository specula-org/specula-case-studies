//! Real HA-set route writer scenario, copied as a child of `ha_set.rs`.

use super::*;
use crate::actors::test::{
    make_dash_ha_global_config, make_dpu_scope_ha_set_config, make_local_dpu_actor_state,
    make_remote_dpu_actor_state, make_vdpu_actor_state,
};
use std::sync::Arc;
use swbus_edge::simple_client::SimpleSwbusEdgeClient;
use swbus_edge::swbus_proto::swbus::{ConnectionType, ServicePath};
use swbus_edge::SwbusEdgeRuntime;

struct TraceGuard;

impl TraceGuard {
    fn start() -> Self {
        swbus_actor::tla_trace::start_from_env();
        Self
    }
}

impl Drop for TraceGuard {
    fn drop(&mut self) {
        swbus_actor::tla_trace::finish();
    }
}

fn state() -> State {
    let edge = Arc::new(SwbusEdgeRuntime::new(
        "specula-route".to_string(),
        ServicePath::from_string("trace.local.none/hamgrd/0").unwrap(),
        ConnectionType::InNode,
    ));
    let client = Arc::new(SimpleSwbusEdgeClient::new(
        edge,
        ServicePath::from_string("trace.local.none/hamgrd/0/ha-set/haset0").unwrap(),
        true,
        false,
    ));
    State::new(client)
}

#[tokio::test]
async fn specula_trace_config_route_writer() {
    let _trace = TraceGuard::start();
    let mut state = state();

    let global = make_dash_ha_global_config();
    let global_kfv = KeyOpFieldValues {
        key: DashHaGlobalConfig::table_name().to_string(),
        operation: KeyOperation::Set,
        field_values: swss_serde::to_field_values(&global).unwrap(),
    };
    let global_msg = ActorMessage::new(DashHaGlobalConfig::table_name(), &global_kfv).unwrap();
    let source = ServicePath::from_string("trace.local.none/hamgrd/0/swss-common-bridge/global").unwrap();
    state
        .incoming()
        .handle_request(3001, source, &global_msg.serialize())
        .await
        .unwrap();

    let (ha_set_id, config) = make_dpu_scope_ha_set_config(0, 0);
    let mut actor = HaSetActor::new(ha_set_id).unwrap();
    actor.dash_ha_set_config = Some(config);

    let local_dpu = make_local_dpu_actor_state(0, 0, true, None, None);
    let remote_dpu = make_remote_dpu_actor_state(1, 0);
    let (local_id, local) = make_vdpu_actor_state(true, &local_dpu);
    let (remote_id, remote) = make_vdpu_actor_state(true, &remote_dpu);
    let vdpus = vec![
        VDpuStateExt {
            id: local_id,
            vdpu: local,
            is_primary: true,
        },
        VDpuStateExt {
            id: remote_id,
            vdpu: remote,
            is_primary: false,
        },
    ];

    // Two independent calls model a config refresh overwriting an already
    // queued candidate. Both calls execute the production serialization and
    // Outgoing enqueue path; only the producer apply is intentionally absent.
    for _ in 0..2 {
        let (_, incoming, outgoing) = state.get_all();
        actor
            .update_vnet_route_tunnel_table(&vdpus, incoming, outgoing, "Config")
            .await
            .unwrap();
    }
    assert_eq!(state.dump_state().outgoing.outgoing_queued.len(), 2);
}
