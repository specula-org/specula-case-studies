# Instrumentation Spec: SPDM Chunking Trace Collection

## Overview

This document specifies how to instrument the libspdm chunking implementation to produce NDJSON traces compatible with the TLA+ trace validation spec (`Trace.tla`).

**System**: libspdm (DMTF SPDM protocol)  
**Target**: Large-message chunking / reassembly  
**Category**: A (Distributed / Message-Passing)  
**Output Format**: NDJSON (one JSON event per line)  
**Trace Location**: `../traces/trace.ndjson`

---

## Section 1: Trace Event Schema

### Event Envelope

Every trace event is a JSON object with the following structure:

```json
{
  "eventName": "<string>",
  "timestamp": "<ISO 8601 timestamp>",
  "nodeId": "<string>",
  "state": {
    "chunk_context": { "send": bool, "get": bool, "seq_no": int, "bytes_transferred": int },
    "large_message_size": int,
    "large_message_capacity": int,
    "large_message_valid": bool,
    "chunk_phase": "INIT" | "CONTINUATION",
    "seq_no_wrap_error": bool
  },
  "message": {}
}
```

### State Fields

State fields are captured at every event and mapped to TLA+ variables:

| Implementation Field | TLA+ Variable | Type | Capture Timing | Notes |
|----------------------|---------------|------|----------------|-------|
| `libspdm_context.local_context.chunk_send_context.chunk_in_use` | `chunk_context.send` | bool | After action | Responder's send-path chunk active flag |
| `libspdm_context.local_context.chunk_send_context.get_in_use` | `chunk_context.get` | bool | After action | Responder's get-path chunk active flag |
| `libspdm_context.local_context.chunk_send_context.chunk_seq_no` | `chunk_context.seq_no` | uint8/uint32 | After action | Current chunk sequence number |
| `libspdm_context.local_context.chunk_send_context.chunk_bytes_transferred` | `chunk_context.bytes_transferred` | uint32 | After action | Bytes accumulated in reassembly |
| `incoming_request.payload_size` (for CHUNK_SEND) | `large_message_size` | uint32 | Before reassembly | Declared total message size |
| `libspdm_get_scratch_buffer_large_message_capacity(ctx)` | `large_message_capacity` | uint32 | At init | Allocated buffer capacity (Family 4) |
| Shadow flag (need to add) | `large_message_valid` | bool | After action | Buffer validity after error/interruption (Family 5) |
| Computed from code path | `chunk_phase` | {INIT, CONTINUATION} | Before/after action | Which size-calculation code path (Family 3) |
| Computed from `SPDMVersion` | `seq_no_wrap_error` | bool | At init | Version-dependent wrap handling (Family 2) |

### Message Fields

Message-specific fields (populated only for message events):

| Implementation Field | Trace Field | Event Type | Notes |
|----------------------|-------------|-----------|-------|
| `request->RequestHeader.RequestResponseCode` | `type` | CHUNK_SEND | "CHUNK_SEND", "CHUNK_GET", etc. |
| `request->ChunkSeqNum` | `seq_no` | CHUNK_SEND | Incoming sequence number |
| `request->ChunkSize` | `chunk_size` | CHUNK_SEND | Payload size in this chunk |
| `request->header.SPDMVersion` | `version` | At init | Version to determine wrap behavior |
| `cmd_type` (inferred from handler) | `cmd_type` | Interruption | GET_VERSION, DecryptError, OTHER |

---

## Section 2: Action-to-Code Mapping

### Action 1: ChunkSendInit

**Spec Action**: `ChunkSendInit(msg_size, chunk_size)` (base.tla:149-173)

**Code Location**: `libspdm_rsp_chunk_send_ack.c:97-159`

**Trigger Point**: After line 156 (memcpy of first chunk payload)

**Trace Event Name**: `ChunkSendInit`

**Trace Event Fields**:
```json
{
  "eventName": "ChunkSendInit",
  "timestamp": "2026-06-04T12:34:56.789Z",
  "nodeId": "responder",
  "state": {
    "chunk_context": {
      "send": true,
      "get": false,
      "seq_no": 0,
      "bytes_transferred": 0
    },
    "large_message_size": 512,
    "large_message_capacity": 1024,
    "large_message_valid": true,
    "chunk_phase": "INIT",
    "seq_no_wrap_error": true
  },
  "message": {}
}
```

**Instrumentation Point**:
- Location: `libspdm_rsp_chunk_send_ack.c:156` (after first memcpy)
- Capture: `req->header.large_message_size`, `chunk_size = bytes copied`, state snapshot
- Code snippet (pseudo-C):
  ```c
  // After line 156: memcpy(large_message, chunk_ptr, chunk_size)
  TRACE_EVENT("ChunkSendInit", {
    .state = {
      .chunk_context = { .send = TRUE, .get = FALSE, .seq_no = 0, ... },
      .large_message_size = req->header.large_message_size,
      .large_message_capacity = libspdm_get_scratch_buffer_capacity(ctx),
      .large_message_valid = TRUE,
      .chunk_phase = "INIT",
      .seq_no_wrap_error = (spdm_version < 1.4)
    }
  });
  ```

**Notes**:
- This marks the entry to chunked transfer. Capture state after `chunk_in_use` is set to TRUE but before any data processing.
- Family 4 bug: verify `large_message_size <= large_message_capacity` here.
- Family 2: `seq_no_wrap_error` must reflect version (line 125: "if SPDM < 1.4" check).

---

### Action 2: ChunkSendContinuation

**Spec Action**: `ChunkSendContinuation(chunk_seq, chunk_size)` (base.tla:155-175)

**Code Location**: `libspdm_rsp_chunk_send_ack.c:160-195`

**Trigger Point**: After line 193 (memcpy of continuation chunk)

**Trace Event Name**: `ChunkSendContinuation`

**Trace Event Fields**:
```json
{
  "eventName": "ChunkSendContinuation",
  "timestamp": "2026-06-04T12:34:56.890Z",
  "nodeId": "responder",
  "state": {
    "chunk_context": {
      "send": true,
      "get": false,
      "seq_no": 1,
      "bytes_transferred": 256
    },
    "large_message_size": 512,
    "large_message_capacity": 1024,
    "large_message_valid": true,
    "chunk_phase": "CONTINUATION",
    "seq_no_wrap_error": true
  },
  "message": {}
}
```

**Instrumentation Point**:
- Location: `libspdm_rsp_chunk_send_ack.c:193` (after continuation memcpy)
- Capture: current seq_no, bytes transferred so far, state snapshot
- Code snippet (pseudo-C):
  ```c
  // After line 193: memcpy(large_message + bytes_so_far, chunk_ptr, chunk_size)
  TRACE_EVENT("ChunkSendContinuation", {
    .state = {
      .chunk_context = {
        .send = TRUE,
        .get = FALSE,
        .seq_no = req->ChunkSeqNum,
        .bytes_transferred = spdm_context->chunk_bytes_transferred + chunk_size
      },
      .large_message_size = req->header.large_message_size,
      .chunk_phase = "CONTINUATION",
      ...
    }
  });
  ```

**Notes**:
- Family 3 bug: Verify that continuation chunk respects `CalcMaxChunkSizeContinuation` (line 164), which differs from first-chunk calc (line 118).
- Family 2 bug: Verify seq_no wrap is checked per version (line 188-190 vs. line 126).
- Family 4 bug: Verify `bytes_transferred + chunk_size <= capacity` (line 172 check must exist in code).

---

### Action 3: ReceiveInterruption

**Spec Action**: `ReceiveInterruption(cmd_type)` (base.tla:180-200)

**Code Location**: `libspdm_rsp_receive_send.c:558-583` (lines 561-571 for send, 572-582 for get)

**Trigger Point**: After line 571 or 582 (state cleared)

**Trace Event Name**: `ReceiveInterruption`

**Trace Event Fields**:
```json
{
  "eventName": "ReceiveInterruption",
  "timestamp": "2026-06-04T12:34:56.950Z",
  "nodeId": "responder",
  "state": {
    "chunk_context": {
      "send": false,
      "get": false,
      "seq_no": 0,
      "bytes_transferred": 0
    },
    "large_message_size": 512,
    "large_message_valid": true,
    "chunk_phase": "INIT",
    "seq_no_wrap_error": true
  },
  "message": {
    "cmd_type": "GET_VERSION"
  }
}
```

**Instrumentation Point**:
- Location: `libspdm_rsp_receive_send.c:561` (for send path) or `572` (for get path)
- Trigger: Before clearing state, determine command type
- Capture: command type, state before/after clear
- Code snippet (pseudo-C):
  ```c
  // Around line 561-582: detect non-chunk command during transfer
  if (chunk_context->chunk_in_use) {
    TRACE_EVENT("ReceiveInterruption", {
      .message = { .cmd_type = (is_get_version ? "GET_VERSION" : "OTHER") },
      .state = {
        .chunk_context = { .send = FALSE, .get = FALSE, ... }
        // State shown AFTER clear (buggy behavior)
      }
    });
  }
  ```

**Notes**:
- **Family 1 bug target**: This action captures the bug — interruption clears state unconditionally (lines 561-582 do not distinguish allowed vs. forbidden).
- The trace shows state *after* clear. Correct implementation should preserve state for forbidden interruptions.
- `cmd_type` mapping:
  - GET_VERSION → "GET_VERSION"
  - Interrupt caused by DecryptError → "DecryptError"
  - Any other command → "OTHER"

---

### Action 4: ErrorDuringReassembly

**Spec Action**: `ErrorDuringReassembly` (base.tla:207-223)

**Code Location**: `libspdm_rsp_chunk_send_ack.c:230-254`

**Trigger Point**: After error detection (line 230) and state clear (line 249-254)

**Trace Event Name**: `ErrorDuringReassembly`

**Trace Event Fields**:
```json
{
  "eventName": "ErrorDuringReassembly",
  "timestamp": "2026-06-04T12:34:56.999Z",
  "nodeId": "responder",
  "state": {
    "chunk_context": {
      "send": false,
      "get": false,
      "seq_no": 0,
      "bytes_transferred": 0
    },
    "large_message_size": 0,
    "large_message_valid": false,
    "chunk_phase": "INIT",
    "seq_no_wrap_error": true
  },
  "message": {}
}
```

**Instrumentation Point**:
- Location: `libspdm_rsp_chunk_send_ack.c:250-254` (after state cleanup)
- Capture: state post-cleanup, error reason (optional)
- Code snippet (pseudo-C):
  ```c
  // Lines 230-254: error handling during reassembly
  if (error_condition) {
    // Lines 249-254: clear state
    chunk_context->chunk_in_use = FALSE;
    chunk_context->seq_no = 0;
    chunk_context->bytes_transferred = 0;
    
    TRACE_EVENT("ErrorDuringReassembly", {
      .state = {
        .chunk_context = { .send = FALSE, ... },
        .large_message_valid = FALSE,
        // Spec models correct behavior (setting to FALSE)
        // But code might NOT invalidate (bug!)
      }
    });
  }
  ```

**Notes**:
- **Family 5 bug target**: Error path does NOT invalidate buffer (spec models the fix; code is buggy).
- Capture `large_message_valid` *after* error — this reveals whether the code correctly clears the flag.
- Multiple error reasons possible (line 230-240 conditions), but all converge on cleanup.

---

### Action 5: RequesterSendChunk

**Spec Action**: `RequesterSendChunk(msg_id, seq_no, payload)` (base.tla:229-240)

**Code Location**: Requester-side chunking (not analyzed in modeling brief, but needed for completeness)

**Trigger Point**: After constructing CHUNK_SEND request, before transmission

**Trace Event Name**: `RequesterSendChunk`

**Trace Event Fields**:
```json
{
  "eventName": "RequesterSendChunk",
  "timestamp": "2026-06-04T12:34:56.750Z",
  "nodeId": "requester",
  "state": {
    "chunk_context": { "send": true, "seq_no": 1, ... }
  },
  "message": {
    "type": "CHUNK_SEND",
    "seq_no": 1,
    "payload_size": 256
  }
}
```

**Instrumentation Point**:
- Location: Requester chunk-send construction (outside analysis scope; placeholder)
- Code snippet (pseudo-C):
  ```c
  TRACE_EVENT("RequesterSendChunk", {
    .message = { .type = "CHUNK_SEND", .seq_no = seq_no, .payload_size = size }
  });
  ```

---

### Action 6: ResponderProcessChunk

**Spec Action**: `ResponderProcessChunk(msg_id, seq_no, payload)` (base.tla:242-257)

**Code Location**: Entry to `libspdm_get_response_chunk_send()`

**Trigger Point**: After processing CHUNK_SEND, before responding

**Trace Event Name**: `ResponderProcessChunk`

**Trace Event Fields**:
```json
{
  "eventName": "ResponderProcessChunk",
  "timestamp": "2026-06-04T12:34:56.800Z",
  "nodeId": "responder",
  "state": { ... },
  "message": {
    "type": "CHUNK_SEND_ACK",
    "offset": 256
  }
}
```

**Instrumentation Point**:
- Location: `libspdm_rsp_chunk_send_ack.c:200-210` (after response construction)

---

## Section 3: Special Considerations

### State Fields That Require Instrumentation Additions

| Field | Implementation Status | Action |
|-------|----------------------|--------|
| `large_message_valid` | Not exposed in current code | Add shadow flag in context structure |
| `chunk_phase` (INIT vs. CONTINUATION) | Inferred from code path | Derive from `chunk_seq_no == 0` vs. `> 0` |
| `seq_no_wrap_error` | Version-dependent behavior | Infer from SPDM negotiated version |

### Concurrency Notes

- **Single-threaded**: libspdm responder is single-threaded event loop; no thread interleaving.
- **Per-context state**: Each `libspdm_context_t` has independent chunk state; if multiple contexts exist, instrument each.

### Bootstrap / Initial State

- `Init` assumes no active chunking.
- Trace should begin with idle state; first event is ChunkSendInit.

### Error Conditions

- Checksum failures, format errors, capacity violations all map to `ErrorDuringReassembly`.
- Capture error classification (optional) for debugging, but trace validation treats all errors uniformly.

### Version Handling

- SPDM version is negotiated before chunking (outside analysis scope).
- Assume version is fixed for a single trace; capture in init event or as constant.
- Version determines:
  - seq_no width (16-bit vs. 32-bit)
  - Wrap-error behavior (SPDM 1.2/1.3 vs. 1.4+)

---

## Instrumentation Implementation Checklist

- [ ] Add shadow flag `large_message_valid` to `libspdm_context.chunk_send_context`
- [ ] Add trace event emission at 6 points: ChunkSendInit (line 156), ChunkSendContinuation (line 193), ReceiveInterruption (line 561, 582), ErrorDuringReassembly (line 250), RequesterSendChunk, ResponderProcessChunk
- [ ] Define `TRACE_EVENT` macro / function to emit JSON lines
- [ ] Verify state capture includes all fields from Section 1
- [ ] Test with simple scenario: 2-chunk transfer, then single chunk, verify trace format
- [ ] Run harness-generation phase to produce actual traces for validation

---

## Trace File Format Example

```jsonl
{"eventName":"ChunkSendInit","timestamp":"2026-06-04T12:00:00.000Z","nodeId":"responder","state":{"chunk_context":{"send":true,"get":false,"seq_no":0,"bytes_transferred":0},"large_message_size":512,"large_message_valid":true,"chunk_phase":"INIT","seq_no_wrap_error":true},"message":{}}
{"eventName":"RequesterSendChunk","timestamp":"2026-06-04T12:00:00.001Z","nodeId":"requester","state":{"chunk_context":{"send":true,"seq_no":0}},"message":{"type":"CHUNK_SEND","seq_no":0,"payload_size":256}}
{"eventName":"ResponderProcessChunk","timestamp":"2026-06-04T12:00:00.002Z","nodeId":"responder","state":{"chunk_context":{"send":true,"seq_no":0,"bytes_transferred":256}},"message":{"type":"CHUNK_SEND_ACK","offset":256}}
{"eventName":"RequesterSendChunk","timestamp":"2026-06-04T12:00:00.003Z","nodeId":"requester","state":{"chunk_context":{"send":true,"seq_no":1}},"message":{"type":"CHUNK_SEND","seq_no":1,"payload_size":256}}
{"eventName":"ChunkSendContinuation","timestamp":"2026-06-04T12:00:00.004Z","nodeId":"responder","state":{"chunk_context":{"send":true,"seq_no":1,"bytes_transferred":512},"chunk_phase":"CONTINUATION"},"message":{}}
```

---

## See Also

- **Base Spec**: `base.tla` — core protocol logic
- **Trace Spec**: `Trace.tla` — event matching and validation
- **Modeling Brief**: `../modeling-brief.md` — bug families and evidence
- **SPDM Specification**: DSP0274 v1.3, §23.3 (chunked transfer)

