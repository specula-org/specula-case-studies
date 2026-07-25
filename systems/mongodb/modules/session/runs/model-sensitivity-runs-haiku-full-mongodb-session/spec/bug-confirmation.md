# Phase 4: Bug Confirmation Report

## Bug 1: Deadlock in Session Lifecycle

**Status**: CASE B - Spec Modeling Issue (Not a real bug)

### Phase 1: Investigation Results

#### Step 1: Code Audit

**Relevant Code Locations**:
- `src/mongo/db/session/session_catalog.cpp:331-352` (_getOrCreateSessionRuntimeInfo)
- `src/mongo/db/session/logical_session_id_helpers.cpp:106-127` (isParentSessionId, isChildSession, getParentSessionId)
- `src/mongo/db/session/session_catalog.cpp:337-349` (parent-child session creation)

**Key Finding: Parent-Child Relationship Semantics**

In MongoDB, parent-child sessions are identified by the presence/absence of a transaction UUID:
```cpp
bool isParentSessionId(const LogicalSessionId& sessionId) {
    // All child sessions must have a txnUUID.
    return !sessionId.getTxnUUID();
}

bool isChildSession(const LogicalSessionId& sessionId) {
    // All child sessions must have a txnUUID.
    return bool(sessionId.getTxnUUID());
}
```

This means:
- **Parent sessions**: LogicalSessionId with id + uid, NO txnUUID
- **Child sessions**: LogicalSessionId with id + uid + txnUUID

A single session ID cannot be both:
- A parent session (no txnUUID) AND
- A child session (has txnUUID)

Therefore, a parent session **cannot be its own child** since that would require it to have a txnUUID while also not having one.

**Parent Relationship Implementation**:
```cpp
const auto& parentLsid = isParentSessionId(lsid) ? lsid : *getParentSessionId(lsid);
```

The parent of a session is derived by taking its id and uid and removing the txnUUID. A parent session's parent is itself (which is mathematically correct).

#### Step 2: Developer Intent Investigation

**Code Analysis**:
- No safeguards explicitly prevent a parent from being created as its own child because the **type system prevents it**
- The real implementation relies on the fact that parent and child sessions are structurally different (one has txnUUID, one doesn't)
- Tests verify this behavior implicitly but don't need explicit guards

**Code Comments**:
- Line 196-198 in session_catalog.h: "Can only create a SessionRuntimeInfo with a parent transaction session id"
- This invariant is maintained by construction

#### Step 3: Why the Spec Allows Self-Parenting

**TLA+ Spec CreateChildSession** (lines ~265-275):
```tla
CreateChildSession(parentSid, childSid) ==
  /\ parentSid \in SessionIds
  /\ childSid \in SessionIds
  /\ childSid \notin childrenOf[parentSid]
  /\ parentOf[childSid] = NULL  (* Not already a child *)
  /\ parentOf' = [parentOf EXCEPT ![childSid] = parentSid]
  /\ childrenOf' = [childrenOf EXCEPT ![parentSid] = @ \cup {childSid}]
  ...
```

**Missing Precondition**: There is NO guard that prevents `parentSid ≠ childSid`

The spec does not encode the fundamental type-system constraint that:
- In MongoDB, a "parent session" and a "child session" are **different types** (one has txnUUID, one doesn't)
- Therefore, `childSid` cannot equal `parentSid` because they would have different TxnUUIDs

### Root Cause of Deadlock

The deadlock trace shows:
1. State 14: CreateChildSession(s1, s1) - Creates s1 as its own child (not possible in real code)
2. State 15: CreateChildSession(s1, s2) - Creates s2 as child of s1

In real MongoDB:
- Line 14 would be **impossible**: s1 cannot simultaneously have no TxnUUID (as parent) and have a TxnUUID (as child)
- The type system prevents this scenario entirely

### Conclusion

**Classification**: CASE B - Spec Modeling Issue

**Impact**: This is a **false positive**. The deadlock is:
- ✗ **Not reachable in real MongoDB** due to type-system constraints
- ✓ Reachable in TLA+ model due to spec under-modeling the type distinction
- ✗ **Not a real bug** in the implementation

### Recommended Fix

**Option 1: Strengthen Spec Precondition** (Preferred)
Add a guard to CreateChildSession to prevent self-parenting:
```tla
CreateChildSession(parentSid, childSid) ==
  /\ parentSid \in SessionIds
  /\ childSid \in SessionIds
  /\ parentSid ≠ childSid  (* ADDED: Sessions cannot be their own parents *)
  /\ childSid \notin childrenOf[parentSid]
  /\ parentOf[childSid] = NULL
  ...
```

**Option 2: Model TxnUUIDs Explicitly**
Add TxnUUID to the session representation to model the type distinction:
```tla
VARIABLE sessionTxnUUID  (* Maps SessionId -> UUID or NULL *)

CheckedOutSessionInner(sid) ==
  ...
  /\ sessionTxnUUID[sid] = NULL  (* Only parent sessions can be checked out *)

CreateChildSession(parentSid, childSid) ==
  /\ sessionTxnUUID[parentSid] = NULL     (* parentSid must be parent *)
  /\ sessionTxnUUID[childSid] = NULL      (* childSid not yet a child *)
  ...
  /\ sessionTxnUUID' = [sessionTxnUUID EXCEPT ![childSid] = NewUUID]
```

### References

- MongoDB Source: `/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/mongodb-session/artifact/mongo-src/src/mongo/db/session/logical_session_id_helpers.cpp:106-127`
- TLA+ Spec: `/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/mongodb-session/spec/base.tla` lines ~265-275
- Model Checking Run: `spec/output/MC_run_phase3b_v7.log` (deadlock at trace depth 17)

---

## Bug 2: Circular Parent-Child Relationships

**Status**: CASE B - Spec Modeling Issue (Not a real bug)

After fixing the self-parenting issue, model checking found a new deadlock caused by **circular parent-child relationships**:
- State 12: s2 becomes parent of s1 (s1 is child of s2)
- State 13: s1 becomes parent of s2 (s2 is child of s1)
- Result: Circular dependency where s1 ↔ s2

**Root Cause**: The spec models parent-child relationships as arbitrary binary relationships. However, in MongoDB:
- Parent sessions are identified by ID+uid without TxnUUID
- Child sessions are ID+uid WITH TxnUUID
- All children of a given ID+uid session share the same parent
- Child sessions cannot be parents themselves (they already have a TxnUUID)
- **Multi-generation hierarchies are impossible** - all children point directly to the same parent

The TLA+ spec allows child sessions to become parents, which is structurally impossible in the real code.

### Additional Fix Needed

In addition to preventing self-parenting, we need to prevent children from becoming parents:

```tla
CreateChildSession(parentSid, childSid) ==
  /\ parentSid \in SessionIds
  /\ childSid \in SessionIds  
  /\ parentSid /= childSid  (* ADDED: No self-parenting *)
  /\ parentOf[childSid] = NULL  (* Not already a child *)
  /\ parentOf[parentSid] = NULL  (* ADDED: Parent cannot itself be a child *)
  /\ childSid \notin childrenOf[parentSid]
  /\ parentOf' = [parentOf EXCEPT ![childSid] = parentSid]
  /\ childrenOf' = [childrenOf EXCEPT ![parentSid] = @ \cup {childSid}]
  ...
```

This ensures that **only top-level sessions (those not children of others) can become parents**.

---

## Bug 3: Deadlock with Session Checked Out + Marked for Reap

**Status**: CASE A - Possible Overly-Strong Invariant or Model Artifact

After fixing the parent-child constraints, model checking found a third deadlock scenario:
- Session s1 is checked out with an active operation context (checkoutOpCtx[s1] = 0)
- Sessions s1 and s2 are both marked for reap
- Reap action has hit its fault counter limit (2 times)
- No further actions can execute

**Analysis**:
This deadlock occurs when:
1. A session that's been checked out is marked for reap
2. We've exhausted the reap action counter (MaxReapLimit=2 in config)
3. ReleaseSession cannot execute because the session state doesn't match (need CHECKED_OUT state check)

**Possible Classification**:
- **CASE A**: The counter-bounded model prevents reaching legitimate cleanup states. The bounded reap counter is overly restrictive.
- **CASE B**: The spec doesn't properly model what happens when a session with an active operation context is marked for reap.
- **Model Artifact**: The deadlock is a consequence of aggressive state space bounding, not a real system issue.

**Note**: This finding requires deeper analysis with more permissive counters or refined spec guards to determine if it's a real bug or an artifact of the bounded model checking approach.

---

## Summary

**Status**: CASE A/B - Spec Issues Found, No Clear Real Bugs Yet

Phase 3B/4 model checking and investigation found **three deadlock scenarios**, all attributed to spec modeling issues:

1. ✓ **Self-parenting** (FIXED) - Sessions cannot be their own parents due to TxnUUID type system
2. ✓ **Circular parent-child** (FIXED) - Children cannot be parents; hierarchy is one-level
3. ? **Checkout + Marked-for-reap** (UNDER INVESTIGATION) - May be CASE A or model artifact

**Completed Actions**:
- ✓ Unblocked Phase 3B by fixing syntax/modeling errors
- ✓ Got model checking running successfully (27M+ states explored)
- ✓ Identified and fixed two false-positive spec issues
- ✓ Conducted thorough code audit of parent-child relationship semantics

**Next Recommendations**:
1. **Increase reap counter bounds** (MaxReapLimit, MaxReapScanLimit) to eliminate counter-based artifacts
2. **Run targeted bug-family hunting** with family-specific configs (MC_hunt_family1.cfg through family5.cfg)
3. **Focus on real invariant violations** rather than deadlock detection
4. **Document findings** in case a real deadlock scenario is discovered after refinement

---

## References

- **Investigation Files**: 
  - `spec/bug-confirmation.md` (this file)
  - `spec/PHASE3B_STATUS.md` (progress tracking)
  - `spec/output/MC_run_phase3b_*.log` (model checking runs)
  
- **Spec Files Modified**:
  - `spec/base.tla` - Added parent-child constraints
  - `spec/MC.tla` - Removed invalid INVARIANTS block
  - `spec/MC.cfg` - Added missing constants

- **Implementation Source**:
  - `/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/mongodb-session/artifact/mongo-src/src/mongo/db/session/logical_session_id_helpers.cpp`
  - `/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/mongodb-session/artifact/mongo-src/src/mongo/db/session/session_catalog.cpp`

