# Analysis Report: sonic-iccpd (ICCP/MCLAG Protocol)

## Coverage Statistics

- **Git commits analyzed**: 13/13 (all commits touching src/iccpd/)
- **Bug-fix commits deeply analyzed**: 7 (34c8adb93, c01f03164, 7d1b99a88, 82b6bcfbb, 426b6aaf5, 570dbf52f, 31dd0b3bf)
- **GitHub issues deeply read (full comments)**: 23 from sonic-buildimage + 9 from sonic-swss = 32 unique
- **GitHub PRs reviewed**: 32 unique
- **Core source files fully read**: 13 (.c files) + 13 (.h files)
- **Findings**: 50+ raw findings -> 6 Bug Families -> 9 model-checkable + 7 test-verifiable + 6 code-review-only

---

## Phase 1: Reconnaissance

### System Architecture

sonic-iccpd implements the Inter-Chassis Communication Protocol (ICCP, RFC 7275) for Multi-Chassis Link Aggregation (MCLAG) in SONiC. Two MCLAG peer switches run iccpd to synchronize MAC/FDB, ARP, NDISC tables and coordinate port isolation and traffic distribution.

### Codebase Structure (15K LOC core)

| File | LOC | Role |
|------|-----|------|
| mlacp_link_handler.c | 4541 | Link events, MAC sync, port isolation, traffic control |
| iccp_netlink.c | 2486 | Kernel netlink interface |
| mlacp_fsm.c | 1669 | MLACP state machine, sync protocol |
| iccp_ifm.c | 1531 | Interface management, ARP/NDISC learning |
| mlacp_sync_update.c | 1339 | Sync message processing (TLV parsing) |
| scheduler.c | 896 | Event loop, socket management |
| iccp_csm.c | 871 | ICCP connection state machine |
| iccp_cmd_show.c | 814 | CLI show commands |
| port.c | 771 | Port/interface data structures |
| mlacp_sync_prepare.c | 746 | Sync message construction |
| app_csm.c | 316 | Application CSM (thin wrapper) |
| iccp_main.c | 272 | Main entry point |
| iccp_consistency_check.c | 166 | Advisory consistency checking |

### Three-Layer State Machine

```
ICCP CSM (connection):
  NONEXISTENT -> INITIALIZED -> CAPSENT -> CAPREC -> CONNECTING -> OPERATIONAL

APP CSM (application):
  APP_NONEXISTENT <-> APP_OPERATIONAL (piggybacks ICCP state)

MLACP FSM (sync protocol):
  INIT -> STAGE1 -> STAGE2 -> EXCHANGE (-> ERROR on bug)
```

### Concurrency Model

Single-threaded epoll event loop (scheduler.c). All mutexes are commented out (scheduler.c:59-72). Signal handling via self-pipe trick. No threading -- all state machine transitions, message processing, and netlink events are serialized. This means no data races exist in the current code, but the single-threaded architecture makes blocking operations (recv, sleep, usleep) catastrophic since they freeze ALL CSMs.

### Classification

**Category A (Distributed / Message-Passing)**: Two peers communicate via TCP + ICCP/LDP protocol. Core risks are protocol state machine correctness, sync ordering, and MAC state consistency between peers.

---

## Phase 2: Bug Archaeology

### Git Commit Analysis (7 bug-fix commits)

| Commit | Bug Type | Severity | Protocol-Relevant? |
|--------|----------|----------|-------------------|
| 34c8adb93 | Stack buffer overflow in port isolation string | Critical | Indirect (crashes iccpd) |
| c01f03164 | Buffer overflow from unchecked config input | High | Indirect (corrupts CSM) |
| 7d1b99a88 | strtok->strtok_r (latent reentrancy) | Low | No |
| 82b6bcfbb | Major enhancement (IF_UP_ACK, warm boot, MAC RB) | N/A | Yes (new protocol) |
| 426b6aaf5 | Stale loop counter in display | Low | No |
| 570dbf52f | Uninitialized pointer array in ARP/ND | High | Indirect (crashes on events) |
| 31dd0b3bf | Missing semicolon bypasses cleanup guard | Medium | Yes (socket cleanup) |

### GitHub Issues Summary (32 unique, deeply read)

**Critical crashes (4)**:
- #16075 -- iccpd stack smashing + orchagent crash (OPEN since 2023-06)
- #9984 -- mclagsyncd NULL pointer segfault (OPEN since 2022-02)
- #2913 (swss) -- Shutdown MCLAG member crashes orchagent (OPEN since 2023-09)
- #19909 -- orchagent crash on standby when active reboots (OPEN since 2024-08)

**MAC/FDB inconsistency (4)**:
- #17606 -- MAC inconsistency between ICCPD and chip (OPEN since 2024-01)
- #1134 (swss) -- FDB event ordering not guaranteed (OPEN since 2020-05)
- #2604 (swss) -- Stale static MAC after VLAN removal (OPEN since 2023-01)
- #2810 (swss) -- MAC can't age after MOVE event (CLOSED, fixed)

**Infrastructure/Docker (4)**:
- #19556 -- Missing NET_ADMIN capability breaks MAC sync (fixed in master)
- #19323 -- ebtables non-functional in container (CLOSED, fixed)
- #5310 -- iccpd disabled by default (OPEN, 27 comments, major user frustration)
- #9153 -- Missing platform env variable

**Design limitations (3)**:
- #21339 -- YANG model rejects domain IDs > 4095
- #14953 -- LACP fallback not supported with MCLAG
- #2167 (swss) -- portsorch doesn't handle traffic_disable

### GitHub PRs Summary (32 unique)

**Protocol-level bugs (open/unmerged)**:
- PR #26567 -- OOB heap read via untrusted TLV num_of_entry (approved, not merged)
- PR #7724 -- NULL deref on peer_link_if + warm_reboot_disconn_time cleared immediately
- PR #7680 -- FDB buffer overflow with >1400 MACs
- PR #7684 -- Port state detection broken after warm reboot
- PR #3764 -- 30-second traffic loss on failover (LACP PDU delay)
- PR #7714 -- No gratuitous ARP on system-id change (L3 traffic blackhole)
- PR #8794 -- Admin-down interfaces flipped to up during sync
- PR #9240 -- ARP entry inconsistency with kernel
- PR #9014 -- add_to_syncd flag not updated

**Key observation**: Many critical bug-fix PRs from community contributors (Inspur, Ragile Networks) remain OPEN and unmerged for years. MCLAG appears to be largely community-maintained with limited upstream review bandwidth.

---

## Phase 3: Deep Analysis

### Finding Details by Bug Family

#### Family 1: MAC/FDB Age Flag State Machine

**F1.1: Wrong variable in age_flag check (mlacp_link_handler.c:2843,2860)**

In `do_mac_update_from_syncd()`, when a MAC already exists in the RB tree and is being updated:
```c
// Line 2838: updates mac_info's age_flag (RB-tree entry)
mac_info->age_flag = set_mac_local_age_flag(csm, mac_info, 0, 1);
// Line 2843: checks mac_msg->age_flag (STACK variable, always 0!)
if (!(mac_msg->age_flag & MAC_AGE_PEER))
```
`mac_msg` is constructed on the stack at line 2685-2692 with `age_flag = 0`. It will NEVER have MAC_AGE_PEER set. Result: `del_mac_from_chip` is always called unnecessarily, and `add_to_syncd` is cleared on the wrong object.

**F1.2: MAC age notifications lost in non-EXCHANGE state (mlacp_link_handler.c:1720)**

When `set_mac_local_age_flag()` sets LOCAL age with `update_peer=1`, it checks `MLACP(csm).current_state != MLACP_STATE_EXCHANGE` at line 1720. If not in EXCHANGE, the MAC_SYNC_DEL is NOT enqueued to the peer. During the next full sync (`mlacp_sync_mac`, mlacp_fsm.c:1024), locally-aged MACs with `age_flag == MAC_AGE_LOCAL` are skipped. The peer retains the MAC forever.

**F1.3: pending_local_del + peer ADD creates DEL ping-pong (mlacp_sync_update.c:266-279)**

When a MAC has `pending_local_del=1` and the peer sends ADD:
1. `pending_local_del` cleared
2. `age_flag` set to `MAC_AGE_LOCAL`
3. `op_type` changed to `MAC_SYNC_DEL`
4. MAC enqueued to send DEL back to peer

If both peers have the same MAC in pending state, they repeatedly send DELs to each other.

**F1.4: Partial MAC batch lost on disconnect (mlacp_fsm.c:260-305)**

`mlacp_sync_send_syncMacInfo()` sends MACs in batches of 30. MACs are dequeued from `mac_msg_list` via `MAC_TAILQ_REMOVE` BEFORE sending. If disconnect occurs mid-batch, dequeued DEL entries are freed permanently (line 288). ADD entries remain in RB tree but without MSG_LIST membership, so they won't be synced until next full resync.

**F1.5: Age flag cleared early on MAC ADD from peer, not restored on early-return (mlacp_sync_update.c:264,319)**

At line 264, `mac_msg->age_flag &= ~MAC_AGE_PEER` clears the PEER age flag unconditionally. If the function returns early at line 319 (MAC already points to peer-link), the PEER flag has been cleared but no compensating logic executes. The MAC may never be aged out on the peer side.

#### Family 2: MLACP FSM State Transition Safety

**F2.1: Sync request during EXCHANGE advances to ERROR (CRITICAL)**

The full path:
1. Peer A receives a NAK -> sets `need_to_sync = 1` (mlacp_fsm.c:1191)
2. Peer A sends sync request TLV to Peer B (mlacp_fsm.c:1486-1487)
3. Peer B receives sync request during EXCHANGE state
4. `mlacp_exchange_handler()` -> `mlacp_sync_receiver_handler()` -> `mlacp_sync_recv_syncReq()` (line 1250-1252)
5. `mlacp_sync_recv_syncReq()` unconditionally calls `mlacp_sync_send_all_info_handler()` (line 568)
6. `mlacp_sync_send_all_info_handler()` does `current_state++` (line 1372)
7. EXCHANGE(3) -> ERROR(4)

Once in ERROR state, the FSM is effectively dead. The only exit is session disconnect (mlacp_fsm.c:851-857 resets to INIT).

**F2.2: Static prev_state shared across CSMs (mlacp_fsm.c:837)**

`static MLACP_APP_STATE_E prev_state = MLACP_SYNC_SYSCONF;` is function-scoped static. When CSM-A transitions to EXCHANGE, `prev_state = EXCHANGE`. When CSM-B also transitions to EXCHANGE, `prev_state` already equals EXCHANGE from CSM-A, so the `if (prev_state != MLACP(csm).current_state)` check at line 913 is false and `mlacp_peer_conn_handler()` is never called for CSM-B. This means FDB sync, port isolation updates, and ICCP state notifications are never performed for the second MCLAG domain.

**F2.3: wait_for_sync_data can get stuck (mlacp_fsm.c:1414-1431)**

In `mlacp_stage_sync_request_handler`, `wait_for_sync_data` is set to 1 at line 1420. It is cleared only when a `SYNC_DATA` TLV with end flag is received (mlacp_fsm.c:546). If the peer crashes after receiving the sync request but before sending sync-done, `wait_for_sync_data` stays at 1 for up to 15 seconds (heartbeat timeout). During this window, the FSM is stuck and no other messages are processed.

#### Family 3: Node ID Collision Livelock

**F3.1: Symmetric collision with no asymmetry-breaking (mlacp_sync_update.c:57-58)**

Both peers have initial node_id = X. Both send sysconfig simultaneously:
1. A receives B's sysconfig(X), detects collision, increments to X+1
2. B receives A's sysconfig(X), detects collision, increments to X+1
3. Both now have node_id = X+1
4. `mlacp_fsm_update_system_conf()` always returns 0 (line 78), so no NAK is sent
5. On next sysconfig exchange: both send X+1, both detect collision, both increment to X+2
6. Infinite collision loop

The only breaking mechanism is if messages arrive asymmetrically (one peer processes sysconfig before sending its own). This depends on network timing, not protocol correctness.

**F3.2: node_id type mismatch (mlacp_fsm.h:69 vs mlacp_tlv.h:56)**

`MLACP(csm).node_id` is `uint32_t` locally but `uint8_t` on wire. After 256 increments, the local value is 256+ but the wire value wraps to 0. Collision detection compares different-width types.

#### Family 4: Session and Heartbeat

**F4.1: 3-byte buffer overflow (scheduler.c:172-174)**

Max msg_len = 0xFFFF -> data_len = 65531. Written at offset 8 in 65536-byte buffer. Total: 65539, exceeding buffer by 3 bytes.

**F4.2: Pointer arithmetic bug in NAK TLV (iccp_csm.c:640)**

`NAKTLV* nak = (NAKTLV*)(icc_hdr + sizeof(ICCHdr))` -- pointer arithmetic on `ICCHdr*` advances by sizeof(ICCHdr) * sizeof(ICCHdr) = 256 bytes instead of 16. Reads garbage at offset 256.

**F4.3: Heartbeat timeout during handshake**

Heartbeat timer starts on first socket activity (scheduler.c:76-79). Heartbeats only sent in EXCHANGE state (mlacp_fsm.c:880). If handshake stalls >15s, timeout fires and kills the session.

**F4.4: Blocking recv in header read (scheduler.c:152-170)**

No MSG_DONTWAIT flag on header recv. A stalled peer (TCP connection alive, no data) blocks the entire event loop indefinitely.

**F4.5: sleep(1) and usleep(10.5s) in event loop (iccp_csm.c:652, scheduler.c:210)**

`sleep(1)` in notification handler and up to 10.5-second blocking usleep in data retry freeze all CSMs.

**F4.6: readfd_count never decremented (scheduler.c:346,640)**

Incremented on accept/connect, never decremented on disconnect. Used to size stack-allocated VLA `events[]` array. After many reconnections, stack overflow.

#### Family 5: Warm Boot Recovery

**F5.1: warm_reboot_disconn_time immediately cleared (PR #7724)**

In `scheduler_session_disconnect_handler()`:
1. Line 851: `mlacp_peer_disconn_handler(csm)` -- sets warm_reboot_disconn_time
2. Line 853: `iccp_csm_status_reset(csm, 0)` -- resets warm_reboot_disconn_time = 0

The 90-second timeout check at mlacp_fsm.c:872 first checks `warm_reboot_disconn_time != 0`, which is false. Timeout never fires. FDB cleanup for failed warm boot reconnection is permanently skipped.

**F5.2: Early return skips all cleanup during warm boot (mlacp_link_handler.c:2377-2388)**

If `sys->warmboot_exit == WARM_REBOOT`, `mlacp_peer_disconn_handler()` returns at line 2378, skipping ALL MAC cleanup, port isolation cleanup, and traffic re-enable.

#### Additional Standalone Findings

**NDISC self-comparison bug (iccp_ifm.c:574-575)** -- All comparisons compare `ndisc_info` against itself. IPv6 neighbor updates are NEVER detected. Copy-paste bug from ARP handler.

**LIST_FOREACH mutation (port.c:299-307)** -- `mlacp_unbind_local_if(lif)` inside `LIST_FOREACH` modifies the iteration pointer. Can skip elements or cause undefined behavior.

**Memory leak in local_if_create (port.c:126-127)** -- Returns NULL without freeing malloc'd struct when port-channel name has no digits.

**Memory leak in iccp_csm_msg_list_finalize (iccp_csm.c:240)** -- `free(msg)` without `free(msg->buf)`.

**Port state handler has no MLACP state guard (iccp_ifm.c:1290-1296)** -- Port state changes trigger MAC/route changes before MLACP sync completes.

**APP CSM intermediate states are dead code (app_csm.c:80-98)** -- Only NONEXISTENT and OPERATIONAL are ever entered. The APP_RESET, APP_CONNSENT, APP_CONNREC, APP_CONNECTING states defined in the enum are unused.

---

## Phase 4: Modeling Priorities

### Top 3 Bug Families for TLA+ Modeling

1. **MAC Age Flag State Machine (Family 1)**: Highest evidence density (15+ code paths, 3+ CRITICAL open issues, confirmed wrong-variable bug). The 2-bit age scheme with peer notification is a finite state machine that TLA+ can enumerate completely.

2. **MLACP FSM Transitions (Family 2)**: Confirmed critical bug (sync request during EXCHANGE -> ERROR). A small TLA+ model with 5 states and sync request/response actions would catch this in seconds.

3. **Node ID Collision (Family 3)**: Classic symmetry-breaking failure. Two symmetric peers with identical code. TLA+ with 2 peers and a small node_id domain would detect the livelock immediately.

### Modeling Scope Recommendation

A combined spec modeling the MLACP FSM (Families 2, 3, 4, 5) with a simplified MAC sync sub-protocol (Family 1) would cover the highest-value findings. The spec would have:
- Two peer processes (symmetric)
- ICCP CSM -> APP CSM -> MLACP FSM state machines per peer
- MAC entries with age flags and peer notification tracking
- Sync request/response protocol
- Node ID collision resolution
- Heartbeat timer
- Session disconnect and warm boot recovery

Estimated state space: manageable with 2 peers, 1-2 MAC entries, node_id domain 0..3.

### Excluded from Modeling

- TLV parsing / buffer overflows: memory safety, not protocol logic
- mclagsyncd interaction: separate daemon
- ARP/NDISC sync: same pattern as MAC with simpler state
- Port isolation implementation: stack overflow is code-level
- Netlink event handling: input to the modeled FSM
