# dash-ha Modeling Brief

## 1. System Overview

`dash-ha` is a Rust implementation of SONiC SmartSwitch HA; the repository has 79 Rust files (25,482 lines), with about 7.1 KLOC of production HAMgrD core logic.
It is **Category A (Distributed / Message-Passing)** because independently scheduled actors, Redis/ZMQ bridges, and peer NPUs exchange state and control messages over SWBus; it is not a Byzantine protocol.
HAMgrD builds a DPU -> vDPU -> HA-set -> HA-scope actor graph; NPU-owned scopes elect Active/Standby roles, drive failover, and feed route selection back through the HA-set.
Each actor callback is serialized, but actors, timers, bridges, peer links, DB writers, and ASIC acknowledgement paths run concurrently; unlike the reference's abstract idempotent transition, ingress ACK, actor application, Redis commit, outgoing enqueue, DB application, and ASIC ACK are separate.
Registrations and retry queues are volatile; caches and persisted HA state survive different subsets of failures, and peer messages carry no pairing epoch or monotone generation.
The recommended model focuses on NPU-driven HA plus the shared actor lifecycle; DPU-driven pending-operation ordering is included only at an abstract prerequisite/edge level.

## 2. Scenarios

### Scenario 1: Non-atomic acceptance, dependency, and hardware-ack pipeline

**Mechanism**: A logical operation crosses independently scheduled acceptance, persistence, producer, and ASIC stages, while code frequently treats an earlier stage as completion. **Affected code paths**: `ActorDriver::handle_swbus_message`, `handle_actor_message`, `HaSetActor::update_dash_ha_set_table`, both HA-scope drivers, and producer bridges.
**Evidence**:

- Historical: issue [#99](https://github.com/sonic-net/sonic-dash-ha/issues/99) and PR [#205](https://github.com/sonic-net/sonic-dash-ha/pull/205) fixed one registration path but explicitly define “programmed” as write issued, not DPU APPL_DB applied; PRs [#162](https://github.com/sonic-net/sonic-dash-ha/pull/162), [#193](https://github.com/sonic-net/sonic-dash-ha/pull/193), [#199](https://github.com/sonic-net/sonic-dash-ha/pull/199), and [#201](https://github.com/sonic-net/sonic-dash-ha/pull/201) repeatedly tightened later acknowledgement gates.
- Code analysis: ingress returns `Ok` before actor logic (`crates/swbus-actor/src/driver.rs:100-129`); HA-set marks its dependency ready immediately after enqueue (`crates/hamgrd/src/actors/ha_set.rs:180-225`); producer apply/ACK is asynchronous (`crates/swss-common-bridge/src/producer.rs:28-70`); DPU-driven pending edges can arrive before HA-set prerequisites (`crates/hamgrd/src/actors/ha_scope/dpu.rs:158-175`, `crates/hamgrd/src/actors/ha_scope/base.rs:381-405`).

**Suggested modeling approach**:

- **Variables**: `msgAccepted`, `actorApplied`, `haSetIssued/applied`, `scopeIssued/applied`, `cpState`, `asicRole`, `ackedTerm`, `pendingFlagEpoch`, `pendingOps`. **Actions**: split receive/ACK, callback, durable commit, producer apply, DPU request, and ASIC ACK; allow prerequisite and pending-edge delivery in either order. **Granularity**: separate every externally scheduled boundary; never collapse “send” and “apply.”

**Priority**: High — **Rationale**: It spans open issues #99/#171, a known partial fix, and safety-critical table/traffic-role ordering.
### Scenario 2: Unversioned at-least-once replay regresses newer state

**Mechanism**: Distinct request IDs retain old and new values for one logical key; ACK loss and delayed retry can deliver the old value last, while receivers overwrite without freshness checks. **Affected code paths**: actor `Outgoing`/`Incoming`, `handle_peer_ha_scope_state`, HA-set scope-state caching and route selection.
**Evidence**:

- Historical: PR [#121](https://github.com/sonic-net/sonic-dash-ha/pull/121) fixed a lost initial snapshot; PR [#210](https://github.com/sonic-net/sonic-dash-ha/pull/210) restored identical replay; PR [#211](https://github.com/sonic-net/sonic-dash-ha/pull/211) only compensates for one stale-Active cache shape.
- Code analysis: outgoing retains/resends each unacked ID (`crates/swbus-actor/src/state/outgoing.rs:37-59,143-180`); incoming blindly replaces by logical key (`crates/swbus-actor/src/state/incoming.rs:49-72,147-154`); NPU peer state/term and HA-set route cache accept arrival order (`crates/hamgrd/src/actors/ha_scope/npu.rs:708-746`; `crates/hamgrd/src/actors/ha_set.rs:512-526`).

**Suggested modeling approach**:

- **Variables**: a message multiset with `requestId`, `kind`, `generation`, `term`, `acked`, and `deliverAfter`; receiver `seenGeneration` and cached peer/route state. **Actions**: drop ACK, retry, duplicate, delay, and reorder old/new messages independently. **Granularity**: delivery and ACK are distinct actions; use an abstract monotone generation rather than wall-clock timestamp.

**Priority**: High — **Rationale**: The runtime intentionally provides bounded at-least-once behavior, but protocol state has no correlation rule; stale state can affect terms and traffic routes.
### Scenario 3: Re-pair changes address but not protocol epoch

**Mechanism**: A new peer replaces only the configured ID/service path; cached peer facts, old destinations, retries, and handlers remain valid and source identity is discarded. **Affected code paths**: `handle_haset_state_update`, peer message dispatch/handlers, HA-set service-path cache, and outgoing retry.
**Evidence**:

- Historical: PR [#157](https://github.com/sonic-net/sonic-dash-ha/pull/157) added in-flight re-pairing; PR [#209](https://github.com/sonic-net/sonic-dash-ha/pull/209) fixes stale physical connections but not actor-level operation recovery or identity.
- Code analysis: re-pair preserves connection/cache/retry state (`crates/hamgrd/src/actors/ha_scope/npu.rs:539-558`); dispatch does not validate source/destination (`crates/hamgrd/src/actors/ha_scope/npu.rs:73-234`; `crates/hamgrd/src/actors/ha_scope/base.rs:125-136`); old messages can drive state/control (`crates/hamgrd/src/actors/ha_scope/npu.rs:708-990`), while a genuinely fresh peer's first message emits `PeerConnected` but Standalone accepts only `PeerStateChanged` (`crates/hamgrd/src/actors/ha_scope/npu.rs:740-745,1808-1817`).

**Suggested modeling approach**:

- **Variables**: `pairEpoch`, `currentPeer`, per-message `sourcePeer/destinationPeer/epoch`, peer cache epoch, and outstanding requests. **Actions**: `RePair`, old-peer delayed delivery, new-peer delivery, reply routing, crash/recover. **Granularity**: increment the epoch independently from route reconnection and cache clearing.

**Priority**: High — **Rationale**: Old-peer control messages can be applied to a new relationship and threaten election safety; no reviewed change introduced an epoch check.
### Scenario 4: Persist-before-send loses transition intent on crash

**Mechanism**: A transition phase is committed before its required outgoing action, but restart logic reconstructs only some phase-specific actions. **Affected code paths**: `drive_npu_state_machine`, `apply_pending_state_side_effects`, `apply_rehydration_side_effects`, DPU pending-operation handling, and ActorDriver commit/send.
**Evidence**:

- Historical: HLD §7.4 requires every transition action to be safely retried; PR [#159](https://github.com/sonic-net/sonic-dash-ha/pull/159) added rehydration, and its review explicitly left rare split brain and several recovery gaps outside the fix; PR [#177](https://github.com/sonic-net/sonic-dash-ha/pull/177) leaves a first-post-restart `down` edge unreported.
- Code analysis: internal commit precedes outgoing send (`crates/swbus-actor/src/driver.rs:146-153`); rehydration omits `BulkSyncCompleted`, switchover FIN, ordinary failover requests, and some shutdown intent (`crates/hamgrd/src/actors/ha_scope/npu.rs:1261-1348,1395-1433`); DPU-driven restart can regenerate a pending-operation UUID (`crates/hamgrd/src/actors/ha_scope/dpu.rs:158-173`; `crates/hamgrd/src/actors/ha_scope/base.rs:461-473`).

**Suggested modeling approach**:

- **Variables**: `persistedPhase`, `durableIntent`, volatile `queuedActions`, `pendingOperationEpoch/ids`, process `up`, and prerequisite state. **Actions**: crash at every ACK/apply/commit/send cut, clear volatile state, rehydrate, and replay/infer each required action. **Granularity**: phase persistence and each protocol side effect must be separate actions.

**Priority**: High — **Rationale**: The reference makes replayability a core recovery premise; multiple current transition phases violate it and can stall or restore unsafe ownership.
### Scenario 5: Actor deletion/recreation crosses configuration epochs

**Mechanism**: Exact routes and stale child caches outlive deletion, while registrations disappear with the parent; a replacement SET can be acknowledged by the dying actor and discarded. **Affected code paths**: ActorCreator/exact routing, actor cleanup, ConsumerBridge cache, DPU/vDPU/HA-set/scope registration handlers, and child dependency gates.
**Evidence**:

- Historical: issues [#100](https://github.com/sonic-net/sonic-dash-ha/issues/100) and [#111](https://github.com/sonic-net/sonic-dash-ha/issues/111), with PRs [#102](https://github.com/sonic-net/sonic-dash-ha/pull/102), [#115](https://github.com/sonic-net/sonic-dash-ha/pull/115), [#158](https://github.com/sonic-net/sonic-dash-ha/pull/158), [#161](https://github.com/sonic-net/sonic-dash-ha/pull/161), and [#163](https://github.com/sonic-net/sonic-dash-ha/pull/163), show repeated lifecycle failures and bounded cleanup.
- Code analysis: a deleting actor ACKs/ignores SET (`crates/swbus-actor/src/driver.rs:57-97`); the bridge caches and does not retry (`crates/swss-common-bridge/src/consumer.rs:75-80,119-121`); registrations are only volatile incoming entries and are not renewed (`crates/hamgrd/src/ha_actor_messages.rs:267-279`; `crates/hamgrd/src/actors/ha_scope/base.rs:55-69`); HA-set deletion sends no invalidation (`crates/hamgrd/src/actors/ha_set.rs:1005-1026`).

**Suggested modeling approach**:

- **Variables**: per-actor `Absent/Live/Deleting`, `configEpoch`, exact route owner, registrations, child cached-parent epoch, cleanup messages, and bridge cache. **Actions**: parent-first/child-first delete, rapid re-add during drain, isolated parent restart, registration/invalidation, cleanup timeout. **Granularity**: config-row presence, actor existence, route ownership, and subscription membership are separate.

**Priority**: High — **Rationale**: Reachable schedules leave a configured resource with no actor or a child programming against a deleted parent indefinitely.
### Scenario 6: Independent update paths overwrite the elected traffic route

**Mechanism**: Failover-derived and configuration-derived handlers write the same VNET route from different state views without a shared eligibility predicate. **Affected code paths**: HA-set config/global/vDPU/scope-state handlers, `get_vdpus`, scope cache, and `update_vnet_route_tunnel_table`.
**Evidence**:

- Historical: PRs [#175](https://github.com/sonic-net/sonic-dash-ha/pull/175), [#180](https://github.com/sonic-net/sonic-dash-ha/pull/180), and [#211](https://github.com/sonic-net/sonic-dash-ha/pull/211) repeatedly repaired route selection; issue [#179](https://github.com/sonic-net/sonic-dash-ha/issues/179) was a no-peer route failure.
- Code analysis: failover routes from cached scope states (`crates/hamgrd/src/actors/ha_set.rs:603-647,961-994`), but any later HA-set config refresh unconditionally rebuilds from preferred config order (`crates/hamgrd/src/actors/ha_set.rs:427-465,851-858`), even in Switch-owned mode; the cache also drops ASIC ACK/term metadata (`crates/hamgrd/src/actors/ha_set.rs:74-78,512-526`).

**Suggested modeling approach**:

- **Variables**: `haOwner`, preferred DPU, config epoch, eligible scope states/ACKs, route primary/backup, and last writer path. **Actions**: failover, state broadcast, config/pinning/global refresh, stale replay, and route apply in arbitrary order. **Granularity**: compute eligibility and apply the route separately for every writer.

**Priority**: High — **Rationale**: A confirmed current path can redirect traffic to the configured preference while the non-preferred peer remains the sole serving scope.
### Scenario 7: One retry counter couples independent protocols

**Mechanism**: Connection, election, and switchover consume and reset the same counter, so one workflow changes another's timeout decision. **Affected code paths**: `handle_vote_request`, `handle_switchover_request`, `check_peer_connection_and_retry`, and re-pair.
**Evidence**:

- Historical: PR [#209](https://github.com/sonic-net/sonic-dash-ha/pull/209) and its linked production incident require outstanding vote recovery after route/reconnect failures; no reviewed PR addressed operation-scoped budgets.
- Code analysis: one `retry_count` is used by vote handling, switchover RST, and connection checks (`crates/hamgrd/src/actors/ha_scope/npu.rs:27-54,818-881,925-955,1947-1978`).

**Suggested modeling approach**:

- **Variables**: an implementation `sharedRetry` and a comparison model `retry[Connect|Vote|Switchover]`, plus active operation IDs. **Actions**: interleave duplicate vote requests, heartbeat timeout, RST, successful response/reset, and re-pair. **Granularity**: every increment/reset is an explicit action tied to its protocol.

**Priority**: Medium — **Rationale**: The liveness consequence is plausible and model-friendly, but has less production evidence than Scenarios 1-6.
## 3. Modeling Recommendations

### 3.1 Model (with rationale)

- **Two HA participants and one HA set with at least one scope**: enough for ownership/election safety; add a second logical scope only if checking scope isolation abstractly.
- **Multi-stage effects**: represent ingress ACK, callback, Redis commit, bridge apply, logical broadcast, DPU request, ASIC ACK, and route apply separately (Scenario 1).
- **Bounded at-least-once channels**: allow ACK loss, delay, duplicate, reorder, resend, and final drop; attach abstract generations and pair epochs (Scenarios 2-3).
- **Crash/recovery cuts**: crash before/after each durable boundary, clear volatile queues/registrations, and require reconstruction from persisted phase plus intent (Scenario 4).
- **Actor/config epochs**: independently model row, actor, route, registration, parent cache, and cleanup lifetime (Scenario 5).
- **All route writers**: configuration refresh and state/failover updates must compete under one eligibility invariant (Scenario 6).
- **Retry interference**: first model the current shared counter, then compare operation-local counters as a repair (Scenario 7).

### 3.2 Do Not Model (with rationale)

- **Exact SWBus service-path/route-map implementation and bridge fanout bugs**: duplicate route teardown and missing row selectors are deterministic integration defects; test them directly.
- **Serde/protobuf/endian/string parsing, empty-field DEL parsing, and `u64` counter arithmetic**: these are implementation-level unit-test targets.
- **Concrete Redis/ZMQ APIs, table field encodings, CLI/metrics, build/MSRV, and performance requests**: abstract them as state variables/actions or exclude them.
- **Malicious source spoofing or Byzantine actors**: the system is Category A but non-BFT; model legitimate stale/wrong-epoch messages only.
- **Full data-plane flow replication and external SDN policy**: retain only role ownership, approval, pending-operation, and route eligibility abstractions needed by the scenarios.

## 4. Proposed Extensions

| Extension | Variables | Purpose | Scenario |
|---|---|---|---|
| EffectPipeline | `accepted`, `applied`, `issued`, `dbApplied`, `asicRole`, `ackedTerm` | Expose asynchronous completion boundaries | 1 |
| PendingEdge | `prereqReady`, `pendingFlagEpoch`, `pendingOps` | Preserve DPU-driven operation edges across ordering/crash | 1, 4 |
| AtLeastOnceNetwork | `messages`, `requestId`, `generation`, `ackState`, `age` | Explore retry, loss, duplicate, and reorder | 2 |
| PairEpoch | `currentPeer`, `pairEpoch`, `cacheEpoch`, message peer/epoch | Reject old-peer control after re-pair | 3 |
| DurableIntent | `persistedPhase`, `intent`, `volatileActions`, `processUp` | Replay every phase-specific side effect | 4 |
| ActorLifecycle | `configEpoch`, `actorPhase`, `routeOwner`, `registrations`, `parentCacheEpoch` | Explore delete/re-add and isolated recreation | 5 |
| RouteWriters | `haOwner`, `preferred`, `eligible`, `route`, `writer` | Unify config- and failover-derived routing | 6 |
| RetryScopes | `sharedRetry`, `retryByProtocol`, `operationId` | Expose cross-protocol budget interference | 7 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|---|---|---|---|
| SingleDecisionMaker | Safety | At most one member may make new-flow decisions in any reachable pair state | Reference §7.1; 1, 3, 4 |
| LegalRolePair | Safety | CP/ASIC role combinations are one of the reference-compatible pairs | Reference §7.1-7.2; 1, 4 |
| TermNonRegression | Safety | A participant's accepted current-epoch term/generation never decreases | 2, 3 |
| AckedTransitionSafety | Safety | Approval/transition cannot use a role ACK from another term or pair epoch | 1, 3 |
| ParentBeforeScope | Safety | `scopeApplied(e)` implies `haSetApplied(e)` for the same configuration epoch | 1, 5 |
| RouteMatchesAckedOwner | Safety | The route primary is a current-epoch, ASIC-acknowledged traffic owner | 1, 2, 6 |
| CurrentPeerIsolation | Safety | A non-current peer/epoch cannot change votes, term, state, role, or route | 3 |
| PendingOperationBijective | Safety | Each live pending-flag epoch has exactly one outstanding operation ID | 1, 4 |
| DurableActionProgress | Liveness | After crash and eventual delivery, every persisted transition reaches a stable state or explicit failure | 4 |
| ConfiguredActorProgress | Liveness | A stable config row eventually has a live actor with current registrations and parent state | 5 |
| PairConvergence | Liveness | With stable health/config and eventual delivery, the pair reaches a compatible stable role pair | 2-5, 7 |
| RetryIsolation | Safety/Liveness | Activity in one protocol cannot exhaust or extend another protocol's retry budget | 7 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Scenario |
|---|---|---|---|
| MC1 | Can a chain of accepted-but-unapplied events expose dependent scope/route state after a prerequisite fails, and can it self-heal without another DB mutation? | `ParentBeforeScope`, `AckedTransitionSafety`, `RouteMatchesAckedOwner` | 1 |
| MC2 | Can ACK loss plus an old resend make a participant accept a lower generation/term and select a stale traffic owner after newer state was observed? | `TermNonRegression`, `RouteMatchesAckedOwner` | 2 |
| MC3 | After re-pair, can former-peer traffic control the new pairing/replies, or can the new pair stall because its first valid state is classified `PeerConnected`? | `CurrentPeerIsolation`, `SingleDecisionMaker`, `PairConvergence` | 3 |
| MC4 | At each persist/send crash cut, can rehydration lose a required action, duplicate a pending operation, or restore traffic ownership without peer safety? | `DurableActionProgress`, `PendingOperationBijective`, `SingleDecisionMaker` | 4 |
| MC5 | When cleanup timeout, rapid re-add, isolated parent recreation, and later full rehydration interleave across both participants, can stale authority or a registration cycle survive otherwise healing events? | `ConfiguredActorProgress`, `ParentBeforeScope`, `PairConvergence` | 5 |
| MC6 | Can config refresh, one-scope availability, ACK-delayed failover, and old-state replay combine so the route oscillates or never reconverges after inputs stabilize? | `RouteMatchesAckedOwner`, `SingleDecisionMaker`, `PairConvergence` | 6 |
| MC7 | Can vote/switchover traffic consume or reset the connection retry budget and cause premature standalone or nontermination? | `RetryIsolation`, `PairConvergence` | 7 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|---|---|---|
| TV1 | Identical ConsumerBridge source paths replace one another and Drop removes the replacement; per-scope DPU-state bridges also accept every scope row | Start two HA sets/scopes, publish keyed updates, assert both subscribers survive and only the matching scope changes |
| TV2 | Empty-field local-DPU DEL is deserialized before the operation check | Send a normal empty DEL; assert actor termination and complete cleanup |
| TV3 | Neighbor, VNET, BFD, and HA resources leak on deletion/key/ownership/membership changes | Mutation tests for VLAN/PA/VIP/VNET and managed-to-remote or partially ready HA-set cleanup |
| TV4 | `InitializingToActive` progresses without a same-term peer ASIC Standby ACK | Reverse the current positive test: omit/mismatch ACK and assert no pending activation |
| TV5 | Counter reset or RX growth greater than TX underflows and can trigger failover | Unit-test decreasing/wrapping counters and saturating/checked delta behavior |
| TV6 | DPU-driven pending state can be lost before prerequisites or duplicated after restart; schema/test and #107 intent disagree on ACK field | Permute vDPU/HA-set/DPU snapshot order, restart with flag true, and use differing `ha_role`/`ha_state` fields to establish contract |
| TV7 | Rapid delete/re-add and isolated parent recreation lose actors/registrations/invalidation | Hold cleanup ACK, replay SET, recreate each parent type, and assert eventual actor/subscription recovery |
| TV8 | Heartbeat stays zero/sticky; closed actor routes spin; unresolved-endpoint error classification and missing channel port can panic | Fake time/peer loss, duplicate-route task termination, NoRoute response, and missing-config tests |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|---|---|---|
| CR1 | Unmanaged-scope cleanup may delete a managed scope row sharing `ha_scope_id` | Confirm production config distribution/topology, then add vDPU-qualified ownership or a two-entry test |
| CR2 | Transport `Ok` means incoming-cache acceptance, not successful actor business handling; actor struct mutations are not rolled back | Define the ACK contract and error recovery semantics before changing the runtime |
| CR3 | DPU-driven peer term/state exchange and heartbeat/leak detection remain unimplemented | Confirm ownership against issues #76/#77 and the deployed DPU contract |
| CR4 | Vote-request state is ignored, flow-reconciliation approval has no transition consumer, and desired-Dead handling is state-dependent | Reconcile each path with HLD §§7-8 and remove or complete dead protocol fields/events |
| CR5 | Mixed-version peers can omit ACK-role or required newer fields and stall/drop messages | Define rolling-upgrade compatibility and defaults; add version-pair tests |
| CR6 | Cleanup drops unacknowledged effects after 60 seconds and several config handlers swallow errors/unwrap input | Document the availability tradeoff and add supervision/validation where required |

## 7. Reference Pointers

- Detailed audit: `/users/Pial/Specula/runs/sonic-dash-ha-vm-codex-gpt56-sol-max-20260801/dash-ha/.specula-output/analysis-report.md`
- Core state machine: `crates/hamgrd/src/actors/ha_scope/npu.rs`; shared lifecycle: `crates/swbus-actor/src/driver.rs`, `crates/swbus-actor/src/state/outgoing.rs`, and `crates/hamgrd/src/actors/ha_scope/base.rs`
- Route/state aggregation: `crates/hamgrd/src/actors/ha_set.rs`; DPU-driven path: `crates/hamgrd/src/actors/ha_scope/dpu.rs`; bridge layer: `crates/swss-common-bridge/src/{consumer,producer}.rs`
- Open core issues: [#171](https://github.com/sonic-net/sonic-dash-ha/issues/171), [#139](https://github.com/sonic-net/sonic-dash-ha/issues/139), [#99](https://github.com/sonic-net/sonic-dash-ha/issues/99), [#77](https://github.com/sonic-net/sonic-dash-ha/issues/77), [#76](https://github.com/sonic-net/sonic-dash-ha/issues/76)
- Reference: [SmartSwitch HA HLD](https://github.com/sonic-net/SONiC/blob/master/doc/smart-switch/high-availability/smart-switch-ha-hld.md), especially §§7-10
- Reference: [SmartSwitch HA detailed design](https://github.com/sonic-net/SONiC/blob/master/doc/smart-switch/high-availability/smart-switch-ha-detailed-design.md), [HAMgrD actor design](https://github.com/sonic-net/SONiC/blob/master/doc/smart-switch/high-availability/smart-switch-ha-hamgrd.md), and [DPU-driven setup](https://github.com/sonic-net/SONiC/blob/master/doc/smart-switch/high-availability/smart-switch-ha-dpu-scope-dpu-driven-setup.md)
