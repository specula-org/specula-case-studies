# Analysis Report: sonic-net/sonic-linkmgrd

## 1. System Classification

**Category**: A (Distributed / Message-Passing)

**Justification**: sonic-linkmgrd is an event-driven state machine system where two ToR (Top of Rack) switches coordinate mux cable state for dual-homed servers. Communication between components (linkmgrd, orchagent, xcvrd/ycabled) happens via Redis DB with async notifications. The core logic is protocol-level state machine transitions, not lock-free data structures or memory-ordering concerns. The concurrency model is boost::asio event loop with strand-based serialization — closer to a distributed message-passing system than a concurrent data structure.

## 2. Reconnaissance Summary

### 2.1 Architecture

Three interleaved state machines per mux port, running on a boost::asio event loop with per-port strand serialization:

1. **LinkProber**: ICMP heartbeat probe state — Active(0), Standby(1), Unknown(2), Wait(3), PeerWait(4), PeerActive(5), PeerUnknown(6) — 7 states
2. **MuxState**: Mux cable hardware state — Active(0), Standby(1), Unknown(2), Error(3), Wait(4) — 5 states
3. **LinkState**: Physical link state — Up(0), Down(1) — 2 states

Composite state: 3-tuple = 70 possible combinations. Only 12-18 have registered handlers.

Two operational modes:
- **Active-Standby**: One ToR active, one standby per server link. Uses y-cable I2C control.
- **Active-Active**: Both ToRs can be active. Uses gRPC control via SoC. More complex peer state tracking.

### 2.2 Core Files (by LOC)

| File | Lines | Role |
|------|-------|------|
| DbInterface.cpp | 1923 | Redis DB interface, SWSS notification thread |
| LinkManagerStateMachineActiveStandby.cpp | 1478 | Active-Standby composite state machine |
| LinkManagerStateMachineActiveActive.cpp | 1423 | Active-Active composite state machine |
| ActiveStandby header | 913 | State definitions, member variables |
| LinkProberBase.cpp | 735 | ICMP heartbeat prober base |
| LinkProberStateMachineBase.h | 752 | LinkProber state machine base |
| ActiveActive header | 757 | State definitions, member variables |
| MuxManager.cpp | 679 | Port management, event routing |
| LinkProberHw.cpp | 567 | Hardware ICMP offload prober |
| MuxPort.cpp | 510 | Per-port event dispatch |

### 2.3 Timers

| Timer | Owner | Purpose |
|-------|-------|---------|
| mDeadlineTimer | LinkManager | Mux probe backoff timeout |
| mWaitTimer | LinkManager | xcvrd/orchagent response timeout |
| mOscillationTimer | ActiveStandby | Oscillation detection |
| mPeerWaitTimer | ActiveActive | Peer mux response timeout |
| mResyncTimer | ActiveActive | Periodic admin forwarding state sync |
| mSuspendTimer | LinkProber | Heartbeat suspension |
| mSwitchActiveCommandTimer | LinkProber | Switch command timeout |
| mShutdownTxTimer | LinkProber | TX shutdown timeout |
| mPositiveProbingTimer | LinkProberHw | Hardware probe positive confirmation |

### 2.4 Event Flow

```
External Sources (Redis DB notifications, ICMP packets)
    │
    ├── DbInterface (SWSS thread) ──→ MuxManager ──→ MuxPort::handleXxx()
    │                                                    │
    │                                              boost::asio::post(mStrand, ...)
    │                                                    │
    │                                                    ▼
    │                                     LinkManagerStateMachineBase
    │                                     ┌─────────────────────┐
    │                                     │  Composite State:    │
    │                                     │  (LP, Mux, Link)    │
    │                                     │                     │
    │   LinkProberStateMachine ◄──────────┤  handleStateChange  │
    │         │                           │  (3 overloads)      │
    │         │ postLinkManagerEvent ──────►                     │
    │                                     │  Transition Table   │
    │   MuxStateMachine ◄─────────────────┤  [LP][Mux][Link]   │
    │         │                           │                     │
    │         │ postLinkManagerEvent ──────►                     │
    │                                     │  Timer handlers     │
    │   LinkStateMachine ◄────────────────┤                     │
    │         │                           └─────────────────────┘
    │         │ postLinkManagerEvent
    │
    └── ICMP packets (LinkProberSw/Hw) ──→ LinkProberStateMachine
```

### 2.5 Concurrency Model

- **boost::asio event loop**: Single `io_service` with thread pool (typically 1-2 threads)
- **Per-port strand**: Each MuxPort has its own `boost::asio::strand` for serialization
- **SWSS notification thread**: Separate `boost::thread` running `DbInterface::handleSwssNotification()`
- **Cross-strand boundary**: Sub-state machines (LinkProber, MuxState, LinkState) post events to the LinkManager's strand using `ioService.post(strand.wrap(...))` — which has the known ordering bug

## 3. Bug Archaeology Results

### 3.1 Coverage Statistics

| Metric | Count |
|--------|-------|
| Total commits touching src/ | 279 |
| Total bug-fix commits analyzed | 38 |
| Commits touching link_manager/ | 92 |
| Commits touching DbInterface.cpp | 31 |
| Commits touching MuxPort.cpp | 24 |
| Total GitHub issues in repo | 37 |
| Issues deeply read (full comments) | 37 |
| Issues confirmed as bugs | 27 |
| Issues classified as flaky tests | 5 |
| Issues classified as build/tooling | 5 |
| Open PRs reviewed | 5 |
| False positives excluded | 0 |

### 3.2 Bug-Fix Commit Hotspot Analysis

| File | Bug-Fix Commits | Key Bug Classes |
|------|----------------|-----------------|
| LinkManagerStateMachineActiveActive.cpp | 14 | Stuck states, missing transitions, default route, peer state |
| LinkManagerStateMachineActiveStandby.cpp | 12 | Oscillation, backoff, default route, link down handling |
| MuxPort.cpp | 4 | strand::wrap race conditions |
| DbInterface.cpp | 3 | strand::wrap, initialization, table names |
| LinkProberBase.cpp | 3 | GUID race, crash |
| MuxManager.cpp | 2 | Warmboot, initialization |

### 3.3 All Confirmed Bugs (Chronological)

| # | Issue/PR | Summary | Root Cause | Family | Fixed? |
|---|---------|---------|------------|--------|--------|
| 1 | PR #1 | Config ignored during Wait | Missing cache for pending config | 2 | Yes |
| 2 | PR #6 | Force switch delay | Mode check after switch | 2 | Yes |
| 3 | PR #22 | xcvrd crash stuck in Wait | No timeout recovery | 3 | Yes |
| 4 | PR #27 | Stale mux probe after switchover | Hardware delay | 3 | Yes |
| 5 | PR #36 | Switching mux to Unknown | Missing guard | 2 | Yes |
| 6 | #42 | std::out_of_range during startup | Race in port registration | 6 | Yes |
| 7 | PR #44 | Heartbeats during missing route | Missing shutdown logic | 4 | Yes |
| 8 | PR #56 | Stale prober after route recovery | Missing state reset | 4 | Yes |
| 9 | PR #70 | WaitActiveUpCount not reset | Missing reset on switch | 3 | Yes |
| 10 | PR #77 | Toggle when both links down | Missing link state check | 2 | Yes |
| 11 | PR #81 | Wait timer backoff jumps to MAX | Incorrect backoff logic | 3 | Yes |
| 12 | PR #90 | Exception on missing loopback | throw→log | 6 | Yes |
| 13 | #101 | Wrong peer table name | Typo in table constant | 5 | Yes |
| 14 | #104 | strand::wrap race in DbInterface | wrap() non-ordering | 1 | Yes |
| 15 | PR #106 | Excessive mux probing | No backoff | 3 | Yes |
| 16 | #113 | Flaky race condition test | Timing-sensitive test | 1 | Yes |
| 17 | PR #128 | Mux config pre-init | setMode inside init check | 6 | Yes |
| 18 | #135 | Config ignored after toggle fail | Missing retry | 2 | Yes |
| 19 | PR #136 | Stuck in unknown after init | Unknown→Unknown no event | 2 | Yes |
| 20 | PR #137 | Syslog flood unknown→standby | Missing delay | 2 | Yes |
| 21 | PR #139 | Retry config mux mode standby | Missing retry | 2 | Yes |
| 22 | #143 | Both ToRs go standby | Premature peer toggle | 5 | Yes |
| 23 | #144 | SERVER_STATUS unknown after reload | Missing toggle | 6 | Yes |
| 24 | PR #145 | Config reload SERVER_STATUS | Missing re-toggle | 6 | Yes |
| 25 | #148 | Double ICMP event reporting | Dual heartbeat handling | 5 | Yes |
| 26 | #153 | Peer ICMP reply not handled | Strand bottleneck | 1 | Yes |
| 27 | PR #166 | Stuck after gRPC loss + mode change | Missing prober reinit | 2 | Yes |
| 28 | #168 | Active with link down at startup | Missing init transitions | 2 | Yes |
| 29 | #172 | Can't change back to standby | Missing auto re-eval | 2 | Yes |
| 30 | #174 | Link down + MuxUnknown no toggle | Guard: ==Active not !=Standby | 2 | Yes |
| 31 | PR #178 | Same as #174 for active-standby | Guard: ==Active not !=Standby | 2 | Yes |
| 32 | PR #183 | Unnecessary probe after auto | Missing delay | 3 | Yes |
| 33 | #194 | No ICMP probes with route present | Restart logic bug | 4 | **NO** |
| 34 | PR #201 | No probe when route NA + BSL | Missing mux wait entry | 2 | Yes |
| 35 | PR #202 | Pre-init config notification lost | Missing event replay | 6 | Yes |
| 36 | #208 | Indefinite heartbeat suspension | Exponential backoff loop | 3 | Yes |
| 37 | PR #216 | Extra toggle after config reload | Init to wrong state | 6 | Yes |
| 38 | PR #225 | show mux status inconsistency | mLastSetMuxState tracking | 2 | Yes |
| 39 | #253 | Oscillation timer during toggle | Timer not cancelled | 3 | Yes |
| 40 | #254 | strand::wrap race default route | wrap() non-ordering | 1 | Yes |
| 41 | PR #257 | strand::wrap all MuxPort handlers | wrap() non-ordering | 1 | Yes |
| 42 | PR #261 | Oscillation logic fix | Timer alive flag | 3 | Yes |
| 43 | #278 | Extra toggles on BGP shutdown | Route flap + probe race | 4 | Yes |
| 44 | PR #279 | Extra toggle after route NA | Missing route check | 4 | Yes |
| 45 | PR #281 | Enforce standby in standby mode | Missing mode override | 2 | Yes |
| 46 | #282 | Stuck after mode change + SoC | switchMuxState skipped | 2 | Yes |
| 47 | #285 | Peer state not persisted after SoC | No re-issue mechanism | 5 | **NO** |
| 48 | PR #291 | Not toggle active on route flap | Stale prober state | 4 | Yes |
| 49 | #292 | Standby after route recovery | Same root cause as #291 | 4 | Yes |
| 50 | #306 | SIGABRT/SIGSEGV during restart | Memory corruption | 6 | **NO** |
| 51 | #307/#308 | Mux port uninitialized | GUID data race | 6 | Yes |
| 52 | PR #319 | GUID generation overhaul | Remove shared mutable state | 6 | Yes |

### 3.4 Bug Distribution by Family

| Family | Historical | Still Open | New Findings (Code Analysis) |
|--------|-----------|------------|------------------------------|
| 1: Event Ordering | 4 | 0 | ~25 unfixed strand::wrap instances |
| 2: Missing Transitions | 15 | 0 | 5 new missing handlers |
| 3: Timer Interference | 8 | 0 | 5 new timer issues |
| 4: Default Route | 6 | 1 (#194) | 4 new guard issues |
| 5: Peer State Desync | 4 | 1 (#285) | 4 new peer tracking issues |
| 6: Restart/Init | 8 | 1 (#306) | 2 new thread safety issues |

## 4. Deep Analysis Findings

### 4.1 Active-Active State Machine

**File**: `src/link_manager/LinkManagerStateMachineActiveActive.cpp` (1423 lines)

#### Finding AA-1: Missing handler for {Unknown, Error, Up}
**Lines**: 653-774 (absent from table)
**Description**: When LinkProber=Unknown and MuxState=Error and Link=Up, the transition table has no handler (default no-op). Unlike {Active, Error, Up} (line 888) which starts a probe timer, this state does nothing. The system stays stuck unless the link prober transitions to Active (handled) or the resync timer fires (only if !mWaitMux).
**Severity**: Medium — reachable when gRPC returns error during packet loss
**Compensating mechanism**: handleAdminForwardingStateSyncUp periodically probes, but only if !mWaitMux
**Classification**: Model-checkable

#### Finding AA-2: Duplicate registration at line 703
**Lines**: 676-683 and 703-710
**Description**: Both register {Active, Unknown, Up}. The second overwrites the first. They bind to the same function, so no current behavioral impact. But this suggests a copy-paste error — the intended registration for line 703 may have been a different combination.
**Severity**: Low (no current impact, but suspicious)
**Classification**: Code-review-only

#### Finding AA-3: DefaultRoute::Wait passes != NA check
**Line**: 807
**Description**: `mDefaultRouteState != DefaultRoute::NA` is the guard for switching to Active in LinkProberActiveMuxStandbyLinkUp. During startup, `mDefaultRouteState` is initialized to `DefaultRoute::Wait`. So if the link prober reports Active and mux is Standby before the default route notification arrives, the system attempts to switch to Active.
**Severity**: Medium — affects startup timing
**Classification**: Model-checkable

#### Finding AA-4: Asymmetric mode guard in default route handler
**Lines**: 1346 and 1358
**Description**: Default route NA triggers standby switch for all modes except Active (`!= Mode::Active`). But recovery (NA→OK) only triggers for Auto mode (`== Mode::Auto`). This means Detached mode switches to Standby on NA but cannot recover when route goes OK.
**Severity**: Medium — permanent Standby in Detached mode after route flap
**Classification**: Model-checkable

#### Finding AA-5: PeerUnknown doesn't update mPeerMuxState when local is Unhealthy
**Lines**: 631-635
**Description**: When peer goes PeerUnknown and local label is NOT Healthy, `switchPeerMuxState()` is not called, and `mPeerMuxState` retains its old value. No mechanism exists to re-evaluate peer state when local becomes Healthy later.
**Severity**: High — can lead to both-standby (similar to #143)
**Classification**: Model-checkable

#### Finding AA-6: Peer mux state not reset on link recovery
**Lines**: 593-595
**Description**: When link transitions Down→Up, `initPeerLinkProberState()` is called, which reads `mPeerMuxState` — but `mPeerMuxState` was never reset. If the peer also restarted, `mPeerMuxState` may be stale.
**Severity**: Medium — matches #285 pattern
**Classification**: Model-checkable

#### Finding AA-7: handlePeerMuxStateNotification accepts unconditionally
**Lines**: 370-380
**Description**: Any peer mux state notification is processed without checking initialization state, current local state, or whether the notification was solicited. Stale or out-of-sequence notifications overwrite peer state.
**Severity**: Medium
**Classification**: Model-checkable

#### Finding AA-8: mDeadlineTimer not cancelled on mux state notification
**Lines**: 202-207
**Description**: `handleMuxStateNotification` cancels `mWaitTimer` but not `mDeadlineTimer`. If a toggle resolves the mux state while a probe cycle is active, the deadline timer still fires later, potentially starting an unnecessary probe.
**Severity**: Low — extra probe is mostly harmless
**Classification**: Model-checkable

#### Finding AA-9: Resync timer doesn't check error code
**Lines**: 464-474
**Description**: `handleAdminForwardingStateSyncUp` always restarts the resync timer, even when `errorCode` indicates cancellation. During shutdown, this could cause use-after-free.
**Severity**: Low for protocol logic, Medium for implementation safety
**Classification**: Test-verifiable

### 4.2 Active-Standby State Machine

**File**: `src/link_manager/LinkManagerStateMachineActiveStandby.cpp` (1478 lines)

#### Finding AS-1: Oscillation timer not cancelled on mode change
**Lines**: 788-836
**Description**: `handleMuxConfigNotification` does NOT call `tryCancelOscillationTimerIfAlive()`. If the oscillation timer is running and mode changes to Manual/Standby, the timer still fires. At fire time, `switchMuxState` checks mode, but the guard may allow a probe in Manual mode.
**Severity**: Low — spurious probe in Manual mode
**Classification**: Test-verifiable

#### Finding AS-2: mUnknownActiveUpBackoffFactor stays at MAX
**Lines**: 1207-1208, 859
**Description**: When prober is Unknown and mux is Active and link is Up, the backoff factor doubles each cycle up to 128. Reset only when prober leaves Unknown, link goes down, or suspend timer fires in a different state. If the server is permanently unresponsive, the factor stays at 128, causing very long suspend times.
**Severity**: Medium — known pattern from #208, may have been partially addressed
**Classification**: Model-checkable

#### Finding AS-3: LinkProberActiveMuxUnknownLinkUp forces Active ignoring default route
**Line**: 1273
**Description**: After N retries, `switchMuxState(Active)` is called without checking default route state. If default route is NA, this creates an Active mux with potentially no valid route.
**Severity**: Medium
**Classification**: Model-checkable

#### Finding AS-4: Suspend timer vs default route conflict
**Lines**: 854-857
**Description**: `handleSuspendTimerExpiry` calls `enterMuxWaitState` and `mDetectLinkFnPtr()` when state is {Unknown, Active, Up}. This restarts link detection even when default route is NA, conflicting with the shutdown logic.
**Severity**: Low-Medium
**Classification**: Test-verifiable

#### Finding AS-5: Unsolicited mux notification always processed
**Lines**: 720-721
**Description**: In `handleMuxStateNotification`, even when logged as "unsolicited," `postMuxStateEvent(label)` is always called. A stale or duplicate notification from state_db can cause an incorrect state transition.
**Severity**: Medium — can cause temporary wrong state
**Classification**: Model-checkable

#### Finding AS-6: mLastSetMuxState set on initiation, not completion
**Lines**: 323, 650
**Description**: `mLastSetMuxState` records the requested state when `switchMuxState` is called, not when the switch completes. If the switch fails (timeout), the variable still holds the requested value. This affects `handleGetMuxStateNotification` correction logic.
**Severity**: Low-Medium — self-correcting in most cases
**Classification**: Model-checkable

#### Finding AS-7: handleGetMuxState skips correction for Wait/Error/Unknown
**Lines**: 647-649
**Description**: The state_db correction logic is gated by `ms != Wait && != Error && != Unknown`. If the system is permanently stuck in one of these states, state_db correction never triggers.
**Severity**: Low — these are supposed to be transient
**Classification**: Model-checkable

#### Finding AS-8: DriverUpdate cause bit not reset after probe response
**Lines**: 666-700 vs 722-725
**Description**: `handleProbeMuxStateNotification` does not reset the `DriverUpdate` WaitStateCause after processing, unlike `handleMuxStateNotification` which resets `SwssUpdate`. The stale cause bit may affect subsequent unsolicited-detection logic.
**Severity**: Low
**Classification**: Test-verifiable

### 4.3 MuxPort and DbInterface

#### Finding MI-1: MuxPort.cpp:433 still uses strand::wrap
**Line**: 433
**Description**: `resetPckLossCount()` uses `ioService.post(mStrand.wrap(...))` — missed by PR #257 which fixed all other handlers.
**Severity**: Low — only affects packet loss count reset
**Classification**: Test-verifiable

#### Finding MI-2: mMuxConfig cross-thread access
**Description**: `MuxConfig` is written by the SWSS thread (e.g., `setNegativeStateChangeRetryCount`) and read by MuxPort/LinkManager on asio threads via `MuxPortConfig` reference. No synchronization.
**Severity**: Low — config changes are rare and mostly at init
**Classification**: Code-review-only

### 4.4 LinkProber and Sub-State Machines

#### Finding LP-1: Pervasive strand::wrap in event posting
**Lines**: LinkProberStateMachineBase.cpp:88,402; MuxStateMachine.cpp:107,126; LinkStateMachine.cpp:93,112
**Description**: ALL cross-state-machine event posting uses the broken `ioService.post(strand.wrap(...))` pattern. This means event ordering between LinkProber, MuxState, and LinkState notifications to the composite LinkManager is not guaranteed.
**Severity**: High — fundamental ordering assumption violated
**Classification**: Model-checkable (model as non-deterministic event queue)

#### Finding LP-2: StandbyState missing IcmpWaitEvent handler
**Description**: LinkProber StandbyState does not handle IcmpWaitEvent or IcmpHwWaitEvent. If the prober is in Standby and a Wait event occurs, the event is dropped with an error log. ActiveState and UnknownState handle this event correctly.
**Severity**: Medium — asymmetric transition capability
**Classification**: Model-checkable

#### Finding LP-3: MuxStateMachine Unknown→Unknown no event
**Description**: When MuxStateMachine is in Unknown state and receives an UnknownEvent, it stays in Unknown. Since the state didn't change, `postLinkManagerEvent` is not called. The composite state machine is never notified, breaking any retry loop that depends on re-notification.
**Severity**: High — exact mechanism of bug #136
**Classification**: Model-checkable

#### Finding LP-4: Error→Error no event
**Description**: Same pattern as LP-3 but for ErrorState. Repeated ErrorEvents produce no LinkManager notification.
**Severity**: Medium
**Classification**: Model-checkable

#### Finding LP-5: Wrong strand in MuxProbeRequestEvent
**Line**: LinkProberStateMachineActiveActive.cpp:191
**Description**: Posts `handleMuxProbeRequestEvent` to `mStrand` (LinkProber's strand) instead of the LinkManager's strand. This handler runs on the wrong strand, violating serialization guarantees.
**Severity**: Medium — handler runs unserialized with other LinkManager events
**Classification**: Test-verifiable

#### Finding LP-6: Timer-state races in LinkProberSw
**Description**: `handleTimeout()` and `handleRecv()` can post conflicting events (IcmpUnknownEvent vs IcmpSelfEvent) whose ordering is not guaranteed by `strand.wrap()`. The unknown event from a timeout could be processed before a self event from a heartbeat that arrived just before the timer fired.
**Severity**: Medium — temporary state misclassification
**Classification**: Model-checkable

#### Finding LP-7: handleIcmpPayload does not validate ICMP sequence number
**Line**: LinkProberSw.cpp:419
**Description**: `mRxSelfSeqNo = mTxSeqNo` stamps the current sequence number without comparing the received packet's actual sequence. A delayed reply from a previous cycle counts as current.
**Severity**: Low — conservative (treats delayed replies as valid)
**Classification**: Code-review-only

## 5. Bug Family Cross-References

### Family 1: Event Ordering / strand Dispatch
- **Historical**: #104, #254, PR #257, #113, #153
- **New findings**: LP-1 (25+ unfixed instances), MI-1 (missed MuxPort handler), LP-5 (wrong strand)
- **Total bugs**: 5 historical + 3 new findings
- **Still vulnerable**: YES — core event dispatch path unfixed

### Family 2: Missing/Incomplete Composite State Transitions
- **Historical**: #1, #6, #36, #77, #136, #137, #139, #169, #175, #178, #201, #202, #225, #282, #135, #165
- **New findings**: AA-1 ({Unknown,Error,Up}), AA-2 (duplicate reg), LP-2 (Standby missing Wait), LP-3 (Unknown→Unknown), LP-4 (Error→Error), AS-5 (unsolicited processed), AS-6 (mLastSetMuxState), AS-7 (correction gated)
- **Total bugs**: 16 historical + 8 new findings
- **Still vulnerable**: YES — new missing handlers found

### Family 3: Timer Interference
- **Historical**: #22, #27, #70, #81, #106, #208, #253, #261
- **New findings**: AA-8 (deadline not cancelled), AA-9 (resync no error check), AS-1 (oscillation+mode), AS-2 (backoff MAX forever), LP-6 (timer-state race)
- **Total bugs**: 8 historical + 5 new findings
- **Still vulnerable**: YES — backoff reset gaps persist

### Family 4: Default Route Interaction
- **Historical**: #44, #56, #194, #278, #279, #291, #292
- **New findings**: AA-3 (Wait passes != NA), AA-4 (asymmetric mode guard), AS-3 (Active ignoring route), AS-4 (suspend vs default route)
- **Total bugs**: 7 historical (1 still open) + 4 new findings
- **Still vulnerable**: YES

### Family 5: Peer State Desynchronization
- **Historical**: #101, #143, #148, #285
- **New findings**: AA-5 (PeerUnknown when unhealthy), AA-6 (peer not reset on link recovery), AA-7 (unconditional accept)
- **Total bugs**: 4 historical (1 still open) + 3 new findings
- **Still vulnerable**: YES

### Family 6: Restart/Initialization
- **Historical**: #42, #90, #128, #144, #168, #202, #217, #306, #307, #308, #319
- **New findings**: MI-2 (mMuxConfig thread safety)
- **Total bugs**: 11 historical (1 still open) + 1 new finding
- **Still vulnerable**: YES (#306 SIGABRT unfixed)

## 6. Modeling Scope Recommendation

### 6.1 Primary Focus: Active-Active Dual-ToR Model

The Active-Active mode has the highest bug density (12 of 16 Family-2 bugs are Active-Active specific) and the most complex interactions (peer state tracking). A TLA+ model should focus on:

1. **Two symmetric ToR processes** — each with full 3-tuple composite state
2. **Non-deterministic event delivery** — events posted but processed in any order (models strand::wrap)
3. **Abstract timers** — can expire at any point, with bounded backoff
4. **Peer state management** — each ToR tracks peer state and can command peer mux changes
5. **Default route as environmental input** — can change NA→OK or OK→NA at any time
6. **Mode as configuration input** — Auto, Standby, Active, Manual, Detached

### 6.2 Expected Spec Size

- ~700-900 lines of TLA+
- 2 ToR processes × (3 state dimensions + peer tracking + timers + default route + mode)
- ~15-20 actions per ToR
- ~8-10 invariants

### 6.3 Key Invariants to Verify

1. **NoDoubleStandby**: At least one ToR must be Active for each link (unless both links Down)
2. **NoStuckState**: Every reachable composite state has a handler or is stable terminal
3. **EventuallyActive**: If conditions allow, mux eventually reaches Active (liveness)
4. **TimerRecovery**: Backoff factors eventually reset when state resolves
5. **DefaultRouteRecovery**: After NA→OK with Active prober, mux returns to Active
6. **NoSpuriousToggle**: No toggle to Standby from healthy (Active/Active/Up) state unless mode requests it
