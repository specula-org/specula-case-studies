# Analysis Report: sonic-net/sonic-dash-ha

## Overview

- **System**: sonic-dash-ha — Rust HA manager for SONiC SmartSwitch DPU pairs
- **Repository**: https://github.com/sonic-net/sonic-dash-ha
- **Language**: Rust (tokio async, actor-based)
- **Total commits analyzed**: 111
- **Bug-fix commits deeply analyzed**: 12
- **GitHub issues deeply read (full comments)**: 19/19
- **GitHub PRs deeply read**: 26 (including the large open PR #145)
- **Core files deeply analyzed**: 6 (ha_scope.rs, ha_set.rs, dpu.rs, vdpu.rs, actors.rs, driver.rs + state modules)
- **Design documents read**: 3 (HLD 1936 lines, hamgrd design, detailed design)

---

## Phase 1: Reconnaissance

### Codebase Structure

| Crate | Purpose |
|-------|---------|
| hamgrd | HA Manager Daemon — actors, state machine, DB integration |
| swbus-actor | Actor framework: driver, state (incoming/outgoing/internal) |
| swbus-edge | Edge runtime for connecting actors to swbusd |
| swbus-core | Central message bus infrastructure (multiplexer, routing) |
| swbusd | Switch bus daemon server |
| swbus-proto | Protobuf definitions |
| swss-common-bridge | Redis consumer/producer bridge layer |

### Core Files

| File | Lines | Purpose |
|------|-------|---------|
| `crates/hamgrd/src/actors/ha_scope.rs` | 963 | HA scope state machine (per ENI/DPU) |
| `crates/hamgrd/src/actors/ha_set.rs` | 1145 | HA set management, VNet routes, BFD sessions |
| `crates/hamgrd/src/actors/dpu.rs` | 657 | DPU lifecycle, health monitoring |
| `crates/hamgrd/src/actors/vdpu.rs` | 223 | Virtual DPU abstraction |
| `crates/hamgrd/src/actors.rs` | 297 | Actor trait, ActorCreator, spawning |
| `crates/hamgrd/src/ha_actor_messages.rs` | 212 | Inter-actor message definitions |
| `crates/hamgrd/src/db_structs.rs` | 835 | Redis DB schema structs |
| `crates/swbus-actor/src/driver.rs` | ~210 | Actor execution loop (select!) |
| `crates/swbus-actor/src/state/incoming.rs` | ~175 | Incoming state table |
| `crates/swbus-actor/src/state/outgoing.rs` | ~270 | Outgoing message queue with resend |
| `crates/swbus-actor/src/state/internal.rs` | ~175 | Redis-backed internal state with COW |

### Concurrency Model

- **Runtime**: tokio async/await, `#[tokio::main]`
- **Per-actor**: Single tokio task with `select!` loop (driver.rs:44)
- **Message passing**: mpsc channels (capacity 10) between actors via swbus
- **State isolation**: Each actor has private Incoming/Outgoing/Internal state
- **DB bridges**: Separate tokio tasks per ConsumerBridge (fire-and-forget)
- **No locks between actors**: All coordination via async message passing

### Actor Hierarchy

```
DPU Actor (per physical DPU, from CONFIG_DB)
  -> VDpu Actor (per virtual DPU, from CONFIG_DB)
    -> HA Set Actor (per HA pair, from DASH_HA_SET_CONFIG_TABLE)
      -> HA Scope Actor (per ENI/DPU scope, from DASH_HA_SCOPE_CONFIG_TABLE)
```

State propagates bottom-up via registration/update messages.
Config arrives top-down via consumer bridges from Redis tables.

---

## Phase 2: Bug Archaeology

### Git History Bug-Fix Commits

| # | Commit | Summary | Root Cause | Component | Severity |
|---|--------|---------|------------|-----------|----------|
| 1 | `4e3706a` | local_ha_state set to ha_role instead of ha_state | Wrong field access | ha_scope.rs | High |
| 2 | `90c10b6` | IPv4 endianness mismatch (bytes reversed) | Missing endian conversion | proto/lib.rs | High |
| 3 | `a9021cf` | Route announcements bounce through intermediate nodes | Missing routing guard + TTL | swbus-core | High |
| 4 | `2c589e7` | Actor handler not unregistered on termination | Missing Drop cleanup | swbus-edge | High |
| 5 | `c2e8f44` | First BFD probe update lost after HA establishment | Stale SubscriberStateTable buffer | consumer.rs | High |
| 6 | `570db05` | Dual-stack service path mismatch breaks CLI | Ambiguous IP-based identity | swbus-config | High |
| 7 | `01a88ef` | No-change DPU_STATE updates flood entire pipeline | Missing deduplication | consumer.rs | Medium |
| 8 | `58dbc27` | swbusd intercepts all ManagementRequests | Missing destination check | conn_worker.rs | Medium |
| 9 | `0a719f6` | Entry-not-found conflated with decode error | Missing error discrimination | incoming.rs | Medium |
| 10 | `f36ffdd` | BFD probe state parsing fails on quoted/padded fields | Input format mismatch | db_structs.rs | Medium |
| 11 | `e205d4d` | Unspecified desired_ha_state not mapped to standby | Missing default mapping | ha_scope.rs | Medium |
| 12 | `817e993` | Route announcements sent on nexthop-only changes | Over-announcement | multiplexer.rs | Low |

### Bug Hotspots (commits touching core files)

| File | Bug-fix Commits |
|------|----------------|
| ha_set.rs | 20 total commits (most changed) |
| db_structs.rs | 19 total commits |
| dpu.rs | 15 total commits |
| ha_scope.rs | 12 total commits |

### GitHub Issues Summary

**Open issues (bug-relevant)**:
- **#139**: Consumer bridge shadowing — second bridge for same table overrides first
- **#99**: DASH_HA_SCOPE_TABLE must be programmed after DASH_HA_SET_TABLE
- **#79**: sent_messages HashMap key collision in outgoing state

**Closed confirmed bugs**: #124 (DPU state out-of-sync after restart), #123 (stale DPU_STATE_DB entries), #118 (dual-stack regression), #111 (stale handler leak), #100 (DELETE op unhandled), #91 (ha_role vs ha_state)

**Open PR #145** (NPU-driven HA, +5065/-993 lines) — review flagged:
- Circular dependency deadlock between peer ha-scope actors during deletion
- `send_with_delay` timing confusion (timestamp dual purpose)
- Shared retry_count for independent workflows
- Panic on missing optional config field
- `HaSetActorState::new_actor_msg` ignores `up` parameter (hardcodes `true`)

---

## Phase 3: Deep Analysis Findings

### ha_scope.rs (14 findings)

| # | Finding | Severity | Classification |
|---|---------|----------|---------------|
| HS-1 | Test helper still uses ha_role instead of ha_state (not updated with #107 fix) | Medium | test-verifiable |
| HS-2 | HashMap iteration → non-deterministic pending operation ordering | Low | model-checkable |
| HS-3 | `unwrap()` panics on malformed config input (version, desired_ha_state) | Medium | test-verifiable |
| HS-4 | Config handler swallows errors, bypassing driver rollback mechanism | High | model-checkable |
| HS-5 | switchover and brainsplit_recover operations are unimplemented no-ops | High | code-review-only |
| HS-6 | Config arriving before vDPU state leaves HA state fields stale | Medium | model-checkable |
| HS-7 | Unspecified desired state: DPU gets "standby", NPU gets "unspecified" | Medium | model-checkable |
| HS-8 | Pending operations accumulate without bound (no expiry/max) | Low | code-review-only |
| HS-9 | Re-subscription not triggered when ha_set_id changes | High | model-checkable |
| HS-10 | peer_ha_state and peer_term never populated | Medium | code-review-only |
| HS-11 | creation_time and heartbeat hardcoded to 0 | Medium | code-review-only |
| HS-12 | Consumer bridge not cleaned up on deletion | Low | code-review-only |
| HS-13 | DPU scope table key may collide across vDPUs | Medium | model-checkable |
| HS-14 | First-time guard prevents re-subscription on config update | High | model-checkable |

### ha_set.rs (16 findings)

| # | Finding | Severity | Classification |
|---|---------|----------|---------------|
| SET-1 | No primary election — purely config-driven preferred_vdpu_id | Info | model-checkable |
| SET-2 | Two DPUs can both believe they are primary (no mutual exclusion) | High | model-checkable |
| SET-3 | No peer coordination, no heartbeat, no failure detection | Info | model-checkable |
| SET-4 | First config skips BFD session + VNet route creation | Medium | model-checkable |
| SET-5 | delete_dash_ha_set_table does NOT notify ha-scope actors | Medium | model-checkable |
| SET-6 | Hard-coded `vdpus[0]`/`vdpus[1]` panics if < 2 VDPUs | High | test-verifiable |
| SET-7 | preferred_vdpu_id not validated against vdpu_ids | Low | code-review-only |
| SET-8 | `unwrap()` on protobuf deserialization panics actor on malformed config | High | test-verifiable |
| SET-9 | HaSetActorState::new_actor_msg ignores `up` parameter (hardcodes `true`) | Medium | code-review-only |
| SET-10 | Config not cleared on delete before actor stop | Low | model-checkable |
| SET-11 | Multi-step DB update (ha_set + vnet route + BFD) non-atomic | Medium | model-checkable |
| SET-12 | Multi-step cleanup can fail partway, leaving orphaned DB entries | Medium | model-checkable |
| SET-13 | Global config deletion not handled; no retry if absent | Low | code-review-only |
| SET-14 | HaSet cleanup fails silently if not all vDPU states available | Medium | model-checkable |
| SET-15 | Empty preferred_vdpu_id produces `Some(vec![])` for primary field | Low | code-review-only |
| SET-16 | VNet route key malformed if vip_v4 is None | Low | test-verifiable |

### dpu.rs + vdpu.rs (20 findings)

| # | Finding | Severity | Classification |
|---|---------|----------|---------------|
| DPU-1 | Pmon transition check misses data_plane_state (inconsistent with calculate_dpu_state) | Medium | model-checkable |
| DPU-2 | DPU deletion does NOT notify registered vDPU actors | High | model-checkable |
| DPU-3 | Remote DPU deletion skips all cleanup | High | model-checkable |
| DPU-4 | Child actors can outlive parents (orphaned actors) | High | model-checkable |
| DPU-5 | vDPU drops ALL messages before config arrives (state lost) | Medium | model-checkable |
| DPU-6 | Non-atomic multi-hop state propagation (DPU→vDPU→HA-Set→HA-Scope) | Medium | model-checkable |
| DPU-7 | DEL message for non-existent actor is dropped | Medium | model-checkable |
| DPU-8 | Stale registrations persist — no GC/TTL mechanism | High | model-checkable |
| DPU-9 | Cold-start pmon transition writes spurious reset record | Medium | test-verifiable |
| DPU-10 | Remote DPU always reported up=false (by design, but affects modeling) | Info | model-checkable |
| DPU-11 | Consumer bridges accumulated but never cleaned up | Low | code-review-only |
| DPU-12 | DPU_STATE key selector hardcodes prefix length (fragile) | Medium | test-verifiable |
| DPU-13 | VDpu re-registers on every config update (unnecessary messages) | Low | code-review-only |
| DPU-14 | vDPU calculate_vdpu_state unwrap fragility | Low | code-review-only |
| DPU-15 | Reset info uses inconsistent DPU ID format | Low | code-review-only |
| DPU-16 | Creation message race after actor spawn | Low | model-checkable |
| DPU-17 | Decode errors silently produce None, treated as "not available" | Low | test-verifiable |
| DPU-18 | BFD health allows single session up as "healthy" | Info | model-checkable |
| DPU-19 | HaSet cleanup fails if vDPU states unavailable (early return) | Medium | model-checkable |
| DPU-20 | HaSetActorState::new_actor_msg ignores `up` param | Medium | code-review-only |

### Actor Framework (11 findings)

| # | Finding | Severity | Classification |
|---|---------|----------|---------------|
| FW-1 | Incoming response sent BEFORE actor handles message (sender thinks success) | High | model-checkable |
| FW-2 | No rollback of incoming state on actor error | Medium | model-checkable |
| FW-3 | Crash window between commit_changes and send_queued_messages (split-brain) | High | model-checkable |
| FW-4 | Consumer bridge is fire-and-forget — DB updates silently lost | High | model-checkable |
| FW-5 | sent_messages key collision (#79) — observability only | Low | test-verifiable |
| FW-6 | time_sent never updated on resend (every-tick resend after first) | Medium | test-verifiable |
| FW-7 | Silent 1-hour drop of unacked messages (no actor notification) | Medium | model-checkable |
| FW-8 | remove_handler by ServicePath can remove new actor's handler | High | model-checkable |
| FW-9 | `todo!()` panic in process_incoming_message on full queue | High | test-verifiable |
| FW-10 | ZmqConsumerStateTable cannot rehydrate (state lost on restart) | Medium | model-checkable |
| FW-11 | Resend uses same message (no dedup at receiver) | Medium | model-checkable |

### Design Document Deviation Analysis

| # | Design Spec | Code Reality | Impact |
|---|-------------|-------------|--------|
| DEV-1 | 11-state machine with RequestVote-based primary election | No election protocol; config-driven preferred_vdpu_id only | Election correctness unverifiable |
| DEV-2 | Term monotonicity; higher term wins election | ha_term never populated in NPU state | Term-based decisions impossible |
| DEV-3 | switchover via SwitchOver message + SwitchingToActive/SwitchingToStandby states | switchover operation is unimplemented TODO | Planned switchover broken |
| DEV-4 | brainsplit_recover workflow | brainsplit_recover is unimplemented TODO | Split-brain recovery broken |
| DEV-5 | Peer hamgrd exchange ha_state and ha_term | No peer communication exists (#77) | No cross-switch coordination |
| DEV-6 | Standalone-Standby (never Standalone-Standalone) | No mechanism enforces this — both could be standalone | Safety invariant unenforceable |
| DEV-7 | Actor heartbeat timer for leak detection | Heartbeat hardcoded to 0 (#76) | Leak detection non-functional |
| DEV-8 | BFD delayed until SAI create switch completes | No such guard in code | BFD probes may start too early |
| DEV-9 | Single decision maker per ENI invariant | No runtime enforcement in hamgrd | Core safety property unchecked |

---

## Phase 3: Bug Family Grouping

### Family 1: Actor Lifecycle — Deletion Notification and Orphan Actors (HIGH)

**Mechanism**: When actors are deleted (config entry removed), downstream actors are not notified, leading to orphaned actors with stale state, stale registrations, and leaked DB entries.

**Evidence**:
- Historical: #111 (stale handler leak, fixed by PR #115), #100 (DELETE unhandled, fixed by PR #102)
- Code analysis: DPU deletion doesn't notify vDPU actors (dpu.rs:137-140), Remote DPU deletion skips all cleanup (dpu.rs:376-378), delete_dash_ha_set_table doesn't notify ha-scope actors (ha_set.rs:154-170), HaSetActorState::new_actor_msg ignores `up` parameter (ha_actor_messages.rs:145), stale registrations persist without GC (ha_actor_messages.rs:194-207), handler removal by ServicePath can remove wrong actor (simple_client.rs:244)
- PR #145 review: circular dependency deadlock between peer ha-scope actors during deletion

**Affected code paths**: DpuActor::do_cleanup, RemoteDpuActor deletion, HaSetActor::delete_dash_ha_set_table, ActorRegistration::get_registered_actors, SimpleSwbusEdgeClient::drop

**Assessment**: 6 confirmed findings sharing the same root cause. 2 historical bugs in this family already fixed. The orphan-actor problem is architecturally systematic — every parent-child boundary in the hierarchy has the same gap. Highly suitable for TLA+ modeling of actor lifecycle transitions.

---

### Family 2: Message Ordering and Missing State Under Reordering (HIGH)

**Mechanism**: Actors receive configuration and state messages from independent sources (CONFIG_DB, STATE_DB, peer actors). Messages can arrive in any order. Multiple code paths silently skip work when expected state is not yet available, with no retry mechanism, leaving the system in a partially-initialized state.

**Evidence**:
- Historical: #99 (DASH_HA_SCOPE_TABLE before DASH_HA_SET_TABLE ordering), #139 (consumer bridge shadowing — second bridge overrides first), PR #121 (BFD probe update lost due to stale buffer)
- Code analysis: Config before vDPU state leaves HA state fields stale (ha_scope.rs:511-513), vDPU drops all messages before config arrives (vdpu.rs:143-145), first ha_set config skips BFD/VNet creation (ha_set.rs:561-569), DEL for non-existent actor dropped (actors.rs:153-158), consumer bridge fire-and-forget (consumer.rs:96-102, 119-127)

**Affected code paths**: HaScopeActor::handle_dash_ha_scope_config_table_message, VDpuActor::handle_message, HaSetActor::handle_dash_ha_set_config_table_message, ActorCreator::handle_received_message, ConsumerBridge::run

**Assessment**: 5+ confirmed findings. The "skip and hope the next event fixes it" pattern is pervasive. The system has no end-to-end consistency mechanism — if the right sequence of events doesn't happen, state can be permanently stale. TLA+ can systematically explore all message orderings.

---

### Family 3: Non-Atomic Operations and Crash Recovery (MEDIUM)

**Mechanism**: Multi-step operations (DB writes + message sends) are not atomic. A crash between steps leaves inconsistent state. The driver's commit sequence (internal.commit_changes → outgoing.send_queued_messages) has a crash window where local state is persisted but peer notifications are never sent.

**Evidence**:
- Historical: #123 (DPU state out-of-sync after restart), #124 (cannot bring DPU back up after shutdown)
- Code analysis: Crash between commit_changes and send_queued_messages (driver.rs:149-150), multi-step ha_set DB updates (ha_set.rs:585-597), multi-step cleanup failures (ha_set.rs:621-643), config handler swallows errors bypassing rollback (ha_scope.rs:643-646), ZmqConsumerStateTable cannot rehydrate (consumer.rs:166-171)

**Affected code paths**: ActorDriver::handle_actor_message, HaSetActor::handle_vdpu_state_update, HaSetActor::do_cleanup, HaScopeActor::handle_message

**Assessment**: 2 historical bugs (now fixed) demonstrate real crash-recovery issues. The commit sequence crash window is a fundamental design concern. TLA+ can model crash + restart to verify state consistency.

---

### Family 4: HA State Machine Protocol Incompleteness (HIGH)

**Mechanism**: The design documents specify an 11-state machine with RequestVote-based primary election, term management, planned switchover, and brainsplit recovery. The implementation has none of these — it is purely configuration-driven with no peer communication protocol.

**Evidence**:
- Design: HLD Section 7.1-7.4 specifies full state machine with RequestVote, SwitchOver, HAStateChanged messages
- Code: No election protocol (ha_set.rs:346-358 — preferred_vdpu_id from config only), switchover/brainsplit_recover are TODO no-ops (ha_scope.rs:257-268), peer_ha_state/peer_term never populated (db_structs.rs:434-436), no peer communication (#77)
- Open PR #145 (NPU-driven HA) is adding infrastructure for this, but introduces new concerns: shared retry counters, circular dependency deadlock potential, timing confusion in send_with_delay

**Affected code paths**: The entire HA state machine in ha_scope.rs, primary election in ha_set.rs

**Assessment**: The current code is effectively a placeholder. PR #145 is building toward the real protocol. This is the highest-priority modeling target because the spec would define the protocol BEFORE it is fully implemented, enabling verification of the design. The design doc's election algorithm and state transitions are the reference.

---

### Family 5: Health Monitoring Inconsistency (MEDIUM)

**Mechanism**: Health determination uses inconsistent criteria across different code paths. A DPU can appear healthy by one measure but unhealthy by another, leading to delayed or missed failover.

**Evidence**:
- Historical: PR #121 (BFD probe update lost), PR #113 (BFD state parsing failures)
- Code analysis: calculate_dpu_state checks 3 pmon signals but handle_pmon_transition only checks 2 (dpu.rs:289-290 vs 257-259), single BFD session counts as "healthy" (dpu.rs:261-262), remote DPU always up=false (dpu.rs:236-239), Unspecified desired state reports differently to DPU vs NPU (ha_scope.rs:282-283 vs 451-456)
- Design: "Traffic will only be forwarded when both BFD probe and ENI-level probe are up" (HLD Section 6.4.1), but ENI-level probe is explicitly skipped

**Affected code paths**: DpuActor::calculate_dpu_state, DpuActor::handle_pmon_transition, HaScopeActor::update_npu_ha_scope_state_ha_state

**Assessment**: Health monitoring inconsistency has caused 2 historical bugs. The code-vs-design gap (ENI-level probe skipped, data_plane_state not checked consistently) creates realistic failure scenarios. Partially model-checkable — the health signal → state transition logic can be modeled.

---

## Coverage Statistics

| Metric | Count |
|--------|-------|
| Total git commits | 111 |
| Bug-fix commits analyzed | 12 |
| GitHub issues (total) | 19 |
| GitHub issues deeply read | 19 (100%) |
| GitHub PRs read | 26 |
| Core files deeply analyzed | 11 |
| Design documents read | 3 |
| Total findings | 61 |
| Findings confirmed | 45 |
| Findings suspected | 12 |
| Findings informational | 4 |
| Bug Families identified | 5 |
| Unique historical bugs | 14 (12 commits + 2 open issues) |
| False positives excluded | 3 (#75 ZMQ reconnect not needed, #54 MSRV request, #78 UI cleanup) |
