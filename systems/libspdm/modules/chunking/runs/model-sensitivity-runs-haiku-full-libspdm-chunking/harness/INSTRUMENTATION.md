# Instrumentation Guide for libspdm-chunking

This document describes the trace instrumentation for the libspdm chunking protocol and how to adjust it during Phase 3 validation.

## Overview

**System**: libspdm (DMTF SPDM protocol)
**Focus**: Large-message chunking and reassembly (responder-side)
**Trace Module**: `harness/src/tla_trace.*` (C implementation)
**Instrumented Files**:
- `artifact/libspdm/library/spdm_responder_lib/libspdm_rsp_chunk_send_ack.c`
- `artifact/libspdm/library/spdm_responder_lib/libspdm_rsp_receive_send.c`

## Instrumentation Points

### 1. ChunkSendInit (libspdm_rsp_chunk_send_ack.c)

**Location**: After line 158 (after memcpy of first chunk)

**Event**: Emitted when a CHUNK_SEND request initiates a new chunked transfer.

**Trace Call**:
```c
tla_trace_chunk_send_init(
    large_message_size,
    send_info->large_message_capacity,
    spdm_request->chunk_size,
    true,  /* send_active */
    spdm_context->chunk_context.get.chunk_in_use,
    true,  /* large_message_valid */
    libspdm_get_connection_version(spdm_context) < SPDM_MESSAGE_VERSION_14
);
```

**Fields Captured**:
- `large_message_size`: Total declared message size (from request)
- `large_message_capacity`: Available buffer capacity
- `chunk_size`: Size of this chunk
- `send_active`: Indicates chunking is now active
- `get_active`: Whether chunk_get is also active
- `large_message_valid`: Buffer validity flag (should be true on init)
- `seq_no_wrap_error`: SPDM version indicator (1.2/1.3 vs 1.4+)

**Adjustments**:
- To add a field: modify `tla_trace_chunk_send_init()` signature in `tla_trace.h/c` and update JSON output in `tla_trace.c`
- To move capture point: change line number but ensure state is captured *after* `chunk_in_use` is set to true

---

### 2. ChunkSendContinuation (libspdm_rsp_chunk_send_ack.c)

**Location**: After line 210 (after memcpy and seq_no/bytes_transferred update)

**Event**: Emitted when a continuation chunk is received and processed.

**Trace Call**:
```c
tla_trace_chunk_send_continuation(
    chunk_seq_no,
    send_info->chunk_bytes_transferred,
    spdm_request->chunk_size,
    send_info->large_message_size,
    send_info->large_message_capacity,
    true,  /* send_active */
    spdm_context->chunk_context.get.chunk_in_use,
    true,  /* large_message_valid */
    libspdm_get_connection_version(spdm_context) < SPDM_MESSAGE_VERSION_14
);
```

**Fields Captured**:
- `seq_no`: Current sequence number
- `bytes_transferred`: Total bytes accumulated so far
- `chunk_size`: Size of this chunk
- Other fields: Same as ChunkSendInit

**Adjustments**:
- To capture additional chunk-specific data: add parameters to the function signature
- To change capture order: ensure `bytes_transferred` is captured *after* the += operation

---

### 3. ReceiveInterruption (libspdm_rsp_receive_send.c)

**Location**: Before line 582 (before state is cleared)

**Event**: Emitted when a non-chunk command is received during chunking (interrupts the transfer).

**Trace Call**:
```c
tla_trace_receive_interruption(
    "OTHER",  /* cmd_type */
    true,     /* send_active before clear */
    context->chunk_context.get.chunk_in_use,
    context->chunk_context.send.chunk_seq_no,
    context->chunk_context.send.chunk_bytes_transferred,
    context->chunk_context.send.large_message_size,
    true,     /* large_message_valid */
    libspdm_get_connection_version(context) < SPDM_MESSAGE_VERSION_14
);
```

**Fields Captured**:
- `cmd_type`: Type of interrupting command ("OTHER", "GET_VERSION", "DecryptError")
- State snapshot *before* state is cleared

**Key Point**: Capture happens *before* the state-clearing operations, to show the pre-interruption state.

**Adjustments**:
- To improve cmd_type classification: check the request opcode and map to specific types
- To capture post-clear state instead: move trace call to after the state-clearing lines (trades pre vs post state)

---

### 4. ErrorDuringReassembly (libspdm_rsp_chunk_send_ack.c)

**Location**: After line 260 (after state is cleared)

**Event**: Emitted when an error occurs during reassembly and the state is reset.

**Trace Call**:
```c
tla_trace_error_during_reassembly(
    false,  /* send_active after clear */
    spdm_context->chunk_context.get.chunk_in_use,
    0,      /* large_message_size after clear */
    false,  /* large_message_valid - false on error */
    libspdm_get_connection_version(spdm_context) < SPDM_MESSAGE_VERSION_14
);
```

**Fields Captured**:
- State snapshot *after* error handling and state clear
- `large_message_valid = false` indicates error condition

**Key Point**: Capture shows state *after* the error path has cleared the chunking context.

**Adjustments**:
- To distinguish error types: add error code parameter to the function
- To capture pre-error state: add a second trace call before the state-clearing operations

---

## Modifying Instrumentation

### Add a new field to an event

1. **Update tla_trace.h**: Add parameter to function signature
   ```c
   void tla_trace_chunk_send_init(
       uint32_t large_message_size,
       ...
       uint32_t new_field  // <-- add here
   );
   ```

2. **Update tla_trace.c**: 
   - Add to `snprintf()` format string
   - Include new field in JSON output
   - Update captured value

3. **Update instrumentation point**: Pass the new field value
   ```c
   tla_trace_chunk_send_init(
       large_message_size,
       ...,
       some_new_value  // <-- pass here
   );
   ```

4. **Update Trace.tla**: Add validation if needed (see base spec)

### Move a capture point

Find the trace call in the source file and relocate it, being careful about:
- **Timing**: Ensure the value you're capturing is in the correct state (before/after operations)
- **Scope**: Make sure variables are still in scope at the new location
- **Consistency**: Keep related captures together when possible

Example: Moving `ChunkSendContinuation` from after `bytes_transferred +=` to before:
```c
// Before move: After the +=
send_info->chunk_bytes_transferred += spdm_request->chunk_size;
tla_trace_chunk_send_continuation(chunk_seq_no, send_info->chunk_bytes_transferred, ...);

// After move: Before the +=
tla_trace_chunk_send_continuation(chunk_seq_no, send_info->chunk_bytes_transferred, ...);
send_info->chunk_bytes_transferred += spdm_request->chunk_size;
```

### Add a new event type

1. **Create new function** in tla_trace.h and tla_trace.c:
   ```c
   void tla_trace_my_new_event(int param1, int param2) {
       char timestamp[64];
       char event_json[1024];
       
       if (!trace_initialized) return;
       tla_trace_get_timestamp(timestamp, sizeof(timestamp));
       snprintf(event_json, sizeof(event_json),
           "{\"eventName\":\"MyNewEvent\",\"timestamp\":\"%s\",\"nodeId\":\"responder\",...}",
           timestamp, ...);
       emit_event(event_json);
   }
   ```

2. **Add instrumentation point** in source file:
   ```c
   #include "tla_trace.h"
   ...
   tla_trace_my_new_event(value1, value2);
   ```

3. **Update Trace.tla**: Add action wrapper and validation

4. **Test**: Rebuild and verify new event appears in traces

---

## Rebuilding After Instrumentation Changes

After modifying instrumentation:

```bash
cd harness
bash apply.sh  # Recompiles and regenerates traces
```

The apply.sh script will:
1. Copy updated trace module files
2. Rebuild the test harness
3. Run tests and collect new traces

---

## Trace Format

Each line in the trace file is a JSON object with structure:
```json
{
  "eventName": "ChunkSendInit",
  "timestamp": "2026-06-04T12:34:56.789Z",
  "nodeId": "responder",
  "state": {
    "chunk_context": { "send": true, "get": false, "seq_no": 0, ... },
    "large_message_size": 512,
    ...
  },
  "message": { "chunk_size": 256 }
}
```

**Required fields**:
- `eventName`: Must match action name in Trace.tla
- `timestamp`: ISO 8601 format (real timestamps, not synthetic)
- `nodeId`: "responder" (single node for this system)
- `state`: All variables from the base spec
- `message`: Message-specific fields (empty `{}` if none)

---

## Testing

To manually test instrumentation:

```bash
cd harness/build
./test_chunking ../traces/manual_trace.ndjson

# Verify output
cat ../traces/manual_trace.ndjson | head -5
```

Each line should be valid JSON with proper timestamps and state fields.

---

## See Also

- **spec/instrumentation-spec.md** — Detailed action-to-code mapping
- **spec/Trace.tla** — Trace validator spec
- **spec/base.tla** — Base protocol spec
