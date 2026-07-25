# Phase 3B: TLA+ Model Checking Bug Report
## libspdm-meas-ext-log

**Report Date**: 2026-06-04  
**Target System**: libspdm Measurement Extension Log (MEL) Protocol  
**Model Checking Results**: 1 finding in bug-family hunting

---

## Executive Summary

Base model checking (MC.cfg) with standard invariants completed successfully with **no violations**. All 6 bug-family hunting configurations were run; only BF3 (Loop Termination Condition Race) produced a finding.

### Key Finding

**BF3 Violation**: Temporal property `TransferCompletes` was violated under message loss conditions without recovery mechanisms. The requester can become stuck in a "waiting" state indefinitely when a response is lost, violating the liveness property that the transfer should eventually complete.

---

## Base Model Checking Results

**Config**: MC.cfg  
**Duration**: 3 seconds  
**States Generated**: 224  
**Distinct States**: 186  
**Result**: ✅ **PASSED** - No invariant violations found

**Invariants Checked**:
- NoOffsetOverflow ✅
- RemainderConsistency ✅
- BufferBounds ✅
- HeaderGuard ✅
- PortionLengthValid ✅
- TotalSizeConsistent ✅

---

## Bug-Family Hunting Results

| Bug Family | Config | Duration | States | Result | Notes |
|-----------|--------|----------|--------|--------|-------|
| BF1 | MC_hunt_BF1.cfg | ~10s | - | ⚠️ Timeout | Out-of-memory (exit 137) |
| BF2 | MC_hunt_BF2.cfg | ~11s | - | ⚠️ Timeout | Out-of-memory (exit 137) |
| BF3 | MC_hunt_BF3.cfg | 4s | 130 gen / 115 dist | ❌ **VIOLATION** | Temporal property violated |
| BF4 | MC_hunt_BF4.cfg | ~10s | - | ⚠️ Timeout | Out-of-memory (exit 137) |
| BF5 | MC_hunt_BF5.cfg | ~11s | - | ⚠️ Timeout | Out-of-memory (exit 137) |
| BF6 | MC_hunt_BF6.cfg | ~11s | - | ⚠️ Timeout | Out-of-memory (exit 137) |

### Timeout Note
BF1, BF2, BF4, BF5, BF6 all exited with code 137 (SIGKILL), indicating TLC hit an out-of-memory condition while exploring their state spaces. These required more aggressive fault injection (higher MessageLossLimit, WrongRemainderLimit, or OffsetOverflowLimit) that causes state-space explosion beyond available memory with the given resource limits.

---

## Finding Details: BF3 - Loop Termination Condition Race

### Classification
**Type**: Case B (Spec Modeling Issue)  
**Severity**: Medium  
**Category**: Liveness Property Violation

### Violation Description

**Temporal Property**: `TransferCompletes == <>(req_pc = "done")`  
This property asserts that the requester should eventually reach the "done" state, completing the transfer.

**Counterexample Trace**:

```
State 1: <Initial predicate>
  - req_pc = "ready"
  - messages = {}
  - messageLossCount = 0
  
State 2: <MCRequesterSendGetMel>
  - req_pc = "waiting"
  - messages = {GetMelRequest(offset=0, length=1)}
  
State 3: <MCResponderReceiveAndSendMel>
  - messages = {MelResponse(portion_length=1, remainder_length=9)}
  
State 4: <MCMessageLoss>
  - messages = {}  (response is lost)
  - messageLossCount = 1
  - req_pc = "waiting"  (requester still waiting for response)
  
State 5: Stuttering
  - No enabled actions can make progress
  - System deadlocked in "waiting" state
  - TransferCompletes property violated (never reaches "done")
```

### Root Cause Analysis

The violation reveals that the protocol model lacks a **recovery mechanism for message loss**. Specifically:

1. **Message Loss Without Timeout**: When a response message is lost (MCMessageLoss action fires), the requester remains in "waiting" state indefinitely with no way to resend the request.

2. **No Timeout or Retry Logic**: The spec doesn't model timeout-based retries. In real protocol implementations like libspdm, a timeout would trigger a resend of the GetMelRequest, allowing the transfer to continue.

3. **Fairness Missing**: The temporal property verification relies on fairness assumptions that the spec doesn't declare. Without explicit fairness constraints, TLC allows infinite stuttering paths.

### Code Location

**Spec**: `/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/libspdm-meas-ext-log/spec/`
- **MC.tla**: MCMessageLoss action (line 29-37) drops response without recovery
- **base.tla**: RequesterReceiveMelResponse action has no timeout handling
- **base.tla**: TransferCompletes property (liveness check for completion)

**Implementation Reference**: 
- libspdm_req_get_measurement_extension_log.c: Should implement timeout-based retry logic for handling message loss

### Is This a Real Bug?

**Assessment**: **Not a real bug in the implementation** (likely Case B issue)

**Rationale**:
- The libspdm implementation almost certainly includes timeout and retry mechanisms to handle network message loss
- The spec model over-simplifies the MEL transfer protocol by omitting these recovery mechanisms
- This is a **spec fidelity issue**, not an implementation bug

### Recommended Action

**Fix Type**: Spec Modification (Case B)

To resolve this violation, the spec should be updated to:

1. **Add Timeout Model**: Introduce a timeout counter that tracks how long the requester has been waiting
2. **Add Retry Action**: Model a "timeout+retry" action that allows the requester to resend the request after timeout
3. **Add Fairness Constraint**: Declare that certain actions (like timeout) are "weakly fair" to guide TLC's verification
4. **Update TransferCompletes**: Either:
   - Keep it as-is with proper fairness (ensures timeouts eventually fire), or
   - Weaken it to account for network conditions

**Example Spec Addition**:
```tla
VARIABLE requestTimeout

RetryAfterTimeout ==
    /\ req_pc = "waiting"
    /\ requestTimeout > TimeoutLimit
    /\ messages' = messages \cup {MakeGetMelRequest(req_offset, req_length)}
    /\ requestTimeout' = 0
    /\ UNCHANGED requesterVars (except req_pc stays "waiting")

(* Temporal property with fairness *)
MCSpec == MCInit /\ [][MCNext]_vars /\ WF_vars(RetryAfterTimeout)
```

---

## Conclusion

The base protocol specification is sound (no invariant violations in standard checking). The BF3 finding is a spec modeling issue reflecting the lack of timeout/retry logic, which is typically handled by the real implementation. The other hunting configs (BF1,2,4,5,6) could not complete due to state-space explosion, suggesting they may require smaller bounds or different hunting parameters to be effectively analyzed.

**Next Steps**:
1. Add timeout/retry model to spec for more faithful MEL protocol representation
2. Re-run BF1,2,4,5,6 with reduced state-space bounds
3. Re-validate with updated spec to verify no new violations introduced

---

## Phase 4: Confirmation Status

**BF3 Investigation Result: FALSE POSITIVE (Spec Artifact)**

Code audit confirms the libspdm implementation includes transport-layer timeout mechanisms:
- `libspdm_receive_response` calls `context->receive_message` with explicit timeout (rtt + st1 or rtt + ct_exponent)
- When response is lost, timeout expires and function returns error (not deadlock)
- Error is properly propagated to caller

The spec model omits timeout/retry mechanisms entirely, causing the temporal property violation. See `confirmed-bugs.md` for detailed audit findings.

**Action**: This is a spec fidelity issue, not an implementation bug. No code changes required to libspdm. Spec should be enhanced with timeout/retry modeling.
