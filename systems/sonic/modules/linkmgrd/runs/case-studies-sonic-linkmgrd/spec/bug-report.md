# Bug Report: sonic-linkmgrd Active-Active Spec Validation

## Summary

**System**: sonic-linkmgrd Active-Active Dual-ToR Link Manager
**Spec**: Triple state machine (LinkProber x MuxState x LinkState) with strand::wrap event dispatch, timers, default route, peer state tracking
**Convergence**: 1 round. 30 min BFS, 2.66B states generated, 637M distinct, depth 13 — no violations on TypeOK + structural invariants.
**Bug hunting**: 2 real bugs found across 5 bug families.

## Bug 1: Missing Transition Handler for (LPWait, MuxError, LinkUp)

**Invariant violated**: `NoStuckState`
**Bug family**: Family 2 — Missing/Incomplete Composite State Transitions (MC-2 class)
**Severity**: Medium — system stuck until next heartbeat arrives

### Counterexample

```
State 1: Init — (LPWait, MuxWait, LinkDown)
State 2: MCMuxNotification(t1) — Mux reports Error: subMuxState → MuxError, event queued
State 3: MCLinkChange(t1) — Link comes up: subLinkState → LinkUp, event queued
State 4: MCProcessEvent(t1) — Processes EvLink(Up): HandleLinkEvent → InitLPFromMux(MuxWait) = LPWait
         → TransitionDispatch(LPWait, MuxWait, LinkUp) → AcceptNoOp → composite = (LPWait, MuxWait, LinkUp)
State 5: MCProcessEvent(t1) — Processes EvMux(Error): HandleMuxEvent → TransitionDispatch(LPWait, MuxError, LinkUp)
         → NO HANDLER → AcceptNoOp → composite = (LPWait, MuxError, LinkUp)
         Queue empty, all timers FALSE → STUCK
```

### Root Cause

`initializeTransitionFunctionTable()` (ActiveActive.cpp:653-774) does not register a handler for the composite state `{LPWait, MuxError, LinkUp}`. The existing handler `TH_LPActive_MxError_Up` only covers `{LPActive, MuxError, LinkUp}`. When the link prober is in Wait state (immediately after link-up initialization), MuxError has no recovery path.

### Impact

The system enters a stuck state with no automatic recovery mechanism. It waits passively for the next heartbeat event (which will transition LP from Wait to Active/Unknown, triggering the existing handler). During this wait period:
- No mux probe timer is running
- No switch is attempted
- Traffic may be misrouted

### Affected Code

- `LinkManagerStateMachineActiveActive.cpp:653-774` — transition table registration
- Missing: handler for `{LPWait, MuxError, LinkUp}` (should start mux probe, similar to `TH_LPActive_MxError_Up` at line 885)
- Also missing: `{LPWait, MuxUnknown, LinkUp}` has the same pattern (no handler, waits for heartbeat)

### Recommendation

Register handlers for `{LPWait, MuxError, LinkUp}` and `{LPWait, MuxUnknown, LinkUp}` that start the mux probe timer, analogous to the existing `TH_LPActive_MxError_Up` handler.

---

## Bug 2: Spurious Standby Toggle via strand::wrap Event Reordering

**Invariant violated**: `NoSpuriousToggle`
**Bug family**: Family 1 — Event Ordering / strand::wrap dispatch (MC-1 class) + Family 3 — Timer Interference
**Severity**: High — causes traffic disruption on healthy link

### Counterexample

```
State 1:  Init — (LPWait, MuxWait, LinkDown)
State 2:  MCHeartbeatActive(t1) — LP becomes Active, EvLP(Active) queued
State 3:  MCHeartbeatUnknown(t1) — LP becomes Unknown, EvLP(Unknown) queued
State 4:  MCMuxNotification(t1) — Mux becomes Active, EvMux(Active) queued
State 5:  MCLinkChange(t1) — Link Up, EvLink(Up) queued
State 6:  MCDefaultRouteChange(t1) — DR → OK
State 7:  MCProcessEvent(t1) — Processes EvLink(Up): composite → (LPWait, MuxWait, LinkUp)
State 8:  MCProcessEvent(t1) — Processes EvMux(Active): composite → (LPWait, MuxActive, LinkUp)
State 9:  MCProcessEvent(t1) — Processes EvLP(Active): composite → (LPActive, MuxActive, LinkUp) — HEALTHY
State 10: MCProcessEvent(t1) — Processes EvLP(Unknown): TH_LPUnknown_MxActive_Up → DoSwitchMux(Standby)
          → switchTarget = MuxStandby — SPURIOUS TOGGLE on healthy system!
```

### Root Cause

The event queue is modeled as an **unordered set** because `boost::asio::strand::wrap()` does NOT guarantee FIFO ordering for events posted from different sources (known issue #104, #254). This allows the **older** LP Unknown event (State 3) to be processed **after** the newer LP Active event (State 2).

At State 9, the system is in a fully healthy state: `(LPActive, MuxActive, LinkUp)` with `defaultRoute=DrOK` and `mode=Auto`. But State 10 processes the stale LP Unknown event, which triggers `TH_LPUnknown_MxActive_Up` → `DoSwitchMux(MuxStandby, TRUE)`. This forces a mux switch to Standby, disrupting traffic on a healthy link.

### Impact

- **Traffic disruption**: Server traffic is incorrectly steered away from an Active, healthy ToR
- **Affects**: All 25+ unfixed `strand::wrap()` call sites identified in the modeling brief
- **Frequency**: Depends on event interleaving timing — more likely under high event rates
- **Related issues**: #104, #254 (same bug class, partially fixed by PR #257 for MuxPort handlers only)

### Affected Code

The bug mechanism exists at every `ioService.post(strand.wrap(...))` call site:
- `LinkProberStateMachineBase.cpp:88` — `postLinkProberStateEvent()` (hot path, every ICMP event)
- `MuxStateMachine.cpp:107,126` — `postLinkManagerEvent()` and `postMuxStateEvent()`
- `LinkStateMachine.cpp:93,112` — both post methods
- `LinkProberBase.cpp:150,406,440,456` — multiple methods
- `MuxPort.cpp:433` — `resetPckLossCount()` (missed by PR #257)

### Recommendation

Replace all `strand::wrap()` calls with `boost::asio::post(strand, ...)` which guarantees FIFO ordering. PR #257 partially addressed this for MuxPort handlers but ~25 instances remain unfixed across the codebase.

---

## State Space Coverage

| Config | Invariant | States Generated | Distinct | Depth | Duration | Result |
|--------|-----------|-----------------|----------|-------|----------|--------|
| MC.cfg | TypeOK + structural | 2,663M | 637M | 13 | 30 min | No violation |
| Family 1 | NoStuckState | 87K | 51K | 9 | 1s | **Bug 1** |
| Family 2 | NoStuckState + UnknownErrorUpReachable | 966K | 427K | 10 | 2s | Bug 1 (same class) |
| Family 3 | BackoffNotStuckAtMax + NoSpuriousToggle | - | - | - | 29s | **Bug 2** |
| Family 4 | NoActiveWithDrWait | - | - | - | <1s | Case A (invariant too strong) |
| Family 5 | NoPeerStaleWhenHealthy | - | - | - | 3s | Case A (invariant too strong) |

## Notes

- **NoDoubleStandby** was removed from invariant checking — it's a liveness property, not a per-state safety property. Transient both-Standby states occur during legitimate transitions (LP Unknown → switchover, DR=NA on both ToRs).
- **NoStuckState** was weakened to accept states with pending timers or LPWait (transient, heartbeats will arrive).
- **Health()** computation: defaultRoute check removed from spec — implementation makes it conditional on `enableDefaultRouteFeature` flag (line 1147).
