# Bug Report: Model Checking Results

## Summary

Model checking successfully executed and found one potential bug: a deadlock state reachable at trace depth 17. This report documents the finding and prepares it for bug confirmation (Phase 4).

## Bug 1: Deadlock in Session Lifecycle (Potential)

### Classification: Under Investigation (Requires Code Audit)

### Counterexample Trace

**File**: `spec/output/MC_run_phase3b_v7.log`  
**Trace Depth**: 17 states  
**Deadlock State**: State 15 (final state where no further actions can execute)

### Final Deadlock State Details

```
State 15:
/\ sessionState = (s1 :> "AVAILABLE" @@ s2 :> "AVAILABLE")
/\ killsRequested = (s1 :> 0 @@ s2 :> 0)
/\ markedForReap = (s1 :> TRUE @@ s2 :> TRUE)
/\ reapMode = (s1 :> "NONEXCLUSIVE" @@ s2 :> "NONEXCLUSIVE")
/\ checkoutOpCtx = (s1 :> -1 @@ s2 :> 0)
/\ opContexts = (0 :> [interrupted |-> FALSE, done |-> FALSE])
/\ parentOf = (s1 :> s1 @@ s2 :> s1)
/\ childrenOf = (s1 :> {s1, s2} @@ s2 :> {})
/\ reapRunning = FALSE
/\ reapedSessionIds = {s1, s2}
/\ activeSessions = {s1, s2}
/\ faultCounters = [
    checkout |-> 1, kill |-> 3, release |-> 0,
    callbackExec |-> 0, callbackComplete |-> 0,
    reapScan |-> 2, createChild |-> 2,
    refresh |-> 2, reap |-> 2
  ]
```

### Execution Sequence

**State 1→2**: MCScanSessionsForReap - Mark s1 for reap
**State 2→3**: MCCheckOutSessionInner(s2, FALSE) - Checkout s2 (opCtxId=0)
**State 3→4**: MCObservableSessionKill(s1) - Increment kill counter
**State 4→5**: MCObservableSessionKill(s1) - Increment kill counter again
**State 5→6**: MCObservableSessionKill(s1) - Increment kill counter (hits MaxKillLimit=3)
**State 6→...**: Series of operations including refresh, reap, and child creation
**State 13→14**: MCCreateChildSession(s1, s1) - **s1 becomes its own parent!**
**State 14→15**: MCCreateChildSession(s1, s2) - **s1 becomes parent of s2**
**State 15**: **DEADLOCK** - No action can execute

### Analysis

#### Suspicious Conditions

1. **Self-Parent Relationship**: At State 14, s1 is created as a child of s1 (itself)
   - Line in state: `parentOf = (s1 :> s1 @@ s2 :> s1)`
   - This creates a self-loop in the parent-child hierarchy

2. **Checked-Out Session Remains in AVAILABLE State**:
   - s2 has opCtxId=0 but sessionState remains "AVAILABLE" (not "CHECKED_OUT")
   - Indicates potential type inconsistency or spec modeling issue

3. **Both Sessions Marked for Reap But Still Active**:
   - markedForReap = (s1 :> TRUE @@ s2 :> TRUE)
   - reapedSessionIds = {s1, s2}
   - But sessionState shows both are still "AVAILABLE"
   - Suggests spec allows unreachable cleanup state

4. **No Actions Enabled**:
   - reapRunning = FALSE
   - refreshRunning = FALSE
   - All fault counters have hit their limits or appropriate bounds
   - checkoutOpCtx[s2] = 0 (s2 still has operation context)
   - No action can progress the system

### Why This Matters

If this deadlock is **reachable in the real MongoDB implementation**, it represents a critical bug:
- Sessions cannot complete their lifecycle
- Operation contexts remain held indefinitely
- Reap operations cannot complete despite being initiated

### Investigation Tasks (Phase 4)

#### Task 1: Code Audit
- [ ] Locate CreateChildSession in `mongo-src/session_catalog.cpp`
- [ ] Check if self-parent relationships are prevented
- [ ] Examine parent-child validation logic
- [ ] Verify sessionState consistency when checking out operations

#### Task 2: Replay in Real System
- [ ] Write a test that attempts to create self-parent relationship
- [ ] Try to recreate the state sequence in actual MongoDB
- [ ] Check if deadlock occurs in implementation

#### Task 3: Spec Validation
- [ ] Verify the trace is valid according to spec semantics
- [ ] Check if parent-child creation guards are modeled correctly
- [ ] Review CheckOutSessionInner logic for state transition consistency

### Files Involved

- **Spec**: `/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/mongodb-session/spec/base.tla`
  - CreateChildSession operator (lines ~260-275)
  - CheckOutSessionInner operator (lines ~151-167)
  - Parent-child consistency invariants

- **Implementation**: `/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/mongodb-session/artifact/mongo-src/`
  - `session_catalog.cpp` - CreateChildSession implementation
  - Check guards and validation logic

### Supporting Details

**Model Configuration**:
- SessionIds = {s1, s2}
- MaxKillLimit = 3
- MaxReapLimit = 2
- MaxCreateChildLimit = 2

**Spec Changes Made** (to enable model checking):
- Added NULL = -1 (numeric sentinel for "no value")
- Added MaxOpCtxId constant
- Bounded operation context ID enumeration to (0..MaxOpCtxId)

### Next Steps

1. **Run bug-confirmation skill**: Follow Phase 4 procedures to:
   - Audit the MongoDB source code
   - Determine if self-parent relationships are allowed
   - Check if this deadlock is actually reachable

2. **Classify the bug**:
   - **Case A** (Invariant Too Strong): If deadlock is benign/expected
   - **Case B** (Spec Issue): If spec models incorrectly
   - **Case C** (Real Bug): If implementation allows this deadlock state

3. **Document findings**: Update this report with classification and evidence

---

**Generated**: 2026-06-04  
**Model Checking Run**: Phase 3B v7 (MC_run_phase3b_v7.log)  
**Status**: Awaiting Phase 4 Bug Confirmation
