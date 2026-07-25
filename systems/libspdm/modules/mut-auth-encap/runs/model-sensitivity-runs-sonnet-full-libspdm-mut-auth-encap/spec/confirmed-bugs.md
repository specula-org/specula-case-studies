# Confirmed Bugs — libspdm Encapsulated Mutual Authentication

**Target**: libspdm — encapsulated mutual authentication flow
**Phase**: 4 — Bug Confirmation
**Date**: 2026-06-08
**Input**: `spec/bug-report.md` (two MC-found invariant violations)

---

## BUG-1: Partial State Reset After Non-NOT_READY Encap Error

**Source**: MC — `MC_hunt_family4.cfg` produced an actual counterexample trace; `NoPartialAuthState` violated.

**Status**: REPRODUCED

**Severity**: Medium

**Location**: `library/spdm_responder_lib/libspdm_rsp_encap_response.c:509-515` (primary); same defect at `:388-395`

**Description**: When `libspdm_process_encapsulated_response` returns a non-`NOT_READY` error, both call sites inside `libspdm_get_response_encapsulated_request` (:388-395) and `libspdm_get_response_encapsulated_response_ack` (:509-515) reset `response_state` to `LIBSPDM_RESPONSE_STATE_NORMAL` but do **not** zero `encap_context.current_request_op_code`. This leaves the context in a half-reset state where `response_state=NORMAL` (signaling the encap flow is complete) while `current_request_op_code != 0` (indicating an op is still active). The `NOT_READY_PEER` path at `:160-166` correctly performs both resets, demonstrating the missing step was a local omission, not a design choice.

**Trigger scenario** (matches MC counterexample, `VAR_BASIC_PK` variant):
1. `libspdm_init_basic_mut_auth_encap_state(ctx)` — sets `cur_op=0`, `response_state=RS_PROCESSING_ENCAP`
2. `GET_ENCAPSULATED_REQUEST` — `libspdm_process_encapsulated_response(ctx, 0, NULL, ...)` advances `cur_op` to `SPDM_CHALLENGE` (0x83); state stays `RS_PROCESSING_ENCAP`
3. `DELIVER_ENCAPSULATED_RESPONSE` with wrong code `SPDM_DIGESTS` (0x01) — `libspdm_process_encap_response_challenge_auth` sees `response_code != SPDM_CHALLENGE_AUTH`, returns `LIBSPDM_STATUS_INVALID_MSG_FIELD`; error path at `:509-515` sets `response_state=NORMAL` but leaves `cur_op=0x83`

**Developer intent investigation**: No git history is available in the artifact snapshot. The `NOT_READY_PEER` branch (`:160-166`) performs the correct double reset, which establishes the intent: `current_request_op_code` should be cleared on every exit from the encap flow. The general-error paths appear to have been written without reference to the `NOT_READY` branch, or the zeroing was inadvertently omitted when the two error sites diverged from a common ancestor. No developer commentary was found; the inference rests on the symmetry argument with the correctly-handled `NOT_READY` path.

**Reproduction test**: `repro/test_bug1_partial_state_reset.c` — Level 2 (direct API call sequence, state injection); exercises the DELIVER path (:509-515) directly via `libspdm_get_response_encapsulated_response_ack`.

**Reproduction result**: PASS — BUG CONFIRMED (exit code 1)

```
=== BUG-1 Reproduction: partial state reset after encap error ===
File: libspdm_rsp_encap_response.c:509-515
Invariant: NoPartialAuthState (response_state=NORMAL => cur_op=0)

After init:
  current_request_op_code = 0x00 (expected 0x00)
  response_state          = 4  (expected PROCESSING_ENCAP=4)
Encap RequesterNonce - c6 29 93 be 77 94 7d e9 25 0d ad a1 36 3c e1 2a 39 f1 5a e6 11 61 33 59 c1 f6 6a 37 72 9b 18 17 

After GET_ENCAP_REQ:
  current_request_op_code = 0x83 (expected SPDM_CHALLENGE=0x83)
  response_state          = 4  (expected PROCESSING_ENCAP=4)

After DELIVER (wrong code, triggers error path at :509-515):
  return status           = 0x0  (LIBSPDM_STATUS_SUCCESS expected)
  current_request_op_code = 0x83  (expected 0x00 if correct; BUG if non-zero)
  response_state          = 0  (expected NORMAL=0)

[RESULT] BUG CONFIRMED
  NoPartialAuthState VIOLATED:
  response_state = NORMAL (0)
  current_request_op_code = 0x83 (expected 0x00)
  Root cause: libspdm_rsp_encap_response.c:509-515 resets
  response_state but omits:
    spdm_context->encap_context.current_request_op_code = 0x00;
  Fix: add that line at :510 and :389.
```

**Recommendation**: Add `spdm_context->encap_context.current_request_op_code = 0x00;` at both error-return sites:
- `:389` (GET_ENCAPSULATED_REQUEST path)
- `:510` (DELIVER_ENCAPSULATED_RESPONSE path)

```c
if (LIBSPDM_STATUS_IS_ERROR(status)) {
    spdm_context->response_state = LIBSPDM_RESPONSE_STATE_NORMAL;
    spdm_context->encap_context.current_request_op_code = 0x00;  // ADD THIS
    return libspdm_generate_error_response(...);
}
```

---

## BUG-2: Phantom Authentication State After Encap Flow Failure

**Source**: MC — `MC_hunt_family2.cfg` produced an actual counterexample trace; `NoPhantomAuth` violated.

**Status**: REPRODUCED

**Severity**: High (security-relevant)

**Location**: `library/spdm_requester_lib/libspdm_req_challenge.c:383,397-399`

**Description**: In `libspdm_send_receive_challenge`, `connection_state` is set to `LIBSPDM_CONNECTION_STATE_AUTHENTICATED` (line 383) before `libspdm_encapsulated_request` is called (line 394). When the encap flow subsequently fails, the error handler at lines 397-399 returns the error without rolling back `connection_state`. The caller receives a non-success status indicating failure, but the context still reports `LIBSPDM_CONNECTION_STATE_AUTHENTICATED`. Any subsequent check of `connection_state` (or `libspdm_get_connection_state()`) will observe a fully-authenticated connection that never completed mutual authentication.

**Trigger scenario** (matches MC counterexample):
1. `CHALLENGE_AUTH` received with `SPDM_CHALLENGE_AUTH_RESPONSE_ATTRIBUTE_BASIC_MUT_AUTH_REQ` flag set
2. `libspdm_send_receive_challenge` validates the response and sets `connection_state = LIBSPDM_CONNECTION_STATE_AUTHENTICATED` at line 383
3. `libspdm_encapsulated_request(spdm_context, NULL, 0, NULL)` at line 394 returns an error (any: transport failure, buffer exhaustion, protocol error)
4. Error handler at lines 397-399 calls `libspdm_reset_message_c` and returns the error without resetting `connection_state`
5. Caller sees error return, but `connection_info.connection_state == LIBSPDM_CONNECTION_STATE_AUTHENTICATED` (=6)

**Developer intent investigation**: The comment at line 381, "At this point the Requester has successfully authenticated the Responder, even if the Responder intends to authenticate the Requester," confirms the developer intended `AUTHENTICATED` to reflect one-directional completion of the Responder's authentication. The missing rollback is an ordering oversight — `connection_state` is set before confirming that the full mutual-auth exchange (including the encap sub-flow) has completed successfully. A structurally identical bug was fixed in the `KEY_EXCHANGE` path at commit b1942fee / Issue #3059, establishing a precedent for this class of error. No developer commentary addresses the `CHALLENGE` path equivalent.

**Reproduction test**: `repro/test_bug2_phantom_auth_state.c` — Level 2 (state injection); pre-sets `connection_state=AUTHENTICATED`, registers a `acquire_sender_buffer` callback that returns `LIBSPDM_STATUS_BUFFER_FULL` to trigger immediate failure from `libspdm_encapsulated_request`, then checks that `connection_state` is not rolled back.

**Reproduction result**: PASS — BUG CONFIRMED (exit code 1)

```
=== BUG-2 Reproduction: phantom authentication state ===
File: libspdm_req_challenge.c:383,394-399
Invariant: NoPhantomAuth (connection_state NOT rolled back on encap failure)
Method: Level 2 state injection

State injection: setting connection_state = LIBSPDM_CONNECTION_STATE_AUTHENTICATED
(Simulates line 383 of libspdm_req_challenge.c having fired)

Calling libspdm_encapsulated_request() with failing buffer callback...
  libspdm_encapsulated_request returned: 0x8001000c (error expected)

Post-error state:
  connection_state = 6  (AUTHENTICATED=6, expect NO rollback = BUG)

[RESULT] BUG CONFIRMED
  NoPhantomAuth VIOLATED:
  connection_state = LIBSPDM_CONNECTION_STATE_AUTHENTICATED (6)
  even though libspdm_encapsulated_request() returned an error (0x8001000c).
  Root cause: libspdm_req_challenge.c:397-399 returns the error
  without resetting connection_state back to its pre-line-383 value.
  Fix: before 'return status' at line 399, add:
    spdm_context->connection_info.connection_state =
        LIBSPDM_CONNECTION_STATE_NEGOTIATED; // or prior state
  Alternatively, move line 383 to AFTER the success check for
  libspdm_encapsulated_request (i.e., after line 401).
```

**Recommendation** (two equivalent options):

*Option A* — roll back on error (minimal diff):
```c
if (LIBSPDM_STATUS_IS_ERROR(status)) {
    libspdm_reset_message_c(spdm_context);
    spdm_context->connection_info.connection_state =
        LIBSPDM_CONNECTION_STATE_NEGOTIATED;  // ADD: roll back phantom state
    return status;
}
```

*Option B* — reorder the assignment (preferred for clarity):
Move line 383 (`connection_state = AUTHENTICATED`) to after the `libspdm_encapsulated_request` success check (after line 401), so the state is only set once mutual auth is confirmed complete.

---

## Summary

| Bug | Source | Status | Severity | Location | Test |
|-----|--------|--------|----------|----------|------|
| BUG-1 | MC (`NoPartialAuthState`) | REPRODUCED | Medium | `libspdm_rsp_encap_response.c:509-515` | `repro/test_bug1_partial_state_reset.c` |
| BUG-2 | MC (`NoPhantomAuth`) | REPRODUCED | High | `libspdm_req_challenge.c:383,397-399` | `repro/test_bug2_phantom_auth_state.c` |
