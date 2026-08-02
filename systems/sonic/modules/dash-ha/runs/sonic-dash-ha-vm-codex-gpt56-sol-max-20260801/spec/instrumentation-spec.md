# dash-ha instrumentation specification

This document is the handoff from the TLA+ model to the trace harness. It is
normative for event names, capture timing, and field names consumed by
`Trace.tla`.

## 1. Trace event schema

### 1.1 Envelope

Write one compact NDJSON object after each modeled step:

```json
{
  "tag": "trace",
  "event": {
    "name": "ActorDriverHandleSwbusMessage",
    "node": "n1",
    "epoch": 2,
    "post": {
      "nodeState": {},
      "pendingRoleWrites": [],
      "haOwner": "Switch",
      "routeCandidate": "n1",
      "routeCandidateEpoch": 1,
      "routeCandidateTerm": 1,
      "routePending": false,
      "routeOwner": "n1",
      "routeEpoch": 1,
      "routeTerm": 1,
      "lastRouteWriter": "ScopeState",
      "messages": [],
      "ackPending": [],
      "inbox": {}
    }
  }
}
```

`node` is the modeled NPU/HA-scope participant (`n1` or `n2`). Global HA-set
events still provide the node whose HA-set actor emitted the event; their trace
wrapper ignores the node projection but trace loading requires the field.

All captures are **post-action** captures. Emit only after the operation named
in the trigger column has completed, but before the next modeled boundary.
Serialize through one ordered trace sink so file order is the observed global
order across actor, bridge, producer, DPU-state, and lifecycle tasks.

### 1.2 Common `post.nodeState` fields

Every node event captures every field below. `Trace.tla` checks all of them;
none is optional or conditionally ignored.

| Group | Exact JSON fields | Implementation/shadow source |
|---|---|---|
| Effect pipeline | `processUp`, `accepted`, `actorApplied`, `actorCommitted`, `haSetIssued`, `haSetApplied`, `prereqReady`, `scopeIssued`, `scopeApplied` | Harness process state plus hooks in `driver.rs:76-164`, `ha_set.rs:180-225`, `producer.rs:28-70`, and `npu.rs:2172-2215`; epochs are monotonically assigned shadow config epochs |
| Queued HA-set/scope work | `queuedHaSetWrite`, `queuedHaSetState`, `haSetStateInFlight`, `producerHaSetPending`, `queuedScopeWrite`, `queuedScopeRole`, `queuedScopeTerm`, `queuedScopePairEpoch`, `producerScopePending`, `producerScopeRole`, `producerScopeTerm`, `producerScopePairEpoch` | Shadow entries updated at `Outgoing::send`, `send_queued_messages`, and producer apply hooks; use `0` for no epoch and `"None"` for no role |
| Local protocol/ASIC | `cpState`, `asicRole`, `ackedRole`, `term`, `ackedTerm`, `ackedPairEpoch` | `NpuDashHaScopeState.local_ha_state`, target term, DPU `ha_role`/`ha_term`, plus pair-epoch provenance shadow updated when the DPU request is issued/acked |
| Peer relationship/cache | `currentPeer`, `pairEpoch`, `peerConnected`, `lastPeerEvent`, `peerGeneration`, `maxPeerGeneration`, `peerTerm`, `peerCachedState`, `peerCachedAckRole`, `peerCachedOwner`, `peerCacheEpoch`, `peerCacheSource`, `foreignApplied` | `HaScopeBase.peer_vdpu_id`, `NpuHaScopeActor.peer_connected`, persisted peer fields, and harness shadows. Increment `pairEpoch` on each re-pair; stamp receipt with source/epoch provenance even though production messages omit it |
| Transition authorization | `transitionAuthorized`, `authorizationTerm`, `authorizationEpoch` | Shadow set exactly when cached peer ACK/state enables a branch in `next_state`; retain as history |
| Recovery/intent | `persistedPhase`, `durableIntent`, `queuedActions`, `completedActions`, `rehydrationNeeded` | Persisted `local_ha_state`/target role, `NpuHaScopeActor.rehydration_needed`, and shadow action sets updated at the transition/commit/send/rehydration hooks |
| Pending operation | `pendingFlagEpoch`, `cachedPendingFlagEpoch`, `pendingOps` | DPU pending flags, cached `dpu_ha_scope_state`, and persisted pending UUID/type lists. `pendingOps` is an array of `{"id": <int>, "epoch": <int>}` shadow records |
| Actor/config lifecycle | `configPresent`, `configEpoch`, `bridgeCacheEpoch`, `configDeliveryPending`, `actorPhase`, `exactRouteEpoch`, `registrations`, `parentCacheEpoch`, `ignoredSet`, `queuedHaSetDelete`, `producerHaSetDeletePending` | Consumer cache/config-row shadow; ActorCreator/Driver lifecycle; incoming registration entries; cached HaSetActorState provenance; deletion queue hooks |
| Shared retry | `sharedRetry`, `retryByProtocol`, `retryIsolationBroken`, `peerLost` | Actual `NpuHaScopeActor.retry_count`; `retryByProtocol` is a JSON object with keys `Connect`, `Vote`, `Switchover`; the last two fields are harness history shadows |

Set-valued fields `durableIntent`, `queuedActions`, and `completedActions` are
JSON arrays of action strings. `pendingOps` is an array of records. Array order
is irrelevant because `Trace.tla` converts each array to a set.

### 1.3 Common shared `post` fields

| Exact JSON field | Shape and source |
|---|---|
| `pendingRoleWrites` | Array of `{"node", "epoch", "term", "role"}` records, maintained from scope producer apply until the corresponding DPU state ACK |
| `haOwner` | `"Switch"` or `"Dpu"`, from the HA-set actor's current owner |
| `routeCandidate`, `routeCandidateEpoch`, `routeCandidateTerm`, `routePending` | Shadow of the most recent route computation and queued producer state |
| `routeOwner`, `routeEpoch`, `routeTerm`, `lastRouteWriter` | Last route applied by the producer; writer is `None`, `Config`, `ScopeState`, or `Replay` |
| `messages` | Array of retained message records with exact fields `id`, `kind`, `sourcePeer`, `destination`, `epoch`, `generation`, `term`, `peerState`, `ackedRole`, `owner`, `age` |
| `ackPending` | Array of integer request IDs for responses in flight |
| `inbox` | Receiver's current message record, or the exact homogeneous sentinel `{ "id":0, "kind":"HaScopeState", "sourcePeer":"NoPeer", "destination":"NoOwner", "epoch":0, "generation":0, "term":0, "peerState":"Dead", "ackedRole":"None", "owner":"NoOwner", "age":0 }` |

The harness may keep these as explicit shadow structures. Update the shadow and
capture while holding the trace-state mutex; do not derive a snapshot later
from logs, because the next async stage may already have changed it.

### 1.4 Action-specific fields

In addition to `name`, `node`, and `post`, emit these fields where listed:

| Field | Used by events |
|---|---|
| `epoch` | `ConsumerBridgeConfigSet`, `DpuHandlePendingOperation` |
| `requestId` | send/receive/response/loss/retry/expiry message events |
| `sourcePeer`, `generation`, `peerState`, `ackedRole`, `owner` | `OutgoingSendHaScopeState` |
| `write` | `DpuAsicAcknowledgeRole`; exact role-write record |
| `nextState` | `NpuDriveStateMachine` |
| `action` | `ActorDriverSendQueuedAction` |
| `operationId` | pending-operation create/approve events |

## 2. Action-to-code mapping

Every row is one spec action and one trace event type. “Common post” means the
complete schema in §§1.2-1.3, not a reduced snapshot.

### 2.1 Acceptance, actor lifecycle, and effect pipeline

| Spec action / event name | Code location | Trigger point | Extra fields | Notes |
|---|---|---|---|---|
| `ConsumerBridgeConfigSet` | `crates/swss-common-bridge/src/consumer.rs:75-102` | After `swbus.send(...).await` returns for a changed SET | `epoch` | Advance bridge/config shadow before capture |
| `ActorCreatorHandleReceivedMessage` | `crates/hamgrd/src/actors.rs:194-274` | After `spawn(actor, ...)` and immediately before/after forwarding the original SET at `run:137-143` as one creator step | — | Exact route exists and `accepted` reflects the forwarded row |
| `ActorDriverHandleSwbusMessage` | `crates/swbus-actor/src/driver.rs:76-129` | After transport response send at line 125, before callback dispatch at line 127 | — | Normal live-actor branch only |
| `ActorDriverHandleSetWhileDeleting` | `crates/swbus-actor/src/driver.rs:82-97` | After ignored-request OK response returns, immediately before `return` | — | Do not emit the normal request event for this branch |
| `ActorDriverHandleActorMessage` | `crates/swbus-actor/src/driver.rs:146-164` | Immediately before awaiting `actor.handle_message` at line 148 | — | Marks callback dispatch so nested actor events follow it in trace order |
| `HaSetActorUpdateDashHaSetTable` | `crates/hamgrd/src/actors/ha_set.rs:180-225` | After producer SET and all HaSetActorState messages have been queued, before return | — | Updates issued and both queued shadows, not applied state |
| `ActorDriverCommitChanges` | `crates/swbus-actor/src/driver.rs:146-153` | After `internal.commit_changes().await` returns, before `send_queued_messages` | — | Snapshot persisted phase/intent here |
| `ActorDriverSendQueuedHaSetWrite` | `crates/swbus-actor/src/state/outgoing.rs:75-105` | After `send_raw` and insertion into `unacked_messages` for `DashHaSetTable` | — | Classify by destination table/message payload |
| `ActorDriverSendQueuedHaSetState` | `crates/swbus-actor/src/state/outgoing.rs:75-105`; `ha_set.rs:214-225` | After `send_raw` and retention for an `HaSetActorState` | — | Independent event even when adjacent in the same drain loop |
| `ProducerBridgeApplyHaSet` | `crates/swss-common-bridge/src/producer.rs:40-70` | After `table.apply_kfv(kfv).await` for `DashHaSetTable`, before response send | — | `haSetApplied` changes here |
| `HaScopeHandleHaSetState` | `crates/hamgrd/src/actors/ha_scope/npu.rs:492-585`; `base.rs:111-123` | After caching/decoding the HaSetActorState and before driving the NPU state machine | — | Stamp `parentCacheEpoch` from message provenance |
| `ActorRegistrationHandle` | `crates/hamgrd/src/ha_actor_messages.rs:267-279`; `actors/ha_set.rs:893-938` | After the active registration is installed/handled | — | Registration table is volatile |
| `NpuUpdateDpuHaScopeTable` | `crates/hamgrd/src/actors/ha_scope/npu.rs:2172-2215` | After `outgoing.send` queues the `DashHaScopeTable` SET | — | Capture role, term, and pair epoch of the queued write |
| `ActorDriverSendQueuedScopeWrite` | `crates/swbus-actor/src/state/outgoing.rs:75-105` | After send/retention of `DashHaScopeTable` request | — | Moves queued metadata into producer-pending shadow |
| `ProducerBridgeApplyScope` | `crates/swss-common-bridge/src/producer.rs:40-70` | After scope `apply_kfv`, before producer response | — | Add exact role write to `pendingRoleWrites` |
| `DpuAsicAcknowledgeRole` | `crates/hamgrd/src/actors/ha_scope/npu.rs:588-632` | After lines 610-617 update acked role/term and DPU cache, before later state-machine work | `write` | Match ACK to the oldest/exact outstanding shadow write selected by observed role/term |
| `ConsumerBridgeConfigDelete` | `crates/swss-common-bridge/src/consumer.rs:75-102`; `ha_set.rs:780-788` | After sending a changed DEL toward the actor | — | Preserve current epoch; set row absent/delivery pending |
| `HaSetActorDoCleanup` | `crates/hamgrd/src/actors/ha_set.rs:1005-1026` | After `do_cleanup` has queued deletions/unregistration, before `context.stop` takes effect | — | Do not invalidate child parent cache |
| `ActorDriverSendQueuedHaSetDelete` | `crates/swbus-actor/src/state/outgoing.rs:75-105`; `ha_set.rs:229-248` | After send/retention of parent-table DEL | — | Separate from producer apply |
| `ProducerBridgeApplyHaSetDelete` | `crates/swss-common-bridge/src/producer.rs:40-70` | After applying `DashHaSetTable` DEL, before response | — | Set `haSetApplied` to zero |
| `ActorDriverFinishDelete` | `crates/swbus-actor/src/driver.rs:57-73` | Immediately before breaking the run loop at lines 61-66 | — | Drop exact-route shadow here |
| `ActorDriverCleanupTimeout` | `crates/swbus-actor/src/state/outgoing.rs:143-180` | After the retention pass removes expired unacked work | — | Only empties pending deletion work; `ActorDriverFinishDelete` is the later termination event |

### 2.2 At-least-once network and re-pair

| Spec action / event name | Code location | Trigger point | Extra fields | Notes |
|---|---|---|---|---|
| `OutgoingSendHaScopeState` | `crates/hamgrd/src/actors/ha_scope/npu.rs:1852-1890`; `outgoing.rs:37-46` | After queuing the peer `HaScopeActorState` with its generated request ID | `requestId`, `sourcePeer`, `generation`, `peerState`, `ackedRole`, `owner` | Stamp current pair epoch as provenance only; it is not added to production wire data |
| `IncomingHandleRequest` | `crates/swbus-actor/src/state/incoming.rs:49-72`; `driver.rs:105-125` | After incoming-table replacement and transport response enqueue/send, before actor callback | `requestId` | Copy the full message into inbox shadow |
| `NpuHandleHaStateChange` | `crates/hamgrd/src/actors/ha_scope/npu.rs:708-746` | After peer fields and `peer_connected`/event classification are updated | — | Update max-generation and foreign-provenance history shadows |
| `OutgoingHandleResponse` | `crates/swbus-actor/src/state/outgoing.rs:118-140` | After an OK removes a live unacked entry | `requestId` | Existing-ID branch only |
| `OutgoingHandleLateResponse` | `crates/swbus-actor/src/state/outgoing.rs:126-129` | Immediately before returning for a response whose ID is absent | `requestId` | Consumes only ACK-in-flight shadow |
| `NetworkLoseAck` | Transport fault hook between `driver.rs:114-125` and `outgoing.rs:118-140` | When the harness deliberately discards an emitted response | `requestId` | Harness-orchestrated fault; no production code change beyond hook |
| `OutgoingDriveMaintenanceLoop` | `crates/swbus-actor/src/state/outgoing.rs:143-180` | After resending one retained message | `requestId` | Increment bounded shadow `age`; content/ID unchanged |
| `OutgoingDropExpired` | `crates/swbus-actor/src/state/outgoing.rs:167-169` | Immediately after one retained ID is removed by expiry | `requestId` | Late ACK may remain independently in flight |
| `NpuHandleHaSetStateUpdateRePairResolved` | `crates/hamgrd/src/actors/ha_scope/npu.rs:539-550` | After new peer ID/path is installed on successful resolution | — | Increment pair epoch; preserve cache, messages, and connection flag |
| `NpuHandleHaSetStateUpdateRePairUnresolved` | `crates/hamgrd/src/actors/ha_scope/npu.rs:539-556` | After failure branch clears `peer_connected` and queues retry | — | Separate event because branch state differs |
| `NpuDriveStateMachinePeerAck` | `crates/hamgrd/src/actors/ha_scope/npu.rs:1374-1383,1685-1708,1776-1818` | After the peer-ACK-driven branch updates CP phase/queues effects | — | Store authorization term/epoch provenance used by the branch |

### 2.3 State machine, crash recovery, and pending operations

| Spec action / event name | Code location | Trigger point | Extra fields | Notes |
|---|---|---|---|---|
| `NpuDriveStateMachine` | `crates/hamgrd/src/actors/ha_scope/npu.rs:1486-1555,1600-1849` | After `apply_pending_state_side_effects`, local phase update, and broadcast queuing, before ActorDriver commit | `nextState` | Increment term shadow only for modeled Active/Standalone entry |
| `ActorDriverSendQueuedAction` | `crates/swbus-actor/src/driver.rs:151-153`; `npu.rs:1355-1480` | After one non-role queued phase action is sent/completed | `action` | `ActivateRole` instead uses the scope-write events above |
| `Crash` | Harness process-control hook around HAMgrD actor tasks; recovery evidence `npu.rs:462-476` | After process/task stop and volatile queue/cache clearing | — | Retain monotone acceptance/application history and already-sent producer/network work |
| `Recover` | `crates/swbus-actor/src/runtime.rs:17-25`; `npu.rs:462-478` | After actor route recreation and persisted phase load, before rehydration effects | — | Registrations and parent cache remain absent |
| `NpuApplyRehydrationSideEffects` | `crates/hamgrd/src/actors/ha_scope/npu.rs:1261-1352` | After the persisted-phase match queues all implemented recovery effects | — | Capture omitted required actions as absent, not as completed |
| `DpuHandlePendingOperation` | `crates/hamgrd/src/actors/ha_scope/dpu.rs:146-181` | After new UUID insertion into pending operations | `epoch`, `operationId` | Assign/retain DPU flag epoch in harness shadow |
| `NpuApprovePendingOperation` | `crates/hamgrd/src/actors/ha_scope/base.rs:445-485` | After named UUID removal and internal state update | `operationId` | Clear flag shadow only when last operation for it is gone |

### 2.4 Route writers

| Spec action / event name | Code location | Trigger point | Extra fields | Notes |
|---|---|---|---|---|
| `HaSetComputeRouteFromScope` | `crates/hamgrd/src/actors/ha_set.rs:512-526,576-650,961-994` | After scope-state selection queues a VNET route SET | — | Writer=`ScopeState`; node is selected owner |
| `HaSetComputeRouteFromConfig` | `crates/hamgrd/src/actors/ha_set.rs:427-465,774-858` | After a non-first config refresh queues its VNET route SET | — | Writer=`Config`; include emitter node in envelope |
| `HaSetComputeRouteFromReplay` | `crates/hamgrd/src/actors/ha_set.rs:512-526,576-650` | After an arrival-ordered cached state queues a route | — | Writer=`Replay`; node is cache receiver/source context |
| `ProducerBridgeApplyRoute` | `crates/swss-common-bridge/src/producer.rs:40-70`; `ha_set.rs:331-353` | After applying `VnetRouteTunnelTable`, before response | — | Move candidate/epoch/term to applied route fields |

### 2.5 Shared retry workflows

| Spec action / event name | Code location | Trigger point | Extra fields | Notes |
|---|---|---|---|---|
| `NpuHandleVoteRequestRetry` | `crates/hamgrd/src/actors/ha_scope/npu.rs:816-876` | Immediately after a RetryLater branch increments `retry_count` | — | Increment Vote comparison counter |
| `NpuHandleVoteRequestFinal` | `crates/hamgrd/src/actors/ha_scope/npu.rs:878-881` | Immediately after non-RetryLater reset | — | Reset Vote comparison; mark interference if another counter was live |
| `NpuHandleSwitchoverRst` | `crates/hamgrd/src/actors/ha_scope/npu.rs:925-955` | After RST retry increments shared count | — | Increment Switchover comparison counter |
| `NpuHandleSwitchoverFin` | `crates/hamgrd/src/actors/ha_scope/npu.rs:931-937` | After FIN resets shared count | — | Reset Switchover comparison; retain interference history |
| `NpuCheckPeerConnectionAndRetry` | `crates/hamgrd/src/actors/ha_scope/npu.rs:1947-1968` | After increment, heartbeat queue, and self-notification queue | — | Increment Connect comparison counter |
| `NpuCheckPeerConnectionLost` | `crates/hamgrd/src/actors/ha_scope/npu.rs:1969-1974` | After terminal reset and `PeerLost` result selection | — | Mark premature loss when local Connect count was not exhausted |
| `NpuPeerConnectedReset` | `crates/hamgrd/src/actors/ha_scope/npu.rs:1975-1978` | After connected branch resets count | — | Complete Connect comparison and record cross-protocol reset |

## 3. Special considerations

### 3.1 Exact one-to-one event discipline

- Emit exactly one listed event for each represented action and no alternate
  event name for the same step.
- Do not coalesce acceptance, callback dispatch, commit, queue drain, producer
  apply, and DPU ACK. Those are intentionally different actions.
- A loop draining two queued messages emits two events at the per-message hook.
- Resolved and unresolved re-pair paths, normal and deleting actor requests,
  and live-ID and late response paths are distinct events.

### 3.2 Shadow state is intentional

Pair epochs, generation maxima, authorization provenance, per-protocol retry
counters, last route writer, and pipeline epochs do not all exist as production
fields. They are observation-only harness shadows motivated by the brief. They
must never influence HAMgrD behavior. Update them atomically with the production
step and include them in `post`.

Map production UUIDs and SWBus request IDs deterministically to the bounded
integer domains in `Trace.cfg` for each trace. Preserve equality: the same real
ID must map to the same integer for the whole trace, and different live IDs must
not collide.

### 3.3 Bootstrap and trace size

Start capture only after the epoch-1 bootstrap represented by `base.Init`:
both actors live and registered, parent/scope tables applied, preferred node
ASIC-acked Active, other node ASIC-acked Standby, and preferred route applied.
Reset all shadow histories to the exact Init values before the first event.

Keep traces short and scenario-focused (roughly 50-300 events). The configured
bounds are `MaxEpoch=2`, `MaxGeneration=2`, three request IDs, three operation
IDs, message age two, and retry limit two; terminate or rotate a trace before a
mapped value would exceed those domains.

### 3.4 Serialization and zero values

Do not omit false, zero, empty-array, `"None"`, `"NoOwner"`, or `"NoPeer"`
fields. `Trace.tla` uses direct field access and intentionally does not make
post-state validation conditional. Preserve the exact camelCase names above.
