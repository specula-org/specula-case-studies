# Instrumentation Spec: libspdm MEL Protocol

**Target**: SPDM Measurement Extension Log (MEL) Protocol
**Category**: A (Distributed / Message-Passing)
**Implementation**: libspdm C library

---

## Section 1: Trace Event Schema

### Event Envelope

Each trace event is a JSON object with the following fields:

```json
{
  "event_name": "string",        // Trace event type (e.g., "req_send_get_mel")
  "timestamp": "uint64",         // Nanosecond timestamp (for ordering)
  "node": "string",              // Role: "req" (requester) or "resp" (responder)
  "state_snapshot": {...},       // Current state after action
  "message_snapshot": {...}      // Message payload (if applicable)
}
```

### State Fields (Common to All Events)

Captured at every event to validate spec state transitions:

| Spec Variable | Source Code Location | Implementation Field | Notes |
|---|---|---|---|
| `req_offset` | libspdm_req_get_measurement_extension_log.c:109 | `mel_size_internal` | Cumulative bytes received so far |
| `req_mel_size` | libspdm_req_get_measurement_extension_log.c:85 | `mel_size_internal` | Same as req_offset in our model |
| `req_remainder` | libspdm_req_get_measurement_extension_log.c:82 | `remainder_length` | Last received remainder_length |
| `req_total_mel_size` | libspdm_req_get_measurement_extension_log.c:203-204 | `total_responder_mel_buffer_length` | Stored total from first response |
| `req_pc` | (inferred) | Local program counter | "ready", "waiting", "done" |
| `responder_mel_size` | libspdm_rsp_measurement_extension_log.c:26 | `spdm_mel_len` | Total MEL data size |
| `responder_mel_entries_len` | libspdm_rsp_measurement_extension_log.c:26 | `spdm_mel->mel_entries_len` | Entries length field |
| `responder_pc` | (inferred) | Local program counter | "ready", "processing" |

### Message Fields (Event-Specific)

Captured in message-related events:

#### Request Message Fields
| Field | Type | Spec Mapping | Source |
|---|---|---|---|
| `msg_type` | string | `GetMelRequest` | Request type constant |
| `msg_offset` | uint32 | Request.offset | libspdm_req_get_measurement_extension_log.c:109 |
| `msg_length` | uint32 | Request.length | libspdm_req_get_measurement_extension_log.c:111-113 |

#### Response Message Fields
| Field | Type | Spec Mapping | Source |
|---|---|---|---|
| `msg_type` | string | `MelResponse` | Response type constant |
| `msg_portion_length` | uint32 | Response.portion_length | libspdm_rsp_measurement_extension_log.c:152 |
| `msg_remainder_length` | uint32 | Response.remainder_length | libspdm_rsp_measurement_extension_log.c:153 |
| `msg_data_len` | uint32 | Actual data payload length | libspdm_rsp_measurement_extension_log.c:157 |
| `recv_portion_length` | uint32 | Received portion in requester | libspdm_req_get_measurement_extension_log.c:214-215 |
| `recv_remainder_length` | uint32 | Received remainder in requester | libspdm_req_get_measurement_extension_log.c:213 |

---

## Section 2: Action-to-Code Mapping

### Action 1: RequesterSendGetMel

**Spec Action**: `RequesterSendGetMel` (base.tla:95-104)
**Code Location**: `libspdm_req_get_measurement_extension_log.c:93-117`
**Trigger Point**: After acquiring sender buffer, before sending request

| Step | Code Location | Description |
|------|---|---|
| 1 | Line 95-98 | Acquire sender buffer |
| 2 | Line 101-103 | Construct request header and parameters |
| 3 | Line 109 | Set `spdm_request->offset` |
| 4 | Line 111-113 | Set `spdm_request->length` |
| 5 | Line 120-121 | Send request message |

**Trace Event**: `"req_send_get_mel"`

**Event Fields**:
- State: `req_offset`, `req_pc` (transitioning from "ready" to "waiting")
- Message: `msg_type="GetMelRequest"`, `msg_offset`, `msg_length`

**Notes**:
- Snapshot is taken AFTER message construction but BEFORE send (to catch pre-send state)
- `req_pc` should transition to "waiting" after this action
- For first request, `req_offset` = 0; for subsequent requests, `req_offset` = accumulated bytes

---

### Action 2: ResponderReceiveAndSendMel

**Spec Action**: `ResponderReceiveAndSendMel` (base.tla:109-138)
**Code Location**: `libspdm_rsp_measurement_extension_log.c:10-160`
**Trigger Point**: After receiving request, before sending response

| Step | Code Location | Description |
|------|---|---|
| 1 | Line 34-39 | Version check |
| 2 | Line 41-45 | SPDM version validation |
| 3 | Line 46-56 | Connection state and session validation |
| 4 | Line 78-84 | Capability check (MEL_CAP) |
| 5 | Line 86-91 | Algorithm validation |
| 6 | Line 93-97 | Request size validation |
| 7 | Line 99-100 | Extract offset and length from request |
| 8 | Line 102-111 | Calculate max_mel_block_length if no CHUNK_CAP |
| 9 | Line 115-124 | Collect MEL data |
| 10 | Line 126-130 | Validate offset < MEL size |
| 11 | Line 132-134 | Calculate actual length (clamp if needed) |
| 12 | Line 135 | Calculate remainder |
| 13 | Line 152-153 | Set response portion_length and remainder_length |
| 14 | Line 155-157 | Copy MEL data into response |
| 15 | Line 159 | Return SUCCESS |

**Trace Event**: `"resp_receive_and_send_mel"`

**Event Fields**:
- State: `responder_mel_size`, `responder_mel_entries_len`, `responder_pc` ("ready")
- Message: `msg_type="MelResponse"`, `msg_portion_length`, `msg_remainder_length`, `msg_data_len`

**Notes**:
- Snapshot taken AFTER response construction but BEFORE send
- All parameter validations (lines 34-97) must pass for event to occur
- If validations fail, log error event instead: `"resp_error"` with error code
- `responder_mel_size` is the total MEL size from `libspdm_measurement_extension_log_collection()`
- `msg_data_len` is the actual number of bytes copied (should equal `msg_portion_length`)

---

### Action 3: RequesterReceiveMelResponse

**Spec Action**: `RequesterReceiveMelResponse` (base.tla:140-175)
**Code Location**: `libspdm_req_get_measurement_extension_log.c:130-241`
**Trigger Point**: After receiving and validating response, before processing

| Step | Code Location | Description |
|------|---|---|
| 1 | Line 131-146 | Acquire receiver buffer and receive response |
| 2 | Line 149-153 | Check response size (minimum header) |
| 3 | Line 154-163 | Handle error responses |
| 4 | Line 164-168 | Check response code |
| 5 | Line 169-173 | Check version match |
| 6 | Line 174-178 | Check response size >= header |
| 7 | Line 179-184 | Validate portion_length > 0 and <= requested |
| 8 | Line 185-190 | Check payload size matches portion_length |
| 9 | Line 191-195 | Check portion_length arithmetic overflow |
| 10 | Line 196-199 | Check remainder_length arithmetic overflow |
| 11 | Line 202-210 | Check remainder consistency (BF2 check) |
| 12 | Line 213 | Read remainder_length |
| 13 | Line 217 | Check buffer capacity |
| 14 | Line 228-231 | Copy data into buffer |
| 15 | Line 233 | Increment mel_size_internal |

**Trace Event**: `"req_receive_mel_response"`

**Event Fields**:
- State: `req_mel_size`, `req_offset`, `req_remainder`, `req_total_mel_size`, `req_pc` (transitioning to "ready" or "done")
- Message: `recv_portion_length`, `recv_remainder_length`

**Notes**:
- Snapshot taken AFTER all validations pass but BEFORE buffer increment
- `req_mel_size` (output state) = prior `req_mel_size` + `portion_length`
- `req_offset` (output state) = new `req_mel_size` (for next request)
- If any validation fails, log validation error event instead
- The `RemainderConsistent` check is implemented at lines 205-210 (BF2 validation point)

---

### Action 4: RequesterCheckTermination

**Spec Action**: `RequesterCheckTermination` (base.tla:177-187)
**Code Location**: `libspdm_req_get_measurement_extension_log.c:242-246`
**Trigger Point**: After loop checks termination condition

| Step | Code Location | Description |
|------|---|---|
| 1 | Line 242 | Check loop condition: `mel_size_internal < expected_size` |
| 2 | Line 245-246 | Store final `mel_size` and return |

**Trace Event**: `"req_check_termination"` (or implicit in "req_done" event)

**Event Fields**:
- State: `req_pc` (transitioning to "done"), `req_mel_size` (final)

**Notes**:
- This action represents the implicit loop exit when `remainder_length == 0`
- Snapshot reflects final state after all data accumulated
- Can be merged with the final `RequesterReceiveMelResponse` that gets `remainder_length == 0`

---

## Section 3: Special Considerations

### Bootstrap State
The implementation's initial state may differ from the base spec's `Init`:
- **responder_mel**: Initialized by `libspdm_measurement_extension_log_collection()` (source of truth for MEL size)
- **req_offset**: Always starts at 0
- **req_mel_size**: Starts at 0, incremented by portions received
- **req_pc**: Implementation uses local loop variable; map to "ready" at start

### Algorithm Parameters
The MEL specification and measurement hash algorithm are negotiated during SPDM capability exchange:
- Code: libspdm_rsp_measurement_extension_log.c:86-91 (validation)
- These are stored in `spdm_context->connection_info.algorithm`
- For trace validation, capture these once at bootstrap (not per-event)

### Non-Atomic Persist (if applicable)
The current implementation does NOT use disk persistence for MEL; it's computed fresh each request.
- If persistence is added in future, model as silent action in Trace spec

### Error Paths
When validations fail, the responder generates an error response instead:
- Code: libspdm_rsp_measurement_extension_log.c:35-38, 42-44, 53-55, etc.
- Log error events with error code field: `{event_name: "resp_error", error_code: "..."}`
- These do NOT advance the state machine; treat as silent failures in MC spec

### Multi-Request Chunking
For testing, ensure instrumentation captures enough detail to validate the chunking logic:
- Capture `msg_offset` and `msg_length` in every request
- Capture `msg_portion_length` and `msg_remainder_length` in every response
- Validate that `offset` from request matches expected cumulative position

### Intermediate State Changes
The loop in `libspdm_try_get_measurement_extension_log()` (lines 93-243) runs multiple iterations:
- Each iteration is ONE `RequesterReceiveMelResponse` action
- Do NOT collapse multiple iterations into one action — each must be traced separately
- Exception: Silent buffer management (malloc/free) can be implicit

---

## Implementation Guide for Harness Generation

1. **Identify Instrumentation Points**: For each action above, add logging/tracing code at the specified code location
2. **Capture State**: At each event, record all state fields (use JSON serialization)
3. **Serialize Messages**: For network messages, extract the raw fields and record them
4. **Handle Non-Determinism**: In MC phase, ensure all non-deterministic choices (e.g., chunk size selection) are logged
5. **Timestamp Ordering**: Use consistent clock source for global event ordering (required for Category A validation)
6. **Error Handling**: Log error conditions as separate events with error codes
7. **Test Both Paths**: Ensure test harness exercises both success and error code paths

---

## Examples

### Example 1: Single Chunk (MEL fits in one response)

```json
{"event_name": "init", "responder_mel_size": 16, "responder_mel_entries_len": 14, "req_offset": 0, "req_mel_size": 0, "req_pc": "ready"}
{"event_name": "req_send_get_mel", "msg_offset": 0, "msg_length": 32, "req_pc": "waiting"}
{"event_name": "resp_receive_and_send_mel", "msg_portion_length": 16, "msg_remainder_length": 0, "responder_pc": "ready"}
{"event_name": "req_receive_mel_response", "recv_portion_length": 16, "recv_remainder_length": 0, "req_mel_size": 16, "req_offset": 16, "req_pc": "done"}
```

### Example 2: Multi-Chunk (MEL requires multiple requests)

```json
{"event_name": "init", "responder_mel_size": 48, "responder_mel_entries_len": 46, "req_offset": 0, "req_mel_size": 0}
{"event_name": "req_send_get_mel", "msg_offset": 0, "msg_length": 32}
{"event_name": "resp_receive_and_send_mel", "msg_portion_length": 32, "msg_remainder_length": 16}
{"event_name": "req_receive_mel_response", "recv_portion_length": 32, "recv_remainder_length": 16, "req_mel_size": 32, "req_offset": 32, "req_pc": "ready"}
{"event_name": "req_send_get_mel", "msg_offset": 32, "msg_length": 32}
{"event_name": "resp_receive_and_send_mel", "msg_portion_length": 16, "msg_remainder_length": 0}
{"event_name": "req_receive_mel_response", "recv_portion_length": 16, "recv_remainder_length": 0, "req_mel_size": 48, "req_offset": 48, "req_pc": "done"}
```

---

## Validation Checklist

Before finalizing harness generation:

- [ ] All 4 actions have corresponding instrumentation points
- [ ] State fields captured at every event
- [ ] Message fields captured for all message events
- [ ] Bootstrap state captured (initial event)
- [ ] Error paths logged separately
- [ ] Timestamp ordering is consistent
- [ ] No fields are omitted from required events
- [ ] JSON schema matches Trace.tla expectations
- [ ] All data types (uint32, uint64, string) match implementation

