# dash-ha trace instrumentation

This is a Category A message-passing harness. `tla_trace.rs` owns one
`Mutex<Option<TraceState>>`, so all actor, bridge, producer, timer, and fault
events enter one ordered NDJSON stream. Tracing is disabled unless
`SPECULA_TRACE_FILE` is set. Every emitted row has a real Unix-nanosecond
timestamp, `"tag":"trace"`, and the complete `Trace.tla` post-state schema.

## Layout and application

- `src/tla_trace.rs`: synchronized writer, ID normalization, complete shadow
  state, and transition handling for all 51 `Trace.tla` events.
- `src/trace_scenarios.rs`: real NPU vote, switchover, and peer-timeout handler
  scenarios.
- `src/ha_set_trace_scenarios.rs`: real HA-set route serialization/enqueue
  scenario.
- `patches/instrumentation.patch`: production emit sites and Rust module wiring.
- `apply.sh`: idempotently applies the patch and copies the three Rust modules.
- `clean.sh`: reverses only this patch and removes only unchanged copied files.
- `run.sh`: applies, builds, runs four scenarios, checks NDJSON, and validates
  every trace with TLC.

`apply.sh` targets `/users/Pial/targets/sonic-dash-ha` by default. Pass another
source path as argument 1 or set `DASH_HA_SOURCE`. It never resets or cleans the
checkout and stops if an overlapping edit makes the patch ambiguous.

## Instrumentation points after apply

All calls are post-action captures. Dynamic classifiers at one emit site are
listed together.

| Source location | Event(s) |
|---|---|
| `crates/swss-common-bridge/src/consumer.rs:109-125` | `ConsumerBridgeConfigSet`, `ConsumerBridgeConfigDelete` |
| `crates/hamgrd/src/actors.rs:140-145` | `ActorCreatorHandleReceivedMessage` |
| `crates/swbus-actor/src/driver.rs:66-71` | `ActorDriverFinishDelete` |
| `crates/swbus-actor/src/driver.rs:102-107` | `ActorDriverHandleSetWhileDeleting` |
| `crates/swbus-actor/src/driver.rs:139-153` | `IncomingHandleRequest`, `ActorDriverHandleSwbusMessage` |
| `crates/swbus-actor/src/driver.rs:181-196` | `ActorDriverHandleActorMessage`, `ActorDriverCommitChanges` |
| `crates/hamgrd/src/actors/ha_set.rs:232-236` | `HaSetActorUpdateDashHaSetTable` |
| `crates/hamgrd/src/actors/ha_set.rs:372-376` | `HaSetComputeRouteFromScope`, `HaSetComputeRouteFromReplay`, `HaSetComputeRouteFromConfig` |
| `crates/hamgrd/src/actors/ha_set.rs:967-972` | `ActorRegistrationHandle` |
| `crates/hamgrd/src/actors/ha_set.rs:1062-1067` | `HaSetActorDoCleanup` |
| `crates/swbus-actor/src/state/outgoing.rs:57-69` | `OutgoingSendHaScopeState` |
| `crates/swbus-actor/src/state/outgoing.rs:142-160` | `ActorDriverSendQueuedHaSetWrite`, `ActorDriverSendQueuedHaSetState`, `ActorDriverSendQueuedScopeWrite`, `ActorDriverSendQueuedHaSetDelete` |
| `crates/swbus-actor/src/state/outgoing.rs:186-208` | `OutgoingHandleLateResponse`, `OutgoingHandleResponse` |
| `crates/swbus-actor/src/state/outgoing.rs:251-262` | `ActorDriverCleanupTimeout`, `OutgoingDropExpired` |
| `crates/swbus-actor/src/state/outgoing.rs:275-280` | `OutgoingDriveMaintenanceLoop` |
| `crates/swss-common-bridge/src/producer.rs:52-66` | `ProducerBridgeApplyHaSet`, `ProducerBridgeApplyHaSetDelete`, `ProducerBridgeApplyScope`, `ProducerBridgeApplyRoute` |
| `crates/hamgrd/src/actors/ha_scope/npu.rs:570-585` | `NpuHandleHaSetStateUpdateRePairResolved`, `NpuHandleHaSetStateUpdateRePairUnresolved` |
| `crates/hamgrd/src/actors/ha_scope/npu.rs:596-601` | `HaScopeHandleHaSetState` |
| `crates/hamgrd/src/actors/ha_scope/npu.rs:654-659` | `DpuAsicAcknowledgeRole` |
| `crates/hamgrd/src/actors/ha_scope/npu.rs:788-793` | `NpuHandleHaStateChange` |
| `crates/hamgrd/src/actors/ha_scope/npu.rs:931-942` | `NpuHandleVoteRequestRetry`, `NpuHandleVoteRequestFinal` |
| `crates/hamgrd/src/actors/ha_scope/npu.rs:1000-1021` | `NpuHandleSwitchoverFin`, `NpuHandleSwitchoverRst` |
| `crates/hamgrd/src/actors/ha_scope/npu.rs:1627-1632` | `NpuApplyRehydrationSideEffects` |
| `crates/hamgrd/src/actors/ha_scope/npu.rs:1653-1671` | `NpuDriveStateMachinePeerAck`, `NpuDriveStateMachine`, `ActorDriverSendQueuedAction` |
| `crates/hamgrd/src/actors/ha_scope/npu.rs:2089-2115` | `NpuCheckPeerConnectionAndRetry`, `NpuCheckPeerConnectionLost`, `NpuPeerConnectedReset` |
| `crates/hamgrd/src/actors/ha_scope/npu.rs:2353-2362` | `NpuUpdateDpuHaScopeTable` |
| `crates/hamgrd/src/actors/ha_scope/dpu.rs:184-189` | `DpuHandlePendingOperation` |
| `crates/hamgrd/src/actors/ha_scope/base.rs:496-501` | `NpuApprovePendingOperation` |
| `harness/src/tla_trace.rs:887-900` | Harness-controlled `Crash`, `Recover`, and `NetworkLoseAck` fault events |

The trace transition table is at `harness/src/tla_trace.rs:502-870`.
`NodeState::initial` mirrors `base.Init`; the writer updates its shadow and
serializes the snapshot while holding the same trace mutex. No event uses a
weak/reduced capture level.

## Initial scenario and event coverage

The checked-in traces cover these real production boundaries:

| Trace | Production behavior | Covered event types |
|---|---|---|
| `vote_retry.ndjson` | Undecided vote retries, then a decisive vote | `NpuHandleVoteRequestRetry`, `NpuHandleVoteRequestFinal` |
| `switchover_retry.ndjson` | RST retry, then FIN completion | `NpuHandleSwitchoverRst`, `NpuHandleSwitchoverFin` |
| `peer_timeout.ndjson` | Real heartbeat/self-notification retries and terminal peer loss | `NpuCheckPeerConnectionAndRetry`, `NpuCheckPeerConnectionLost` |
| `config_route.ndjson` | Two real route serialization/enqueue calls from config | `HaSetComputeRouteFromConfig` |

The remaining instrumented types have concrete emit sites but are not present
in the first isolated batch:

- Live Redis/SWBus actor and bridge lifecycle is required for
  `ConsumerBridgeConfigSet`, `ConsumerBridgeConfigDelete`,
  `ActorCreatorHandleReceivedMessage`, `ActorDriverHandleSwbusMessage`,
  `ActorDriverHandleSetWhileDeleting`, `ActorDriverHandleActorMessage`,
  `ActorDriverCommitChanges`, `HaSetActorUpdateDashHaSetTable`,
  `ActorDriverSendQueuedHaSetWrite`, `ActorDriverSendQueuedHaSetState`,
  `ProducerBridgeApplyHaSet`, `HaScopeHandleHaSetState`,
  `ActorRegistrationHandle`, `NpuUpdateDpuHaScopeTable`,
  `ActorDriverSendQueuedScopeWrite`, `ProducerBridgeApplyScope`,
  `HaSetActorDoCleanup`, `ActorDriverSendQueuedHaSetDelete`,
  `ProducerBridgeApplyHaSetDelete`, `ActorDriverFinishDelete`, and
  `ActorDriverCleanupTimeout`.
- A live peer/transport plus ACK interception or timer aging is required for
  `OutgoingSendHaScopeState`, `IncomingHandleRequest`,
  `NpuHandleHaStateChange`, `OutgoingHandleResponse`,
  `OutgoingHandleLateResponse`, `NetworkLoseAck`,
  `OutgoingDriveMaintenanceLoop`, `OutgoingDropExpired`,
  `NpuHandleHaSetStateUpdateRePairResolved`,
  `NpuHandleHaSetStateUpdateRePairUnresolved`, and
  `NpuDriveStateMachinePeerAck`.
- Persisted Redis state, a managed vDPU, DPU state notifications, or process
  task control is required for `NpuDriveStateMachine`,
  `ActorDriverSendQueuedAction`, `Crash`, `Recover`,
  `NpuApplyRehydrationSideEffects`, `DpuHandlePendingOperation`,
  `NpuApprovePendingOperation`, and `DpuAsicAcknowledgeRole`.
- Scope-cache arrival/replay and a running producer bridge are required for
  `HaSetComputeRouteFromScope`, `HaSetComputeRouteFromReplay`, and
  `ProducerBridgeApplyRoute`.
- A successful connection after a nonzero retry budget is required for
  `NpuPeerConnectedReset`.

The focused tests use `SPECULA_TRACE_EVENTS` allowlists so unrelated hooks do
not weaken or perturb a scenario. Add a live-service scenario before claiming
coverage for any event above.

## Adjusting the harness

To add a state field, add it to `NodeState` and `NodeState::initial` in
`src/tla_trace.rs`, update it in the appropriate `apply_event` match arm, and
add the exact camelCase field to `Trace.tla` validation. Global fields belong
to `TraceState`/`PostState`. Do not add captured data without a corresponding
TLA+ check.

To add an event type, add one `apply_event` arm, insert one post-action
`tla_trace::emit` in the real code path, and add the exact event to a scenario's
`SPECULA_TRACE_EVENTS` list in `run.sh`. Message and UUID values should enter as
`requestIdRaw`/`operationIdRaw`; the trace module maps them into bounded TLA+
IDs while holding the writer lock.

To move a capture point, keep it after the named production mutation or await,
and before the next modeled boundary. For nested state-machine effects, retain
the order `NpuDriveStateMachine[PeerAck]` followed by its observed
`ActorDriverSendQueuedAction` completions.

From `.specula-output`, rebuild and validate everything with:

```bash
bash harness/run.sh
```

Optional controls are `DASH_HA_SOURCE`, `SWSS_COMMON_REPO`, and
`SPECULA_HOME`. `run.sh` wraps the build, every test, dependency provisioning,
and every TLC invocation in timeouts. It also checks event sets, line counts,
timestamps, the full post envelope, and TLC L2 post-state validation.
