# Instrumentation Spec: libspdm Large-Message Chunking

**Target**: libspdm — SPDM large-message chunking / reassembly  
**Trace format**: NDJSON (one JSON object per line)  
**Trace file**: `../traces/trace.ndjson` (or `IOEnv.JSON` override)  
**Spec action count**: 11 actions → 11 event types

---

## Section 1: Trace Event Schema

### Event Envelope

Every event is a single JSON object with these top-level fields:

```json
{
  "event":  "<event_name>",     // string — see action mapping below
  "node":   "responder" | "requester",
  "ts_ns":  <uint64>,           // wall-clock nanoseconds (for ordering analysis)
  ...                           // event-specific fields (see below)
}
```

### State Fields (captured at every event)

These fields MUST be present on every event; they map directly to TLA+ variables.

| JSON field | C source | TLA+ variable | Notes |
|------------|----------|---------------|-------|
| `send_in_use` | `spdm_context->chunk_context.send.chunk_in_use` | `send_in_use` | bool |
| `send_seq_no` | `spdm_context->chunk_context.send.chunk_seq_no` | `send_seq_no` | uint32 |
| `send_bytes_transferred` | `spdm_context->chunk_context.send.chunk_bytes_transferred` | `send_bytes_transferred` | size_t |
| `send_large_msg_size` | `spdm_context->chunk_context.send.large_message_size` | `send_large_msg_size` | uint32 |
| `get_in_use` | `spdm_context->chunk_context.get.chunk_in_use` | `get_in_use` | bool |
| `get_seq_no` | `spdm_context->chunk_context.get.chunk_seq_no` | `get_seq_no` | uint32 |
| `get_bytes_sent` | `spdm_context->chunk_context.get.chunk_bytes_transferred` | `get_bytes_sent` | size_t |
| `get_large_msg_size` | `spdm_context->chunk_context.get.large_message_size` | `get_large_msg_size` | uint32 |
| `req_state` | local state variable in `libspdm_handle_large_response` | `req_state` | "IDLE"\|"IN_PROGRESS"\|"SUCCESS"\|"ERROR" |
| `req_bytes_so_far` | `large_response_size_so_far` | `req_bytes_so_far` | size_t |
| `last_chunk_received` | tracked locally (see note below) | `last_chunk_received` | bool |
| `output_written` | tracked locally | `output_written` | bool |
| `scratch_zeroed` | tracked locally | `scratch_zeroed` | bool |
| `transfer_status` | `status` local variable mapped to SUCCESS/ERROR | `transfer_status` | "IDLE"\|"IN_PROGRESS"\|"SUCCESS"\|"ERROR" |

**Note on `last_chunk_received`**: The C code does not have a persistent field for this. The harness must introduce a local shadow variable updated whenever `spdm_response->header.param1 & SPDM_CHUNK_GET_RESPONSE_ATTRIBUTE_LAST_CHUNK` is observed. See Family 1 note in §3.

---

## Section 2: Action-to-Code Mapping

### 1. `ResponderChunkSendReceivedFirstChunk`

| Field | Value |
|-------|-------|
| **Event name** | `chunk_send_first` |
| **Node** | `responder` |
| **Source file** | `library/spdm_responder_lib/libspdm_rsp_chunk_send_ack.c` |
| **Code location** | After line 159 (`send_info->chunk_bytes_transferred = spdm_request->chunk_size`) — first-chunk initialization complete |
| **Trigger point** | After state is updated, before sending `CHUNK_SEND_ACK` response |
| **Additional fields** | `handle: spdm_request->header.param2`, `incoming_seq_no: 0`, `chunk_size: spdm_request->chunk_size`, `large_size: large_message_size` |
| **Notes** | Only fires on the `!send_in_use` path (line 106). The `!get_in_use` guard at line 90–95 is a precondition — if violated, a different error is returned and no event is emitted. |

---

### 2. `ResponderChunkSendReceivedValidSeqNo`

| Field | Value |
|-------|-------|
| **Event name** | `chunk_send_valid` |
| **Node** | `responder` |
| **Source file** | `libspdm_rsp_chunk_send_ack.c` |
| **Code location** | After line 199 (`send_info->chunk_bytes_transferred += spdm_request->chunk_size`) |
| **Trigger point** | After successful copy and seq-no increment (line 198–199), before building response |
| **Additional fields** | `handle: spdm_request->header.param2`, `incoming_seq_no: chunk_seq_no`, `is_last: (param1 & LAST_CHUNK) != 0` |
| **Notes** | Only fires when `chunk_seq_no == send_info->chunk_seq_no + 1` (line 166 check passes). The `is_last` field drives the `send_in_use'` update. |

---

### 3. `ResponderChunkSendReceivedInvalidSeqNo`

| Field | Value |
|-------|-------|
| **Event name** | `chunk_send_invalid_seq` |
| **Node** | `responder` |
| **Source file** | `libspdm_rsp_chunk_send_ack.c` |
| **Code location** | After line 168 (`status = LIBSPDM_STATUS_INVALID_MSG_FIELD`) AND after line 199 (if the else-branch at line 191 was entered despite the error) |
| **Trigger point** | After the point where state may or may not have been mutated — capture BOTH `send_bytes_transferred` snapshots if possible |
| **Additional fields** | `handle: spdm_request->header.param2`, `incoming_seq_no: chunk_seq_no`, `seq_no_mismatch: true`, `bytes_advanced: (new_transferred != old_transferred)` |
| **Notes** | **Family 2 bug capture.** The key observable is whether `send_bytes_transferred` changed. The harness should capture the value before line 166 (snapshot `old_transferred`) and after line 199 (snapshot `new_transferred`), then emit the event with both values. If `bytes_advanced=true`, the invariant `NoStateAdvanceOnSeqNoMismatch` should be violated. |

---

### 4. `ResponderLargeResponseReady`

| Field | Value |
|-------|-------|
| **Event name** | `large_response_ready` |
| **Node** | `responder` |
| **Source file** | `library/spdm_responder_lib/libspdm_rsp_receive_send.c` |
| **Code location** | After ~line 680 (large response stored in scratch, `get_info->chunk_in_use = true`) |
| **Trigger point** | After `get_info` is fully initialized, before sending `LARGE_RESPONSE` error to requester |
| **Additional fields** | `handle: get_info->chunk_handle`, `large_size: get_info->large_message_size` |
| **Notes** | This event drives `RequesterReceivesLargeResponseError` indirectly — the network delivers a `LARGE_RESPONSE` error which the requester processes. |

---

### 5. `RequesterReceivesLargeResponseError`

| Field | Value |
|-------|-------|
| **Event name** | `large_response_error_received` |
| **Node** | `requester` |
| **Source file** | `library/spdm_requester_lib/libspdm_req_handle_error_response.c` |
| **Code location** | After ~line 320 (requester confirms `LARGE_RESPONSE` error, initializes CHUNK_GET loop variables) |
| **Trigger point** | After `large_response_size` is extracted from the error response and the loop begins |
| **Additional fields** | `handle: spdm_response->header.param2`, `large_size: large_response_size`, `chunk_seq_no: 0` |
| **Notes** | Shadow variable `harness_last_chunk_received` should be initialized to `false` here. |

---

### 6. `ResponderServesChunkGet`

| Field | Value |
|-------|-------|
| **Event name** | `chunk_get_served` |
| **Node** | `responder` |
| **Source file** | `library/spdm_responder_lib/libspdm_rsp_chunk_response.c` |
| **Code location** | After ~line 210 (response built, `get_info->chunk_seq_no` incremented, `get_info->chunk_bytes_transferred` updated) |
| **Trigger point** | After all state updates, before returning |
| **Additional fields** | `handle: spdm_request->header.param2`, `seq_no: chunk_seq_no`, `chunk_size: chunk_data_size`, `is_last: (param1 & LAST_CHUNK) != 0`, `large_size: get_info->large_message_size` |
| **Notes** | Normal path: `send_in_use=false` at entry. Distinguish from `chunk_get_during_send` by checking `spdm_context->chunk_context.send.chunk_in_use` at event capture time. |

---

### 7. `ResponderServesChunkGetWhileSendInProgress`

| Field | Value |
|-------|-------|
| **Event name** | `chunk_get_during_send` |
| **Node** | `responder` |
| **Source file** | `libspdm_rsp_chunk_response.c` |
| **Code location** | After ~line 210 (same location as above), but only when `spdm_context->chunk_context.send.chunk_in_use == true` at entry |
| **Trigger point** | Same as `ResponderServesChunkGet` |
| **Additional fields** | Same as `chunk_get_served` plus `send_in_use_at_entry: true` |
| **Notes** | **Family 5 bug capture.** The emitted event should include a `send_in_use_at_entry` field to confirm the asymmetry was exercised. In TLA+ `Trace.tla`, `TraceResponderServesChunkGetWhileSendInProgress` validates `send_in_use = TRUE`. |

---

### 8. `RequesterProcessChunkResponseValid`

| Field | Value |
|-------|-------|
| **Event name** | `chunk_response_processed_valid` |
| **Node** | `requester` |
| **Source file** | `libspdm_req_handle_error_response.c` |
| **Code location** | After line 453 (`large_response_size_so_far += spdm_response->chunk_size`) and line 455 (`chunk_seq_no++`) |
| **Trigger point** | After copy and counter updates, before the `while` condition re-evaluation |
| **Additional fields** | `seq_no: chunk_seq_no - 1` (the seq_no of the chunk just processed), `chunk_size: spdm_response->chunk_size`, `received_msg_size: response_size`, `is_last: (param1 & LAST_CHUNK) != 0`, `last_chunk_received: harness_last_chunk_received` |
| **Notes** | **Family 1**: Update shadow `harness_last_chunk_received = (param1 & LAST_CHUNK) != 0` before emitting. Only fires when `chunk_size <= received_msg_size - sizeof(spdm_chunk_response_response_t)` — i.e., source-bound check WOULD pass (use for normal-path traces). |

---

### 9. `RequesterProcessChunkResponseSourceUnbounded`

| Field | Value |
|-------|-------|
| **Event name** | `chunk_response_source_oob` |
| **Node** | `requester` |
| **Source file** | `libspdm_req_handle_error_response.c` |
| **Code location** | Same as above (line 453), but only when `spdm_response->chunk_size > response_size - sizeof(spdm_chunk_response_response_t)` |
| **Trigger point** | Same as `chunk_response_processed_valid` |
| **Additional fields** | Same fields plus `oob_detected: true`, `actual_payload_bound: response_size - sizeof(spdm_chunk_response_response_t)` |
| **Notes** | **Family 4 bug capture.** In production this would require a fuzzer or adversarial responder to set `chunk_size` larger than the actual message. The harness should add a comparison check and emit this event when the over-bound is detected. |

---

### 10. `RequesterTransferCompleteSuccess`

| Field | Value |
|-------|-------|
| **Event name** | `transfer_complete_success` |
| **Node** | `requester` |
| **Source file** | `libspdm_req_handle_error_response.c` |
| **Code location** | After line 471 (`libspdm_zero_mem(large_response, large_response_size)`) |
| **Trigger point** | After both `libspdm_copy_mem` (line 466–468) and `libspdm_zero_mem` (line 471) have executed |
| **Additional fields** | `last_chunk_received: harness_last_chunk_received`, `output_written: true`, `scratch_zeroed: true`, `bytes_so_far: large_response_size_so_far`, `large_size: large_response_size` |
| **Notes** | Only fires when `large_response_size <= response_capacity` (line 465 branch taken). If `last_chunk_received=false` here, `TransferCompleteImpliesLastChunk` will be violated. |

---

### 11. `RequesterTransferCompleteBufferOverflow`

| Field | Value |
|-------|-------|
| **Event name** | `transfer_complete_overflow` |
| **Node** | `requester` |
| **Source file** | `libspdm_req_handle_error_response.c` |
| **Code location** | After line 473 (the `if/else-if` chain ends — no else branch exists for the overflow case) |
| **Trigger point** | At the point where `large_response_size > response_capacity` holds but no action is taken — capture state just before `return status` at line 475 |
| **Additional fields** | `last_chunk_received: harness_last_chunk_received`, `output_written: false`, `scratch_zeroed: false`, `bytes_so_far: large_response_size_so_far`, `large_size: large_response_size`, `response_capacity: <caller-side buffer size>` |
| **Notes** | **Family 3 bug capture.** This event fires when the code falls through the `if/else-if` at lines 462–472 without entering either branch — because `large_response_size > response_capacity` is not handled. The harness must compute `response_capacity` from the caller's `*inout_response_size` parameter before the loop starts. `output_written=false` and `scratch_zeroed=false` with `transfer_status=SUCCESS` is the bug signature. |

---

## Section 3: Special Considerations

### 3.1 Shadow variables required by harness

The C implementation does not maintain persistent equivalents of:
- `harness_last_chunk_received` — introduce as a harness-local `bool`, reset at loop entry (`large_response_error_received`), set when `param1 & LAST_CHUNK` is observed during loop processing.
- `harness_output_written` — set to `true` after `libspdm_copy_mem` executes (line 466).
- `harness_scratch_zeroed` — set to `true` after `libspdm_zero_mem` executes (line 471).
- `harness_req_state` — encode the local state of the CHUNK_GET loop as a string: "IDLE" before entry, "IN_PROGRESS" inside the do-while, "SUCCESS" after return, "ERROR" on error return.

All four shadow variables must be captured in every event emitted from the requester side.

### 3.2 Access to `response_capacity`

The `response_capacity` value (caller's `*inout_response_size`) is only available at the top of `libspdm_handle_large_response` as a parameter. It must be captured into a harness-local variable before the do-while loop so it is accessible when emitting `transfer_complete_overflow`.

### 3.3 Concurrent event ordering

The SPDM protocol is single-threaded per-context; there are no concurrent threads within one context. Events within a single transfer are strictly ordered. No ViablePIDs or timebox logic is needed (Category A).

### 3.4 Serialization

All `bool` fields should serialize as JSON `true`/`false`. All `size_t` and `uint32_t` fields serialize as JSON numbers. The `req_state` field serializes as a string constant matching the TLA+ constant names: `"IDLE"`, `"IN_PROGRESS"`, `"SUCCESS"`, `"ERROR"`.

### 3.5 Bootstrap state

The initial state has all context fields zeroed. No bootstrap events are needed; `TraceInit` in `Trace.tla` sets variables to match C's initial zero state. If a test runs multiple transfers back-to-back within a single SPDM session, the harness should emit one trace file per transfer (reset shadow variables between transfers).

### 3.6 Distinguishing `chunk_get_served` vs `chunk_get_during_send`

At the instrumentation site (after line 210 in `libspdm_rsp_chunk_response.c`), the `send_in_use` flag has already been potentially modified by concurrent CHUNK_SEND handling — but this is single-threaded, so the value at the start of `libspdm_get_response_chunk_send` is the authoritative check. The harness should capture `spdm_context->chunk_context.send.chunk_in_use` at function ENTRY (before any state changes) and use that value to choose the event name.

### 3.7 CHUNK_SEND_ACK error path (Family 2)

For `chunk_send_invalid_seq`, the harness must instrument TWO points:
1. Before line 166 (capture `old_bytes = send_info->chunk_bytes_transferred`)
2. After line 199 or wherever the function path exits (capture `new_bytes = send_info->chunk_bytes_transferred`)

If `new_bytes != old_bytes`, emit `bytes_advanced: true`. This single boolean is the observable that confirms the Family 2 bug is triggerable.
