# Instrumentation Guide

Brief reference for Phase 3 (spec validation) to adjust instrumentation.

## Files modified

After applying `patches/instrumentation.patch`:

| File | Purpose |
|------|---------|
| `include/tla_trace.h` | New — header-only trace emission library |
| `library/spdm_requester_lib/libspdm_req_psk_exchange.c` | `SendPskExchange` + `RecvPskExchangeRsp` |
| `library/spdm_responder_lib/libspdm_rsp_psk_exchange_rsp.c` | `GetResponsePskExchange` |
| `library/spdm_requester_lib/libspdm_req_psk_finish.c` | `SendPskFinish` + `RecvPskFinishRsp` |
| `library/spdm_responder_lib/libspdm_rsp_receive_send.c` | `GetResponsePskFinish` (dispatch layer) |
| `unit_test/test_spdm_psk_trace/psk_trace_test.c` | New — two-context integration test |
| `unit_test/test_spdm_psk_trace/CMakeLists.txt` | New — build config |

## Instrumentation points (file:approx_line after apply)

### SendPskExchange
- File: `library/spdm_requester_lib/libspdm_req_psk_exchange.c`
- Trigger: after `libspdm_send_spdm_request()` returns SUCCESS (before `libspdm_release_sender_buffer`)
- Look for: `tla_emit_send_psk_exchange(`
- `session_id` is the raw `req_session_id` (16-bit, cast to uint32) — the full 32-bit ID isn't assigned yet

### GetResponsePskExchange
- File: `library/spdm_responder_lib/libspdm_rsp_psk_exchange_rsp.c`
- Trigger: just before `return LIBSPDM_STATUS_SUCCESS` at end of function
- Look for: `tla_emit_get_response_psk_exchange(`
- `session_version` = `sm_->secured_message_version` (from `libspdm_assign_session_id`)
- `negotiated_version` = `secured_message_version` local variable (call-2 value)
- `has_opaque` = `spdm_request->opaque_length != 0`

### RecvPskExchangeRsp
- File: `library/spdm_requester_lib/libspdm_req_psk_exchange.c`
- Trigger: after `session_info->heartbeat_period = ...` assignment, before `status = LIBSPDM_STATUS_SUCCESS`
- Look for: `tla_emit_recv_psk_exchange_rsp(`

### SendPskFinish
- File: `library/spdm_requester_lib/libspdm_req_psk_finish.c`
- Trigger: after `libspdm_send_spdm_request()` returns SUCCESS (before `libspdm_reset_message_buffer`)
- Look for: `tla_emit_send_psk_finish(`

### GetResponsePskFinish
- File: `library/spdm_responder_lib/libspdm_rsp_receive_send.c`
- Trigger: in `SPDM_PSK_FINISH_RSP` case, after `libspdm_set_session_state(ESTABLISHED)`
- Look for: `tla_emit_get_response_psk_finish(`

### RecvPskFinishRsp
- File: `library/spdm_requester_lib/libspdm_req_psk_finish.c`
- Trigger: after `libspdm_secured_message_set_session_state(ESTABLISHED)`
- Look for: `tla_emit_recv_psk_finish_rsp(`

## How to add a field to an event

1. Open `include/tla_trace.h`
2. Find the relevant `tla_emit_*` function (e.g., `tla_emit_send_psk_finish`)
3. Add a parameter and extend the `snprintf` format string
4. Update the call site in the instrumented source file

## How to move a capture point

The instrumented code looks like:
```c
/* TRACE: EventName */
{
    libspdm_secured_message_context_t *sm_ = ...;
    tla_emit_*(session_id, ...);
}
```
Move the entire `/* TRACE: ... */ { ... }` block to the new location.

## How to rebuild and re-run

```bash
cd /path/to/libspdm-psk-exchange
bash harness/run.sh
```

Or to skip the cmake configure step:
```bash
cmake --build artifact/build --target test_spdm_psk_trace -j$(nproc)
TLA_TRACE_DIR=traces artifact/build/bin/test_spdm_psk_trace  # path may vary
```

## Notes

- `FinalOpaqueWrite` is NOT instrumented — it fires only on the non-default opaque callback path (when `libspdm_psk_exchange_rsp_opaque_data` returns true). The default test path uses the library's own opaque data builder. To instrument it, add an emit after the call at line ~432 in `libspdm_rsp_psk_exchange_rsp.c` (the else branch inside the `if (spdm_request->opaque_length != 0)` block).

- `session_id` in `SendPskExchange` is the requester's 16-bit `req_session_id` cast to uint32. This differs from the full 32-bit session ID used in subsequent events (which includes the responder's half). This is because no session exists yet at the time of SendPskExchange.

- Capture levels: All events use **Full** capture (all spec-required fields are present).

- State after `libspdm_secured_message_set_session_state(ESTABLISHED)` clears handshake keys, but `secured_message_version` remains intact in the struct.
