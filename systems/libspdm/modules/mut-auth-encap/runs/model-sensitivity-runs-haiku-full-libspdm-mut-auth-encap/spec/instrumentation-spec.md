# Instrumentation Specification: libspdm-mut-auth-encap

Mapping between TLA+ spec actions and source code instrumentation points.
Harness generation uses this document to determine where to insert trace event
emission and what fields to capture.

---

## Section 1: Trace Event Schema

### Event Envelope

All trace events follow this structure (NDJSON format, one event per line):

```json
{
  "event": "<event_name>",
  "node": "<responder|requester>",
  "timestamp": <rdtsc|wall_clock>,
  "state": { <state_fields> },
  "message": { <message_fields> }
}
```

### State Fields (Captured at Every Event)

| Spec Variable | Source Field | Type | Notes |
|---|---|---|---|
| `requester_state` | `spdm_context->connection_info.connection_state` (requester view) | enum | UNINITIALIZED, CHALLENGE_SENT, etc. |
| `responder_state` | `spdm_context->connection_info.connection_state` (responder view) | enum | Same as requester, but from responder perspective |
| `protocol_version` | `spdm_context->connection_info.version` | uint | 11, 12, or 13 |
| `signature_verified` | `result` from signature verification functions | bool | TRUE if last verify succeeded |
| `message_transcript_len` | `Len(context->transcript)` | uint | Current message buffer length |
| `transcript_complete` | Derived: all expected messages appended | bool | Computed at action boundary |
| `opaque_data_size` | `opaque_data_size` variable at line 169-173 | uint | Calculated but may underflow |
| `response_buffer_size` | `*response_size` parameter | uint | Total allocated response buffer |
| `hash_size` | Result of `libspdm_get_hash_size()` | uint | 32, 48, or 64 depending on algorithm |
| `signature_size` | Result of `libspdm_get_req_asym_signature_size()` | uint | Depends on algorithm |
| `buffer_reset_status` | Return value of `libspdm_reset_message_buffer_via_request_code()` | enum | success or failure |
| `req_context_match` | Result of `libspdm_consttime_is_mem_equal()` | bool | For version 1.3+ validation |

### Message Fields (Captured Per-Event)

| Event Type | Message Field | Source | Spec Mapping |
|---|---|---|---|
| `responder_get_encap_request_challenge` | `version` | `spdm_request->header.spdm_version` | `protocol_version` |
| `responder_get_encap_request_challenge` | `nonce` | `spdm_request->nonce` | For tracing crypto inputs |
| `requester_get_encap_response_challenge_auth` | `response_buffer_size` | `*response_size` parameter | `response_buffer_size` |
| `requester_get_encap_response_challenge_auth` | `opaque_data_offset` | Pointer arithmetic at line 172 | `opaque_data_offset` |
| `requester_get_encap_response_challenge_auth` | `opaque_data_size` | Line 169-173 | `opaque_data_size` |
| `process_encap_response_challenge_auth` | `response_version` | `spdm_response->header.spdm_version` | Version consistency check |
| `process_encap_response_challenge_auth` | `opaque_length` | `*(uint16_t *)ptr` at line 199 | Parsed opaque data size |
| `process_encap_response_challenge_auth` | `req_context_echo` | Ptr+offset at line 238 | For version 1.3+ echo validation |
| `transition_to_authenticated` | `new_state` | `LIBSPDM_CONNECTION_STATE_AUTHENTICATED` | `STATE_AUTHENTICATED` |

---

## Section 2: Action-to-Code Mapping

### Action: ResponderGetEncapRequestChallenge

**Spec Action Name**: `ResponderGetEncapRequestChallenge`

**Code Location**:
- Primary: `libspdm/library/spdm_responder_lib/libspdm_rsp_encap_challenge.c:12-78`
- Buffer reset: Line 62-63
- Request generation: Line 44-48
- Nonce generation: Line 48-52
- Context setup (v1.3+): Line 54-60
- Transcript append: Line 67-70

**Trigger Point**: After `libspdm_get_encap_request_challenge()` completes successfully

**Trace Event Name**: `responder_get_encap_request_challenge`

**Fields to Capture**:
- State: `protocol_version`, `responder_state` (before and after)
- Message: `version` (from request header)
- State: `buffer_reset_status` (outcome of line 62-63)

**Notes**:
- The encapsulated challenge request is generated entirely on the responder side
- Version 1.3+ includes REQ_CONTEXT field from responder's stored context
- Capture state before action (UNINITIALIZED) and after (CHALLENGE_SENT)

---

### Action: RequesterGetEncapResponseChallengeAuth

**Spec Action Name**: `RequesterGetEncapResponseChallengeAuth`

**Code Location**:
- Primary: `libspdm/library/spdm_requester_lib/libspdm_req_encap_challenge_auth.c:12-237`
- Buffer reset: Line 97-98
- Request parsing and version check: Line 44-71
- Hash/signature size determination: Line 100-108
- Buffer assertion: Line 114-116
- Opaque data size calculation: Line 169-173 (**CRITICAL: potential underflow**)
- Opaque data generation: Line 175-186
- Request context echo (v1.3+): Line 195-198
- Request append to transcript: Line 214-219
- Response append to transcript: Line 221-228
- Signature generation: Line 229-234

**Trigger Point**: After the function returns (success or error)

**Trace Event Name**: `requester_get_encap_response_challenge_auth`

**Fields to Capture**:
- State: `requester_state` (before = UNINITIALIZED, after = CHALLENGE_AUTH_RESPONSE_RECEIVED)
- State: `protocol_version` (from request)
- State: `hash_size`, `signature_size` (from algorithm negotiation)
- State: `response_buffer_size` (input parameter `*response_size`)
- Message: `opaque_data_offset` (calculated pointer, line 172)
- Message: `opaque_data_size` (calculated, line 169-173, **may underflow**)
- State: `buffer_reset_status` (outcome of line 97-98)
- State: `transcript_complete` (TRUE after successful appends)

**Notes**:
- **CRITICAL**: Line 169-173 calculates opaque_data_size as subtraction. If this underflows
  (response_size too small), the value wraps. Capture the raw calculation result.
- Version-dependent field handling: For v1.3+, REQ_CONTEXT is included (lines 64-71, 195-198)
- Two message appends (lines 214-219, 221-228) must both succeed for transcript to be complete
- Signature is generated after appends (line 229-234)

---

### Action: ProcessEncapResponseChallengeAuth

**Spec Action Name**: `ProcessEncapResponseChallengeAuth`

**Code Location**:
- Primary: `libspdm/library/spdm_responder_lib/libspdm_rsp_encap_challenge.c:80-268`
- Response header validation: Line 100-112
- Size checks: Line 114-121
- Version-dependent size validation (v1.3+): Line 117-121
- Opaque data length parsing: Line 199-202
- REQ_CONTEXT validation (v1.3+): Line 237-241
- Message append: Line 248-252
- Signature verification: Line 257-261
- State transition to AUTHENTICATED: Line 263

**Trigger Point**: After signature verification completes (line 257-261)

**Trace Event Name**: `process_encap_response_challenge_auth`

**Fields to Capture**:
- State: `responder_state` (before = CHALLENGE_SENT, after = CHALLENGE_AUTH_RESPONSE_RECEIVED)
- Message: `response_version` (from `spdm_response->header.spdm_version`)
- Message: `opaque_length` (parsed from line 199)
- State: `response_buffer_size` (input parameter `encap_response_size`)
- State: `signature_verified` (result of line 257-261, TRUE if verify succeeds)
- State: `req_context_match` (result of line 238-241 for v1.3+, FALSE otherwise)
- State: `transcript_complete` (TRUE after message append at line 248-252)

**Notes**:
- Version consistency: Response version (line 103) must match negotiated version
- REQ_CONTEXT echo validation (line 238-241) only for version 1.3+
- Message append (line 248-252) does NOT include the signature (size = total - signature_size)
- State transition (line 263) immediately follows verification; capture state after this line

---

### Action: TransitionToAuthenticated

**Spec Action Name**: `TransitionToAuthenticated`

**Code Location**:
- Primary: `libspdm/library/spdm_responder_lib/libspdm_rsp_encap_challenge.c:263`
- State transition call: `libspdm_set_connection_state(spdm_context, LIBSPDM_CONNECTION_STATE_AUTHENTICATED)`

**Trigger Point**: Immediately after line 263

**Trace Event Name**: `transition_to_authenticated`

**Fields to Capture**:
- State: `requester_state` (should become AUTHENTICATED)
- State: `responder_state` (should become AUTHENTICATED)
- State: `connection_state` (synthesized: should become AUTHENTICATED)
- State: `signature_verified` (should be TRUE)
- State: `pending_state_transition` (should be FALSE after transition)

**Notes**:
- This is a non-atomic state transition (spec Family 1)
- State is set only after signature verification succeeds
- Capture state transition as a separate event to model the atomicity gap

---

## Section 3: Special Considerations

### 1. Opaque Data Arithmetic (Family 3 - Critical)

**Location**: `libspdm_req_encap_challenge_auth.c:169-173`

The opaque_data_size calculation is the most critical instrumentation point:

```c
opaque_data_size = *response_size - (sizeof(...) + hash_size + SPDM_NONCE_SIZE + ... + signature_size);
```

**Instrumentation requirement**:
- Capture the result of this calculation **before** any bounds checking
- If underflow occurs (result > response_size in unsigned comparison), capture the wrapped value
- This is necessary to detect Buffer Bounds violations (Family 3)

**Example capture**:
```
opaque_data_size = <unsigned_subtraction_result>
buffer_underflow_detected = (opaque_data_size > response_size)
```

### 2. Version-Dependent Field Sizes (Family 2)

**Locations**:
- Request parsing: Lines 64-71 of req_encap_challenge_auth.c
- Response size validation: Lines 206-227 of rsp_encap_challenge.c
- REQ_CONTEXT echo: Lines 237-241 of rsp_encap_challenge.c

**Instrumentation requirement**:
- Capture protocol version at the start of each action
- For v1.3+, capture whether REQ_CONTEXT field is included
- Capture all size calculations that depend on version

### 3. Message Transcript Assembly (Family 5)

**Locations**:
- Request append: `libspdm_req_encap_challenge_auth.c:214-219`
- Response body append: `libspdm_req_encap_challenge_auth.c:221-228`
- Response body append (responder side): `libspdm_rsp_encap_challenge.c:248-252`

**Instrumentation requirement**:
- Capture the return value of each `libspdm_append_message_mut_c()` call
- If any append fails, set `transcript_complete = FALSE`
- Signature verification should only proceed if all appends succeeded

### 4. Signature Verification (Family 1)

**Locations**:
- Signature generation: `libspdm_req_encap_challenge_auth.c:229-234`
- Signature verification: `libspdm_rsp_encap_challenge.c:257-261`

**Instrumentation requirement**:
- Capture the return value of signature operations
- Capture state transition outcome (line 263)
- State should only transition if signature verification returned success

### 5. Buffer Reset Failures (Family 4)

**Locations**:
- Responder: `libspdm_rsp_encap_challenge.c:62-63`
- Requester: `libspdm_req_encap_challenge_auth.c:97-98`

**Instrumentation requirement**:
- Capture return value of `libspdm_reset_message_buffer_via_request_code()`
- If reset fails, message buffer may retain stale data
- Capture `message_transcript_len` before and after reset

### 6. Opaque Data Generation Failures (Family 6)

**Location**: `libspdm_req_encap_challenge_auth.c:175-186`

**Instrumentation requirement**:
- Capture return value of `libspdm_encap_challenge_opaque_data()` callback
- Capture state before and after this call
- If callback fails, response is partially populated

---

## Section 4: Trace Event Examples

### Example 1: Successful Mutual Authentication Flow

```ndjson
{"event": "responder_get_encap_request_challenge", "node": "responder", "timestamp": 1000, "state": {"protocol_version": 13, "responder_state": "challenge_sent"}, "message": {"version": 13}}
{"event": "requester_get_encap_response_challenge_auth", "node": "requester", "timestamp": 2000, "state": {"requester_state": "challenge_auth_response_received", "transcript_complete": true, "opaque_data_size": 100}, "message": {"response_buffer_size": 512}}
{"event": "process_encap_response_challenge_auth", "node": "responder", "timestamp": 3000, "state": {"signature_verified": true, "req_context_match": true, "responder_state": "challenge_auth_response_received"}, "message": {"opaque_length": 100}}
{"event": "transition_to_authenticated", "node": "responder", "timestamp": 4000, "state": {"connection_state": "authenticated", "signature_verified": true}}
```

### Example 2: Opaque Data Size Underflow (Family 3 Bug)

```ndjson
{"event": "requester_get_encap_response_challenge_auth", "node": "requester", "timestamp": 2000, "state": {"requester_state": "challenge_auth_response_received", "response_buffer_size": 100, "opaque_data_size": 18446744073709551516}, "message": {"underflow_detected": true}}
```

The large opaque_data_size value is the result of unsigned underflow (100 - 596 wraps to 18446744073709551516).

---

## Section 5: Bootstrap and Initial State

### TraceInit vs Spec Init

The trace replay spec's `TraceInit` may differ from the base spec's `Init` because the implementation may have pre-negotiated state:

| Variable | Spec Init | Trace Init | Reason |
|---|---|---|---|
| `protocol_version` | `Version_11` (lowest) | Captured from trace | Implementation may have negotiated higher version already |
| `requester_state` | `STATE_UNINITIALIZED` | Captured from trace | Trace starts mid-execution |
| `message_transcript` | `<<>>` | Empty or partially populated | Trace may start after prior messages |

**Action**: Capture initial state from the first trace event and initialize accordingly.

---

## Section 6: Temporal Constraints

### Real-Time Ordering

The trace is ordered by wall-clock time (or per-thread rdtsc). TLC explores all interleavings
consistent with the captured timestamps and dependencies.

### Cross-Node Dependencies

- Requester sends challenge request
- Responder receives request and generates response
- Requester receives response and verifies signature
- Responder receives authenticated state change

These dependencies are implicit in message content (e.g., response references request context).

---

## Section 7: Validation Checkpoints

Trace validation stops if any of these invariants are violated:

1. **Type Consistency**: State variables have expected types
2. **Authenticated Implies Verified**: `connection_state = AUTHENTICATED` → `signature_verified = TRUE`
3. **Buffer Bounds**: `opaque_data_offset + opaque_data_size <= response_buffer_size`
4. **Version Consistency**: All messages use negotiated version
5. **Transcript Before Signature**: Signature verification only after message append succeeds

---

