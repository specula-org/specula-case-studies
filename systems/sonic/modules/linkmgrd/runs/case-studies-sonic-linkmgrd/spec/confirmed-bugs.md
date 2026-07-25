# Confirmed Bug Report — sonic-linkmgrd

## Summary
- Total findings reviewed: 25 (2 MC-confirmed bugs + 12 model-checkable hypotheses + 6 test-verifiable + 5 code-review-only)
- Reproduced: 2
- Historical (matched to existing issues, no reproduction needed): 1
- False positives: 1
- Inconclusive: 1
- Filtered out (defensive coding, style, theoretical, or subsumed by other findings): 20

---

## Bug 1: Missing Transition Handler for (LPWait, MuxError, LinkUp) in Active-Active Mode

- **Source**: MC (counterexample provided)
- **Status**: REPRODUCED
- **Severity**: Medium — system stuck until next heartbeat arrives; traffic may be misrouted during stuck period
- **Location**: `src/link_manager/LinkManagerStateMachineActiveActive.cpp:653-774`

### Description

The transition function table `initializeTransitionFunctionTable()` does not register a handler for the composite state `{LinkProberWait, MuxError, LinkUp}`. When this state is reached, the base class `noopTransitionFunction` runs — logging but taking no recovery action. No mux probe timer is started, no mux state change is requested, and no switch is attempted. The system passively waits for the next heartbeat event to transition LinkProber out of Wait state.

The existing handler `LinkProberActiveMuxErrorLinkUpTransitionFunction` (line 885) handles `{LPActive, MuxError, LinkUp}` by calling `startMuxProbeTimer()`, which is the correct recovery action. But when MuxError occurs before the first heartbeat response (LP still in Wait), this recovery path is unreachable.

Additionally, line 703 contains a duplicate registration of `{Active, Unknown, Up}` (identical to line 676), which is likely a copy-paste error. The intended registration may have been `{Unknown, Error, Up}`, which is also missing from the table.

### Trigger Scenario (MC counterexample)

```
State 1: Init — (LPWait, MuxWait, LinkDown)
State 2: Mux reports Error → subMuxState = MuxError, event queued
State 3: Link comes up → subLinkState = LinkUp, event queued
State 4: Process EvLink(Up) → composite = (LPWait, MuxWait, LinkUp)
State 5: Process EvMux(Error) → composite = (LPWait, MuxError, LinkUp)
         NO HANDLER → noopTransitionFunction → STUCK
```

This sequence occurs when mux hardware reports an error during the initial startup phase before the first ICMP heartbeat response arrives.

### Developer Intent

Developers have previously fixed similar missing-handler bugs in this exact family: #169 (Unknown/Unknown/Down and Unknown/Wait/Down), #175 (link down with MuxState Unknown in Active-Active), #178 (same for Active-Standby). These fixes addressed other gaps in the transition table but missed this particular combination. No comments or TODO markers exist for the {Wait, Error, Up} state.

### Reproduction Test

**File**: `repro/test_bug1_missing_transition_handler.cpp`
**Test name**: `LinkManagerStateMachineActiveActiveTest.BugMissingHandlerWaitErrorUp`

**Run command**:
```bash
docker exec sonic-build bash -c \
  "cd /workspace/case-studies/sonic-linkmgrd/artifact/sonic-linkmgrd && \
   ./linkmgrd-test --gtest_filter='LinkManagerStateMachineActiveActiveTest.BugMissingHandlerWaitErrorUp'"
```

**Actual output**:
```
Note: Google Test filter = LinkManagerStateMachineActiveActiveTest.BugMissingHandlerWaitErrorUp
[==========] Running 1 test from 1 test suite.
[----------] Global test environment set-up.
[----------] 1 test from LinkManagerStateMachineActiveActiveTest
[ RUN      ] LinkManagerStateMachineActiveActiveTest.BugMissingHandlerWaitErrorUp
[       OK ] LinkManagerStateMachineActiveActiveTest.BugMissingHandlerWaitErrorUp (1 ms)
[----------] 1 test from LinkManagerStateMachineActiveActiveTest (1 ms total)

[----------] Global test environment tear-down
[==========] 1 test from 1 test suite ran. (1 ms total)
[  PASSED  ] 1 test.
```

**Reproduction result**: PASS (bug triggered). The test confirms that after reaching composite state (Wait, Error, Up), both `mSetMuxStateInvokeCount` and `mProbeForwardingStateInvokeCount` remain unchanged — no recovery action is taken, and the system is stuck. The test asserts this stuck behavior, and the assertion passes, proving the missing handler.

### Recommendation

Register handlers for `{LPWait, MuxError, LinkUp}` and `{LPWait, MuxUnknown, LinkUp}` that call `startMuxProbeTimer()`, analogous to the existing `LinkProberActiveMuxErrorLinkUpTransitionFunction`. Also fix the duplicate registration at line 703 — it should likely register `{Unknown, Error, Up}` instead.

---

## Bug 2: Spurious Standby Toggle via strand::wrap Event Reordering

- **Source**: MC (counterexample provided) + Code Review (Family 1)
- **Status**: HISTORICAL — matches known issues #104, #254; partially addressed by PR #257
- **Severity**: High — traffic disruption on healthy link
- **Location**: All `ioService.post(strand.wrap(...))` call sites (~25 instances), primarily:
  - `src/link_prober/LinkProberStateMachineBase.cpp:88` — `postLinkProberStateEvent()` (hot path)
  - `src/mux_state/MuxStateMachine.cpp:107,126` — `postLinkManagerEvent()`, `postMuxStateEvent()`
  - `src/link_state/LinkStateMachine.cpp:93,112` — both post methods
  - `src/MuxPort.cpp:433` — `resetPckLossCount()` (missed by PR #257)

### Description

`boost::asio::strand::wrap()` does NOT guarantee FIFO ordering for handlers posted from different execution contexts. Events from LinkProber, MuxStateMachine, and LinkStateMachine can be reordered when they arrive at the composite state machine. The MC counterexample shows a scenario where an older LP Unknown event is processed after a newer LP Active event, causing a spurious mux switch to Standby on a fully healthy link.

PR #257 partially addressed this for MuxPort handlers by replacing `strand.wrap()` with `boost::asio::post(strand, ...)`, but ~25 instances remain unfixed across LinkProberStateMachineBase, MuxStateMachine, LinkStateMachine, and LinkProberBase.

### MC Counterexample

```
States 1-8: System reaches (LPActive, MuxActive, LinkUp) — fully healthy
State 9:    Processes LP Active event → composite = (Active, Active, Up) ← HEALTHY
State 10:   Processes STALE LP Unknown event (from earlier, reordered by strand::wrap)
            → TH_LPUnknown_MxActive_Up → DoSwitchMux(Standby) ← SPURIOUS TOGGLE
```

### Reproduction

Not reproduced — this is a known/historical bug matching issues #104, #254 with partial fix in PR #257. Per the bug-confirmation guide, historical bugs with existing tickets do not require reproduction.

### Recommendation

Replace all remaining `strand::wrap()` calls with `boost::asio::post(strand, ...)` across the codebase, completing the fix started in PR #257.

---

## Bug 3: DefaultRoute::Wait Passes `!= NA` Check — Premature Active Switch

- **Source**: Code Review (MC-6 in modeling brief)
- **Status**: REPRODUCED
- **Severity**: Medium — premature Active switch during startup when default route feature is enabled; brief window of incorrect forwarding
- **Location**: `src/link_manager/LinkManagerStateMachineActiveActive.cpp:807`

### Description

The `LinkProberActiveMuxStandbyLinkUpTransitionFunction` handler at line 807 uses the check `mDefaultRouteState != DefaultRoute::NA` to decide whether to switch to Active. The `DefaultRoute` enum has three values: `{Wait, NA, OK}`, with `Wait` as the initial value (line 673 of `LinkManagerStateMachineBase.h`). When the default route feature is enabled but no DR notification has been received yet (DR = Wait), this check evaluates to true (`Wait != NA`), causing a premature switch to Active.

This is inconsistent with the health computation at line 1147, which correctly uses `mDefaultRouteState == DefaultRoute::OK`. The handler at line 807 is the only transition handler in Active-Active mode that uses the `!= NA` pattern; all other DR-checking code uses `== OK` or `== NA`.

### Trigger Scenario

1. Service starts with `enableDefaultRouteFeature = true`
2. Link comes up, LP receives heartbeats → LP Active
3. Mux hardware reports Active → system is at (Active, Active, Up) with DR = Wait
4. Mux reports Standby (e.g., orchagent override or hardware glitch)
5. Handler `{Active, Standby, Up}` fires, checks `DR != NA` → true (Wait != NA)
6. Switches to Active — but DR hasn't been confirmed OK yet

### Developer Intent

The codebase has 6 other default route checks in related code that all use `== OK`: lines 775, 997, 1147, 1250, 1356 in Active-Standby and Active-Active. Line 807 is the sole outlier. No comments explain this choice. The design document (`doc/default_route.md`) describes the full Wait→NA→OK lifecycle but doesn't address how the initial Wait state should be handled. This appears to be an inconsistent deviation from the established pattern, not a deliberate choice.

### Reproduction Test

**File**: `repro/test_bug3_default_route_wait.cpp`
**Test name**: `LinkManagerStateMachineActiveActiveTest.BugDefaultRouteWaitPrematureActiveSwitch`

**Run command**:
```bash
docker exec sonic-build bash -c \
  "cd /workspace/case-studies/sonic-linkmgrd/artifact/sonic-linkmgrd && \
   ./linkmgrd-test --gtest_filter='LinkManagerStateMachineActiveActiveTest.BugDefaultRouteWaitPrematureActiveSwitch'"
```

**Actual output**:
```
Note: Google Test filter = LinkManagerStateMachineActiveActiveTest.BugDefaultRouteWaitPrematureActiveSwitch
[==========] Running 1 test from 1 test suite.
[----------] Global test environment set-up.
[----------] 1 test from LinkManagerStateMachineActiveActiveTest
[ RUN      ] LinkManagerStateMachineActiveActiveTest.BugDefaultRouteWaitPrematureActiveSwitch
[       OK ] LinkManagerStateMachineActiveActiveTest.BugDefaultRouteWaitPrematureActiveSwitch (32 ms)
[----------] 1 test from LinkManagerStateMachineActiveActiveTest (32 ms total)

[----------] Global test environment tear-down
[==========] 1 test from 1 test suite ran. (32 ms total)
[  PASSED  ] 1 test.
```

**Reproduction result**: PASS (bug triggered). The test confirms that with the default route feature enabled and DR still in Wait state, the `{Active, Standby, Up}` handler calls `switchMuxState(Active)`. The assertion `mDbInterfacePtr->mLastSetMuxState == Active` passes, proving the premature switch. The switch count `mSetMuxStateInvokeCount > 1` also passes, confirming the switch was requested.

### Recommendation

Change line 807 from:
```cpp
} else if (mDefaultRouteState != DefaultRoute::NA) {
```
to:
```cpp
} else if (!mMuxPortConfig.ifEnableDefaultRouteFeature() || mDefaultRouteState == DefaultRoute::OK) {
```
This aligns with the health check pattern at line 1147 and prevents premature switching when DR is in the initial Wait state.

---

## Finding 4: Detached Mode Asymmetric Default Route Guard

- **Source**: Code Review (MC-7 in modeling brief)
- **Status**: INCONCLUSIVE — may be intentional safety mechanism
- **Severity**: Low-Medium (if bug)
- **Location**: `src/link_manager/LinkManagerStateMachineActiveActive.cpp:1345-1367`

### Description

In the `handleDefaultRouteStateNotification` handler:
- **DR = NA** (line 1346): switches to Standby if `mode != Active` — this includes Detached mode
- **DR = NA→OK** (line 1358): recovers (resets LP state) only if `mode == Auto` — this excludes Detached mode

In Detached mode, the port switches to Standby when DR becomes NA but cannot recover when DR returns to OK. This creates a one-way trap where Detached-mode ports accumulate in Standby after DR flaps.

However, this may be intentional: the DR=NA→Standby switch could be a safety mechanism that takes priority over the "no automatic switching" semantics of Detached mode. Without clear developer documentation on Detached mode's interaction with default route, this cannot be conclusively classified.

### Reproduction

Not attempted — the finding is architecturally ambiguous and may be by design.

---

## Finding 5: Active-Standby Forces Active Switch Ignoring Default Route State

- **Source**: Code Review (MC-11 in modeling brief)
- **Status**: FALSE POSITIVE
- **Severity**: N/A
- **Location**: `src/link_manager/LinkManagerStateMachineActiveStandby.cpp:1264-1277`

### Description

`LinkProberActiveMuxUnknownLinkUpTransitionFunction` forces a switch to Active after `getNegativeStateChangeRetryCount()` retries without checking the default route state. The modeling brief flagged this as inconsistent with `LinkProberUnknownMuxStandbyLinkUpTransitionFunction` (line 1250) which checks `mDefaultRouteState == DefaultRoute::OK` before switching.

### Why False Positive

The two handlers serve different purposes:
- **{Unknown, Standby, Up}**: LP Unknown means heartbeats are failing — the system is UNSURE about link health. Checking DR before taking over from the peer is appropriate because two uncertain signals (Unknown LP + Unknown DR) shouldn't trigger a switch.
- **{Active, Unknown, Up}**: LP Active means heartbeats ARE succeeding — the link is CONFIRMED healthy. The mux state is Unknown (hardware query returned unknown), which is a mux hardware/software issue, not a link issue. Forcing Active to match the known-healthy LP state is the correct recovery action regardless of DR state.

The asymmetry is intentional: LP Active is a strong positive signal that overrides DR uncertainty for mux recovery purposes.

---

## Regression Check

All 49 Active-Active tests pass after adding the two reproduction tests:
```
[==========] 49 tests from 1 test suite ran. (82551 ms total)
[  PASSED  ] 49 tests.
```
