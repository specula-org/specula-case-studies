# Modeling Brief: sonic-net/sonic-dash-ha

## 1. System Overview

- **System**: sonic-dash-ha — HA manager (hamgrd) for SONiC SmartSwitch DPU pairs
- **Language**: Rust, ~4000 LOC core logic (ha_scope.rs + ha_set.rs + dpu.rs + vdpu.rs + actors.rs + actor framework)
- **Protocol**: SmartSwitch HA state machine — 11-state active-standby failover for DPU pairs
- **Key architectural choices**:
  - **Actor hierarchy** with async message passing (DPU → vDPU → HA-Set → HA-Scope), no locks between actors
  - **Redis-backed state** persistence with copy-on-write rollback (internal state table)
  - **Fire-and-forget consumer bridges** from Redis tables (at-most-once delivery to actors)
  - **Two-phase commit** in driver: `commit_changes()` (Redis) then `send_queued_messages()` (swbus) — crash window between them
  - **No peer communication protocol implemented yet** — primary election is purely config-driven (`preferred_vdpu_id`). The design docs specify a RequestVote-based election with term management, but this is not in the code. Open PR #145 is building toward it.
- **Concurrency model**: Single tokio task per actor with `select!` loop; actors communicate via mpsc channels through swbus routing

## 2. Bug Families

### Family 1: Actor Lifecycle — Deletion Notification Gaps (HIGH)

**Mechanism**: When actors are deleted (config entry removed from Redis), downstream actors are not notified. This leaves orphaned actors running with stale state, stale registrations pointing to dead actors, and leaked DB entries.

**Evidence**:
- Historical: #111 — actor handler not unregistered on termination (fixed PR #115). #100 — DELETE op unhandled by hamgrd (fixed PR #102). PR #145 review — circular dependency deadlock between peer ha-scope actors during deletion.
- Code analysis: DPU deletion doesn't notify vDPU actors (`dpu.rs:137-140`). Remote DPU deletion skips all cleanup (`dpu.rs:376-378`). `delete_dash_ha_set_table` doesn't notify ha-scope actors (`ha_set.rs:154-170`). `HaSetActorState::new_actor_msg` ignores `up` parameter, hardcodes `true` (`ha_actor_messages.rs:145`). Stale registrations persist without GC (`ha_actor_messages.rs:194-207`). `remove_handler` by ServicePath can remove a *new* actor's handler if old actor drops late (`simple_client.rs:244`, `route_map.rs:26-27`).

**Affected code paths**: `DpuActor::do_cleanup`, remote DPU `handle_remote_dpu_message` Del branch, `HaSetActor::delete_dash_ha_set_table`, `ActorRegistration::get_registered_actors`, `SimpleSwbusEdgeClient::drop`

**Suggested modeling approach**:
- Variables: `actorState [ActorId -> {alive, dead}]`, `registrations [ActorId -> SUBSET ActorId]`, `pendingMessages [ActorId -> Seq(Message)]`
- Actions: `DeleteActor(id)` — marks dead but does NOT propagate. `PropagateDown(parent, child)` — explicit notification. `OrphanDetect` — periodic GC check.
- Key property: after deletion cascade completes, no alive actor holds a registration to a dead actor.

**Priority**: High
**Rationale**: 3 historical bugs, 6 new findings, all sharing the same architectural gap. Every parent-child boundary in the 4-level hierarchy has this problem. Directly model-checkable.

---

### Family 2: Message Ordering and Missing State (HIGH)

**Mechanism**: Actors receive configuration and state from independent Redis tables via fire-and-forget consumer bridges. Messages can arrive in any order. Multiple code paths silently skip processing when prerequisite state is missing, with no retry mechanism — leaving the system permanently in a partially-initialized state if the "right" event sequence doesn't occur.

**Evidence**:
- Historical: #99 — DASH_HA_SCOPE_TABLE must come after DASH_HA_SET_TABLE (open). #139 — consumer bridge shadowing loses updates (open). PR #121 — first BFD probe update lost (stale buffer).
- Code analysis: Config before vDPU state leaves HA state fields stale (`ha_scope.rs:511-513`) — `handle_vdpu_state_update` does NOT call `update_npu_ha_scope_state_ha_state`. vDPU drops ALL messages before config arrives (`vdpu.rs:143-145`). First ha_set config skips BFD/VNet route creation (`ha_set.rs:561-569`). DEL for non-existent actor is silently dropped (`actors.rs:153-158`). Consumer bridge fire-and-forget (`consumer.rs:96-102`).

**Affected code paths**: `HaScopeActor::handle_dash_ha_scope_config_table_message`, `VDpuActor::handle_message`, `HaSetActor::handle_dash_ha_set_config_table_message`, `ActorCreator::handle_received_message`, `ConsumerBridge::run`

**Suggested modeling approach**:
- Variables: `configReceived [ActorId -> BOOLEAN]`, `stateReceived [ActorId -> [Source -> BOOLEAN]]`
- Actions: Non-deterministic message delivery order. `ReceiveConfig`, `ReceiveVdpuState`, `ReceiveHaSetState`, `ReceiveDpuState` — each with guards checking prerequisites.
- Model both "happy path" (correct order) and adversarial orderings. Check that eventual consistency is reached regardless of ordering.
- Include message loss (consumer bridge fire-and-forget) as a fault injection action.

**Priority**: High
**Rationale**: 3 historical bugs, 5 new findings. The "skip-and-hope" pattern is pervasive. TLA+ is ideal for exhaustive ordering exploration.

---

### Family 3: Non-Atomic Operations and Crash Recovery (MEDIUM)

**Mechanism**: The actor driver commits state in two sequential steps: (1) write to Redis via `internal.commit_changes()`, (2) send messages via `outgoing.send_queued_messages()`. A crash between steps creates split-brain: local state is updated but peer actors are never notified. Multi-step cleanup operations similarly leave partial state on failure.

**Evidence**:
- Historical: #123 — DPU state out-of-sync after restart (stale Redis entries). #124 — cannot bring DPU back up after planned shutdown.
- Code analysis: Crash window between commit_changes and send_queued_messages (`driver.rs:149-150`). Multi-step ha_set DB updates are non-atomic (`ha_set.rs:585-597` — ha_set_table + vnet_route + bfd_sessions). Config handler swallows errors, bypassing driver rollback (`ha_scope.rs:643-646`). ZmqConsumerStateTable cannot rehydrate on restart (`consumer.rs:166-171`). Unacked messages silently dropped after 1 hour (`outgoing.rs:121-122`).

**Affected code paths**: `ActorDriver::handle_actor_message` (commit sequence), `HaSetActor::handle_vdpu_state_update`, `HaSetActor::do_cleanup`, `HaScopeActor::handle_message` (error swallowing)

**Suggested modeling approach**:
- Variables: `redisState [Table -> [Key -> Value]]`, `actorVolatileState [ActorId -> State]`, `pendingOutgoing [ActorId -> Seq(Message)]`
- Actions: `Crash(actorId)` — resets volatile state, clears pending outgoing, preserves redisState. `Recover(actorId)` — rehydrates from redisState. Split `HandleMessage` into `CommitToRedis` + `SendOutgoing` with `Crash` interposable.
- Key property: after crash and recovery, the actor's state is consistent with Redis AND peer actors eventually converge.

**Priority**: Medium
**Rationale**: 2 historical bugs. The commit sequence crash window is a fundamental design concern but mitigated by eventual resend/rehydration for most paths. Worth modeling but lower priority than Families 1-2 which have more findings.

---

### Family 4: HA State Machine Protocol (HIGH — for spec design)

**Mechanism**: The design documents specify an 11-state machine with a RequestVote-based primary election (term comparison, desired-state tiebreaking), planned switchover (SwitchOver + SwitchingToActive/SwitchingToStandby), and brainsplit recovery. The current implementation has none of this — it is a config-driven stub. PR #145 is building the infrastructure.

**Evidence**:
- Design docs: HLD Section 7.1-7.4 (state machine), Section 7.3 (election algorithm), Section 8.2 (switchover), Section 10.1 (standalone operation)
- Code gaps: No election protocol (`ha_set.rs:346-358` — preferred_vdpu_id from config). switchover/brainsplit_recover are TODO (`ha_scope.rs:257-268`). peer_ha_state/peer_term never populated (`db_structs.rs:434-436`). No peer communication (#77). Standalone-Standalone pair not prevented.
- PR #145 concerns: shared retry_count for independent workflows, circular dependency deadlock between peer actors, send_with_delay timing confusion

**Affected code paths**: `HaScopeActor` (entire state machine), `HaSetActor` (primary election)

**Suggested modeling approach**:
- This is a **spec-first** modeling target. Model the protocol from the design docs, NOT from the current code.
- Variables: `haState [Node -> HAState]` (11 states), `haTerm [Node -> Nat]`, `desiredState [Node -> DesiredState]`, `peerState [Node -> HAState]` (last known), `messages [Seq(Message)]` (RequestVote, BecomeActive/Standby/Standalone, SwitchOver, HAStateChanged, BulkSyncDone)
- Actions per HLD Section 7.3 election algorithm and Section 7.1 state transition table
- Key invariants: SingleDecisionMaker (at most one Active or Standalone-making-decisions per ENI), NoStandaloneStandalonePair, TermMonotonicity, ElectionConvergence (liveness)

**Priority**: High
**Rationale**: The core protocol hasn't been implemented yet. Modeling it first enables verification BEFORE the code is written — maximum value from formal verification. The election algorithm and switchover protocol have clear invariants from the design docs.

---

### Family 5: Health Monitoring Inconsistency (MEDIUM)

**Mechanism**: DPU health is determined by combining pmon signals (midplane, control plane, data plane) and BFD probe status. Different code paths use different subsets of these signals, creating windows where a DPU appears healthy by one measure but not another.

**Evidence**:
- Historical: PR #121 — first BFD probe update lost. PR #113 — BFD state parsing failures.
- Code analysis: `calculate_dpu_state` checks 3 pmon signals but `handle_pmon_transition` only checks 2 (`dpu.rs:289-290` vs `257-259`). Single BFD session = healthy (`dpu.rs:261-262`). Remote DPU always `up=false` (`dpu.rs:236-239`). Unspecified desired state: DPU told "standby" but NPU reports "unspecified" (`ha_scope.rs:282-283` vs `451-456`).

**Suggested modeling approach**:
- Variables: `pmonState [DPU -> [Signal -> {up, down}]]`, `bfdState [DPU -> [Session -> {up, down}]]`, `dpuHealth [DPU -> BOOLEAN]`
- Actions: `PmonSignalChange(dpu, signal, value)`, `BfdSessionChange(dpu, session, value)`, `CalculateHealth(dpu)`
- Check: health determination is consistent across all code paths.

**Priority**: Medium
**Rationale**: 2 historical bugs. Partially model-checkable. The inconsistency between `calculate_dpu_state` and `handle_pmon_transition` is a concrete finding, but the DPU health → HA state interaction is the more important modeling target (captured in Family 4).

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| HA state machine (11 states) | Family 4: core protocol not yet implemented, design doc is the reference | Model from HLD spec, not code. Per-ENI process with state enum. |
| Primary election (RequestVote) | Family 4: term-based election with tiebreaking rules from HLD Section 7.3 | Two-node election with term comparison, desired-state tiebreaking |
| Planned switchover | Family 4: SwitchOver + SwitchingToActive/SwitchingToStandby transient states | Model message exchange and transient states; verify single-decision-maker |
| Actor lifecycle (create/delete) | Family 1: 6 findings on deletion notification gaps | Model 4-level hierarchy with create/delete actions; verify no orphans |
| Message ordering | Family 2: 5 findings on ordering-dependent behavior | Non-deterministic delivery from independent sources; verify eventual consistency |
| Crash and recovery | Family 3: crash window between Redis write and message send | Split commit into two steps; add Crash action; verify recovery consistency |
| Health signals → HA state | Family 5: inconsistent health criteria feed into state transitions | Abstract pmon + BFD into health boolean; model health → state transition |
| Unreliable message delivery | Families 1-3: fire-and-forget bridges, message loss, 1-hour silent drop | Model message loss as non-deterministic; verify safety under loss |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| Redis internals | Abstract Redis as reliable shared store with per-key read/write. Redis itself is not the bug source. |
| swbus routing/multiplexing | 1700-line multiplexer is infrastructure. Abstract as unreliable async delivery. |
| BFD protocol details | BFD is an external system. Model as an oracle that reports session up/down. |
| Protobuf serialization | Parsing bugs (PR #113, endianness) are implementation issues, not protocol logic. |
| VNet route / tunnel management | Downstream of HA state decisions. Not part of the HA protocol. |
| Data plane flow replication | Explicitly out of scope per design — handled by DPU hardware, not hamgrd. |
| swbusd route exchange | Fixed bugs (#117, #130) are in infrastructure, not HA protocol. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Actor lifecycle | `actorAlive`, `registrations`, `pendingNotify` | Track create/delete propagation through hierarchy | Family 1 |
| Message ordering | `configReady`, `stateReady`, `messageQueue` per actor | Model independent message arrival and skip-on-missing behavior | Family 2 |
| Crash recovery | `redisState`, `volatileState`, `commitPhase` | Split commit into Redis-write + message-send with crash between | Family 3 |
| Election protocol | `haTerm`, `desiredState`, `retryCount` | Full RequestVote algorithm from HLD Section 7.3 | Family 4 |
| Switchover | `switchoverRequested`, transient states | SwitchOver message + SwitchingToActive/SwitchingToStandby | Family 4 |
| Health signals | `pmonUp`, `bfdUp`, `dpuHealth` | Abstract health inputs feeding into state transitions | Family 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| SingleDecisionMaker | Safety | At most one node in {Active, Standalone, SwitchingToActive} per ENI at any time | Family 4 |
| NoStandaloneStandalone | Safety | Both nodes cannot be in Standalone simultaneously | Family 4 |
| TermMonotonicity | Safety | Terms only increase; a node never decreases its term | Family 4 |
| ElectionDeterminism | Safety | Given same term + desired state, election always produces the same outcome | Family 4 |
| NoOrphanActors | Safety | After deletion cascade, no alive actor holds a registration to a dead actor | Family 1 |
| EventualStateConsistency | Liveness | Regardless of message ordering, all actors eventually reach consistent state | Family 2 |
| CrashRecoveryConsistency | Safety | After crash + restart, Redis state and actor volatile state are consistent | Family 3 |
| HealthTransitionCompleteness | Safety | Every health signal change eventually triggers a state machine transition | Family 5 |
| SwitchoverSafety | Safety | During planned switchover, exactly one node can make flow decisions at all times | Family 4 |
| ElectionConvergence | Liveness | Two connected nodes in Connected state eventually reach Active-Standby or Standalone-Standby | Family 4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | DPU deletion doesn't notify vDPU → orphaned actors with stale state | NoOrphanActors | 1 |
| MC-2 | delete_dash_ha_set_table doesn't notify ha-scope → stale HaSetActorState | NoOrphanActors | 1 |
| MC-3 | Config before vDPU state → HA state fields permanently stale | EventualStateConsistency | 2 |
| MC-4 | vDPU drops messages before config → state lost forever | EventualStateConsistency | 2 |
| MC-5 | First ha_set config skips BFD/VNet → never created without subsequent event | EventualStateConsistency | 2 |
| MC-6 | Crash between commit_changes and send_queued_messages → split-brain | CrashRecoveryConsistency | 3 |
| MC-7 | Config handler swallows error → partial state committed (bypasses rollback) | CrashRecoveryConsistency | 3 |
| MC-8 | Election with equal terms + both desired Active → possible deadlock/livelock | ElectionConvergence | 4 |
| MC-9 | Both nodes enter Standalone simultaneously (peer down detection race) | NoStandaloneStandalone | 4 |
| MC-10 | Switchover during concurrent DPU failure → dual decision maker | SingleDecisionMaker, SwitchoverSafety | 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | `unwrap()` panics on malformed config (ha_scope.rs:277, ha_set.rs:516) | Fuzz test with malformed Redis entries |
| TV-2 | `vdpus[0]`/`vdpus[1]` panics if < 2 VDPUs (ha_set.rs:89) | Unit test with 0/1 vDPU config |
| TV-3 | Test helper uses ha_role instead of ha_state (test.rs:606,610) | Fix test to use ha_state; add test where ha_role ≠ ha_state |
| TV-4 | `todo!()` panic on full receive queue (core_client.rs:203) | Load test with many concurrent messages |
| TV-5 | Cold-start pmon transition writes spurious reset (dpu.rs:294-298) | Integration test: restart hamgrd while DPU is down |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | switchover/brainsplit_recover are unimplemented TODOs (ha_scope.rs:257-268) | Implement per HLD Section 8.2 and Section 10.1.5 |
| CR-2 | peer_ha_state/peer_term never populated (db_structs.rs:434-436) | Implement peer state exchange per #77 |
| CR-3 | Heartbeat/creation_time hardcoded to 0 (ha_scope.rs:343-344) | Implement per #76 |
| CR-4 | HaSetActorState::new_actor_msg ignores `up` parameter (ha_actor_messages.rs:145) | Fix to use the parameter |
| CR-5 | Pending operations accumulate without bound (ha_scope.rs:616-624) | Add expiry/max count |

## 7. Reference Pointers

- **Full analysis report**: `case-studies/sonic-dash-ha/analysis-report.md`
- **Key source files**:
  - `artifact/sonic-dash-ha/crates/hamgrd/src/actors/ha_scope.rs` (963 lines — HA state machine)
  - `artifact/sonic-dash-ha/crates/hamgrd/src/actors/ha_set.rs` (1145 lines — HA set, primary config)
  - `artifact/sonic-dash-ha/crates/hamgrd/src/actors/dpu.rs` (657 lines — DPU lifecycle)
  - `artifact/sonic-dash-ha/crates/swbus-actor/src/driver.rs` (~210 lines — actor execution loop)
- **Design documents**:
  - `invariants/smart-switch-ha-hld.md` — Main HLD (11-state machine spec, election algorithm, failure scenarios)
  - `invariants/smart-switch-ha-hamgrd.md` — hamgrd daemon design
  - `invariants/smart-switch-ha-detailed-design.md` — Detailed protocol design
- **GitHub issues**: #139 (consumer bridge shadowing), #99 (table ordering), #79 (key collision), #77 (peer state exchange), #76 (heartbeat timer), #123/#124 (restart desync)
- **GitHub PR**: #145 (NPU-driven HA infrastructure — the most relevant open work)
- **Repository**: https://github.com/sonic-net/sonic-dash-ha
