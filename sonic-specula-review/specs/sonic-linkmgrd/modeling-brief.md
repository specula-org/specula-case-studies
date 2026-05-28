# Modeling Brief: sonic-net/sonic-linkmgrd

## 1. System Overview

- **System**: sonic-linkmgrd — C++ Dual-ToR Link Manager for SONiC, ~5000 LOC core logic
- **Category**: **Category A (Distributed / Message-Passing)** — event-driven state machines communicating via Redis DB, boost::asio strand-based concurrency, two ToR instances coordinating mux state for each server link
- **Protocol**: Dual-ToR mux cable state machine (Active-Standby and Active-Active modes)
- **Key architectural choices**:
  - Three interleaved state machines per port: LinkProber (7 states), MuxState (5 states), LinkState (2 states) — 70 composite states
  - boost::asio strand for serialization, but `strand::wrap()` used pervasively instead of `boost::asio::post(strand, ...)` — does NOT guarantee FIFO ordering
  - Redis DB as shared state between linkmgrd, orchagent, and xcvrd/ycabled — async notifications with no ordering guarantees
  - Multiple timers (6 in Active-Active mode) interact with state transitions; any timer can expire during any state
  - Active-Active mode adds bidirectional peer state management via gRPC
- **Concurrency model**: Single boost::asio event loop with per-port strands; separate SWSS notification thread dispatches DB events to strands

## 2. Bug Families

### Family 1: Event Ordering / strand Dispatch (HIGH)

**Mechanism**: `ioService.post(strand.wrap(...))` does not guarantee FIFO ordering of handlers posted to the same strand. Events from LinkProber, MuxStateMachine, and LinkStateMachine can be reordered, causing the composite state machine to process events in wrong order.

**Evidence**:
- Historical: #104 — strand::wrap race in DbInterface (metrics table cleaned after mux state set)
- Historical: #254 — strand::wrap race in default route handler (route state stuck wrong)
- Historical: PR #257 — comprehensive fix for MuxPort handlers only
- Code analysis: LinkProberStateMachineBase.cpp:88 — `postLinkProberStateEvent()` uses broken pattern (hot path, every ICMP event)
- Code analysis: MuxStateMachine.cpp:107,126 — `postLinkManagerEvent()` and `postMuxStateEvent()` use broken pattern
- Code analysis: LinkStateMachine.cpp:93,112 — both post methods use broken pattern
- Code analysis: LinkProberBase.cpp:150,406,440,456 — multiple methods use broken pattern
- Code analysis: MuxPort.cpp:433 — `resetPckLossCount()` missed by PR #257
- Code analysis: ~25 total unfixed instances across the codebase

**Affected code paths**: Every event dispatch path between the three sub-state-machines and the composite LinkManager state machine.

**Suggested modeling approach**:
- Variables: Per-port event queue that is a set (unordered) rather than a sequence (ordered) — models the non-FIFO behavior
- Actions: `PostEvent(type)` adds to unordered set; `ProcessEvent` non-deterministically picks any event from the set
- Granularity: Each event post is a separate action; each event processing is a separate action
- This directly captures the mechanism: when two events are posted "simultaneously," either can be processed first

**Priority**: High
**Rationale**: 3 historical bugs (one discovered 2 years after original fix). ~25 remaining unfixed instances. The bug class is systemic — every cross-state-machine event is affected. Excellent TLA+ target because the non-deterministic event ordering is the core mechanism.

---

### Family 2: Missing/Incomplete Composite State Transitions (HIGH)

**Mechanism**: The 3D transition table (LinkProber × MuxState × LinkState) has 70 entries but only 12-18 are registered with handlers. Missing handlers default to no-op, leaving the system stuck when it reaches unhandled composite states. Additionally, sub-state-machine self-transitions (Unknown→Unknown) produce no event, breaking the retry loop.

**Evidence**:
- Historical: #136 — stuck in unknown after init (MuxState Unknown→Unknown = no event posted)
- Historical: #169 — missing {Unknown, Unknown, Down} and {Unknown, Wait, Down} handlers (Active-Active)
- Historical: #175 — link down not handled when MuxState is Unknown (Active-Active)
- Historical: #178 — same pattern for Active-Standby
- Historical: #201 — no mux probe when default route NA + BSL (Active-Standby)
- Code analysis: ActiveActive {Unknown, Error, Up} — no handler, no probe timer, no recovery action
- Code analysis: ActiveActive duplicate registration at line 703 — possible copy-paste error hiding a missing handler
- Code analysis: ActiveStandby {Unknown, Error, Up} — no handler
- Code analysis: MuxStateMachine Unknown→Unknown and Error→Error — no LinkManager event posted
- Code analysis: LinkProber StandbyState missing IcmpWaitEvent handler — cannot transition Standby→Wait

**Affected code paths**:
- `LinkManagerStateMachineActiveActive::initializeTransitionFunctionTable()` (lines 653-774)
- `LinkManagerStateMachineActiveStandby::initializeTransitionFunctionTable()` (lines 72-221)
- `MuxStateMachine::processEvent()` (line 176 — self-transition check)
- `LinkProberStateMachineBase::processEvent()` (line 202 — self-transition check)

**Suggested modeling approach**:
- Variables: Explicit composite state tuple `<<lpState, muxState, linkState>>` per port
- Actions: Model ALL 70 entries — handlers for registered states, explicit no-op for unregistered states
- Key: Add an invariant `NoStuckState` that checks every reachable composite state has a handler or is a stable terminal state (Active/Active/Up or Standby/Standby/Up)
- Model sub-state-machine self-transitions explicitly (Unknown→Unknown produces no event to the composite machine)

**Priority**: High
**Rationale**: 6 historical bugs in this family, 5+ new potential findings. The 70-state space is ideal for exhaustive model checking — manually reasoning about all combinations is error-prone, which is why bugs keep appearing.

---

### Family 3: Timer Interference with State Transitions (MEDIUM-HIGH)

**Mechanism**: Multiple timers (deadline, wait, oscillation, peer wait, resync, suspend) can expire at any point during a state transition. Timer expiry handlers check current state, but the state may have changed between when the timer was started and when it fires. Backoff factors can reach maximum and never reset, causing indefinite delays.

**Evidence**:
- Historical: #253 — oscillation timer fires during legitimate standby→active toggle
- Historical: #81 — mux wait timer backoff jumps to MAX immediately; peer wait timer can't stop
- Historical: #70 — WaitActiveUpCount not reset, causing unnecessary heartbeat suspension
- Historical: #106 — no backoff, excessive probing load
- Historical: #208 — indefinite heartbeat suspension with exponential backoff
- Code analysis: ActiveActive mDeadlineTimer not cancelled on mux state notification (line 202-207)
- Code analysis: ActiveActive resync timer doesn't check error code (line 464-474)
- Code analysis: ActiveStandby mUnknownActiveUpBackoffFactor stays at MAX=128 indefinitely
- Code analysis: ActiveStandby mMuxUnknownBackoffFactor stays at MAX=128 if mux stays Unknown
- Code analysis: ActiveStandby oscillation timer not cancelled on mode change (line 788-836)

**Affected code paths**:
- All `startXxxTimer()` and `handleXxxTimeout()` functions in both ActiveActive and ActiveStandby
- Backoff factor variables: mMuxProbeBackoffFactor, mUnknownActiveUpBackoffFactor, mWaitActiveUpCount, mWaitStandbyUpBackoffFactor, mMuxUnknownBackoffFactor

**Suggested modeling approach**:
- Variables: Abstract timers as boolean `timerPending[TimerType]` + non-deterministic `TimerExpires(type)` action
- Actions: `StartTimer(type)` sets timerPending; `CancelTimer(type)` clears it; `TimerExpires(type)` fires handler if pending
- Key: Allow timers to expire at ANY point (non-deterministic scheduling). This naturally explores the interference scenarios.
- Model backoff factors as bounded integers that double on each expiry and reset on specific events

**Priority**: Medium-High
**Rationale**: 5 historical bugs, 5+ new findings. Timer interference is inherently hard to reason about manually — model checking excels here because it explores all possible timer orderings.

---

### Family 4: Default Route State Interaction (MEDIUM)

**Mechanism**: Default route transitions (OK→NA, NA→OK) interact with mux switching, heartbeat suspension, and link prober state. Rapid route flaps can leave the system in inconsistent state because the route change handler modifies state mid-transition.

**Evidence**:
- Historical: #292 — mux standby after default route recovery (stale link prober state)
- Historical: #279 — extra toggle after default route NA (Active-Active)
- Historical: #44 — heartbeats continue when default route missing
- Historical: #56 — stale link prober state after default route recovery
- Historical: #194 — no ICMP probes despite default route present (UNFIXED)
- Code analysis: ActiveActive line 807 — `DefaultRoute::Wait` passes `!= NA` check, enabling premature Active switch
- Code analysis: ActiveActive lines 1346 vs 1358 — asymmetric mode guard (Detached mode switches to Standby on NA but cannot recover on OK)
- Code analysis: ActiveStandby line 1273 — forces Active switch ignoring default route state entirely
- Code analysis: ActiveStandby line 854 — suspend timer restarts link detection even when default route is NA

**Affected code paths**:
- `handleDefaultRouteStateNotification()` in both ActiveActive and ActiveStandby
- `shutdownOrRestartLinkProberOnDefaultRoute()` in ActiveStandby
- All transition functions that check `mDefaultRouteState`

**Suggested modeling approach**:
- Variables: `defaultRoute ∈ {OK, NA, Wait}` per port
- Actions: `DefaultRouteChange(newState)` — non-deterministic, can happen at any time
- Key: Model the interaction between route changes and in-flight mux transitions. The `Wait` initial value is critical.

**Priority**: Medium
**Rationale**: 5 historical bugs (1 still unfixed). The default route is a cross-cutting concern that interacts with nearly every state transition. Model checking can verify that route flaps never leave the system permanently stuck.

---

### Family 5: Peer State Desynchronization — Active-Active (MEDIUM-HIGH)

**Mechanism**: In Active-Active mode, each ToR tracks peer state and can command peer mux changes. Peer state can become stale after SoC restart, lost gRPC connection, or when the local ToR is itself unhealthy. This can lead to both ToRs becoming standby simultaneously.

**Evidence**:
- Historical: #143 — both ToRs go standby (asymmetric upstream failure)
- Historical: #285 — peer state not persisted after SoC restart (UNFIXED)
- Historical: #101 — wrong table name for peer forwarding state (peer toggles never take effect)
- Code analysis: ActiveActive line 631-635 — PeerUnknown doesn't update mPeerMuxState when local is Unhealthy; stale peer state persists
- Code analysis: ActiveActive line 593-595 — peer mux state not reset on link recovery (Down→Up)
- Code analysis: ActiveActive line 370-380 — handlePeerMuxStateNotification accepts all notifications unconditionally (no validation)
- Code analysis: ActiveActive line 1107 — switchPeerMuxState blocked in Detached mode

**Affected code paths**:
- `handlePeerStateChange()` (ActiveActive line 613-642)
- `switchPeerMuxState()` (ActiveActive line 1105-1118)
- `handlePeerMuxStateNotification()` (ActiveActive line 370-380)
- `initPeerLinkProberState()` (ActiveActive line 1187-1208)

**Suggested modeling approach**:
- Variables: Model TWO ToR instances, each with its own composite state + peer tracking state
- Actions: `PeerHeartbeatReceived/Lost`, `PeerMuxSwitch`, `SoCRestart` (resets admin forwarding state on host)
- Key: The critical invariant is `NoDoubleStandby` — at least one ToR must be Active for each server link
- Model asymmetric failures (one ToR unhealthy while peer also failing)

**Priority**: Medium-High
**Rationale**: 3 historical bugs (1 still unfixed). The dual-ToR interaction is the highest-complexity aspect of the system. Both-standby is the most severe failure mode (complete traffic loss). Excellent TLA+ target because it requires reasoning about two concurrent state machines.

---

### Family 6: Restart/Initialization Ordering (LOW for TLA+)

**Mechanism**: Service restart exposes initialization ordering dependencies — DB notifications arriving before state machine activation, GUID generation data races, missing event replay after init.

**Evidence**:
- Historical: #306 — SIGABRT/SIGSEGV crash during restart (UNFIXED, memory corruption)
- Historical: #307/#308 — GUID generation data race (shared unordered_set without mutex)
- Historical: #42 — std::out_of_range during startup (port type not yet registered)
- Historical: #168 — mux active with link down at startup
- Historical: #202 — pre-init mux config notification lost
- Historical: #217 — extra toggle after config reload

**Priority**: Low (for TLA+ modeling)
**Rationale**: These are primarily implementation-level issues (data races, memory corruption, initialization ordering). They are better addressed by unit/integration testing and code review rather than protocol-level model checking.

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Three sub-state machines per port | Family 2: the 70-state composite space is the source of most bugs | Model LinkProber (Active/Unknown/Wait), MuxState (Active/Standby/Unknown/Wait/Error), LinkState (Up/Down) as concurrent processes posting events |
| Non-deterministic event ordering | Family 1: strand::wrap doesn't preserve FIFO — this is the root cause of the most pervasive bug class | Event queue modeled as a set (not sequence); ProcessEvent picks any element non-deterministically |
| Abstract timers | Family 3: timer expiry during any state is a major bug source | Boolean timerPending flags with non-deterministic expiry actions; backoff as bounded counters |
| Two ToR instances (Active-Active) | Family 5: peer state desync and both-standby are the most severe failures | Two symmetric ToR processes, each tracking local + peer state; peer mux commands delivered asynchronously |
| Default route state | Family 4: route flaps interact with nearly every transition | DefaultRoute ∈ {OK, NA, Wait}; non-deterministic transitions |
| Mux notification from multiple sources | Family 1 & 2: probe response, orchagent notification, state_db read can deliver conflicting state | Model the three notification types as separate actions, each delivering potentially different state |
| Mode (Auto/Standby/Active/Manual/Detached) | Family 2 & 4: mode guards affect which transitions are allowed | Mode as a variable that can change at any time (config notification) |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| ICMP packet details | Implementation-level; the link prober state machine abstracts away packet content |
| gRPC transport | Transport details don't affect protocol logic; model as async message delivery |
| Redis DB internals | Model as a shared store with async notifications; DB implementation details don't matter |
| Physical mux hardware | Hardware response is already abstracted as xcvrd probe responses |
| GUID generation | Family 6 issue; data race fixed by PR #308/#319, not protocol logic |
| IPv4/IPv6 routing details | Neighbor table management, proxy ARP/NDP — orthogonal to mux state machine |
| Warm reboot reconciliation | Complex but self-contained; not interleaving with core state machine |
| Metrics/logging | No protocol impact |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Non-deterministic event queue | `eventQueue ∈ SUBSET EventType` | Capture strand::wrap non-ordering | Family 1 |
| Complete transition table | Handlers for all 70 composite states | Verify no stuck states | Family 2 |
| Abstract timers | `timerPending[TimerType] ∈ BOOLEAN`, `backoff[TimerType] ∈ 1..MAX` | Explore timer interference | Family 3 |
| Default route state | `defaultRoute ∈ {OK, NA, Wait}` | Model route flap interactions | Family 4 |
| Dual-ToR peer tracking | `peerMuxState`, `peerLinkProberState` per ToR | Detect both-standby | Family 5 |
| Multiple notification sources | `probeResult`, `orchagentNotification`, `stateDbRead` as separate actions | Model conflicting state delivery | Family 1,2 |
| Mode variable | `mode ∈ {Auto, Standby, Active, Manual, Detached}` | Guard condition verification | Family 2,4 |
| Self-transition suppression | Model that Unknown→Unknown produces no event | Capture the #136 bug class | Family 2 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| NoStuckState | Safety | Every reachable composite state either has a handler or is a stable terminal state (Active/Active/Up, Standby/Standby/Up, Standby/Standby/Down) | Family 2 |
| NoDoubleStandby | Safety | For Active-Active: at least one ToR must be in Active forwarding state for each server link (unless both links are Down) | Family 5 |
| EventuallyActive | Liveness | If link is Up and heartbeats are received, the mux eventually reaches Active state | Family 2,3,4 |
| EventuallyConsistent | Liveness | If timers are not permanently disabled, the mux state eventually matches the link prober state | Family 3 |
| TimerRecovery | Liveness | Backoff factors eventually reset (don't stay at MAX forever when state resolves) | Family 3 |
| DefaultRouteRecovery | Liveness | If default route transitions NA→OK and link prober is Active, mux eventually returns to Active | Family 4 |
| PeerStateConvergence | Liveness | After a SoC restart, peer state eventually converges to the correct value | Family 5 |
| NoSpuriousToggle | Safety | A mux switch to Standby does not occur when the composite state is healthy (Active/Active/Up with DefaultRoute OK) — unless mode explicitly requests it | Family 3 (oscillation) |
| ModeRespected | Safety | In Manual or Detached mode, no automatic mux switching occurs (unless explicitly overridden) | Family 2,4 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC-1 | strand::wrap non-ordering allows mux state event to be processed before link prober event that logically preceded it | NoStuckState, EventuallyConsistent | 1 |
| MC-2 | {Unknown, Error, Up} in Active-Active has no handler — system stays stuck | NoStuckState | 2 |
| MC-3 | MuxStateMachine Unknown→Unknown produces no event, breaking retry loop | EventuallyActive | 2 |
| MC-4 | Oscillation timer fires during legitimate toggle when prober is stuck in Wait | NoSpuriousToggle | 3 |
| MC-5 | mUnknownActiveUpBackoffFactor reaches MAX=128 and never resets | TimerRecovery | 3 |
| MC-6 | DefaultRoute::Wait passes != NA check, enabling premature Active switch before route confirmed | ModeRespected | 4 |
| MC-7 | Detached mode: switches to Standby on DefaultRoute NA but cannot recover on OK (asymmetric guard) | DefaultRouteRecovery | 4 |
| MC-8 | PeerUnknown when local is Unhealthy: stale mPeerMuxState persists, no re-evaluation when local becomes Healthy | NoDoubleStandby | 5 |
| MC-9 | Peer mux state not reset on link Down→Up (SoC restart): stale peer state drives incorrect decisions | PeerStateConvergence | 5 |
| MC-10 | Two conflicting mux notifications (probe=Active, orchagent=Standby) delivered in non-deterministic order | EventuallyConsistent | 1,2 |
| MC-11 | Active-Standby: LinkProberActiveMuxUnknownLinkUp forces Active switch ignoring default route state | DefaultRouteRecovery | 4 |
| MC-12 | Resync timer firing between mWaitTimer expiry and mDeadlineTimer expiry causes double probe | EventuallyConsistent | 3 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|----------------------|
| TV-1 | MuxPort.cpp:433 resetPckLossCount still uses strand::wrap | Unit test with concurrent resetPckLossCount and state transition |
| TV-2 | Oscillation timer not cancelled on mode change | Integration test: start oscillation timer, change mode to Manual, verify no spurious toggle |
| TV-3 | Suspend timer restarts link detection when default route is NA | Unit test: set default route NA, trigger suspend timer, verify no detection restart |
| TV-4 | handleMuxStateNotification logs solicited notification as unsolicited if mux left Wait early | Unit test with controlled mux state change timing |
| TV-5 | DriverUpdate cause bit not reset after probe response | Unit test: probe mux, verify WaitStateCause cleared |
| TV-6 | handleAdminForwardingStateSyncUp restarts timer even on cancellation (use-after-free risk) | ASAN/TSAN test during shutdown |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR-1 | Duplicate transition table registration at ActiveActive line 703 (copy-paste error?) | Verify intended state combination, fix or document |
| CR-2 | mMuxConfig cross-thread reads/writes without synchronization | Add atomic or mutex protection |
| CR-3 | mPeerLinkProberState variable is set but never read (dead state) | Remove or use for cross-checking |
| CR-4 | mWaitActiveUpCount grows without bound (uint32_t, no cap) | Add explicit cap |
| CR-5 | handlePeerMuxStateNotification accepts all notifications without validation | Add component-init and sequence checks |

## 7. Reference Pointers

- **Full analysis report**: `.specula-output/analysis-report.md`
- **Key source files** (artifact/sonic-linkmgrd/src/):
  - `link_manager/LinkManagerStateMachineActiveActive.cpp` (1423 lines) — PRIMARY TARGET
  - `link_manager/LinkManagerStateMachineActiveStandby.cpp` (1478 lines) — PRIMARY TARGET
  - `link_manager/LinkManagerStateMachineBase.cpp` (373 lines) — Shared base
  - `link_prober/LinkProberStateMachineBase.cpp` (411 lines) — Event posting (strand::wrap bug)
  - `mux_state/MuxStateMachine.cpp` (206 lines) — Sub-state machine
  - `MuxPort.cpp` (510 lines) — Event dispatch
  - `DbInterface.cpp` (1923 lines) — DB notification thread
- **Design documents**: `invariants/dualtor_active_standby_hld.md`, `invariants/active_active_hld.md`
- **GitHub issues**: #104, #254 (Family 1); #136, #169, #175, #178 (Family 2); #253, #81, #70, #208 (Family 3); #292, #279, #194 (Family 4); #143, #285 (Family 5); #306, #307 (Family 6)
- **GitHub repo**: https://github.com/sonic-net/sonic-linkmgrd
