# Bug Report — libspdm SPDM 1.3 Event Subscription

**Target**: libspdm (DMTF SPDM 1.3 event subscription)
**Method**: TLA+ model checking (BFS exhaustive) + counterexample analysis
**Spec**: MC.tla / base.tla
**Date**: 2026-06-08

---

## Summary

Three real implementation bugs (Case C) confirmed by TLC counterexamples and cross-referenced
against the libspdm source code. All three were found in their respective `MC_hunt_familyN.cfg`
runs after the base convergence check passed cleanly.

| Bug ID | Family | Invariant | Severity | File |
|--------|--------|-----------|----------|------|
| BUG-1 | 1 | MCRequestInFlightGuard | HIGH | libspdm_rsp_event_ack.c |
| BUG-2 | 2 | MCEventAllOverriddenToNone | HIGH | libspdm_rsp_subscribe_event_types_ack.c |
| BUG-3 | 3 | MCSubscribeNoneBlocksEvents | MEDIUM | libspdm_rsp_encap_response.c |

One invariant was found to be overly strong (Case A) and was removed from the hunt config:
- `MCNoDualInFlightConflict` — see "Spec Notes" section.

---

## BUG-1: Response-state check order in SEND_EVENT handler

**Severity**: HIGH
**Category**: Protocol state machine violation
**Classification**: Case C — Real Implementation Bug
**Violated invariant**: `MCRequestInFlightGuard`
**Confirmation status**: REPRODUCED (Phase 4, Level 0)

### Root Cause

`libspdm_get_response_event_ack()` in `libspdm_rsp_event_ack.c` checks the request
version at line 47 **before** checking `response_state` at line 68. When
`response_state == LIBSPDM_RESPONSE_STATE_PROCESSING_ENCAP`, the handler should return
`SPDM_ERROR_CODE_REQUEST_IN_FLIGHT` (via `libspdm_responder_handle_response_state()`),
but a version-mismatched request short-circuits at line 56 and returns
`SPDM_ERROR_CODE_VERSION_MISMATCH` instead.

Every other SPDM 1.3 event handler (e.g. `libspdm_rsp_subscribe_event_types_ack.c:38-43`)
checks `response_state` **first**.

### Counterexample (5 actions)

```
State 1  Initial predicate
         session_state=NOT_STARTED, response_state=NORMAL, subscription_state=SUB_NONE

State 2  MCHandleKeyExchangeNoEventAll
         session_state=HANDSHAKE

State 3  MCHandleFinish
         session_state=ESTABLISHED

State 4  MCHandleSubscribeList
         subscription_state=SUB_LIST, subscribe_types_sent=TRUE

State 5  MCInitEncapSendEvent
         response_state=PROCESSING_ENCAP, encap_event_in_flight=TRUE

State 6  MCHandleSendEventVersionMismatch   ← BUG
         direct_send_active=TRUE
         last_send_event_response=RESP_VERSION_MISMATCH
         last_mismatch_response_state=PROCESSING_ENCAP   ← handler called during encap!
         response_state=PROCESSING_ENCAP (unchanged)
         ⟹ MCRequestInFlightGuard VIOLATED
```

**Key**: `last_mismatch_response_state=PROCESSING_ENCAP` proves the handler was invoked
while the encap flow was active. The correct response at that point is `REQUEST_IN_FLIGHT`.

### Affected Code

**File**: `library/spdm_responder_lib/libspdm_rsp_event_ack.c`

```c
// Line 47: version check fires FIRST
if (spdm_request->header.spdm_version != libspdm_get_connection_version(spdm_context)) {
    // Line 56: returns VERSION_MISMATCH — response_state never examined
    return libspdm_generate_error_response(spdm_context,
                                           SPDM_ERROR_CODE_VERSION_MISMATCH, 0,
                                           response_size, response);
}
// Line 68: response_state check (only reached when version MATCHES)
if (spdm_context->response_state != LIBSPDM_RESPONSE_STATE_NORMAL) {
    return libspdm_responder_handle_response_state(...);
}
```

The TLA trace instrumentation already in the file (lines 48-55) even logs
`response_state` at the version-mismatch exit — confirming the developers were
aware of the ordering question.

### Fix

Move the `response_state` check to **before** the version check:

```c
// Check response_state FIRST
if (spdm_context->response_state != LIBSPDM_RESPONSE_STATE_NORMAL) {
    return libspdm_responder_handle_response_state(...);
}
// THEN check version
if (spdm_request->header.spdm_version != libspdm_get_connection_version(spdm_context)) {
    return libspdm_generate_error_response(..., SPDM_ERROR_CODE_VERSION_MISMATCH, ...);
}
```

### Spec Note

The original `MCNoDualInFlightConflict` invariant was also flagging a false positive on
this family (see Spec Notes below). `MCRequestInFlightGuard` was refined to use
`last_mismatch_response_state` to correctly distinguish the bug scenario from a valid
"version mismatch then encap starts" sequence.

---

## BUG-2: SUBSCRIBE_NONE silently overrides EVENT_ALL_POLICY subscription

**Severity**: HIGH
**Category**: Incorrect state override / silent event suppression
**Classification**: Case C — Real Implementation Bug
**Violated invariant**: `MCEventAllOverriddenToNone`
**Confirmation status**: REPRODUCED (Phase 4, Level 0)

### Root Cause

When `KEY_EXCHANGE` includes `SESSION_POLICY_EVENT_ALL_POLICY`, libspdm calls
`libspdm_event_subscribe(... LIBSPDM_EVENT_SUBSCRIBE_ALL ...)` to establish an
all-events subscription for the session (`libspdm_rsp_key_exchange.c:798-810`).

A subsequent `SUBSCRIBE_EVENT_TYPES` request with `subscribe_event_group_count == 0`
causes `libspdm_get_response_subscribe_event_types_ack()` to call
`libspdm_event_subscribe(... LIBSPDM_EVENT_SUBSCRIBE_NONE ...)` unconditionally at
line 134 — with no guard checking whether an `EVENT_ALL_POLICY` subscription is active.

The integrator's `libspdm_event_subscribe()` (sample: `spdm_device_secret_lib_sample/event.c:82`)
clears `g_event_all_subscribe = false` without checking `event_all_policy`.

### Counterexample (3 actions)

```
State 1  Initial predicate
         subscription_state=SUB_NONE, event_all_policy=FALSE

State 2  MCHandleKeyExchangeWithEventAll
         session_state=HANDSHAKE
         subscription_state=SUB_ALL       ← EVENT_ALL_POLICY subscription established
         event_all_policy=TRUE

State 3  MCHandleFinish
         session_state=ESTABLISHED

State 4  MCHandleSubscribeNone            ← BUG
         subscription_state=SUB_NONE      ← overrides SUB_ALL without guard!
         event_all_policy=TRUE            ← policy still says ALL but subscription is NONE
         subscribe_types_sent=TRUE
         ⟹ MCEventAllOverriddenToNone VIOLATED
```

### Affected Code

**File**: `library/spdm_responder_lib/libspdm_rsp_subscribe_event_types_ack.c`

```c
// Line 124: no guard for event_all_policy
if (subscribe_event_group_count == 0) {
    subscribe_type = LIBSPDM_EVENT_SUBSCRIBE_NONE;  // line 125
    ...
}
// Line 134: calls event_subscribe with NONE — overrides EVENT_ALL_POLICY
if (!libspdm_event_subscribe(spdm_context, ..., subscribe_type, ...)) { ... }
```

**Secondary**: `os_stub/spdm_device_secret_lib_sample/event.c:82` — the integrator's
`libspdm_event_subscribe(SUBSCRIBE_NONE)` path clears the subscription unconditionally.

### Impact

Sessions negotiated with `EVENT_ALL_POLICY` become silently unsubscribed if the
requester sends a `SUBSCRIBE_EVENT_TYPES` with count=0. No error is returned;
the requester believes they are still subscribed. Subsequent events are silently dropped.

### Fix

In `libspdm_get_response_subscribe_event_types_ack()`, add a guard before processing
`SUBSCRIBE_NONE`:

```c
if (subscribe_event_group_count == 0) {
    // Refuse to downgrade an EVENT_ALL_POLICY session to NONE
    if (session_info->event_all_policy) {
        return libspdm_generate_error_response(spdm_context,
                                               SPDM_ERROR_CODE_INVALID_REQUEST, 0,
                                               response_size, response);
    }
    subscribe_type = LIBSPDM_EVENT_SUBSCRIBE_NONE;
}
```

---

## BUG-3: Encap SEND_EVENT initiated without subscription check

**Severity**: MEDIUM
**Category**: Event delivery to unsubscribed recipient
**Classification**: Case C — Real Implementation Bug
**Violated invariant**: `MCSubscribeNoneBlocksEvents`
**Confirmation status**: REPRODUCED (Phase 4, Level 0)

### Root Cause

`libspdm_init_send_event_encap_state()` (`libspdm_rsp_encap_response.c:249-272`) sets
`response_state = LIBSPDM_RESPONSE_STATE_PROCESSING_ENCAP` and enqueues the encap
`SEND_EVENT` flow without consulting the session's `subscription_state`. If the requester
has `SUBSCRIBE_NONE`, the encap flow proceeds regardless.

Similarly, `libspdm_get_encap_request_send_event()` (`libspdm_rsp_encap_send_event.c`)
calls `libspdm_generate_event_list()` without checking subscription_state.

### Counterexample (3 actions)

```
State 1  Initial predicate
         subscription_state=SUB_NONE, encap_event_in_flight=FALSE

State 2  MCHandleKeyExchangeNoEventAll
         session_state=HANDSHAKE
         subscription_state=SUB_NONE   ← no subscription

State 3  MCHandleFinish
         session_state=ESTABLISHED

State 4  MCInitEncapSendEvent           ← BUG
         response_state=PROCESSING_ENCAP
         encap_event_in_flight=TRUE
         subscription_state=SUB_NONE   ← unchanged; subscription was never checked
         ⟹ MCSubscribeNoneBlocksEvents VIOLATED
```

### Affected Code

**File**: `library/spdm_responder_lib/libspdm_rsp_encap_response.c`

```c
// Line 249: libspdm_init_send_event_encap_state
void libspdm_init_send_event_encap_state(void *spdm_context, uint32_t session_id)
{
    // ... context setup ...
    context->response_state = LIBSPDM_RESPONSE_STATE_PROCESSING_ENCAP;  // line 262
    // No subscription_state check anywhere in this function
}
```

### Impact

The integrator can trigger an encap SEND_EVENT for a requester that never subscribed
or has since unsubscribed. The requester receives an event it did not request. Per
SPDM 1.3, the Responder MUST check the subscription state before initiating event
delivery.

### Fix

In `libspdm_init_send_event_encap_state()`, add a subscription guard:

```c
void libspdm_init_send_event_encap_state(void *spdm_context, uint32_t session_id)
{
    libspdm_context_t *context = spdm_context;
    libspdm_session_info_t *session_info;

    session_info = libspdm_get_session_info_via_session_id(context, session_id);
    if (session_info == NULL) { return; }

    // Guard: only initiate encap if session has active subscription
    if (session_info->subscription_state == LIBSPDM_EVENT_SUBSCRIBE_NONE) {
        return;  // or signal error to caller
    }

    // ... existing setup ...
    context->response_state = LIBSPDM_RESPONSE_STATE_PROCESSING_ENCAP;
}
```

---

## Spec Notes

### MCNoDualInFlightConflict — Case A (Invariant Too Strong)

**Original invariant**:
```tla
MCNoDualInFlightConflict ==
    (direct_send_active = TRUE /\ encap_event_in_flight = TRUE)
        => last_send_event_response = RESP_REQUEST_IN_FLIGHT
```

**Problem**: The invariant assumes that whenever both a direct SEND_EVENT and an encap
flow are active simultaneously, the direct must have been blocked with REQUEST_IN_FLIGHT.
This ignores a valid ordering:

1. Requester's SEND_EVENT is handled correctly (response_state=NORMAL → RESP_OK,
   direct_send_active=TRUE)
2. Integrator then initiates encap flow (response_state → PROCESSING_ENCAP,
   encap_event_in_flight=TRUE)

In this valid path: direct_send_active=TRUE, encap_event_in_flight=TRUE,
last_send_event_response=RESP_OK — which violates the invariant even though no bug occurred.

**Resolution**: Removed from `MC_hunt_family1.cfg`. The actual Family 1 bug is
correctly captured by `MCRequestInFlightGuard` (which was refined to use
`last_mismatch_response_state` for precise historical state tracking).

### Spec Change: Added `last_mismatch_response_state`

To correctly detect the Family 1 bug without false positives, `base.tla` was extended
with a `last_mismatch_response_state` variable that records `response_state` at the
time `HandleSendEventVersionMismatch` fires. This allows `MCRequestInFlightGuard` to
distinguish:

- **Bug path**: Encap active → version-mismatch handler fires →
  `last_mismatch_response_state = PROCESSING_ENCAP` (VIOLATION)
- **Valid path**: Version-mismatch handler fires (NORMAL) → encap starts later →
  `last_mismatch_response_state = NORMAL` (OK)

---

## TLC Run Summary

| Config | Output | States | Violations | Duration |
|--------|--------|--------|------------|----------|
| MC.cfg (base, v1) | output/MC_base.out | 87 distinct | None | 6s |
| MC.cfg (base, v2 after spec fix) | output/MC_base_v2.out | 159 distinct | None | 5s |
| MC_hunt_family1.cfg (v3, fixed) | output/MC_hunt_family1_v3.out | 63 distinct | MCRequestInFlightGuard | 5s |
| MC_hunt_family2.cfg | output/MC_hunt_family2.out | 21 distinct | MCEventAllOverriddenToNone | 5s |
| MC_hunt_family3.cfg | output/MC_hunt_family3.out | 59 distinct | MCSubscribeNoneBlocksEvents | 5s |

All runs used BFS exhaustive model checking with 90 workers, 50G heap, 200G off-heap,
30-minute timeout. All state spaces exhausted well within the time budget.
