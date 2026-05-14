# Modeling Brief: sonic-net/sonic-buildimage — ICCP/MCLAG Protocol (iccpd)

## 1. System Overview

- **System**: sonic-iccpd — C daemon implementing ICCP (RFC 7275) for MCLAG in SONiC
- **Language**: C, ~15K LOC core logic (mlacp_link_handler 4541, iccp_netlink 2486, mlacp_fsm 1669, iccp_ifm 1531, mlacp_sync_update 1339, scheduler 896, iccp_csm 871)
- **System Category**: **Category A (Distributed / Message-Passing)** — two MCLAG peers communicate via TCP socket (port 8888) using ICCP/LDP protocol with TLV-encoded messages (RFC 7275). Core risks are FSM correctness, sync protocol ordering, MAC state machine consistency, and session establishment/teardown races.
- **Protocol**: MCLAG ICCP — two switches form a redundancy group, synchronize MAC/ARP/NDISC tables, and coordinate port isolation and traffic distribution. Implements RFC 7275 with SONiC-specific extensions (warm boot, IF_UP_ACK, unique IP, FDB sync via mclagsyncd).
- **Key architectural choices**:
  - Single-threaded event loop (epoll, 100ms timeout) — all mutexes commented out (scheduler.c:59-72)
  - Three-layer FSM: ICCP CSM (6 states, connection setup) → APP CSM (2 states, piggybacks ICCP) → MLACP FSM (5 states, sync protocol)
  - MAC entries stored in RB-tree with 2-bit age flags (MAC_AGE_LOCAL=1, MAC_AGE_PEER=2); deletion requires both flags set
  - Sync protocol: Active sends in STAGE1, Standby in STAGE2, then both exchange in EXCHANGE state
  - Role assignment: lower IP = active/client, higher IP = standby/server (iccp_csm.c:852)
  - Heartbeat timeout: configurable (default 15s), ANY received message resets timer
- **Concurrency model**: Single-threaded event loop. No threading. Netlink, peer socket, and mclagsyncd socket events serialized by epoll.

## 2. Bug Families

### Family 1: MAC/FDB Age Flag State Machine (HIGH)

**Mechanism**: The 2-bit age flag scheme (MAC_AGE_LOCAL, MAC_AGE_PEER) is manipulated across 15+ code paths with inconsistent guards. Age flags can be cleared without notifying the peer, set on wrong objects (stack variable vs RB-tree entry), or left in states that prevent deletion.

**Evidence**:
- Historical: #17606 — MAC inconsistency between ICCPD and chip (race between static MAC add and chip learn, OPEN)
- Historical: #2913 — Shutdown MCLAG member crashes orchagent (FDB flush races with static MAC update, OPEN)
- Historical: PR #9014 — `add_to_syncd` flag not updated after `add_mac_to_chip()`, stale entries in APP_DB
- Code analysis: mlacp_link_handler.c:2843,2860 — `mac_msg->age_flag` checked instead of `mac_info->age_flag` (stack var always 0, never has MAC_AGE_PEER)
- Code analysis: mlacp_link_handler.c:2849,2865 — `del_mac_from_chip(mac_msg)` called on stack object; `add_to_syncd` cleared on wrong object
- Code analysis: mlacp_link_handler.c:1720 — MAC age notifications lost when MLACP not in EXCHANGE state; peer never learns about locally-aged MACs
- Code analysis: mlacp_link_handler.c:1874-1880 — `pending_local_del` cleared on port-up but LOCAL age flag removal disabled (commented out), no peer re-sync
- Code analysis: mlacp_sync_update.c:264,319 — PEER age flag cleared early on ADD, not restored on some early-return paths
- Code analysis: mlacp_sync_update.c:266-279 — `pending_local_del` + peer ADD → sends DEL back → potential ping-pong

**Affected code paths**:
- `do_mac_update_from_syncd()` (mlacp_link_handler.c:2685-3058)
- `mlacp_fsm_update_mac_entry_from_peer()` (mlacp_sync_update.c:216-553)
- `set_mac_local_age_flag()` (mlacp_link_handler.c:1700-1730)
- `update_l2_mac_state()` (mlacp_link_handler.c:1740-1910)
- `mlacp_peer_disconn_fdb_handler()` (mlacp_link_handler.c:2291-2355)

**Suggested modeling approach**:
- Variables: `macState[MAC -> {alive, localAged, peerAged, bothAged}]`, `addToSyncd[MAC -> BOOLEAN]`, `pendingLocalDel[MAC -> BOOLEAN]`
- Actions: `LocalLearn`, `LocalAge`, `PeerAdd`, `PeerDel`, `PortDown`, `PortUp`, `SessionDown`, `SessionUp`
- Granularity: Each age flag transition is a separate action. Track peer notification separately from local state change.

**Priority**: High
**Rationale**: Dominant bug class with 3+ CRITICAL open issues. 15+ code paths manipulate age flags. The wrong-variable bug (mac_msg vs mac_info) is confirmed. Classic state machine verification target.

---

### Family 2: MLACP FSM State Transition Safety (HIGH)

**Mechanism**: Unguarded `current_state++` increments in the MLACP FSM can advance the state machine from EXCHANGE(3) to ERROR(4). A sync request TLV received during EXCHANGE state triggers this unconditionally. Additionally, a static `prev_state` variable is shared across all CSM instances, breaking multi-domain MCLAG.

**Evidence**:
- Code analysis: mlacp_fsm.c:1372 — `MLACP(csm).current_state++` in `mlacp_sync_send_all_info_handler()` with no state guard
- Code analysis: mlacp_fsm.c:557-568 — `mlacp_sync_recv_syncReq()` unconditionally calls `mlacp_sync_send_all_info_handler()`
- Code analysis: mlacp_fsm.c:1250-1252 — `mlacp_sync_receiver_handler()` dispatches sync request TLV to `mlacp_sync_recv_syncReq()` without state check
- Code analysis: mlacp_fsm.c:1474-1477 — `mlacp_exchange_handler()` calls `mlacp_sync_receiver_handler()` for APP_DATA messages
- Trigger path: Peer sets `need_to_sync` (via NAK, mlacp_fsm.c:1191) → sends sync request TLV → receiver in EXCHANGE calls `mlacp_sync_recv_syncReq` → `current_state++` → ERROR state
- Code analysis: mlacp_fsm.c:837 — `static MLACP_APP_STATE_E prev_state` shared across all CSMs; second CSM's `mlacp_peer_conn_handler()` never called

**Affected code paths**:
- `mlacp_sync_send_all_info_handler()` (mlacp_fsm.c:1350-1378)
- `mlacp_sync_recv_syncReq()` (mlacp_fsm.c:557-573)
- `mlacp_fsm_transit()` (mlacp_fsm.c:833-953)

**Suggested modeling approach**:
- Variables: `mlacpState[Peer -> {INIT, STAGE1, STAGE2, EXCHANGE, ERROR}]`, `needToSync[Peer -> BOOLEAN]`
- Actions: `SendSyncRequest`, `ReceiveSyncRequest`, `SendNAK`, `ReceiveNAK`, `StageTransition`
- Key: Model sync request reception during EXCHANGE state triggering state advance to ERROR

**Priority**: High
**Rationale**: Confirmed critical bug — peer can crash local FSM to ERROR state via sync request during EXCHANGE. No guard exists. The static prev_state bug affects multi-domain deployments. Both are classic model-checkable properties.

---

### Family 3: Node ID Collision Livelock (MEDIUM)

**Mechanism**: When both MCLAG peers have the same initial node_id, both increment their local node_id on receiving the peer's sysconfig. Since `mlacp_fsm_update_system_conf()` always returns 0 (no NAK sent), both peers advance to the same new ID, creating an infinite collision cycle.

**Evidence**:
- Code analysis: mlacp_sync_update.c:57-58 — `if (sysconf->node_id == MLACP(csm).node_id) MLACP(csm).node_id++`
- Code analysis: mlacp_sync_update.c:78 — always returns 0 (no error, no NAK sent)
- Code analysis: mlacp_fsm.c:1184 — NAK handler decrements node_id, but NAK is never sent for sysconfig collision
- Code analysis: mlacp_fsm.h:69 vs mlacp_tlv.h:56 — node_id is uint32_t locally but uint8_t on wire; silent truncation after 255 increments

**Affected code paths**:
- `mlacp_fsm_update_system_conf()` (mlacp_sync_update.c:44-79)
- `mlacp_sync_recv_nak_handler()` (mlacp_fsm.c:1170-1202)

**Suggested modeling approach**:
- Variables: `nodeId[Peer -> 0..MaxId]`, `remoteNodeId[Peer -> 0..MaxId]`
- Actions: `SendSysConfig`, `ReceiveSysConfig` (with collision detection + increment)
- Invariant: `NodeIdEventuallyDiverge` — eventually nodeId[A] /= nodeId[B]

**Priority**: Medium
**Rationale**: Classic symmetry-breaking protocol failure. Both peers have identical code and symmetric initial state. TLA+ with 2 symmetric peers would detect the livelock immediately. Node_id determines LACP system-id, so persistent collision means wrong LACP operation.

---

### Family 4: Session Establishment and Heartbeat (MEDIUM)

**Mechanism**: The ICCP connection handshake has blocking operations that freeze the entire single-threaded event loop, heartbeat timeout can fire during handshake before any heartbeats are exchanged, and a 3-byte buffer overflow exists in the message reception path.

**Evidence**:
- Code analysis: scheduler.c:152-170 — blocking `recv()` for LDP header with no timeout; stalled peer hangs entire iccpd
- Code analysis: scheduler.c:172-174 — max msg_len=0xFFFF → data_len=65531 → total 65539 exceeds CSM_BUFFER_SIZE=65536 by 3 bytes
- Code analysis: scheduler.c:210-212 — 10.5-second blocking usleep in retry path freezes all CSMs
- Code analysis: iccp_csm.c:652 — `sleep(1)` in notification handler blocks entire scheduler
- Code analysis: scheduler.c:76-88 — heartbeat timeout starts ticking on first socket activity, but heartbeats only sent in EXCHANGE state
- Historical: commit 31dd0b3bf — missing semicolon bypassed socket cleanup guard (already fixed)

**Affected code paths**:
- `scheduler_csm_read_callback()` (scheduler.c:130-258)
- `heartbeat_check()` (scheduler.c:74-100)
- `iccp_csm_correspond_from_msg()` (iccp_csm.c:632-665)

**Suggested modeling approach**:
- Variables: `heartbeatTimer[Peer -> Nat]`, `iccpState[Peer -> ICCP_STATE]`, `heartbeatSent[Peer -> BOOLEAN]`
- Actions: `SendHeartbeat` (only in EXCHANGE), `ReceiveAnyMessage` (resets timer), `HeartbeatTimeout` (disconnects)
- Invariant: `NoFalseTimeout` — heartbeat timeout should not fire if the peer is alive and sending messages

**Priority**: Medium
**Rationale**: The 3-byte buffer overflow is critical for security but not model-checkable. The heartbeat-during-handshake issue and blocking recv are model-checkable and affect operational stability. Multiple blocking calls in the single-threaded loop can cascade into multi-peer starvation.

---

### Family 5: Warm Boot Recovery Race (MEDIUM)

**Mechanism**: The `warm_reboot_disconn_time` is set by `mlacp_peer_disconn_handler()` then immediately reset to 0 by `iccp_csm_status_reset()` in the same disconnect handler chain. The 90-second warm boot timeout never fires, so warm boot recovery never transitions to normal disconnect, and FDB cleanup is skipped permanently.

**Evidence**:
- Historical: PR #7724 — `warm_reboot_disconn_time` immediately cleared (OPEN, unmerged)
- Historical: PR #7684 — port state detection broken after warm reboot (rtnl_link_get_operstate returns UNKNOWN)
- Code analysis: scheduler.c:851-853 — `mlacp_peer_disconn_handler(csm)` then `iccp_csm_status_reset(csm, 0)`
- Code analysis: mlacp_link_handler.c:2380-2388 — early return skips FDB cleanup during warm reboot disconnect
- Code analysis: iccp_csm.c:146 — `iccp_csm_status_reset` sets `warm_reboot_disconn_time = 0`
- Code analysis: mlacp_fsm.c:868-878 — warm_reboot_disconn_time timeout at line 872 never fires (time is 0)

**Affected code paths**:
- `scheduler_session_disconnect_handler()` (scheduler.c:831-858)
- `mlacp_peer_disconn_handler()` (mlacp_link_handler.c:2359-2420)
- `iccp_csm_status_reset()` (iccp_csm.c:140-167)

**Suggested modeling approach**:
- Variables: `warmRebootTime[Peer -> Nat]`, `warmRebootFlag[Peer -> BOOLEAN]`, `fdbCleanedUp[Peer -> BOOLEAN]`
- Actions: `PeerSendWarmBoot`, `SessionDisconnect`, `CsmStatusReset`, `WarmBootTimeout`, `NormalDisconnectCleanup`
- Key: Model the ordering of disconnect handler and status reset

**Priority**: Medium
**Rationale**: Known unmerged bug (PR #7724). Warm boot is a critical SONiC feature. The timeout race is a concrete model-checkable property: verify that FDB cleanup eventually happens after warm boot disconnect.

---

### Family 6: Port Isolation and Traffic Distribution (LOW)

**Mechanism**: Port isolation state and traffic distribution flags are managed across session transitions with incomplete guards. Traffic can be permanently blocked on detach due to an inverted condition, and port isolation has a window of inconsistency during session establishment.

**Evidence**:
- Code analysis: mlacp_link_handler.c:2128-2138 — documented timing issue; traffic disable/enable race during interface detach
- Code analysis: mlacp_link_handler.c:3597 — traffic disable gated on EXCHANGE state; pre-EXCHANGE port-down events don't disable traffic
- Code analysis: mlacp_link_handler.c:2400 — port isolation cleanup on disconnect; window before reconnection
- Historical: #16075 — stack overflow in `update_peerlink_isolate_from_all_csm_lif` (CRITICAL, OPEN)
- Historical: PR #19324 — ebtables non-functional in Docker container

**Affected code paths**:
- `mlacp_mlag_intf_detach_handler()` (mlacp_link_handler.c:2102-2157)
- `update_peerlink_isolate_from_all_csm_lif()` (mlacp_link_handler.c:1044-1172)
- `mlacp_link_enable_traffic_distribution()` / `mlacp_link_disable_traffic_distribution()`

**Suggested modeling approach**:
- Variables: `portIsolation[Port -> BOOLEAN]`, `trafficDisabled[Port -> BOOLEAN]`
- Actions: Model isolation state changes during session up/down/detach transitions

**Priority**: Low
**Rationale**: The stack overflow (#16075) is critical but not model-checkable (buffer size issue). The timing issues are model-checkable but lower impact. Port isolation is best verified via integration tests.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| MAC age flag state machine | Family 1: 15+ code paths, confirmed wrong-variable bug, 3+ CRITICAL open issues | Per-MAC age_flag variable with LOCAL/PEER bits. Separate actions for local learn/age, peer ADD/DEL, port down/up. Track peer notification status. |
| MLACP FSM state transitions | Family 2: confirmed state advance to ERROR via sync request during EXCHANGE | State enum variable per peer. Model sync request/response and state increment. |
| Sync protocol ordering | Family 2: STAGE1→STAGE2→EXCHANGE with wait_for_sync_data flag | Model the handshake: active sends first, standby responds. Verify no stuck states. |
| Node ID collision resolution | Family 3: classic symmetry-breaking failure with two symmetric peers | Per-peer node_id. Collision detection + increment on sysconfig receive. Check eventual divergence. |
| Warm boot disconnect timing | Family 5: warm_reboot_disconn_time reset race (PR #7724) | Model disconnect handler ordering. Verify FDB cleanup eventually happens. |
| Session establishment + heartbeat | Family 4: heartbeat timeout during handshake | Model heartbeat timer vs. heartbeat send (only in EXCHANGE). Verify no false timeout for live peers. |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| TLV parsing / buffer overflows | Family 4/7: memory safety issues (OOB reads, buffer overflow). Test-verifiable, not protocol logic. |
| mclagsyncd interaction | Separate daemon with its own socket. The FDB/MAC race conditions (#17606, #2913) are in orchagent, not iccpd. |
| Netlink event handling | Single-threaded processing of kernel events. Interface state changes feed into the modeled FSM, not a separate protocol. |
| ARP/NDISC sync details | ARP/NDISC follow the same sync pattern as MAC but with simpler state (no age flags). MAC model covers the mechanism. |
| Port isolation implementation | Family 6: Stack overflow and ebtables issues are code-level. Timing issues are secondary to MAC sync correctness. |
| CLI/config parsing | Buffer overflows in config input (commit c01f0316) are code-quality issues, not protocol logic. |
| NDISC self-comparison bug | iccp_ifm.c:574-575 — clear copy-paste bug but affects only IPv6 neighbor updates, not protocol correctness. Test-verifiable fix. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| MAC age flag machine | `ageFlag[MAC -> {0,LOCAL,PEER,BOTH}]`, `peerNotified[MAC -> BOOLEAN]` | Model 2-bit age scheme and peer notification consistency | Family 1 |
| Pending local delete | `pendingDel[MAC -> BOOLEAN]` | Model pending_local_del interaction with peer ADD/DEL | Family 1 |
| MLACP state + sync | `mlacpState`, `waitForSyncData`, `needToSync` | Model state transitions and sync request handling | Family 2 |
| Node ID collision | `nodeId[Peer -> 0..Max]` | Model symmetric collision resolution protocol | Family 3 |
| Warm boot timing | `warmBootTime`, `warmBootFlag`, `fdbCleaned` | Model disconnect handler ordering with warm boot state | Family 5 |
| Heartbeat timer | `heartbeatTimer`, `heartbeatSent` | Model heartbeat send (only EXCHANGE) vs timeout check (all states) | Family 4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| MACConsistency | Safety | If age_flag has LOCAL set, a MAC_SYNC_DEL was sent to peer (or session is down) | Family 1 |
| AddToSyncdConsistency | Safety | add_to_syncd=1 iff MAC was last sent as ADD to syncd | Family 1 |
| NoPendingDelLeak | Safety | pending_local_del not set after port comes back up AND MAC is in final state | Family 1 |
| NoErrorState | Safety | MLACP FSM never reaches ERROR state during normal operation | Family 2 |
| SyncRequestSafety | Safety | Receiving sync request during EXCHANGE does not change current_state | Family 2 |
| NodeIdDivergence | Liveness | Eventually nodeId[A] /= nodeId[B] | Family 3 |
| WarmBootFdbCleanup | Liveness | After warm boot disconnect, FDB cleanup eventually happens (either via timeout or reconnect) | Family 5 |
| NoFalseHeartbeatTimeout | Safety | Heartbeat timeout does not fire for a peer that is alive and connected | Family 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| M1 | Wrong age_flag variable (mac_msg vs mac_info) causes incorrect del_mac_from_chip | MACConsistency, AddToSyncdConsistency | 1 |
| M2 | Age notifications lost when not in EXCHANGE → peer has stale age state | MACConsistency | 1 |
| M3 | pending_local_del + peer ADD → DEL sent back → potential ping-pong | NoPendingDelLeak | 1 |
| M4 | Sync request during EXCHANGE → current_state++ → ERROR | NoErrorState, SyncRequestSafety | 2 |
| M5 | Static prev_state → mlacp_peer_conn_handler skipped for 2nd CSM | Family 2 (multi-CSM) | 2 |
| M6 | Both peers increment node_id simultaneously → infinite collision | NodeIdDivergence | 3 |
| M7 | warm_reboot_disconn_time reset by iccp_csm_status_reset → timeout never fires | WarmBootFdbCleanup | 5 |
| M8 | Heartbeat timeout during handshake (heartbeat not sent until EXCHANGE) | NoFalseHeartbeatTimeout | 4 |
| M9 | Partial MAC batch lost on disconnect (dequeued but not sent) | MACConsistency | 1 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| T1 | NDISC self-comparison bug (iccp_ifm.c:574-575) — IPv6 neighbor changes never detected | Change host MAC, verify NDISC update propagates |
| T2 | LIST_FOREACH mutation in local_if_po_remove (port.c:299-307) — iterator corruption | Remove port-channel with 3+ members, verify all unbound |
| T3 | Buffer overflow: max msg_len exceeds CSM_BUFFER_SIZE by 3 bytes (scheduler.c:172-174) | Send crafted ICCP message with msg_len=0xFFFF |
| T4 | Pointer arithmetic bug: NAK TLV at offset 256 instead of 16 (iccp_csm.c:640) | Trigger notification message, check parsed status code |
| T5 | readfd_count never decremented (scheduler.c:346) — grows after each reconnect cycle | Cycle connection 1000 times, check stack usage |
| T6 | Format string crash: %s receives uint8_t (mlacp_sync_update.c:501-503) | Trigger orphan port MAC ADD with no peer-link |
| T7 | num_of_entry not validated against TLV length (PR #26567) | Send crafted TLV with inflated count |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| C1 | Mutexes are all no-ops (scheduler.c:59-72) | Remove dead mutex code or implement properly |
| C2 | Global g_csm_buf shared across all CSMs (iccp_csm.c:54) | Document single-thread assumption |
| C3 | Memory leak: msg->buf not freed in iccp_csm_msg_list_finalize (iccp_csm.c:240) | Add free(msg->buf) before free(msg) |
| C4 | sleep(1) in notification handler blocks scheduler (iccp_csm.c:652) | Remove or replace with async handling |
| C5 | Memory leak: local_if_create for name without digits (port.c:126-127) | Free local_if before return NULL |
| C6 | Purged interfaces retain stale csm pointer (port.c:370-379) | Set lif->csm = NULL after LIST_REMOVE |

## 7. Reference Pointers

- **Full analysis report**: `.specula-output/analysis-report.md`
- **Key source files**:
  - `src/iccpd/src/mlacp_link_handler.c` (4541 lines) — MAC sync, port isolation, traffic distribution
  - `src/iccpd/src/mlacp_fsm.c` (1669 lines) — MLACP state machine, sync protocol
  - `src/iccpd/src/mlacp_sync_update.c` (1339 lines) — TLV parsing, MAC/ARP/NDISC update from peer
  - `src/iccpd/src/scheduler.c` (896 lines) — event loop, socket management
  - `src/iccpd/src/iccp_csm.c` (871 lines) — ICCP connection state machine
  - `src/iccpd/src/iccp_ifm.c` (1531 lines) — interface management, ARP/NDISC learning
- **Critical GitHub issues**: #17606 (MAC inconsistency), #2913 (orchagent crash), #16075 (stack smashing), #19909 (standby crash on reboot)
- **Critical GitHub PRs**: #7724 (warm boot race), #26567 (TLV OOB), #7680 (FDB buffer overflow), #7684 (warm boot port state)
- **Reference algorithm**: RFC 7275 (ICCP), IEEE 802.1AX (LACP)
