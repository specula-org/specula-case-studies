# Instrumentation Spec: SPDM KEY_EXCHANGE / FINISH Protocol

## Section 1: Trace Event Schema

### Event Envelope

Every trace event is a JSON object with the following fields:

```json
{
  "event": "<event_name>",
  "node": "<requester|responder>",
  "session_id": <int>,
  "timestamp": <int>,
  "state_snapshot": { ... },
  "message_fields": { ... }
}
```

### State Fields (Captured at Every Event)

These fields represent the implementation state and are captured at each instrumentation point. Map each to a TLA+ variable:

| Implementation Field | TLA+ Variable | Notes |
|---|---|---|
| `requester.state` | `requesterState.state` | State machine: "IDLE", "KEX_SENT", "KEX_RECEIVED", "FINISH_SENT", "HANDSHAKING" |
| `responder.state` | `responderState.state` | State machine: "IDLE", "KEX_SENT", "KEX_RECEIVED", "FINISH_RECEIVED", "HANDSHAKING" |
| `session.session_type` | `sessionType[session_id]` | "DHE", "PSK", "PSK_DHE" |
| `session.state` | `sessions[session_id].state` | State machine: "INIT", "KEX_SENT", "KEX_RECEIVED", "FINISH_SENT", "FINISH_RECEIVED", "HANDSHAKING" |
| `transcript_hash_kex` | `transcriptHashKEX[session_id]` | Hex string of transcript hash after KEY_EXCHANGE |
| `transcript_hash_finish` | `transcriptHashFINISH[session_id]` | Hex string of transcript hash after FINISH |
| `dhe_keys_agreed` | `sessions[session_id].dheKeysAgreed` | Boolean flag |
| `hmac_verified` | `sessions[session_id].hmacVerified` | Boolean flag |
| `capabilities_validated` | `capabilitiesValidated` | Boolean flag |
| `session_id_pool_count` | `sessionIDPoolCount` | Integer: count of allocated session IDs |

### Message Fields (Event-Specific)

When message objects are captured, include:

| Field | Type | Notes |
|---|---|---|
| `type` | string | "KEY_EXCHANGE_REQ", "KEY_EXCHANGE_RSP", "FINISH_REQ", "FINISH_RSP", "ERROR" |
| `session_id` | int | Allocated by responder on KEY_EXCHANGE_RSP |
| `nonce` | hex | Used for DH agreement |
| `dhePublicKey` | hex | DH public key |
| `signature` | hex | Signature field (responder only) |
| `signature2` | hex | Second signature field (mutual auth, responder only) |
| `hmac` | hex | HMAC for authentication |
| `heartbeatPeriod` | int | Optional, validated by Family 2 logic |
| `mutAuthRequested` | int | Bitfield, validated by Family 2 logic |
| `slot_id` | int | Certificate slot ID (Family 4 validation) |
| `capabilities` | set | Negotiated flags |

---

## Section 2: Action-to-Code Mapping

### Action: ReqSendKeyExchange

**Spec Action**: `ReqSendKeyExchange`  
**Code Location**: `/artifact/libspdm/library/spdm_requester_lib/libspdm_req_key_exchange.c:300-400`  
**Trigger Point**: After requester initializes and before KEY_EXCHANGE_REQ is sent

**Trace Event Name**: `REQ_SEND_KEY_EXCHANGE`

**Fields to Capture**:
- State snapshot: `requesterState.state` → "KEX_SENT"
- Message: the KEY_EXCHANGE_REQ object
- Capabilities: empty (not yet negotiated)

**Notes**:
- Capture nonce generated for this KEY_EXCHANGE request
- This is the start of the session establishment flow
- No session ID allocated at this point (allocated by responder)

---

### Action: RespReceiveKeyExchange

**Spec Action**: `RespReceiveKeyExchange`  
**Code Location**: `/artifact/libspdm/library/spdm_responder_lib/libspdm_rsp_key_exchange.c:50-350`  
**Trigger Point**: After responder receives KEY_EXCHANGE_REQ, allocates session ID, and before sending KEY_EXCHANGE_RSP

**Trace Event Name**: `RESP_RECEIVE_KEY_EXCHANGE`

**Fields to Capture**:
- State snapshot:
  - `responderState.state` → "KEX_SENT"
  - `responderState.currentSessionID` → allocated session ID
  - `sessionType[session_id]` → "DHE"
  - `sessions[session_id].state` → "INIT" (after allocation)
  - `sessionIDPoolCount` → incremented
- Message: KEY_EXCHANGE_RSP with allocated session_id, nonce, DHE key
- Session type: "DHE"

**Notes**:
- Session ID allocation happens here (Family 3 tracking point)
- Allocate unique IDs from 1..MAX_SESSIONS
- Verify DH key generation completes successfully
- Record the session_id for use in subsequent messages

---

### Action: ReqReceiveKeyExchange

**Spec Action**: `ReqReceiveKeyExchange`  
**Code Location**: `/artifact/libspdm/library/spdm_requester_lib/libspdm_req_key_exchange.c:500-700`  
**Trigger Point**: After requester receives KEY_EXCHANGE_RSP and validates before moving to KEX_RECEIVED state

**Trace Event Name**: `REQ_RECEIVE_KEY_EXCHANGE`

**Fields to Capture**:
- State snapshot:
  - `requesterState.state` → "KEX_RECEIVED"
  - `requesterState.currentSessionID` → session ID from response
  - `sessions[session_id].state` → "KEX_RECEIVED"
  - `sessions[session_id].dheKeysAgreed` → TRUE
  - `transcriptHashKEX[session_id]` → hash of messages so far
  - `capabilitiesValidated` → TRUE
- Message: the received KEY_EXCHANGE_RSP
- Validation results:
  - `heartbeat_period_valid` → boolean (Family 2)
  - `mut_auth_bits_valid` → boolean (Family 2)
  - `slot_id_valid` → boolean (Family 4)

**Notes**:
- This is the key validation point for Family 2 (capability consistency) and Family 4 (slot validation)
- Capture validation results for each check:
  - ValidateHeartbeatPeriod() result
  - ValidateMutAuthRequested() result
  - ValidateSlotID() result (if present)
- Transcript hash is computed here (Family 5 tracking)
- Ensure both fast-path and WITH_RECORDS modes are captured if applicable

---

### Action: ReqSendFinish

**Spec Action**: `ReqSendFinish`  
**Code Location**: `/artifact/libspdm/library/spdm_requester_lib/libspdm_req_finish.c:50-150`  
**Trigger Point**: After requester decides to send FINISH and before FINISH_REQ is transmitted

**Trace Event Name**: `REQ_SEND_FINISH`

**Fields to Capture**:
- State snapshot:
  - `requesterState.state` → "FINISH_SENT"
  - `sessionType[session_id]` → "DHE" or "PSK_DHE" (Family 1 check)
  - `transcriptHashFINISH[session_id]` → hash after FINISH message
- Message: FINISH_REQ with session_id and hmac
- Session type consistency check result (Family 1)

**Notes**:
- Critical point for Family 1 (protocol mixing detection)
- Verify that session_type is consistent with KEY_EXCHANGE type
- Compute transcript hash including FINISH message
- Capture HMAC value sent

---

### Action: RespReceiveFinish

**Spec Action**: `RespReceiveFinish`  
**Code Location**: `/artifact/libspdm/library/spdm_responder_lib/libspdm_rsp_finish_rsp.c:50-300`  
**Trigger Point**: After responder receives FINISH_REQ, validates, and before sending FINISH_RSP

**Trace Event Name**: `RESP_RECEIVE_FINISH`

**Fields to Capture**:
- State snapshot:
  - `responderState.state` → "FINISH_SENT"
  - `sessions[session_id].state` → "FINISH_RECEIVED"
  - `sessions[session_id].hmacVerified` → TRUE
- Message: received FINISH_REQ and generated FINISH_RSP
- Validation results:
  - `opaque_length_valid` → boolean (Family 2, Family 5 dual-path check)

**Notes**:
- Family 2: Validate opaque_length bounds (line 280+)
- Family 5: Both WITH_RECORDS and FAST_PATH modes must produce same HMAC verification result
- Capture opaque_length field if present
- This is the responder's mutual authentication point

---

### Action: ReqReceiveFinish

**Spec Action**: `ReqReceiveFinish`  
**Code Location**: `/artifact/libspdm/library/spdm_requester_lib/libspdm_req_finish.c:85-150`  
**Trigger Point**: After requester receives FINISH_RSP and completes session establishment

**Trace Event Name**: `REQ_RECEIVE_FINISH`

**Fields to Capture**:
- State snapshot:
  - `requesterState.state` → "HANDSHAKING"
  - `sessions[session_id].state` → "HANDSHAKING"
  - `transcriptHashKEX[session_id]` and `transcriptHashFINISH[session_id]` → verify ordering
- Message: received FINISH_RSP
- Transcript consistency check result (Family 1)

**Notes**:
- Final validation point for Family 1 (transcript continuity)
- Verify transcriptHashKEX ⊆ transcriptHashFINISH (prefix property)
- Session is now established and ready for secured messages
- This marks the completion of the KEY_EXCHANGE / FINISH handshake

---

### Action: KeyExchangeErrorCleanup

**Spec Action**: `KeyExchangeErrorCleanup`  
**Code Location**: `/artifact/libspdm/library/spdm_requester_lib/libspdm_req_key_exchange.c:744-878`  
**Trigger Point**: When KEY_EXCHANGE fails at any validation point (opaque_length, signature, HMAC)

**Trace Event Name**: `KEY_EXCHANGE_ERROR`

**Fields to Capture**:
- Error context:
  - `error_reason` → string describing the failure point (e.g., "opaque_length_invalid", "signature_verify_failed", "hmac_mismatch")
  - `session_id_freed` → boolean (Family 3 tracking)
- State snapshot:
  - `sessionIDPoolCount` → should decrement if ID was freed
  - `session_id_pool` → updated set of allocated IDs

**Notes**:
- Family 3: Critical tracking point for session ID cleanup
- Capture which error path was taken (line ranges 744-878)
- If session_id_freed is FALSE, this is evidence of Family 3 Bug #476
- All error paths in this range must include cleanup

---

### Action: FinishErrorCleanup

**Spec Action**: `FinishErrorCleanup`  
**Code Location**: `/artifact/libspdm/library/spdm_requester_lib/libspdm_req_finish.c` (entire function)  
**Trigger Point**: When FINISH fails (HMAC verification, state validation, etc.)

**Trace Event Name**: `FINISH_ERROR`

**Fields to Capture**:
- Error context:
  - `error_reason` → string describing the failure (e.g., "hmac_verify_failed", "invalid_state", "session_not_found")
  - `session_id_freed` → boolean (Family 3 tracking)
- State snapshot:
  - `sessionIDPoolCount` → should decrement if ID was freed
  - `session_id_pool` → updated set of allocated IDs

**Notes**:
- Family 3: This is where FINISH error paths should clean up session IDs
- Note: The modeling brief identifies this function has NO cleanup (Family 3 Bug #476)
- Capture `session_id_freed` as FALSE to confirm the bug when it occurs
- This is one of the most important instrumentation points for Family 3

---

## Section 3: Special Considerations

### Bootstrap State

The trace validation initializes from a recorded initial state that may differ from `Init`:

- If the recorded trace starts mid-session (not from IDLE), TraceInit should load:
  - `requesterState.currentSessionID` and `responderState.currentSessionID` from the trace
  - Existing `sessions` map with pre-allocated session IDs
  - Pre-computed `sessionIDPool` and `sessionIDPoolCount`
  - Pre-loaded `capabilitiesRsp` from prior negotiation

### Concurrent Threads / Event Interleaving

This spec assumes single-threaded operation of requester and responder (no concurrent KEY_EXCHANGE requests from the same requester). If the harness captures concurrent behavior, use Category B (Timebox) trace validation instead.

### Transcript Hash Computation (Family 5)

**Two instrumentation paths**:

1. **WITH_RECORDS mode** (`LIBSPDM_RECORD_TRANSCRIPT_DATA_SUPPORT`):
   - Capture: Full transcript buffer and final hash value
   - Location: After each message is added to transcript

2. **FAST_PATH mode** (without `LIBSPDM_RECORD_TRANSCRIPT_DATA_SUPPORT`):
   - Capture: Incremental hash updates (no full buffer)
   - Location: After each hash_update call

Both paths must be instrumented to verify `PathEquivalence` invariant. If both modes are compiled, emit separate trace events or use conditional capture to record which mode computed the hash.

### Session ID Allocation & Cleanup (Family 3)

For proper Family 3 bug detection, **track session IDs across the entire handshake**:

- **Allocation point**: `libspdm_rsp_key_exchange.c:` where session ID is assigned
- **Cleanup points**: All error returns in `libspdm_req_key_exchange.c:744-878` and `libspdm_req_finish.c`

When an error occurs, check whether the cleanup code path was executed. Emit `KEY_EXCHANGE_ERROR` or `FINISH_ERROR` with:
- `session_id` that was (or should have been) freed
- `session_id_freed` flag: TRUE if freed, FALSE if leaked

### Capability Validation (Family 2)

Instrument all parameter validation checks:

- `ValidateHeartbeatPeriod()` — check HBEAT_CAP flag and period bounds (line 580-590)
- `ValidateMutAuthRequested()` — check bit encoding (line 590-651)
- `ValidateSlotID()` — check MULTI_KEY_CAP and key_usage_bits (line 623-636)

Emit validation result in trace:
```json
{
  "validation_check": "heartbeat_period",
  "passed": true/false,
  "parameter_value": <int>,
  "capability_bit_set": true/false
}
```

### Slot Validation (Family 4)

For SPDM 1.3+ multi-key deployments, capture:
- Requested slot_id from message
- Actual key_usage_bits in `cert_slots[slot_id]`
- MULTI_KEY_CAP negotiation result

Example:
```json
{
  "slot_id": 1,
  "key_usage_bits": [0x01, 0x00],
  "key_usage_bits_set": false,
  "multi_key_cap_negotiated": true,
  "validation_passed": false
}
```

### Serialization Quirks

- **Zero-value fields**: Some implementations omit fields that are zero. The harness should capture them as 0 explicitly so trace events are complete.
- **Hex encoding**: All hash, HMAC, signature, and key values should be hex-encoded strings (with "0x" prefix).
- **Session ID range**: Use integers; NULL_SESSION_ID = 0 represents "no session".

### Timing & Ordering

Since this is a message-passing protocol, events occur in strict sequence:
1. REQ_SEND_KEY_EXCHANGE
2. RESP_RECEIVE_KEY_EXCHANGE
3. REQ_RECEIVE_KEY_EXCHANGE
4. REQ_SEND_FINISH
5. RESP_RECEIVE_FINISH
6. REQ_RECEIVE_FINISH

Error events (KEY_EXCHANGE_ERROR, FINISH_ERROR) can occur at any validation point and terminate the handshake.

---

## Appendix: Example Trace Events

### Successful Handshake

```ndjson
{"event":"REQ_SEND_KEY_EXCHANGE","node":"requester","session_id":0,"timestamp":1000,"state_snapshot":{"requester_state":"KEX_SENT","capabilities_req":[]},"message_fields":{"type":"KEY_EXCHANGE_REQ","nonce":"abcd1234","dhePublicKey":"def56789"}}
{"event":"RESP_RECEIVE_KEY_EXCHANGE","node":"responder","session_id":1,"timestamp":1001,"state_snapshot":{"responder_state":"KEX_SENT","session_type":"DHE","session_state":"INIT"},"message_fields":{"type":"KEY_EXCHANGE_RSP","sessionID":1,"nonce":"0987fedc","dhePublicKey":"aabbccdd","signature":"sig1","hmac":"hmac1","heartbeatPeriod":0,"mutAuthRequested":0}}
{"event":"REQ_RECEIVE_KEY_EXCHANGE","node":"requester","session_id":1,"timestamp":1002,"state_snapshot":{"requester_state":"KEX_RECEIVED","session_state":"KEX_RECEIVED","dheKeysAgreed":true,"transcriptHashKEX":"kexhash123","capabilitiesValidated":true},"validation_results":{"heartbeat_period_valid":true,"mut_auth_bits_valid":true,"slot_id_valid":true}}
{"event":"REQ_SEND_FINISH","node":"requester","session_id":1,"timestamp":1003,"state_snapshot":{"requester_state":"FINISH_SENT","session_type":"DHE","transcriptHashFINISH":"finishhash456"},"message_fields":{"type":"FINISH_REQ","sessionID":1,"hmac":"req_hmac1"}}
{"event":"RESP_RECEIVE_FINISH","node":"responder","session_id":1,"timestamp":1004,"state_snapshot":{"responder_state":"FINISH_SENT","session_state":"FINISH_RECEIVED","hmacVerified":true},"validation_results":{"opaque_length_valid":true}}
{"event":"REQ_RECEIVE_FINISH","node":"requester","session_id":1,"timestamp":1005,"state_snapshot":{"requester_state":"HANDSHAKING","session_state":"HANDSHAKING"},"validation_results":{"transcript_consistency_valid":true}}
```

### Failure Case (Session ID Leak)

```ndjson
{"event":"REQ_SEND_KEY_EXCHANGE","node":"requester","session_id":0,"timestamp":2000,"state_snapshot":{"requester_state":"KEX_SENT"},"message_fields":{"type":"KEY_EXCHANGE_REQ","nonce":"1111","dhePublicKey":"2222"}}
{"event":"RESP_RECEIVE_KEY_EXCHANGE","node":"responder","session_id":1,"timestamp":2001,"state_snapshot":{"responder_state":"KEX_SENT","session_type":"DHE","session_id_pool_count":1},"message_fields":{"type":"KEY_EXCHANGE_RSP","sessionID":1}}
{"event":"REQ_RECEIVE_KEY_EXCHANGE","node":"requester","session_id":1,"timestamp":2002,"state_snapshot":{"requester_state":"KEX_RECEIVED"},"message_fields":{"type":"KEY_EXCHANGE_RSP","sessionID":1}}
{"event":"REQ_SEND_FINISH","node":"requester","session_id":1,"timestamp":2003,"state_snapshot":{"requester_state":"FINISH_SENT"},"message_fields":{"type":"FINISH_REQ","sessionID":1}}
{"event":"RESP_RECEIVE_FINISH","node":"responder","session_id":1,"timestamp":2004,"state_snapshot":{"responder_state":"IDLE"},"message_fields":{"type":"ERROR","detail":"opaque_length_invalid"}}
{"event":"FINISH_ERROR","node":"responder","session_id":1,"timestamp":2005,"state_snapshot":{"session_id_pool_count":1},"error_fields":{"error_reason":"opaque_length_invalid","session_id_freed":false}}
```
^ Note: session_id_pool_count remains 1 (leaked ID), confirming Family 3 Bug #476.

====
