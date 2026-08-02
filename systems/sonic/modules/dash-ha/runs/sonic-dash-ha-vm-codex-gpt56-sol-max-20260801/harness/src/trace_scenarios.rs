//! Focused real-code scenarios for retry-counter trace boundaries.
//!
//! Copied as a child module of `actors::ha_scope`, which lets the tests call
//! the private production handlers without duplicating their logic.

use super::base::HaScopeBase;
use super::npu::NpuHaScopeActor;
use crate::ha_actor_messages::{MessageMetaFlags, SwitchoverRequest, VoteRequest};
use std::sync::Arc;
use swbus_actor::{ActorMessage, Context, State};
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

struct Fixture {
    actor: NpuHaScopeActor,
    state: State,
    context: Context,
    source: ServicePath,
}

fn fixture() -> Fixture {
    let base_sp = ServicePath::from_string("trace.local.none/hamgrd/0").unwrap();
    let edge = Arc::new(SwbusEdgeRuntime::new(
        "specula-trace".to_string(),
        base_sp,
        ConnectionType::InNode,
    ));
    let actor_sp = ServicePath::from_string("trace.local.none/hamgrd/0/ha-scope/vdpu0:haset0").unwrap();
    let client = Arc::new(SimpleSwbusEdgeClient::new(edge.clone(), actor_sp, true, false));
    let state = State::new(client);
    let context = Context::new(edge);
    let source = ServicePath::from_string("trace.peer.none/hamgrd/0/ha-scope/vdpu1:haset0").unwrap();
    let base = HaScopeBase::new("vdpu0:haset0".to_string()).unwrap();
    Fixture {
        actor: NpuHaScopeActor::new(base),
        state,
        context,
        source,
    }
}

async fn receive(fixture: &mut Fixture, request_id: u64, message: ActorMessage) -> String {
    fixture
        .state
        .incoming()
        .handle_request(request_id, fixture.source.clone(), &message.serialize())
        .await
        .unwrap()
}

#[tokio::test]
async fn specula_trace_vote_retry_and_final() {
    let _trace = TraceGuard::start();
    let mut fixture = fixture();

    // With no persisted local state/config, the production handler reaches
    // its undecided RetryLater branch and consumes the shared budget.
    let retry = VoteRequest::new_actor_msg(
        "vdpu1:haset0",
        "vdpu0:haset0",
        "0",
        "HA_STATE_DEAD",
        "DESIRED_HA_STATE_UNSPECIFIED",
    )
    .unwrap();
    let retry_key = receive(&mut fixture, 1001, retry).await;
    fixture.actor.handle_vote_request(&mut fixture.state, &retry_key);
    assert_eq!(fixture.actor.retry_count, 1);

    // A peer with explicit Active preference drives the production final
    // decision branch, which resets the same implementation counter.
    let final_request = VoteRequest::new_actor_msg(
        "vdpu1:haset0",
        "vdpu0:haset0",
        "0",
        "HA_STATE_DEAD",
        "DESIRED_HA_STATE_ACTIVE",
    )
    .unwrap();
    let final_key = receive(&mut fixture, 1002, final_request).await;
    fixture.actor.handle_vote_request(&mut fixture.state, &final_key);
    assert_eq!(fixture.actor.retry_count, 0);
}

#[tokio::test]
async fn specula_trace_switchover_retry_and_final() {
    let _trace = TraceGuard::start();
    let mut fixture = fixture();

    let rejected = SwitchoverRequest::new_actor_msg(
        "vdpu1:haset0",
        "vdpu0:haset0",
        "real-switchover-uuid",
        MessageMetaFlags::Rst,
    )
    .unwrap();
    let rejected_key = receive(&mut fixture, 2001, rejected).await;
    fixture
        .actor
        .handle_switchover_request(&mut fixture.state, &rejected_key)
        .unwrap();
    assert_eq!(fixture.actor.retry_count, 1);

    let accepted = SwitchoverRequest::new_actor_msg(
        "vdpu1:haset0",
        "vdpu0:haset0",
        "real-switchover-uuid",
        MessageMetaFlags::Fin,
    )
    .unwrap();
    let accepted_key = receive(&mut fixture, 2002, accepted).await;
    fixture
        .actor
        .handle_switchover_request(&mut fixture.state, &accepted_key)
        .unwrap();
    assert_eq!(fixture.actor.retry_count, 0);
}

#[tokio::test]
async fn specula_trace_peer_connection_timeout() {
    let _trace = TraceGuard::start();
    let mut fixture = fixture();

    // These are the real maintenance handler calls. With no peer configured,
    // resolution/heartbeat return their normal retryable errors while the
    // self-notification is queued by production Outgoing state.
    for expected in 1..=2 {
        let event = fixture
            .actor
            .check_peer_connection_and_retry(&mut fixture.state, &mut fixture.context)
            .await
            .unwrap();
        assert_eq!(event, super::HaEvent::None);
        assert_eq!(fixture.actor.retry_count, expected);
    }

    // Production uses a limit of three while Trace.cfg intentionally bounds
    // counters at two. Set up the real terminal branch directly, as a boundary
    // unit test would, then let the handler perform/reset the operation.
    fixture.actor.retry_count = super::MAX_RETRIES;
    let event = fixture
        .actor
        .check_peer_connection_and_retry(&mut fixture.state, &mut fixture.context)
        .await
        .unwrap();
    assert_eq!(event, super::HaEvent::PeerLost);
    assert_eq!(fixture.actor.retry_count, 0);
}
