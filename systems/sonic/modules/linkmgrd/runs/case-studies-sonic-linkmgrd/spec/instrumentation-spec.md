# Instrumentation Spec: sonic-linkmgrd Active-Active

Maps TLA+ spec actions to source code locations for trace generation.

## 1. Trace Event Schema

### Event Envelope

```json
{
  "tag": "linkmgrd",
  "event": "<spec_action_name>",
  "tor": "<tor_id>",
  "ts": <timestamp_ns>,
  "state": { <state_fields> },
  "data": { <event_specific_fields> }
}
```

### State Fields (captured at every event)

| Implementation Field | TLA+ Variable | Getter/Access |
|---|---|---|
| `LinkProberStateMachineBase::getCurrentState()` | `subLpState` | `mLinkProberStateMachinePtr->getCurrentState()` |
| `MuxStateMachine::getCurrentState()` | `subMuxState` | `mMuxStateMachinePtr->getCurrentState()` |
| `LinkStateMachine::getCurrentState()` | `subLinkState` | `mLinkStateMachinePtr->getCurrentState()` |
| Composite LP component | `lpState` | `ps(getCompositeState())` |
| Composite Mux component | `muxState` | `ms(getCompositeState())` |
| Composite Link component | `linkState` | `ls(getCompositeState())` |
| `mPeerMuxState` | `peerMuxState` | `mPeerMuxState` member |
| `mPeerLinkProberState` | `peerLpState` | `mPeerLinkProberState` member |
| `mMuxProbeBackoffFactor` | `muxProbeBackoff` | `mMuxProbeBackoffFactor` member |
| `mDefaultRouteState` | `defaultRoute` | `mDefaultRouteState` member |
| `muxPortConfig.getMode()` | `mode` | `mMuxPortConfig.getMode()` |
| `mLastMuxStateNotification` | `lastMuxNotification` | `mLastMuxStateNotification` member |

### State Value Mapping

| Implementation Enum | TLA+ Value |
|---|---|
| `LinkProberState::Active` | `"active"` |
| `LinkProberState::Unknown` | `"unknown"` |
| `LinkProberState::Wait` | `"wait"` |
| `LinkProberState::PeerActive` | `"peer_active"` |
| `LinkProberState::PeerUnknown` | `"peer_unknown"` |
| `LinkProberState::PeerWait` | `"peer_wait"` |
| `MuxState::Active` | `"active"` |
| `MuxState::Standby` | `"standby"` |
| `MuxState::Unknown` | `"unknown"` |
| `MuxState::Error` | `"error"` |
| `MuxState::Wait` | `"wait"` |
| `LinkState::Up` | `"up"` |
| `LinkState::Down` | `"down"` |
| `DefaultRoute::OK` | `"ok"` |
| `DefaultRoute::NA` | `"na"` |
| `DefaultRoute::Wait` | `"wait"` |
| `Mode::Auto` | `"auto"` |
| `Mode::Active` | `"active"` |
| `Mode::Standby` | `"standby"` |
| `Mode::Detached` | `"detached"` |

## 2. Action-to-Code Mapping

### 2.1 External Stimulus Actions

#### HeartbeatActive

- **Spec action**: `HeartbeatActive(t)`
- **Code location**: `src/link_prober/LinkProberStateMachineBase.cpp:188-207`
- **Trigger point**: After `processEvent<IcmpSelfEvent>` completes and state transitions to Active
- **Trace event name**: `"HeartbeatActive"`
- **Fields**: `state.sub_lp_state`
- **Notes**: Only emit when state actually changes (not self-transition). The self-transition check is at line 202: `if (nextLinkProberState != currentLinkProberState)`.

#### HeartbeatUnknown

- **Spec action**: `HeartbeatUnknown(t)`
- **Code location**: `src/link_prober/LinkProberStateMachineBase.cpp:188-207`
- **Trigger point**: After `processEvent<IcmpUnknownEvent>` completes and state transitions to Unknown
- **Trace event name**: `"HeartbeatUnknown"`
- **Fields**: `state.sub_lp_state`
- **Notes**: Same self-transition check as HeartbeatActive.

#### PeerHeartbeatActive

- **Spec action**: `PeerHeartbeatActive(t)`
- **Code location**: `src/link_prober/LinkProberStateMachineBase.cpp:345-370` (peer event handler)
- **Trigger point**: After peer ICMP event processed, state transitions to PeerActive
- **Trace event name**: `"PeerHeartbeatActive"`
- **Fields**: `state.sub_lp_state`
- **Notes**: Peer heartbeat events use `IcmpPeerActiveEvent`.

#### PeerHeartbeatUnknown

- **Spec action**: `PeerHeartbeatUnknown(t)`
- **Code location**: `src/link_prober/LinkProberStateMachineBase.cpp:345-370`
- **Trigger point**: After peer ICMP event processed, state transitions to PeerUnknown
- **Trace event name**: `"PeerHeartbeatUnknown"`
- **Fields**: `state.sub_lp_state`
- **Notes**: Uses `IcmpPeerUnknownEvent`.

#### MuxNotification

- **Spec action**: `MuxNotification(t)`
- **Code locations**:
  1. `src/link_manager/LinkManagerStateMachineActiveActive.cpp:295-330` — `handleMuxStateNotification` (toggle response)
  2. `src/link_manager/LinkManagerStateMachineActiveActive.cpp:202-250` — `handleProbeMuxStateNotification` (probe response)
- **Trigger point**: After timer cancellation (line 307,310) and before `postMuxStateEvent` (line 321)
- **Trace event name**: `"MuxNotification"`
- **Fields**: `state.sub_mux_state`, `state.last_mux_notification`, `data.source` (toggle/probe)
- **Notes**: The notification source matters — `handleMuxStateNotification` and `handleProbeMuxStateNotification` have different code paths. Capture both with a `source` field.

#### LinkChange

- **Spec action**: `LinkChange(t)`
- **Code location**: `src/common/MuxPort.cpp:156-170` — `handleLinkState`
- **Trigger point**: After string-to-enum conversion (line 160), before posting to strand (line 165)
- **Trace event name**: `"LinkChange"`
- **Fields**: `state.sub_link_state`, `data.new_state`
- **Notes**: Capture both Up and Down transitions.

### 2.2 Event Processing

#### ProcessEvent

- **Spec action**: `ProcessEvent(t)`
- **Code locations**:
  1. `src/link_manager/LinkManagerStateMachineActiveActive.cpp:525-540` — `handleStateChange(LinkProberEvent)`
  2. `src/link_manager/LinkManagerStateMachineActiveActive.cpp:530-560` — `handleStateChange(MuxStateEvent)`
  3. `src/link_manager/LinkManagerStateMachineActiveActive.cpp:574-600` — `handleStateChange(LinkStateEvent)`
  4. `src/link_manager/LinkManagerStateMachineActiveActive.cpp:613-642` — `handlePeerStateChange`
- **Trigger point**: After transition handler completes (after `mStateTransitionHandler[ps][ms][ls](nextState)` returns)
- **Trace event name**: `"ProcessEvent"`
- **Fields**: `state.lp_state`, `state.mux_state`, `state.link_state`, `state.peer_mux_state`, `state.peer_lp_state`, `state.mux_probe_backoff`, `data.event_type` (lp/mux/link/peer_lp), `data.handler_name`
- **Notes**: This is the most important instrumentation point — captures the result of the transition table dispatch. The `event_type` field maps to `EvLP`/`EvMux`/`EvLink`/`EvPeerLP`. The `handler_name` field captures which transition function was called (or "noop" for unregistered states). Instrument all 4 code locations.

### 2.3 Timer Actions

#### MuxProbeTimeout

- **Spec action**: `MuxProbeTimeout(t)`
- **Code location**: `src/link_manager/LinkManagerStateMachineActiveActive.cpp:1235-1250` — `handleMuxProbeTimeout`
- **Trigger point**: At entry to handler (after error code check)
- **Trace event name**: `"MuxProbeTimeout"`
- **Fields**: `state.mux_probe_backoff`, `data.mux_state_at_expiry`
- **Notes**: The handler checks the error code first (line 1237). Only emit if `!errorCode`.

#### MuxWaitTimeout

- **Spec action**: `MuxWaitTimeout(t)`
- **Code location**: `src/link_manager/LinkManagerStateMachineActiveActive.cpp:1276-1290` — `handleMuxWaitTimeout`
- **Trigger point**: At entry to handler
- **Trace event name**: `"MuxWaitTimeout"`
- **Fields**: `data.wait_cause`
- **Notes**: Capture the wait cause (SwssUpdate/DriverUpdate) from `mWaitStateCause`.

#### PeerWaitTimeout

- **Spec action**: `PeerWaitTimeout(t)`
- **Code location**: `src/link_manager/LinkManagerStateMachineActiveActive.cpp:1314-1330` — `handlePeerMuxWaitTimeout`
- **Trigger point**: At entry to handler
- **Trace event name**: `"PeerWaitTimeout"`
- **Fields**: `data.last_set_peer_mux_state`

#### ResyncTimeout

- **Spec action**: `ResyncTimeout(t)`
- **Code location**: `src/link_manager/LinkManagerStateMachineActiveActive.cpp:464-474` — `handleAdminForwardingStateSyncUp`
- **Trigger point**: At entry to handler (after error code check)
- **Trace event name**: `"ResyncTimeout"`
- **Fields**: `data.wait_mux`
- **Notes**: The handler doesn't check the error code (bug — line 464-474). Emit unconditionally.

### 2.4 Environment Actions

#### DefaultRouteChange

- **Spec action**: `DefaultRouteChange(t)`
- **Code location**: `src/link_manager/LinkManagerStateMachineActiveActive.cpp:1337-1370` — `handleDefaultRouteStateNotification`
- **Trigger point**: After route state update (line 1343), before mode-specific logic
- **Trace event name**: `"DefaultRouteChange"`
- **Fields**: `state.default_route`, `data.old_route`, `data.new_route`
- **Notes**: Capture both old and new route state for transition tracking.

#### ModeChange

- **Spec action**: `ModeChange(t)`
- **Code location**: `src/link_manager/LinkManagerStateMachineActiveActive.cpp:266-293` — `handleMuxConfigNotification`
- **Trigger point**: After mode update (line 290), before switch logic
- **Trace event name**: `"ModeChange"`
- **Fields**: `state.mode`, `data.old_mode`, `data.new_mode`

### 2.5 Fault Injection

#### SoCRestart

- **Spec action**: `SoCRestart(t)`
- **Code location**: No single code location — this is an external event detected by heartbeat loss and gRPC disconnection
- **Trigger point**: When the system detects SoC restart (peer heartbeat transitions to PeerWait and admin forwarding state resets)
- **Trace event name**: `"SoCRestart"`
- **Fields**: `state.peer_mux_state`, `state.peer_lp_state`
- **Notes**: SoC restart is an emergent event — detect it via the resync timer activation at `startAdminForwardingStateSyncUpTimer()` (line 451-462). Alternatively, instrument the DbInterface notification path that triggers the resync.

## 3. Special Considerations

### 3.1 Strand Serialization and Event Ordering

All handlers run on the boost::asio strand, so events are serialized within a single port. However, `strand::wrap()` does NOT guarantee FIFO ordering for events posted from different threads (Family 1). The trace will show the actual processing order, which may differ from the posting order.

**Impact on instrumentation**: Events should be captured at the PROCESSING point (inside the strand handler), not at the POSTING point. This ensures the trace reflects the actual execution order.

### 3.2 Sub-SM State vs Composite State Timing

The sub-SM state changes BEFORE the event reaches the LinkManager composite state. When instrumenting:
- **Stimulus events** (HeartbeatActive, MuxNotification, etc.): capture `sub_*_state` fields (the sub-SM has already transitioned)
- **ProcessEvent**: capture `lp_state`, `mux_state`, `link_state` fields (the composite state has now been updated by the handler)

### 3.3 Self-Transition Events

When a sub-SM receives an event that doesn't change its state (self-transition), NO trace event should be emitted. The self-transition check is at:
- `LinkProberStateMachineBase.cpp:202`: `if (nextLinkProberState != currentLinkProberState)`
- `MuxStateMachine.cpp:176`: `if (nextMuxState != currentMuxState)`

Only emit the stimulus event if the state actually changed.

### 3.4 Multiple Code Paths for MuxNotification

The `MuxNotification` action maps to two different code paths:
1. `handleMuxStateNotification` — mux toggle response (from ycabled via orchagent)
2. `handleProbeMuxStateNotification` — mux probe response (from ycabled directly)

Both should emit the same `"MuxNotification"` event with a `data.source` field to distinguish them. Both cancel timers and update `lastMuxNotification`, but `handleProbeMuxStateNotification` also handles initialization logic (line 687: sets mux to Wait during init).

### 3.5 Event Queue is Not Directly Observable

The `eventQueue` variable in the spec models the strand event queue, which is internal to boost::asio. It cannot be directly instrumented. Instead, the trace captures:
1. When events are **posted** (stimulus actions)
2. When events are **processed** (ProcessEvent)

The spec's non-deterministic queue ordering handles the gap.

### 3.6 Timer Pending State

Timer pending state (`timerPending`) is not directly observable from outside the timer callback. Instrument timer starts (`startMuxProbeTimer`, `startMuxWaitTimer`, etc.) and timer expiry handlers. The spec infers pending state from the sequence of start/expiry events.

### 3.7 ToR Identification

Each event must include a `tor` field identifying which ToR the event belongs to. In the implementation, this maps to the MuxPort instance. Use the port name or a unique identifier.

### 3.8 Bootstrap State

The trace Init state should match:
- `lpState = LPWait`, `muxState = MuxWait`, `linkState = LinkDown`
- `defaultRoute = DrWait`, `mode = ModeAuto`
- `peerMuxState = MuxWait`, `peerLpState = LPPeerWait`

If the implementation starts with different initial values (e.g., after warm reboot), the TraceInit in `Trace.tla` may need adjustment.
