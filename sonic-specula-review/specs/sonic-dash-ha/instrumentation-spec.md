# Instrumentation Spec: sonic-dash-ha

Maps TLA+ spec actions to source code locations for trace harness generation.

## 1. Trace Event Schema

### Event Envelope

```json
{
  "tag": "ha",
  "event": "<spec_action_name>",
  "node": "<node_id>",
  "ha_state": "<current_ha_state>",
  "term": <current_term>,
  "desired_state": "<desired_ha_state>",
  "ts": <timestamp_ms>,
  ...event-specific fields...
}
```

### State Fields (captured at every event)

| Implementation Field | TLA+ Variable | Getter |
|---|---|---|
| `DpuDashHaScopeState.ha_state` | `haState[n]` | `get_dpu_ha_scope_state()` (ha_scope.rs:89-106) |
| `DpuDashHaScopeState.ha_term` | `haTerm[n]` | `get_dpu_ha_scope_state()` (ha_scope.rs:89-106) |
| `HaScopeConfig.desired_ha_state` | `desiredState[n]` | `dash_ha_scope_config` field (ha_scope.rs:478) |
| `DpuActorState.up` | `dpuUp[n]` | `calculate_dpu_state()` (dpu.rs:235-269) |

### Message Fields (event-specific)

| Implementation Field | TLA+ Message Field | Used By |
|---|---|---|
| `RequestVote.term` | `m.term` | HandleRequestVote |
| `RequestVote.desired_state` | `m.desired` | HandleRequestVote |
| `VoteResponse.response` | `m.response` | HandleVoteResponse |
| `VoteResponse.term` | `m.term` | HandleVoteResponse |
| `HAStateChanged.new_state` | `m.newState` | CompleteSwitchoverToActive/Standby, HandlePeerDestroying |
| `HAStateChanged.new_term` | `m.newTerm` | CompleteSwitchoverToActive/Standby |
| `BulkSyncDone.term` | `m.term` | HandleBulkSyncDone |

## 2. Action-to-Code Mapping

### StartConnecting

- **Spec action**: `StartConnecting(n)`
- **Code location**: `ha_scope.rs:539-580` — `handle_vdpu_state_update()`
- **Trigger point**: After `vdpu_is_managed()` check succeeds and consumer bridge created (line 560)
- **Event name**: `start_connecting`
- **Fields**: `ha_state`, `term`, `desired_state`, `dpu_up`
- **Notes**: First vDPU state update triggers lazy initialization. Only fires once (first time `vdpu_is_managed()` returns true).

### BecomeConnected

- **Spec action**: `BecomeConnected(n)`
- **Code location**: Not yet implemented in code (Family 4 — spec-first)
- **Trigger point**: After BFD probe confirms peer reachability
- **Event name**: `become_connected`
- **Fields**: `ha_state`, `term`
- **Notes**: Currently no code path — the HLD describes this as "Connected to peer" transition. Instrument when PR #145 or successor implements peer discovery.

### SendRequestVote

- **Spec action**: `SendRequestVote(n)`
- **Code location**: Not yet implemented (Family 4 — HLD Section 7.3)
- **Trigger point**: Before sending RequestVote message via HA control channel
- **Event name**: `send_request_vote`
- **Fields**: `ha_state`, `term`, `desired_state`
- **Notes**: Currently uses config-driven `preferred_vdpu_id` (ha_set.rs:346-358). Instrument when election protocol is implemented per #77.

### HandleRequestVote

- **Spec action**: `HandleRequestVote(n)`
- **Code location**: Not yet implemented (Family 4 — HLD Section 7.3)
- **Trigger point**: After evaluating vote and transitioning state
- **Event name**: `handle_request_vote`
- **Fields**: `ha_state`, `term`, `desired_state`, `vote_response` (the response sent back)
- **Notes**: The `EvaluateVote` algorithm from HLD Section 7.3. Instrument when implemented.

### HandleVoteResponse

- **Spec action**: `HandleVoteResponse(n)`
- **Code location**: Not yet implemented (Family 4 — HLD Section 7.3)
- **Trigger point**: After processing vote response and transitioning
- **Event name**: `handle_vote_response`
- **Fields**: `ha_state`, `term`, `desired_state`, `vote_response` (received)
- **Notes**: Instrument when election protocol implemented.

### CompleteInitToActive

- **Spec action**: `CompleteInitToActive(n)`
- **Code location**: `ha_scope.rs:601-639` — `handle_dpu_ha_scope_state_update()`, detecting `activate_role_pending` transition
- **Trigger point**: After DPU acknowledges active role (line 616: new `activate_role_pending`)
- **Event name**: `complete_init_to_active`
- **Fields**: `ha_state`, `term`
- **Notes**: DPU reports `ha_state=active` via `DpuDashHaScopeState`. The operation generates an "activate_role" pending operation (line 616-617).

### HandleBulkSyncDone

- **Spec action**: `HandleBulkSyncDone(n)`
- **Code location**: Not yet implemented (Family 4)
- **Trigger point**: After receiving BulkSyncDone from active peer
- **Event name**: `handle_bulk_sync_done`
- **Fields**: `ha_state`, `term`
- **Notes**: Bulk sync is in HLD but not implemented. Instrument when flow replication is added.

### InitiateSwitchover

- **Spec action**: `InitiateSwitchover(n)`
- **Code location**: `ha_scope.rs:257-258` — `update_dpu_ha_scope_table()` TODO for switchover
- **Trigger point**: After detecting desired_state=Active while in Standby
- **Event name**: `initiate_switchover`
- **Fields**: `ha_state`, `term`, `desired_state`
- **Notes**: Currently a TODO. Instrument when switchover implemented per HLD Section 8.2.

### HandleSwitchOver

- **Spec action**: `HandleSwitchOver(n)`
- **Code location**: Not yet implemented (Family 4)
- **Trigger point**: After receiving SwitchOver message and transitioning to SwitchingToStandby
- **Event name**: `handle_switchover`
- **Fields**: `ha_state`, `term`
- **Notes**: Instrument when implemented.

### CompleteSwitchoverToActive

- **Spec action**: `CompleteSwitchoverToActive(n)`
- **Code location**: Not yet implemented (Family 4)
- **Trigger point**: After receiving HAStateChanged(SwitchingToStandby) from peer
- **Event name**: `complete_switchover_to_active`
- **Fields**: `ha_state`, `term`
- **Notes**: Instrument when implemented.

### CompleteSwitchoverToStandby

- **Spec action**: `CompleteSwitchoverToStandby(n)`
- **Code location**: Not yet implemented (Family 4)
- **Trigger point**: After receiving HAStateChanged(Active) from new active
- **Event name**: `complete_switchover_to_standby`
- **Fields**: `ha_state`, `term`
- **Notes**: Instrument when implemented.

### SwitchoverFailed

- **Spec action**: `SwitchoverFailed(n)`
- **Code location**: Not yet implemented (Family 4)
- **Trigger point**: Switchover timeout — no confirmation received
- **Event name**: `switchover_failed`
- **Fields**: `ha_state`, `term`
- **Notes**: Instrument when timeout mechanism added.

### EnterStandalone

- **Spec action**: `EnterStandalone(n)`
- **Code location**: `dpu.rs:255-266` — `calculate_dpu_state()` detects peer down; trigger in `ha_scope.rs`
- **Trigger point**: After peer DPU health goes to false and HA scope transitions
- **Event name**: `enter_standalone`
- **Fields**: `ha_state`, `term`
- **Notes**: Currently, standalone transition is implicit (DPU health drives desired state from SDN controller). Instrument at the state machine transition point when implemented per HLD Section 10.1.

### ExitStandalone

- **Spec action**: `ExitStandalone(n)`
- **Code location**: Not yet implemented (Family 4)
- **Trigger point**: After peer DPU recovers and ExitStandalone handshake completes
- **Event name**: `exit_standalone`
- **Fields**: `ha_state`, `term`
- **Notes**: Instrument when implemented.

### HandlePeerDestroying

- **Spec action**: `HandlePeerDestroying(n)`
- **Code location**: Not yet implemented (Family 4)
- **Trigger point**: After receiving HAStateChanged(Destroying) from peer
- **Event name**: `handle_peer_destroying`
- **Fields**: `ha_state`, `term`
- **Notes**: Instrument when peer state exchange implemented (#77).

### InitToStandbyTimeout

- **Spec action**: `InitToStandbyTimeout(n)`
- **Code location**: Not yet implemented (Family 4)
- **Trigger point**: Timeout waiting for BulkSyncDone while peer is down
- **Event name**: `init_to_standby_timeout`
- **Fields**: `ha_state`, `term`
- **Notes**: Instrument when timeout logic added.

### StartDestroying

- **Spec action**: `StartDestroying(n)`
- **Code location**: `ha_scope.rs:478-500` — `handle_dash_ha_scope_config_table_message()` Del branch
- **Trigger point**: After desired_state=Dead while in Standby (line 493-500)
- **Event name**: `start_destroying`
- **Fields**: `ha_state`, `term`, `desired_state`
- **Notes**: Currently the Delete handler calls `do_cleanup()` and `context.stop()`. Instrument at the transition point.

### CompleteDestroy

- **Spec action**: `CompleteDestroy(n)`
- **Code location**: `ha_scope.rs:221-228` — `do_cleanup()`
- **Trigger point**: After cleanup operations complete (delete DPU table, NPU state, unregister)
- **Event name**: `complete_destroy`
- **Fields**: `ha_state`
- **Notes**: The Destroying → Dead transition. Fires after all cleanup steps complete.

### GoToDead

- **Spec action**: `GoToDead(n)`
- **Code location**: `ha_scope.rs:478-500` — config Del handler; also DPU failure path
- **Trigger point**: After state transitions to Dead (desired=Dead or DPU failure)
- **Event name**: `go_to_dead`
- **Fields**: `ha_state`, `dpu_up`
- **Notes**: Covers both config deletion and DPU hardware failure paths.

### DpuHealthChange

- **Spec action**: `DpuHealthChange(n, newUp)`
- **Code location**: `dpu.rs:235-269` — `calculate_dpu_state()`
- **Trigger point**: After `calculate_dpu_state()` returns new health value (line 266)
- **Event name**: `dpu_health_change`
- **Fields**: `dpu_up` (boolean), `pmon_up` (optional detail), `bfd_up` (optional detail)
- **Notes**: Health is combination of pmon (3 planes all up) AND BFD (at least 1 session up). Capture both the combined result and individual signals for debugging.

### ReceiveConfig

- **Spec action**: `ReceiveConfig(n)`
- **Code location**: `ha_scope.rs:478-537` — `handle_dash_ha_scope_config_table_message()` Set branch
- **Trigger point**: After deserializing config (line 504-506)
- **Event name**: `receive_config`
- **Fields**: `desired_state`, `ha_set_id`
- **Notes**: First config reception triggers registration to vDPU/HA-set actors. Subsequent configs trigger updates.

### ReceiveVdpuState

- **Spec action**: `ReceiveVdpuState(n)`
- **Code location**: `ha_scope.rs:539-580` — `handle_vdpu_state_update()`
- **Trigger point**: After `vdpu_is_managed()` check (line 545)
- **Event name**: `receive_vdpu_state`
- **Fields**: `dpu_up`
- **Notes**: vdpu.rs:143-145 drops ALL messages before config arrives. Instrument after the managed check.

### ReceiveHasetState

- **Spec action**: `ReceiveHasetState(n)`
- **Code location**: `ha_scope.rs:585-599` — `handle_haset_state_update()`
- **Trigger point**: After verifying vDPU is managed (line 587)
- **Event name**: `receive_haset_state`
- **Fields**: `vip_v4`, `peer_ip`
- **Notes**: Contains VIP and peer IP info from HA set.

### ChangeDesiredState

- **Spec action**: `ChangeDesiredState(n, ds)`
- **Code location**: `ha_scope.rs:478-537` — config message with new `desired_ha_state`
- **Trigger point**: After detecting desired_ha_state changed from previous config
- **Event name**: `change_desired_state`
- **Fields**: `desired_state`
- **Notes**: Track the previous desired_state and only emit when it changes.

## 3. Special Considerations

### Spec-First Actions (Family 4)

Many actions model the HLD design, not the current code. The following are NOT YET IMPLEMENTED in the codebase and require instrumenting new code when it's written:

- `SendRequestVote`, `HandleRequestVote`, `HandleVoteResponse` — election protocol (#77)
- `BecomeConnected` — peer discovery
- `HandleBulkSyncDone` — bulk sync
- `InitiateSwitchover`, `HandleSwitchOver`, `CompleteSwitchoverToActive`, `CompleteSwitchoverToStandby`, `SwitchoverFailed` — switchover (HLD Section 8.2)
- `EnterStandalone`, `ExitStandalone`, `HandlePeerDestroying`, `InitToStandbyTimeout` — standalone operations (HLD Section 10.1)

For initial trace validation, focus on:
1. **DpuHealthChange** — fully implemented (dpu.rs)
2. **ReceiveConfig**, **ReceiveVdpuState**, **ReceiveHasetState** — fully implemented (ha_scope.rs)
3. **CompleteInitToActive** — partially implemented via DPU state update
4. **GoToDead**, **StartDestroying**, **CompleteDestroy** — implemented (ha_scope.rs)
5. **ChangeDesiredState** — implemented (ha_scope.rs config handler)

### Two-Phase Commit Instrumentation (Family 3)

The crash window is between `driver.rs:149` (commit_changes) and `driver.rs:150` (send_queued_messages). To capture this:

1. Emit a `"commit_start"` event at `driver.rs:149` (before commit_changes)
2. Emit a `"commit_complete"` event at `driver.rs:150` (after send_queued_messages)
3. The spec's `FlushOutgoing` corresponds to `commit_complete`
4. `CrashNode` corresponds to a crash between the two events

### Actor Lifecycle Instrumentation (Family 1)

Actor creation/deletion events:

| Event | Code Location | Fields |
|---|---|---|
| `create_actor` | `actors.rs` — actor spawn | `level`, `node` |
| `delete_actor` | `dpu.rs:137-140`, `ha_set.rs:154-170` | `level`, `node` |

Key: track whether child actors receive delete notifications. The bug is that they DON'T.

### Bootstrap State

- Initial `haState` = Dead for all nodes
- Initial `haTerm` = 0 (braft starts at 1, but this system starts at 0)
- Initial `desiredState` = Unspecified
- Initial `dpuUp` = FALSE (DPUs start as unhealthy until pmon reports up)
- Actors start with empty `actorAlive` — created as bridges spawn

### Node Identity

Each hamgrd instance manages one DPU. The node ID in traces should be the vDPU ID (e.g., `"vdpu0"`, `"vdpu1"`) since the HA scope actor is keyed by `vdpu_id:ha_scope_id`.

For a 2-node HA pair, map:
- `"vdpu0"` → `n1`
- `"vdpu1"` → `n2`
