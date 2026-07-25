# Instrumentation Guide

This document describes how the libspdm-psk-exchange source code is instrumented for trace collection and how to modify the instrumentation if needed.

## Overview

The instrumentation captures key protocol state and message fields at critical points in the PSK exchange handshake:
- RequesterSendPskExchange: After the requester builds and sends the PSK_EXCHANGE message
- ResponderRecvPskExchange: After the responder validates the received PSK_EXCHANGE message
- ResponderSendPskExchangeRsp: Before the responder sends the PSK_EXCHANGE_RSP message
- RequesterRecvPskExchangeRsp: After the requester receives and validates the PSK_EXCHANGE_RSP

## Instrumentation Points

### File: artifact/libspdm/library/spdm_requester_lib/libspdm_req_psk_exchange.c

#### Point 1: RequesterSendPskExchange Event (after line 325)
**Location**: After `libspdm_release_sender_buffer()` completes in `libspdm_try_send_receive_psk_exchange()`
**Fields captured**:
- `req_session_id`: Allocated session ID
- `opaque_length`: Size of opaque data in request
- `context_length`: Size of context in request
- `pc`: Set to "sent_psk_exchange"
- `session_state`: Set to "IDLE"
- `allocated_ids`: Array containing the allocated session ID

**How to modify**: 
- To add fields: Edit the `trace_message_fields_t` struct initialization in the emission code
- To change trigger point: Move the entire trace emit block to a different line (e.g., before vs. after message send)

#### Point 2: RequesterRecvPskExchangeRsp Event (after line 508)
**Location**: After `libspdm_assign_session_id()` succeeds in `libspdm_try_send_receive_psk_exchange()`
**Fields captured**:
- `rsp_session_id`: Responder's allocated session ID
- `opaque_length`: Size of opaque data in response
- `context_length`: Size of context in response
- `version_negotiated`: Whether version was negotiated via opaque data
- `opaque_length_checked`: Whether bounds check at line 453 passed
- `pc`: Set to "received_psk_exchange_rsp"
- `session_state`: Set to "HANDSHAKING"

**How to modify**:
- To capture additional bounds check results: Add boolean fields to trace_state_snapshot_t and set them based on validation results
- To capture responder context data: Add fields to trace_message_fields_t

### File: artifact/libspdm/library/spdm_responder_lib/libspdm_rsp_psk_exchange_rsp.c

#### Point 1: ResponderRecvPskExchange Event (after line 342)
**Location**: After opaque data is processed in `libspdm_get_response_psk_exchange()`
**Fields captured**:
- `req_session_id`: From received PSK_EXCHANGE message
- `opaque_length`: Size of opaque data in request
- `context_length`: Size of context in request
- `use_default_opaque`: Whether default opaque data handling was used
- `version_negotiated`: Whether version was negotiated
- `pc`: Set to "recv_psk_exchange"
- `session_state`: Set to "IDLE"
- `opaque_length_checked`: Implicit bounds check (lines 238-241)

**How to modify**:
- To capture opaque data parsing errors: Add error status field to message_fields
- To capture PSK hint: Add psk_hint_length field (already captured)

#### Point 2: ResponderSendPskExchangeRsp Event (before line 586)
**Location**: Before `return LIBSPDM_STATUS_SUCCESS` in `libspdm_get_response_psk_exchange()`
**Fields captured**:
- `rsp_session_id`: Responder's allocated session ID
- `opaque_length`: Size of opaque data in response
- `context_length`: Size of context in response
- `version_negotiated`: Whether version was negotiated
- `use_default_opaque`: Whether default opaque data was used
- `session_id`: The combined session ID (req + rsp)
- `pc`: Set to "sent_psk_exchange_rsp"
- `session_state`: Set to "HANDSHAKING"

**How to modify**:
- To capture measurement hash: Add measurement_summary_hash_size field
- To change state after send: Modify session_state in state snapshot (currently "HANDSHAKING", should move to "ESTABLISHED" for finish message)

## Trace Module

### File: harness/src/tla_trace.h
Defines the data structures for trace events:
- `trace_state_snapshot_t`: Capture of state at event time
- `trace_message_fields_t`: Protocol message fields

### File: harness/src/tla_trace.c
Implements trace emission:
- `tla_trace_init(trace_file)`: Opens trace file for writing
- `tla_trace_emit(...)`: Writes one NDJSON event to file
- `tla_trace_shutdown()`: Closes trace file

Thread-safe via mutex for Category A (no concurrent instrumentation expected).

## Building and Testing

1. Apply instrumentation:
   ```bash
   bash harness/apply.sh
   ```

2. Build trace module and tests:
   ```bash
   bash harness/run.sh
   ```

3. View generated traces:
   ```bash
   cat traces/trace.ndjson | head
   ```

## Troubleshooting

**No traces generated**:
- Check that trace file path is accessible
- Verify `tla_trace_init()` is being called
- Ensure `tla_trace_shutdown()` is called to flush and close file

**Compilation errors**:
- Verify `tla_trace.h` is in the include path (relative path `../../../harness/src/tla_trace.h`)
- Check that pthread library is linked for mutex support

**Missing event types**:
- Each instrumentation point emits one event type
- If an event type is missing from traces, the code path is not being executed by tests
- Add test scenarios that exercise that code path

## Future Enhancements

- Instrument PSK_FINISH and PSK_FINISH_RSP messages (Actions 5-8)
- Add more granular bounds check tracking
- Capture session ID allocation/deallocation (Family 2)
- Add error path tracing for validation failures
