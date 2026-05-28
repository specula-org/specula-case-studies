# Bug Report — sonic-iccpd (ICCP/MCLAG)

## Summary

- Bug families tested: 5
- Bugs found: 4 (Findings M1, M4, M6, M8)
- Configs run: MC_hunt_family1.cfg, MC_hunt_family2.cfg, MC_hunt_family3.cfg, MC_hunt_family4.cfg, MC_hunt_family5.cfg

## Bug 1: Wrong Variable in MAC Age Flag Check (Finding M1)

- **Bug Family**: 1 (MAC/FDB Age Flag State Machine)
- **Severity**: High
- **Invariant violated**: MACConsistency
- **Config**: MC_hunt_family1.cfg
- **Counterexample**: 3 states, output file: `output/hunt_family1_bfs.out`

### Trace Summary

1. **Initial**: Both peers disconnected, no MACs.
2. **LocalMacLearn(p1, m1)**: p1 learns MAC m1 locally. `macExists=TRUE`, `ageFlag={}`, `addToSyncd=TRUE`.
3. **MacUpdateFromSyncd(p1, m1)**: p1 receives MAC update from syncd (existing MAC relearned). The spec models the implementation's wrong-variable bug: `mac_msg->age_flag` (stack variable, always 0) is checked instead of `mac_info->age_flag` (RB-tree entry). Since the incoming age flag is always 0, the condition `!(mac_msg->age_flag & MAC_AGE_PEER)` is always TRUE, causing `del_mac_from_chip()` unconditionally. Result: `addToSyncd=FALSE` while MAC still exists with no age flags.

### Root Cause

In `do_mac_update_from_syncd()`, lines 2843 and 2860 check `mac_msg->age_flag` (the incoming stack variable from syncd, which never carries `MAC_AGE_PEER`) instead of `mac_info->age_flag` (the stored RB-tree entry, which may have `MAC_AGE_PEER` set by a peer's DEL notification). This means `del_mac_from_chip()` is called unconditionally — the MAC is removed from hardware even when the peer hasn't aged it.

### Affected Code

- `src/iccpd/src/mlacp_link_handler.c:2843`: `if (!(mac_msg->age_flag & MAC_AGE_PEER))` — should be `mac_info->age_flag`
- `src/iccpd/src/mlacp_link_handler.c:2860`: Same wrong variable check
- `src/iccpd/src/mlacp_link_handler.c:2849`: `del_mac_from_chip(mac_msg)` called on stack object; `add_to_syncd` cleared on wrong object

### Recommendation

Change `mac_msg->age_flag` to `mac_info->age_flag` at lines 2843 and 2860 of `mlacp_link_handler.c`. Also change `del_mac_from_chip(mac_msg)` to `del_mac_from_chip(mac_info)` and update `add_to_syncd` on the RB-tree entry.

---

## Bug 2: Sync Request During EXCHANGE Advances FSM to ERROR (Finding M4)

- **Bug Family**: 2 (MLACP FSM State Transition Safety)
- **Severity**: Critical
- **Invariant violated**: NoErrorState
- **Config**: MC_hunt_family2.cfg
- **Counterexample**: 16 states, output file: `output/hunt_family2_bfs.out`

### Trace Summary

1. **States 1-13**: Normal MLACP handshake completes. Both peers reach EXCHANGE state.
2. **State 14 (MlacpReceiveNAK p2)**: p2 receives a NAK (sent by p1 during handshake). This sets `needToSync[p2] = TRUE`.
3. **State 15 (MlacpSendSyncRequestFromExchange p2)**: p2 sends a sync request TLV to p1, clears `needToSync`.
4. **State 16 (MlacpReceiveSyncRequestInExchange p1)**: p1 receives the sync request while in EXCHANGE. The handler calls `mlacp_sync_send_all_info_handler()` which does `current_state++`. Since EXCHANGE=3, the state becomes ERROR=4.

### Root Cause

`mlacp_sync_send_all_info_handler()` (mlacp_fsm.c:1372) unconditionally executes `MLACP(csm).current_state++` with no guard against the current state being EXCHANGE. The call path is: `mlacp_exchange_handler` (line 1474) dispatches APP_DATA messages to `mlacp_sync_receiver_handler` (line 1250), which calls `mlacp_sync_recv_syncReq` (line 557) for sync request TLVs, which calls `mlacp_sync_send_all_info_handler` (line 568). No state check exists anywhere in this chain.

### Affected Code

- `src/iccpd/src/mlacp_fsm.c:1372`: `MLACP(csm).current_state++` — no state guard
- `src/iccpd/src/mlacp_fsm.c:557-568`: `mlacp_sync_recv_syncReq()` unconditionally calls `mlacp_sync_send_all_info_handler()`
- `src/iccpd/src/mlacp_fsm.c:1250-1252`: `mlacp_sync_receiver_handler()` dispatches sync request without state check
- `src/iccpd/src/mlacp_fsm.c:1474-1477`: `mlacp_exchange_handler()` dispatches APP_DATA to receiver handler

### Recommendation

Add a guard in `mlacp_sync_send_all_info_handler()` to skip the `current_state++` when already in EXCHANGE state (or beyond). Alternatively, guard the dispatch in `mlacp_sync_receiver_handler()` to reject sync requests when in EXCHANGE.

---

## Bug 3: Node ID Collision Livelock (Finding M6)

- **Bug Family**: 3 (Node ID Collision)
- **Severity**: Medium
- **Invariant violated**: NodeIdCollisionDetected
- **Config**: MC_hunt_family3.cfg
- **Counterexample**: 13 states, output file: `output/hunt_family3_bfs.out`

### Trace Summary

1. **States 1-11**: Both peers start with `nodeId=0`. Normal MLACP handshake progresses. During the handshake, each peer sends a SysConfig TLV containing its `nodeId=0`.
2. **State 12 (ReceiveSysConfig p1)**: p1 receives p2's SysConfig with `mnodeId=0`. Since `0 == nodeId[p1]=0`, collision detected. p1 increments: `nodeId[p1]=1`. Stores `remoteNodeId[p1]=0`.
3. **State 13 (ReceiveSysConfig p2)**: p2 receives p1's SysConfig (sent earlier with `mnodeId=0`). Since `0 == nodeId[p2]=0`, collision detected. p2 increments: `nodeId[p2]=1`. Stores `remoteNodeId[p2]=0`.
4. **Result**: Both peers now have `nodeId=1`. The collision persists — the protocol has no asymmetry-breaking mechanism.

### Root Cause

`mlacp_fsm_update_system_conf()` (mlacp_sync_update.c:57-58) detects collisions by comparing the received `sysconf->node_id` with the local `MLACP(csm).node_id`. On collision, it increments the local node_id. However, since both peers have identical code and symmetric initial state, both increment simultaneously to the same value. The function always returns 0 (no NAK sent, line 78), so there is no feedback mechanism. Additionally, `node_id` is `uint32_t` locally (mlacp_fsm.h:69) but `uint8_t` on wire (mlacp_tlv.h:56), causing silent truncation after 255 increments.

### Affected Code

- `src/iccpd/src/mlacp_sync_update.c:57-58`: `if (sysconf->node_id == MLACP(csm).node_id) MLACP(csm).node_id++`
- `src/iccpd/src/mlacp_sync_update.c:78`: Always returns 0 (no error, no NAK)
- `src/iccpd/src/mlacp_fsm.h:69` vs `src/iccpd/include/mlacp_tlv.h:56`: `uint32_t` vs `uint8_t` type mismatch

### Recommendation

Introduce an asymmetry-breaking mechanism. For example, the peer with the lower IP (Active role) could always decrement instead of increment, or use a random tiebreaker. Alternatively, send a NAK on collision and let the NAK handler (which decrements node_id) provide the asymmetry.

---

## Bug 4: False Heartbeat Timeout During ICCP Handshake (Finding M8)

- **Bug Family**: 4 (Session Establishment and Heartbeat)
- **Severity**: High
- **Invariant violated**: NoFalseHeartbeatTimeout
- **Config**: MC_hunt_family4.cfg
- **Counterexample**: 5 states, output file: `output/hunt_family4_bfs.out`

### Trace Summary

1. **State 1**: Both peers disconnected. Heartbeat timer inactive.
2. **State 2 (TcpConnect p1)**: TCP connection established for both peers. Heartbeat timer starts ticking (`heartbeatActive=TRUE`, `heartbeatTimer=0`). BUT `iccpOperational` is still FALSE — ICCP handshake hasn't completed.
3. **States 3-5 (TimerTick p1 x3)**: Heartbeat timer for p1 advances: 0→1→2→3. No heartbeats are exchanged because `SendHeartbeat` requires `iccpOperational=TRUE`.
4. **State 5**: `heartbeatTimer[p1]=3=MaxTimer`. The timer has reached the timeout threshold while both peers are alive and connected — a false timeout.

### Root Cause

`heartbeat_check()` (scheduler.c:76-88) evaluates the heartbeat timer for any peer with `sock_fd > 0` (i.e., TCP connected). But `mlacp_sync_send_heartbeat()` (mlacp_fsm.c:413) and the entire `mlacp_fsm_transit()` (line 848) require `app_csm.current_state == APP_OPERATIONAL`. So the heartbeat timer starts ticking when the TCP socket is established, but heartbeat messages are only sent after the ICCP handshake completes (APP_OPERATIONAL). If the ICCP handshake (NONEXISTENT→...→OPERATIONAL, 6 states) takes longer than `session_timeout` seconds, the heartbeat check disconnects the session — even though the peer is alive and actively handshaking.

### Affected Code

- `src/iccpd/src/scheduler.c:76-78`: Heartbeat timer starts on `sock_fd > 0` (TCP connected)
- `src/iccpd/src/scheduler.c:82-86`: Timeout check fires regardless of ICCP state
- `src/iccpd/src/mlacp_fsm.c:848`: `mlacp_fsm_transit` requires `APP_OPERATIONAL`
- `src/iccpd/src/mlacp_fsm.c:413-427`: Heartbeat send requires operational state

### Recommendation

Either (a) don't start the heartbeat timer until ICCP becomes operational, or (b) skip the timeout check when `app_csm.current_state != APP_OPERATIONAL`. The simplest fix is adding a guard in `heartbeat_check()`: `if (csm->app_csm.current_state != APP_OPERATIONAL) continue;`.

---

## Not Reproduced

| Bug Family | Config | States Explored | Diameter | Result |
|------------|--------|-----------------|----------|--------|
| Family 5 (Warm Boot) | MC_hunt_family5.cfg | N/A | N/A | Invariant too strong (Case A): `WarmBootFdbConsistency` violated by initial state. The underlying bug (Finding M7 — `warm_reboot_disconn_time` immediately cleared by `iccp_csm_status_reset`) is confirmed by code analysis but the invariant formulation incorrectly triggers before any warm boot has occurred. The bug makes `WarmBootTimeout` unreachable, preventing FDB cleanup after warm boot disconnect. |

## Convergence MC.cfg Run

| Config | Mode | Duration | States Generated | Distinct States | Diameter | Violations |
|--------|------|----------|------------------|-----------------|----------|------------|
| MC.cfg | BFS | 30 min | 705M | 78.7M | 15 | None |

## Spec Fixes During Bug Hunting

- **Family 5**: WarmBootFdbConsistency invariant identified as Case A (too strong). Not modified — documented as "not reproduced" with code-analysis confirmation of the underlying bug.
