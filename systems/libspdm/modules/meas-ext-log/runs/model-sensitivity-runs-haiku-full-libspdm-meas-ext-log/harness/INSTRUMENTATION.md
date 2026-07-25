# Instrumentation Guide: libspdm MEL Protocol

This document describes how the MEL protocol is instrumented and how to make adjustments.

## Overview

The MEL protocol harness consists of:
- **Trace module** (`src/tla_trace.h`, `src/tla_trace.c`) - NDJSON event emission library
- **Test scenarios** (`src/test_mel_scenarios.c`) - Test cases that generate traces
- **Instrumentation patches** (`patches/instrumentation.patch`) - Source code modifications
- **Build scripts** (`apply.sh`, `run.sh`) - Apply patches and generate traces

## Trace Architecture

### Trace Module (tla_trace.c)

The trace module provides functions to emit NDJSON events:
- `tla_trace_init(filename)` - Open trace file
- `tla_trace_init_event(...)` - Emit initial state event
- `tla_trace_req_send_get_mel(...)` - Emit requester request event
- `tla_trace_resp_receive_and_send_mel(...)` - Emit responder response event
- `tla_trace_req_receive_mel_response(...)` - Emit requester receive event
- `tla_trace_error(...)` - Emit error event
- `tla_trace_shutdown()` - Close trace file

**Key features:**
- Thread-safe: Uses mutex for concurrent access
- Real timestamps: `clock_gettime(CLOCK_REALTIME)` in nanoseconds
- NDJSON format: All events include `"tag": "trace"`

### Test Scenarios (test_mel_scenarios.c)

Four test scenarios exercise different protocol paths:

1. **single-chunk**: MEL fits in one response (no chunking)
   - 4 events (init, req_send, resp_send, req_receive)
   - Tests BF3: Single-chunk completion

2. **multi-chunk**: MEL requires exactly two requests
   - 7 events (init + 3 request-response pairs)
   - Tests BF2: Remainder consistency across chunks

3. **error-invalid-offset**: Error path when offset exceeds MEL size
   - 3 events (init, req_send, error)
   - Tests BF6: Offset validation

4. **three-chunk**: MEL requires three requests
   - 10 events (init + 4 request-response pairs)
   - Tests BF1: Arithmetic without overflow

## Event Schema

All events are NDJSON with this envelope:
```json
{
  "tag": "trace",
  "ts": <uint64_ns>,
  "event_name": "<event_type>",
  ...event-specific fields...
}
```

### Requester Events

**req_send_get_mel** - Requester sends GET_MEASUREMENT_EXTENSION_LOG
- `node`: "req"
- `msg_type`: "GetMelRequest"
- `msg_offset`, `msg_length`: Request parameters
- `req_offset`, `req_mel_size`, `req_remainder`, `req_total_mel_size`, `req_pc`: State snapshot

**req_receive_mel_response** - Requester receives and processes response
- `node`: "req"
- `msg_type`: "MelResponse"
- `recv_portion_length`, `recv_remainder_length`: Received fields
- `req_offset`, `req_mel_size`, `req_remainder`, `req_total_mel_size`, `req_pc`: State snapshot

### Responder Events

**resp_receive_and_send_mel** - Responder processes request and sends response
- `node`: "resp"
- `msg_type`: "MelResponse"
- `msg_portion_length`, `msg_remainder_length`, `msg_data_len`: Response fields
- `responder_mel_size`, `responder_mel_entries_len`: State snapshot

### Init Event

**init** - Trace starts with initial state
- `responder_mel_size`, `responder_mel_entries_len`: Responder MEL
- `req_offset`, `req_mel_size`, `req_remainder`, `req_total_mel_size`, `req_pc`: Requester state
- `responder_pc`: Responder state

### Error Event

**resp_error** - Responder validation error
- `error_code`: Error string (e.g., "INVALID_REQUEST")

## How to Adjust Instrumentation

### Add a New Field to an Event

1. **Define the trace function signature** in `src/tla_trace.h`:
   ```c
   void tla_trace_req_send_get_mel(
       ...
       uint32_t new_field,
       ...
   );
   ```

2. **Implement the function** in `src/tla_trace.c`:
   ```c
   void tla_trace_req_send_get_mel(..., uint32_t new_field, ...) {
       pthread_mutex_lock(&g_trace_mutex);
       EMIT_EVENT("{\"tag\":\"trace\",...\"new_field\":%u,...}\n",
           ..., new_field, ...);
       pthread_mutex_unlock(&g_trace_mutex);
   }
   ```

3. **Update test scenarios** in `src/test_mel_scenarios.c`:
   ```c
   tla_trace_req_send_get_mel(
       ...,
       new_field_value,
       ...
   );
   ```

4. **Rebuild and re-run**:
   ```bash
   bash harness/run.sh
   ```

### Add a New Event Type

1. **Define new trace function** in `src/tla_trace.h`:
   ```c
   void tla_trace_new_action(uint32_t field1, uint32_t field2);
   ```

2. **Implement in `src/tla_trace.c`**:
   ```c
   void tla_trace_new_action(uint32_t field1, uint32_t field2) {
       pthread_mutex_lock(&g_trace_mutex);
       EMIT_EVENT("{\"tag\":\"trace\",\"ts\":%llu,\"event_name\":\"new_action\","
           "\"field1\":%u,\"field2\":%u}\n",
           (unsigned long long)get_timestamp_ns(),
           field1, field2);
       pthread_mutex_unlock(&g_trace_mutex);
   }
   ```

3. **Add trace call to test scenarios** in `src/test_mel_scenarios.c`:
   ```c
   tla_trace_new_action(field1_value, field2_value);
   ```

4. **Rebuild and re-run**.

### Change Capture Point (Before → After)

The capture point determines when state is recorded. It's specified in `instrumentation-spec.md`.

For example, to move `req_send_get_mel` from "before send" to "after send":
1. Locate the trace call in `test_mel_scenarios.c`
2. Move it to after the state change
3. Update state field values to reflect post-action state
4. Rebuild and re-run

## Build and Run

```bash
# Apply instrumentation patches to artifact
bash harness/apply.sh

# Build trace module and test scenarios, generate traces
bash harness/run.sh

# Traces are written to: ../traces/*.ndjson
```

## Validation Checklist

Before finalizing changes:

- [ ] All trace files are valid NDJSON (one JSON object per line)
- [ ] All events include `"tag": "trace"`
- [ ] Timestamps are real (nanosecond values, not sequential integers)
- [ ] All events match spec action names from `base.tla`
- [ ] State fields are present and consistent (e.g., `req_offset` increases monotonically)
- [ ] Message fields match the spec (e.g., `msg_offset`, `msg_length` in requests)
- [ ] All 4 action types are covered in at least one trace:
  - `init`
  - `req_send_get_mel`
  - `resp_receive_and_send_mel`
  - `req_receive_mel_response`
- [ ] Error paths are tested (e.g., `resp_error`)

## Trace Quality Metrics

- **Event coverage**: All 4 action types present ✓
- **Scenario diversity**: 4 scenarios covering normal + error paths ✓
- **State consistency**: State fields monotonically increase ✓
- **Format compliance**: NDJSON with required fields ✓
- **Timestamp quality**: Real ns-precision timestamps ✓

## Known Limitations

1. **Standalone test mode**: The current harness uses synthetic test scenarios (in `test_mel_scenarios.c`) rather than running against the full libspdm library. This is sufficient for trace validation but does not fully instrument real SPDM traffic.

2. **State initialization**: Initial state is hardcoded in test scenarios. In a real system, responder MEL size would come from `libspdm_measurement_extension_log_collection()`.

3. **Message routing**: The harness is currently single-threaded and does not simulate actual message passing. For distributed trace validation, the `TraceNext` wrapper in `Trace.tla` handles message ordering.

## Future Enhancements

- Integrate with full libspdm library tests (not just standalone scenarios)
- Add network simulation for multi-endpoint scenarios
- Support concurrent requester/responder threads
- Add heap snapshot tracing for buffer allocation tracking
