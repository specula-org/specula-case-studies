# iccpd Modeling Brief

## 1. System Overview

- **System/revision**: SONiC `iccpd`, C, `9df8ccbf72c31948741b5554d09c38ac6c1ec6e9`; 23,641 physical C/header lines under `src/iccpd` (about 21 K excluding bundled tree/control-client code).
- **Category**: **Category A (Distributed / Message-Passing)**. Two peers synchronize control-plane and forwarding state over TCP and drive an asynchronous kernel/`mclagsyncd` data plane.
- **Algorithm**: ICCP/mLACP redundancy-group establishment, staged configuration/state synchronization, heartbeat failover, warm-restart grace, and MAC/ARP/ND recovery, based on RFC 7275.
- **Architecture**: one `epoll` scheduler serializes ICCP, application, and mLACP FSMs; signal handling only writes a pipe and no worker thread exists.
- **Reference deviations**: raw TCP/8888 replaces LDP, any complete frame refreshes liveness, a custom heartbeat and data-plane TLVs are used, and the RFC application-connect FSM is bypassed.
- **Atomicity boundary**: in-memory mutation, socket write, peer delivery, `mclagsyncd`/kernel application, and acknowledgement are distinct failure points even where the code treats them as one operation.

## 2. Scenarios

### Scenario 1: Recovery evidence is destroyed before failover completes

**Mechanism**: Restart/failover is represented by transient timestamps and inferred snapshots that can be cleared, skipped, or consumed before ordinary recovery has run.

**Evidence**:
- Historical/open: [PR #7724](https://github.com/sonic-net/sonic-buildimage/pull/7724) identifies warm-grace and peer-link lifecycle gaps; [#7684](https://github.com/sonic-net/sonic-buildimage/pull/7684), [#7685](https://github.com/sonic-net/sonic-buildimage/pull/7685), [#7714](https://github.com/sonic-net/sonic-buildimage/pull/7714), and [#7769](https://github.com/sonic-net/sonic-buildimage/pull/7769) expose restart reconstruction/replay defects.
- Code analysis: warm receipt sets a marker (`mlacp_sync_update.c:1342-1349`); disconnect records grace and returns before cleanup (`mlacp_link_handler.c:2376-2439`), then reset erases both markers (`iccp_csm.c:129-146`).
- Code analysis: the intended 90-second fallback is below the disconnected/non-operational early return (`mlacp_fsm.c:935-965`), so it cannot fire while the peer remains absent.
- Code analysis: startup dumps neighbors before syncd supplies VLAN membership, discarding pre-existing L2 SVI neighbors with no second dump (`scheduler.c:383-395`; `iccp_ifm.c:188-268,448-528`; `mlacp_link_handler.c:3295-3324`). Netlink-loss resync is event-dependent and GETLINK-only (`iccp_netlink.c:1859-1868,2035-2075`; `iccp_ifm.c:63-114`).

**Affected code paths**: `scheduler_session_disconnect_handler`, `mlacp_peer_disconn_handler`, `iccp_csm_status_reset`, `mlacp_fsm_transit`, netlink reconstruction and peer reconnect handlers.

**Suggested modeling approach**:
- Variables: `sessionUp`, `warmAnnounced`, `graceArmed`, `cleanupDone`, `kernelTruth`, `observedState`, `resyncPending`, `snapshotReady`, `advertisedState`.
- Actions: warm announcement, disconnect, timeout, ordinary cleanup, crash/restart, authoritative snapshot, reconnect.
- Granularity: split disconnect detection, grace installation, state reset, cleanup, and reconnect into separate actions.

**Priority**: High  
**Rationale**: The current timeout is unreachable, retained forwarding state can blackhole or loop traffic indefinitely, and crash/reconnect composition is well suited to state exploration.

### Scenario 2: Synchronization progress is committed without delivery proof

**Mechanism**: A multi-message synchronization transaction advances local stages and discards dirty state after a one-shot write rather than after complete, correlated peer acceptance.

**Evidence**:
- Historical/open: [PR #7680](https://github.com/sonic-net/sonic-buildimage/pull/7680) documents prior framing failures; fixed bounds PRs [#26567](https://github.com/sonic-net/sonic-buildimage/pull/26567) and [#26930](https://github.com/sonic-net/sonic-buildimage/pull/26930) show recurring receive-contract drift.
- Code analysis: `iccp_csm_send` performs one `write`, merely logging short/error returns (`iccp_csm.c:245-281`); queues, change flags, request state, and sender stages are nevertheless consumed/advanced (`mlacp_fsm.c:190-366,1438-1463,1497-1517,1569-1645`).
- Code analysis: a legal Sync Request in `EXCHANGE` runs the full-response helper, whose unconditional `current_state++` changes `EXCHANGE` to `ERROR` (`mlacp_fsm.c:557-569,1017-1032,1438-1463`).
- Code analysis: request number zero is hard-coded and responses are not correlated (`mlacp_sync_prepare.c:49-146`; `mlacp_fsm.c:538-568`); established resync omits the persistent MAC/neighbor snapshot (`mlacp_fsm.c:1393-1436`).

**Affected code paths**: `iccp_csm_send`, `mlacp_sync_recv_syncReq`, `mlacp_sync_send_all_info_handler`, `mlacp_stage_sync_send_handler`, `mlacp_exchange_handler`, MAC/ARP/ND delta senders.

**Suggested modeling approach**:
- Variables: `syncEpoch`, `syncPhase`, `outstandingReq`, `dirtyVersion`, `peerVersion`, `sendOutcome`, per-direction FIFO channels.
- Actions: prepare, full/failed/partial write, FIFO delivery, Start/Data/End receipt, correlated completion, legal established resync.
- Granularity: split local mutation from write and delivery; preserve TCP order and model partial write as frame corruption/session failure, not arbitrary reordering.

**Priority**: High  
**Rationale**: It combines a directly confirmed illegal state transition with open safety/liveness questions about incomplete snapshots and healthy heartbeats.

### Scenario 3: An acknowledgement certifies intent, not current data-plane state

**Mechanism**: Interface-up acknowledgement has no transition generation and is sent before proving that peer isolation was successfully applied.

**Evidence**:
- Historical: [issue #19323](https://github.com/sonic-net/sonic-buildimage/issues/19323), [#5310](https://github.com/sonic-net/sonic-buildimage/issues/5310), and [#9153](https://github.com/sonic-net/sonic-buildimage/issues/9153) confirm real isolation-programming failures in deployed stacks.
- Code analysis: an UP update is acknowledged even if no peer interface matches (`mlacp_sync_update.c:165-210`; `mlacp_fsm.c:508-534`).
- Code analysis: desired isolation is mutated before unchecked/ignored `mclagsyncd`, `ebtables`, and STATE_DB effects (`mlacp_link_handler.c:1021-1041,1044-1220`).
- Code analysis: the ACK carries no generation, its isolation field is ignored, and current `po_active` alone enables traffic (`mlacp_tlv.h:447-470`; `mlacp_fsm.c:759-793`).

**Affected code paths**: `mlacp_portchannel_state_handler`, `mlacp_fsm_update_Aggport_state`, `mlacp_fsm_send_if_up_ack`, `mlacp_fsm_recv_if_up_ack`, peer-link isolation and traffic enable/disable helpers.

**Suggested modeling approach**:
- Variables: `lagGen`, `localLagUp`, `peerKnownGen`, `isolationDesired`, `isolationApplied`, `trafficEnabled`, `ackGen`, `sidecarAvailable`.
- Actions: down/up transition, peer receipt, isolation apply/fail, ACK send/delay/loss, ACK receipt, traffic enable.
- Granularity: make peer receipt, external apply, and ACK independent actions; allow rapid same-session down/up before an old ACK arrives.

**Priority**: High  
**Rationale**: A stale/false ACK can create a forwarding loop, while a lost ACK can blackhole a healthy LAG; the ABA sequence is compact and model-checkable.

### Scenario 4: Transport activity and scheduler progress diverge

**Mechanism**: The single event loop can block inside one stream while protocol timers stop, yet complete non-progress traffic can keep a logically stuck session alive.

**Evidence**:
- Historical: [issue #9984](https://github.com/sonic-net/sonic-buildimage/issues/9984) confirms `mclagsyncd` crash/restart failure; [#16075](https://github.com/sonic-net/sonic-buildimage/issues/16075) confirms daemon failure during peer reconnect/isolation processing.
- Code analysis: the blocking peer-header loop waits indefinitely after 1-7 bytes; body retry sleeps inline for about the session timeout (`scheduler.c:129-239`).
- Code analysis: accepted-side writes have no timeout, while client-side writes use only 100 ms (`scheduler.c:318-347,579-640`); no peer write uses `MSG_NOSIGNAL`.
- Code analysis: every complete peer frame refreshes heartbeat (`iccp_netlink.c:2225-2235`), including unsupported APP frames accumulated in an unconsumed queue (`app_csm.c:100-166`).
- Code analysis: `mclagsyncd` EOF/error is ignored, leaving a positive stale fd that the reconnect condition never repairs (`mlacp_link_handler.c:3369-3543`; `iccp_netlink.c:2212-2215`; `scheduler.c:469-474`).

**Affected code paths**: `scheduler_session_read_handler`, `iccp_handle_events`, heartbeat update/check, APP enqueue, `iccp_mclagsyncd_msg_handler`, syncd reconnect loop.

**Suggested modeling approach**:
- Variables: `schedulerEnabled`, `sessionActivity`, `protocolProgress`, `heartbeatAge`, `streamState`, `syncdConnected`.
- Actions: partial-header arrival, scheduler block/unblock, non-progress frame, heartbeat timeout, syncd EOF/reconnect.
- Granularity: model scheduler availability separately from network delivery and protocol progress; use weak fairness only for enabled, non-blocked actions.

**Priority**: Medium  
**Rationale**: Availability impact is high, but byte accounting and OS blocking details should remain test abstractions rather than expand the protocol state space.

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

- **Recovery epochs**: model warm grace, crash, snapshot readiness, reconnect, and ordinary cleanup separately to explore Scenario 1 recovery compositions.
- **Transactional synchronization**: model Start/Data/End envelopes, dirty-version retention, correlated requests, and fallible FIFO writes for Scenario 2.
- **Generation-bound data-plane acknowledgement**: distinguish desired/applied isolation and current/stale ACKs for Scenario 3.
- **Protocol progress versus transport activity**: add a small scheduler/heartbeat abstraction for Scenario 4; do not encode byte buffers.
- **Reference core**: retain RFC ordering—system configuration before aggregation/port state—and require explicit synchronization completion before Exchange.

### 3.2 Do Not Model (with rationale)

- Raw TLV lengths, heap corruption, pointer arithmetic, `realloc`, SIGPIPE, or exact stream-fragment bytes: use ASan/socket tests and code review.
- Arbitrary TCP reorder or duplication: each connection is FIFO; model full failure, partial-frame corruption, delay, and disconnect only.
- Exact MAC/ARP/ND table contents, CLI formatting, command parsing, logging, ebtables syntax, and Redis wire formats: abstract one replicated object and one external apply result.
- Multi-domain shared statics: supported YANG has `max-elements 1`; synthetic multi-CSM behavior is a test-only future-compatibility concern.
- RFC application-connect and Node-ID wire encoding: important interoperability review, but not needed to answer the selected same-version SONiC safety questions.
- Closed historical bounds/initialization bugs: keep them as mechanism evidence only; do not recreate already-fixed revisions.

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| Recovery epoch | `warmAnnounced`, `graceArmed`, `cleanupDone`, `kernelTruth`, `observedState`, `snapshotReady` | Represent failure and recovery as ordered, interruptible steps | 1 |
| Sync transaction | `syncEpoch`, `syncPhase`, `dirtyVersion`, `peerVersion`, `outstandingReq` | Prevent local completion without a complete correlated snapshot | 2 |
| Fallible FIFO send | `channel`, `sendOutcome`, `frameValid` | Separate local commit from full, failed, or corrupt delivery | 2 |
| Data-plane transaction | `lagGen`, `isolationDesired`, `isolationApplied`, `ackGen`, `trafficEnabled` | Tie traffic enablement to the current applied peer state | 3 |
| Progress/liveness split | `schedulerEnabled`, `sessionActivity`, `protocolProgress`, `heartbeatAge` | Explore sessions that are transport-live but protocol-stuck | 2, 4 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| `TypeOK` | Safety | Every state and message field remains in its declared domain | All |
| `LegalFSMState` | Safety | A legal established resync cannot enter `ERROR` without protocol rejection | 2 |
| `SyncEnvelopeOrdering` | Safety | Items attributed to a sync response are accepted only between its matching Start/End | 2 |
| `ConfigBeforeState` | Safety | System/aggregation configuration precedes state for an epoch | 2 |
| `ExchangeAgreement` | Safety | If both peers are in Exchange, both completed the same sync epoch/version | 2 |
| `DirtyStateAccounted` | Safety | Clearing dirty state implies current delivery or retained retry state | 2 |
| `WarmRecoveryTerminates` | Liveness | Warm disconnect eventually reconnects or executes ordinary cleanup | 1 |
| `RecoveryBeforeAdvertise` | Safety | Recovered state is not advertised/applied before its authoritative snapshot | 1 |
| `CurrentIsolationBeforeTraffic` | Safety | During an operational peer-reliant LAG-up handshake, enabled traffic implies isolation is applied for current `lagGen` | 3 |
| `NoPeerLinkLoop` | Safety | Both nodes never enable a forwarding cycle through peer/member links | 3 |
| `SyncEventuallyResolves` | Liveness | A requested sync eventually reaches matching Exchange or disconnects | 2, 4 |
| `StuckSessionDetected` | Liveness | Absent protocol progress eventually causes recovery despite irrelevant traffic | 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Scenario |
|---|---|---|---|
| MC1 | Can any warm-announcement/disconnect/crash/reconnect ordering retain peer state forever without a successful recovery or ordinary failover? | `WarmRecoveryTerminates` | 1 |
| MC2 | With full/failed/partial writes and legal established resync, can peers remain session-live while disagreeing on sync epoch or object version? | `ExchangeAgreement`, `SyncEventuallyResolves` | 2 |
| MC3 | Can delayed same-session ACK plus rapid down/up, or external apply failure, enable traffic before isolation for the current generation? | `CurrentIsolationBeforeTraffic`, `NoPeerLinkLoop` | 3 |
| MC4 | Can restart plus delayed/unknown reconstruction advertise or destructively apply stale interface state before the authoritative snapshot? | `RecoveryBeforeAdvertise` | 1 |
| MC5 | Can syntactically valid non-progress traffic indefinitely mask an `ERROR`/incomplete-sync session? | `StuckSessionDetected` | 2, 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| TV1 | Warm-grace marker is erased and its timeout unreachable | Drive warm TLV then disconnect; advance >90 s and assert normal cleanup |
| TV2 | Sync Request in Exchange increments into Error and established resync omits persistent tables | Inject request into an Exchange CSM with persistent but empty delta tables |
| TV3 | Failed/short peer writes consume state; EPIPE may terminate the daemon | `socketpair`, constrained buffers/write shim, and subprocess SIGPIPE tests |
| TV4 | IF_UP ACK succeeds without a matching peer interface; lost/stale ACK behavior | Empty-PIF and delayed-ACK integration tests with rapid LAG flaps |
| TV5 | Partial peer headers stall the scheduler and small timeout arithmetic underflows | Fake peer sends 1-7 header bytes/body fragments while watchdog checks FSM ticks |
| TV6 | Fragmented syncd headers corrupt accounting; EOF never reconnects | Fragment every 4-byte-header boundary and close/restart fake `mclagsyncd` |
| TV7 | Detaching a traffic-disabled MLAG leaves the resulting PortChannel blocked | Disable, detach with distinct peer-link, and inspect syncd traffic state |
| TV8 | Malformed fixed TLVs/NA options, max frame, NAK offset, oversized member list, and orphan APP queue | ASan/UBSan packet/config corpus plus sustained unsupported APP frames |
| TV9 | Late FDB redirect and failed sidecar writes diverge shadow/applied state | Inject late ADD during local-down and fail each external write |
| TV10 | `readfd_count` grows on reconnect and can exhaust stack | Repeated connect/disconnect under instrumentation |
| TV11 | Neighbor identity collapses same address on distinct interfaces/VRFs | Seed duplicate IPv4/IPv6 neighbors and inspect both persistent/delta tables |
| TV12 | Startup ordering and nominal netlink resync omit authoritative objects | Restart with quiet L2 SVI neighbors; inject missed delete/ENOBUFS and compare caches to kernel truth |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR1 | RFC App Connect is bypassed; Node ID is out of range/mutated on collision; Sync Request uses reserved zero | Decide supported interoperability contract and align with RFC 7275 §§4.4, 7.2, 9.2 |
| CR2 | Open [#24868](https://github.com/sonic-net/sonic-buildimage/pull/24868) has self-comparisons suppressing ND updates | Correct comparisons and require a regression test |
| CR3 | Open [#27611](https://github.com/sonic-net/sonic-buildimage/pull/27611) tests a zeroed transient age flag instead of persistent MAC state | Review the proposed object/flag correction |
| CR4 | Open [#7760](https://github.com/sonic-net/sonic-buildimage/pull/7760) mixes local `ifindex` with peer `po_id` | Define identifier types and remove implicit interchange |
| CR5 | Startup token capacity, eight direct `realloc` assignments, and oversized interface clears remain in #28697/#28696/#28695 | Audit helper contracts; retain the documented severity qualifications |
| CR6 | Direct syncd writes mutate desired/shadow flags despite failure | Route all writes through one full-send helper and track applied state explicitly |

## 7. Reference Pointers

- Detailed audit: [analysis-report.md](./analysis-report.md)
- Core FSM/transport: `scheduler.c:129-281,462-486,831-895`; `iccp_csm.c:245-281,602-768`; `app_csm.c:80-166`; `mlacp_fsm.c:935-1709`
- Synchronization/data plane: `mlacp_sync_prepare.c:49-146`; `mlacp_sync_update.c:44-210,843-1252,1329-1350`; `mlacp_link_handler.c:1021-1220,2067-2439,2654-3637`
- Recovery/events: `iccp_netlink.c:166-329,668-1070,1859-2242`; `iccp_ifm.c:63-114,188-588`; `system.c:75-127,175-190`
- Wire/state definitions: `iccp_csm.h:40,82-148`; `mlacp_fsm.h:39-61`; `mlacp_tlv.h:447-470`; `msg_format.h:503-508`; `system.h:296-340`
- Reference: [RFC 7275 — Inter-Chassis Communication Protocol for L2VPN PE Redundancy](https://www.rfc-editor.org/rfc/rfc7275.html)
- Central open fixes: [#7724](https://github.com/sonic-net/sonic-buildimage/pull/7724), [#7684](https://github.com/sonic-net/sonic-buildimage/pull/7684), [#7685](https://github.com/sonic-net/sonic-buildimage/pull/7685), [#7714](https://github.com/sonic-net/sonic-buildimage/pull/7714), [#7769](https://github.com/sonic-net/sonic-buildimage/pull/7769), [#24868](https://github.com/sonic-net/sonic-buildimage/pull/24868), [#27611](https://github.com/sonic-net/sonic-buildimage/pull/27611)
- Historical fixes: [#5112](https://github.com/sonic-net/sonic-buildimage/pull/5112), [#5214](https://github.com/sonic-net/sonic-buildimage/pull/5214), [#11197](https://github.com/sonic-net/sonic-buildimage/pull/11197), [#11694](https://github.com/sonic-net/sonic-buildimage/pull/11694), [#18270](https://github.com/sonic-net/sonic-buildimage/pull/18270), [#21172](https://github.com/sonic-net/sonic-buildimage/pull/21172), [#26567](https://github.com/sonic-net/sonic-buildimage/pull/26567), [#26930](https://github.com/sonic-net/sonic-buildimage/pull/26930)
