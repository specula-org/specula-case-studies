# Instrumentation Spec: sonic-iccpd (ICCP/MCLAG)

Action-to-code mapping for trace harness generation. Each spec action maps to one or more source code locations where trace events must be emitted.

All file paths are relative to `sonic-buildimage/src/iccpd/`.

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "tag": "trace",
  "ts": "<monotonic_ns>",
  "event": {
    "name": "<spec_action_name>",
    "nid": "<peer_id>",
    "state": {
      "mlacpState": "<INIT|STAGE1|STAGE2|EXCHANGE|ERROR>",
      "connected": "<bool>",
      "iccpOperational": "<bool>",
      "nodeId": "<uint8>",
      "waitForSyncData": "<bool>",
      "needToSync": "<bool>",
      "portState": "<UP|DOWN>",
      "ageFlag": "<int 0-3>",
      "pendingLocalDel": "<bool>"
    },
    "mac": "<mac_addr_string>",
    "msg": {
      "from": "<peer_id>",
      "to": "<peer_id>",
      ...message-specific fields...
    }
  }
}
```

### State Fields (captured at every event)

| Impl Field | TLA+ Variable | Getter |
|-----------|---------------|--------|
| `MLACP(csm).current_state` | `mlacpState` | Enum name from `mlacp_state(csm)` |
| `csm->sock_fd > 0` | `connected` | `csm->sock_fd > 0` |
| `csm->app_csm.current_state == APP_OPERATIONAL` | `iccpOperational` | Check `app_csm.current_state` |
| `MLACP(csm).node_id` | `nodeId` | `MLACP(csm).node_id` |
| `MLACP(csm).wait_for_sync_data` | `waitForSyncData` | `MLACP(csm).wait_for_sync_data` |
| `MLACP(csm).need_to_sync` | `needToSync` | `MLACP(csm).need_to_sync` |

### MAC-Specific State Fields (captured for MAC events)

| Impl Field | TLA+ Variable | Getter |
|-----------|---------------|--------|
| `mac_msg->age_flag` | `ageFlag` | Integer 0-3 (LOCAL=1, PEER=2) |
| `mac_msg->pending_local_del` | `pendingLocalDel` | Boolean |
| Port state of associated interface | `portState` | `lif->state` enum |

### Peer ID Mapping

The peer ID (`nid`) should use the CSM's `mlag_id` or the sender/peer IP pair to uniquely identify each MCLAG peer. Map to `"p1"` or `"p2"` consistently.

## Section 2: Action-to-Code Mapping

### 2.1 TcpConnect

| Field | Value |
|-------|-------|
| **Spec action** | `TcpConnect` |
| **Code location** | `src/scheduler.c:310-340` (scheduler_server_accept_handler or client connect path) |
| **Trigger point** | After `csm->sock_fd` is set to a valid value |
| **Trace event name** | `TcpConnect` |
| **Fields** | `state.connected = true` |
| **Notes** | Both peers connect; emit on the peer that initiates. The `heartbeatActive` flag effectively starts here (scheduler.c:76-78 initializes timer on next heartbeat_check call). |

### 2.2 IccpBecomeOperational

| Field | Value |
|-------|-------|
| **Spec action** | `IccpBecomeOperational` |
| **Code location** | `src/iccp_csm.c:500-530` (iccp_csm_transit, transition to ICCP_OPERATIONAL) |
| **Trigger point** | After `csm->current_state` transitions to `ICCP_OPERATIONAL` |
| **Trace event name** | `IccpBecomeOperational` |
| **Fields** | `state.iccpOperational = true` |
| **Notes** | Abstracts NONEXISTENT→INITIALIZED→CAPSENT→CAPREC→CONNECTING→OPERATIONAL. Only instrument the final transition. |

### 2.3 MlacpInitToStage1

| Field | Value |
|-------|-------|
| **Spec action** | `MlacpInitToStage1` |
| **Code location** | `src/mlacp_fsm.c:921-927` (inside mlacp_fsm_transit) |
| **Trigger point** | After `MLACP(csm).current_state = MLACP_STATE_STAGE1` (line 924) |
| **Trace event name** | `MlacpInitToStage1` |
| **Fields** | `state.mlacpState = "STAGE1"`, `state.waitForSyncData` |
| **Notes** | Snapshot is POST-action. |

### 2.4 MlacpSendSyncRequest

| Field | Value |
|-------|-------|
| **Spec action** | `MlacpSendSyncRequest` |
| **Code location** | `src/mlacp_fsm.c:1416-1420` (mlacp_stage_sync_request_handler, send path) |
| **Trigger point** | After `iccp_csm_send(csm, ...)` for the sync request TLV |
| **Trace event name** | `MlacpSendSyncRequest` |
| **Fields** | `state.waitForSyncData` |
| **Notes** | Also emitted from exchange path (2.7). |

### 2.5 MlacpStageSendAllInfo

| Field | Value |
|-------|-------|
| **Spec action** | `MlacpStageSendAllInfo` |
| **Code location** | `src/mlacp_fsm.c:1397-1401` (mlacp_stage_sync_send_handler, after receiving sync request) → calls `mlacp_sync_send_all_info_handler` (line 1350-1378) |
| **Trigger point** | After `mlacp_sync_send_all_info_handler` returns (after current_state++ at line 1372) |
| **Trace event name** | `MlacpStageSendAllInfo` |
| **Fields** | `state.mlacpState`, `state.waitForSyncData` |
| **Notes** | This is the function that contains the current_state++ bug. Snapshot must be POST-action to capture the new state. |

### 2.6 MlacpReceiveSyncDone

| Field | Value |
|-------|-------|
| **Spec action** | `MlacpReceiveSyncDone` |
| **Code location** | `src/mlacp_fsm.c:1425-1428` (mlacp_stage_sync_request_handler, after sync done received) |
| **Trigger point** | After `MLACP(csm).current_state++` (line 1427) |
| **Trace event name** | `MlacpReceiveSyncDone` |
| **Fields** | `state.mlacpState`, `state.waitForSyncData` |
| **Notes** | wait_for_sync_data is set to 0 by mlacp_sync_recv_syncData (line 546) before this point. |

### 2.7 MlacpSendSyncRequestFromExchange

| Field | Value |
|-------|-------|
| **Spec action** | `MlacpSendSyncRequestFromExchange` |
| **Code location** | `src/mlacp_fsm.c:1481-1488` (mlacp_exchange_handler, need_to_sync path) |
| **Trigger point** | After `iccp_csm_send(csm, ...)` for the sync request TLV |
| **Trace event name** | `MlacpSendSyncRequestFromExchange` |
| **Fields** | `state.needToSync` (should be FALSE after clearing at line 1484) |
| **Notes** | Distinguished from 2.4 by being in EXCHANGE state. |

### 2.8 MlacpReceiveSyncRequestInExchange

| Field | Value |
|-------|-------|
| **Spec action** | `MlacpReceiveSyncRequestInExchange` |
| **Code location** | `src/mlacp_fsm.c:1250-1252` (mlacp_sync_receiver_handler dispatches to mlacp_sync_recv_syncReq) → `src/mlacp_fsm.c:557-568` → `src/mlacp_fsm.c:1350-1378` |
| **Trigger point** | After `mlacp_sync_send_all_info_handler` returns when called from EXCHANGE state |
| **Trace event name** | `MlacpReceiveSyncRequestInExchange` |
| **Fields** | `state.mlacpState` (will be "ERROR" if bug triggered) |
| **Notes** | This is the Bug Family 2 trigger point. The key instrumentation point is inside `mlacp_sync_send_all_info_handler` after line 1372, but only when the caller's state was EXCHANGE. Use `MLACP(csm).current_state` before the call to detect the context. |

### 2.9 MlacpSendNAK

| Field | Value |
|-------|-------|
| **Spec action** | `MlacpSendNAK` |
| **Code location** | `src/iccp_csm.c:250-260` (iccp_csm_prepare_nak_msg, after sending NAK) |
| **Trigger point** | After NAK TLV is sent via `iccp_csm_send` |
| **Trace event name** | `MlacpSendNAK` |
| **Fields** | `msg.nakType` (SysConfig or Other) |
| **Notes** | NAK is sent from iccp_csm_correspond_from_msg for unrecognized messages. |

### 2.10 MlacpReceiveNAK

| Field | Value |
|-------|-------|
| **Spec action** | `MlacpReceiveNAK` |
| **Code location** | `src/mlacp_fsm.c:1160-1202` (mlacp_sync_recv_nak_handler) |
| **Trigger point** | After processing NAK (after line 1186 for SysConfig, after line 1191 for others) |
| **Trace event name** | `MlacpReceiveNAK` |
| **Fields** | `state.nodeId`, `state.needToSync`, `msg.nakType` |
| **Notes** | For SysConfig NAK, node_id is decremented (line 1184). For other NAKs, need_to_sync is set (line 1191). |

### 2.11 ReceiveSysConfig

| Field | Value |
|-------|-------|
| **Spec action** | `ReceiveSysConfig` |
| **Code location** | `src/mlacp_sync_update.c:44-79` (mlacp_fsm_update_system_conf) |
| **Trigger point** | After collision check and node_id update (after line 58) |
| **Trace event name** | `ReceiveSysConfig` |
| **Fields** | `state.nodeId`, `msg.remoteNodeId` (= `sysconf->node_id`) |
| **Notes** | Critical for Family 3 (Node ID collision). Must capture both the local node_id (after potential increment) and the received remote node_id. |

### 2.12 LocalMacLearn

| Field | Value |
|-------|-------|
| **Spec action** | `LocalMacLearn` |
| **Code location** | `src/mlacp_link_handler.c:2870-2930` (do_mac_update_from_syncd, new MAC path) |
| **Trigger point** | After new MAC is inserted into RB-tree |
| **Trace event name** | `LocalMacLearn` |
| **Fields** | `mac` (MAC address string), `state.ageFlag`, `state.portState` |
| **Notes** | Only for genuinely new MACs (not found in RB-tree). |

### 2.13 LocalMacAge

| Field | Value |
|-------|-------|
| **Spec action** | `LocalMacAge` |
| **Code location** | `src/mlacp_link_handler.c:1709-1733` (set_mac_local_age_flag, set=1 path) |
| **Trigger point** | After `new_age_flag |= MAC_AGE_LOCAL` (line 1713) |
| **Trace event name** | `LocalMacAge` |
| **Fields** | `mac`, `state.ageFlag` (post-set value) |
| **Notes** | Bug Family 1, Finding M2: if not in EXCHANGE, the DEL notification to peer is silently dropped (line 1720 guard). |

### 2.14 MacUpdateFromSyncd

| Field | Value |
|-------|-------|
| **Spec action** | `MacUpdateFromSyncd` |
| **Code location** | `src/mlacp_link_handler.c:2828-2868` (do_mac_update_from_syncd, existing MAC update path) |
| **Trigger point** | After `set_mac_local_age_flag(csm, mac_info, 0, 1)` (line 2838) |
| **Trace event name** | `MacUpdateFromSyncd` |
| **Fields** | `mac`, `state.ageFlag` (post-clear-LOCAL value) |
| **Notes** | Bug Family 1, Finding M1: Lines 2843 and 2860 check `mac_msg->age_flag` (stack variable, always 0) instead of `mac_info->age_flag` (RB-tree entry). Capture BOTH values: `storedAgeFlag` = `mac_info->age_flag`, `incomingAgeFlag` = `mac_msg->age_flag`. |

### 2.15 ReceivePeerMacAdd

| Field | Value |
|-------|-------|
| **Spec action** | `ReceivePeerMacAdd` |
| **Code location** | `src/mlacp_sync_update.c:262-303` (mlacp_fsm_update_mac_entry_from_peer, existing MAC + ADD) |
| **Trigger point** | After age flag manipulation (after line 264 for normal, after line 278 for pending_local_del) |
| **Trace event name** | `ReceivePeerMacAdd` |
| **Fields** | `mac`, `state.ageFlag`, `state.pendingLocalDel` |
| **Notes** | Bug Family 1, Finding M3: pending_local_del + peer ADD path (lines 266-279) sends DEL back, potential ping-pong. |

### 2.16 ReceivePeerMacAddNew

| Field | Value |
|-------|-------|
| **Spec action** | `ReceivePeerMacAddNew` |
| **Code location** | `src/mlacp_sync_update.c:478-553` (mlacp_fsm_update_mac_entry_from_peer, new MAC + ADD) |
| **Trigger point** | After new MAC inserted into RB-tree |
| **Trace event name** | `ReceivePeerMacAddNew` |
| **Fields** | `mac`, `state.ageFlag` |
| **Notes** | New MAC from peer: age_flag set to MAC_AGE_LOCAL (remote MAC = local age). |

### 2.17 ReceivePeerMacDel

| Field | Value |
|-------|-------|
| **Spec action** | `ReceivePeerMacDel` |
| **Code location** | `src/mlacp_sync_update.c:449-477` (mlacp_fsm_update_mac_entry_from_peer, MAC_SYNC_DEL) |
| **Trigger point** | After `mac_msg->age_flag |= MAC_AGE_PEER` (line 452) |
| **Trace event name** | `ReceivePeerMacDel` |
| **Fields** | `mac`, `state.ageFlag` |
| **Notes** | If both aged (line 458), MAC is deleted. |

### 2.18 PortDown

| Field | Value |
|-------|-------|
| **Spec action** | `PortDown` |
| **Code location** | `src/mlacp_link_handler.c:1739-1863` (update_l2_mac_state, po_state=0) |
| **Trigger point** | At entry to function when `po_state == 0` |
| **Trace event name** | `PortDown` |
| **Fields** | `state.portState = "DOWN"` |
| **Notes** | Emit one event per port-channel down. Individual MAC updates are handled internally. |

### 2.19 PortUp

| Field | Value |
|-------|-------|
| **Spec action** | `PortUp` |
| **Code location** | `src/mlacp_link_handler.c:1864-1937` (update_l2_mac_state, po_state=1) |
| **Trigger point** | At entry to function when `po_state == 1` |
| **Trace event name** | `PortUp` |
| **Fields** | `state.portState = "UP"` |
| **Notes** | Bug: pending_local_del cleared (line 1875) but age_flag NOT cleared (line 1880 commented out). |

### 2.20 SendHeartbeat

| Field | Value |
|-------|-------|
| **Spec action** | `SendHeartbeat` |
| **Code location** | `src/mlacp_fsm.c:413-427` (mlacp_sync_send_heartbeat) |
| **Trigger point** | After `iccp_csm_send(csm, ...)` for heartbeat (line 422) |
| **Trace event name** | `SendHeartbeat` |
| **Fields** | state snapshot only |
| **Notes** | Called from mlacp_fsm_transit (line 880). Only runs when APP_OPERATIONAL. |

### 2.21 ReceiveHeartbeat

| Field | Value |
|-------|-------|
| **Spec action** | `ReceiveHeartbeat` |
| **Code location** | `src/mlacp_sync_update.c:1317-1325` (mlacp_fsm_update_heartbeat) |
| **Trigger point** | After `time(&csm->heartbeat_update_time)` (line 1322) |
| **Trace event name** | `ReceiveHeartbeat` |
| **Fields** | state snapshot only |
| **Notes** | This is the ONLY function that resets the heartbeat timer. |

### 2.22 HeartbeatTimeout

| Field | Value |
|-------|-------|
| **Spec action** | `HeartbeatTimeout` |
| **Code location** | `src/scheduler.c:82-86` (heartbeat_check, timeout path) |
| **Trigger point** | Before `scheduler_session_disconnect_handler(csm)` (line 86) |
| **Trace event name** | `HeartbeatTimeout` |
| **Fields** | state snapshot (pre-disconnect) |
| **Notes** | Bug Family 4: this can fire during ICCP handshake before heartbeats are exchanged. |

### 2.23 SessionDisconnect

| Field | Value |
|-------|-------|
| **Spec action** | `SessionDisconnect` |
| **Code location** | `src/scheduler.c:831-858` (scheduler_session_disconnect_handler) |
| **Trigger point** | After `iccp_csm_status_reset(csm, 0)` (line 853) |
| **Trace event name** | `SessionDisconnect` |
| **Fields** | `state.mlacpState`, `state.connected`, `state.iccpOperational` |
| **Notes** | Bug Family 5: warm_reboot_disconn_time set at line 851 (via mlacp_peer_disconn_handler:2386) then cleared at line 853 (via iccp_csm_status_reset:146). Snapshot is POST-action. |

### 2.24 PeerWarmBoot

| Field | Value |
|-------|-------|
| **Spec action** | `PeerWarmBoot` |
| **Code location** | `src/mlacp_sync_update.c:1327-1340` (mlacp_fsm_update_warmboot) |
| **Trigger point** | After `time(&csm->peer_warm_reboot_time)` |
| **Trace event name** | `PeerWarmBoot` |
| **Fields** | state snapshot only |
| **Notes** | Sets peer_warm_reboot_time, which affects disconnect behavior. |

### 2.25 SendWarmBoot

| Field | Value |
|-------|-------|
| **Spec action** | `SendWarmBoot` |
| **Code location** | Warm boot notification send path (system warm reboot initiation) |
| **Trigger point** | After warm boot TLV is sent to peer |
| **Trace event name** | `SendWarmBoot` |
| **Fields** | state snapshot only |
| **Notes** | Triggered when local system enters warm reboot. |

### 2.26 WarmBootTimeout

| Field | Value |
|-------|-------|
| **Spec action** | `WarmBootTimeout` |
| **Code location** | `src/mlacp_fsm.c:868-878` (mlacp_fsm_transit, warm boot timeout path) |
| **Trigger point** | After `csm->warm_reboot_disconn_time = 0` (line 874) |
| **Trace event name** | `WarmBootTimeout` |
| **Fields** | state snapshot only |
| **Notes** | Bug Family 5: This path is UNREACHABLE because iccp_csm_status_reset already cleared warm_reboot_disconn_time. If instrumented, this event should never appear in traces — its absence confirms the bug. |

## Section 3: Special Considerations

### 3.1 Single-Threaded Event Loop

iccpd is single-threaded (scheduler.c epoll loop). All events are serialized — no concurrent access concerns. The `pthread_mutex` functions are all no-ops (scheduler.c:59-72). This simplifies instrumentation: no locking needed for trace emission.

### 3.2 CSM Identification

Each CSM is identified by `csm->mlag_id`. For a 2-peer MCLAG setup, there is typically one CSM instance. Map `mlag_id` to peer ID consistently.

### 3.3 MAC Address Representation

MAC addresses in the trace should use the string representation from `mac_addr_to_str()`. The `mac` field in trace events uses this string. In the spec, MACs are abstract constants — the harness must map MAC strings to spec MAC constants.

### 3.4 Age Flag Encoding

The age_flag is an integer in the C code:
- `0` = no age flags
- `1` = `MAC_AGE_LOCAL` only
- `2` = `MAC_AGE_PEER` only
- `3` = both `MAC_AGE_LOCAL | MAC_AGE_PEER`

Emit as integer in traces. The spec's `AgeFlagMapping` converts to set representation.

### 3.5 Bootstrap State Differences

The trace spec's `TraceInit` uses the same initial state as the base spec:
- Both peers disconnected
- MLACP in INIT state
- No MACs

If the implementation starts with a different initial state (e.g., pre-existing MACs from a previous session), the harness must either clear state before trace collection or adjust `TraceInit`.

### 3.6 Wrong-Variable Bug Instrumentation (Finding M1)

For `MacUpdateFromSyncd` (action 2.14), capture BOTH:
- `mac_info->age_flag` (the stored RB-tree entry, correct variable)
- `mac_msg->age_flag` (the incoming stack variable, wrong variable used in code)

This allows trace validation to verify whether the code's check at lines 2843/2860 uses the wrong variable. Emit as additional fields:
```json
{
  "storedAgeFlag": <mac_info->age_flag>,
  "incomingAgeFlag": <mac_msg->age_flag>
}
```

### 3.7 Warm Boot Unreachable Path

The `WarmBootTimeout` event (action 2.26) should theoretically never appear in traces due to the bug (warm_reboot_disconn_time is always 0 when checked). Its absence in trace data is itself evidence of the Bug Family 5 finding. If the bug is fixed, this event will start appearing.

### 3.8 Heartbeat Timer Abstraction

The spec models heartbeat timing as abstract counter ticks. The harness does NOT need to emit `TimerTick` events — these are silent actions in the trace spec. The heartbeat-relevant events are `SendHeartbeat`, `ReceiveHeartbeat`, and `HeartbeatTimeout`.
