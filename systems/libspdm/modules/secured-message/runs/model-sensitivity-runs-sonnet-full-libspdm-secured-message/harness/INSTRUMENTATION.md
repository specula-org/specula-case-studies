# Instrumentation Guide (Phase 3)

## Overview

The harness instruments `libspdm` secured-message encode/decode and session-key management code
to emit NDJSON trace events for TLA+ trace validation.

## Files Modified / Added

| File (relative to `artifact/libspdm/`) | Purpose |
|---|---|
| `include/internal/spdm_tla_trace.h` | Trace module API (conditional on `SPDM_TLA_TRACE_ENABLE`) |
| `unit_test/test_spdm_secured_message/spdm_tla_trace.c` | Trace module implementation |
| `unit_test/test_spdm_secured_message/test_tla_scenarios.c` | Test scenarios (4 scenarios) |
| `library/spdm_secured_message_lib/libspdm_secmes_encode_decode.c` | encode/decode events |
| `library/spdm_secured_message_lib/libspdm_secmes_session.c` | epoch tracking hooks |
| `library/spdm_secured_message_lib/CMakeLists.txt` | `-DSPDM_TLA_TRACE` build option |
| `unit_test/test_spdm_secured_message/CMakeLists.txt` | Add trace sources, pthread, define |
| `unit_test/test_spdm_secured_message/test_spdm_secured_message.c` | Call `libspdm_tla_trace_scenarios_main()` |

## Instrumentation Points

### `libspdm_secmes_encode_decode.c`

| Event | Location (function) | Notes |
|---|---|---|
| `encode_advance_seq` | `libspdm_encode_secured_message`, after seq++ | `state.seq` = post-increment |
| `encode_success` | `libspdm_encode_secured_message`, before `return SUCCESS` | Only ESTABLISHED state |
| `decode_increment_seq` | `libspdm_decode_secured_message`, after seq++ | Fires before any validation |
| `decode_session_id_fail` | `libspdm_decode_secured_message`, ENC_MAC session_id check | seq already incremented |
| `decode_aead_fail_backup` | `libspdm_decode_secured_message`, ENC_MAC+MAC_ONLY AEAD fail path | `backup_valid=true` branch |
| `decode_aead_fail` | `libspdm_decode_secured_message`, ENC_MAC+MAC_ONLY AEAD fail path | `backup_valid=false` branch |
| `decode_success` | `libspdm_decode_secured_message`, after AEAD success | ENC_MAC and MAC_ONLY paths |

### `libspdm_secmes_session.c`

| Hook | Location | Effect on trace state |
|---|---|---|
| `spdm_tla_on_create_update(smc, 1)` | After `requester_backup_valid = true` | Bumps `req_active_epoch` |
| `spdm_tla_on_create_update(smc, 0)` | After `responder_backup_valid = true` | Bumps `rsp_active_epoch` |
| `spdm_tla_on_activate_update(smc, is_req, commit)` | End of `libspdm_activate_update_session_data_key` | On rollback: reverts epoch |

## Adding a New Field to an Existing Event

1. Open `spdm_tla_trace.c`, find the `spdm_tla_emit_<event_name>` function.
2. Add the field to the `snprintf` format string and corresponding argument.
3. If the field comes from the `libspdm_secured_message_context_t` struct, read it directly — the struct is available as `libspdm_secured_message_context_t *ctx = smc`.
4. Rebuild: `cmake --build artifact/build_tla_debug --target test_spdm_secured_message -j4`
5. Re-run: `TLA_TRACE_DIR=traces artifact/build_tla_debug/bin/test_spdm_secured_message`

## Adding a New Event Type

1. Add a new `spdm_tla_emit_<name>` function declaration to `spdm_tla_trace.h` (inside `#ifdef SPDM_TLA_TRACE_ENABLE`) and a no-op macro in the `#else` block.
2. Implement the function in `spdm_tla_trace.c`.
3. Add the `#ifdef SPDM_TLA_TRACE_ENABLE` call in the relevant source file.
4. Add a test exercise to `test_tla_scenarios.c` if needed.
5. Rebuild and re-run.

## Moving a Capture Point

Example: move `encode_advance_seq` from before AEAD to after AEAD:
1. Cut the `#ifdef SPDM_TLA_TRACE_ENABLE ... #endif` block from its current location.
2. Paste it at the desired location.
3. Ensure the local variables (`tla_seq`, `session_state`) are still in scope.
4. Rebuild and re-run.

## Rebuild and Re-run After Changes

```bash
# Rebuild debug binary (fast):
cmake --build artifact/build_tla_debug --target test_spdm_secured_message -j$(nproc)

# Re-collect traces:
TLA_TRACE_DIR=traces artifact/build_tla_debug/bin/test_spdm_secured_message

# Or run the full pipeline (configures+builds from scratch):
bash harness/run.sh
```

## Event Coverage by Scenario

| Event | Scenario | Notes |
|---|---|---|
| `encode_advance_seq` | 1, 2, 3, 4 | From instrumented encode function |
| `encode_success` | 1, 2, 3, 4 | From instrumented encode function |
| `decode_increment_seq` | 1, 2, 3, 4 | From instrumented decode function |
| `decode_success` | 1, 2, 3, 4 | From instrumented decode function |
| `decode_session_id_fail` | 1 | From instrumented decode function |
| `decode_aead_fail` | 1 | From instrumented decode function |
| `decode_aead_fail_backup` | 4 | From instrumented decode function |
| `create_update_responder_key` | 3 | Emitted from test code after real `create_update(RESPONDER)` |
| `send_key_update_request` | 2, 3 | Emitted from test code (protocol-level event) |
| `responder_receive_key_update` | 2, 3 | Emitted from test code after real `create_update(REQUESTER)` |
| `requester_receive_key_update_ack` | 2, 3 | Emitted from test code after real `create+activate(REQUESTER)` |
| `responder_receive_verify_new_key` | 2, 3 | Emitted from test code after real `activate(REQUESTER, true)` |
| `responder_try_discard_key_update` | 4 | Emitted from test code after real `activate(REQUESTER, false)` |
| `requester_receive_verify_ack` | 2, 3 | Emitted from test code (protocol-level event) |
| `encap_create_activate_rsp_key` | — | Not exercised in current tests; requires encap flow |
| `requester_handle_response_not_ready` | — | Not exercised; requires NOT_READY error flow |

## Note on Key-Update Protocol Events

Events like `send_key_update_request`, `responder_receive_key_update`, etc. are emitted from the **test code** (`test_tla_scenarios.c`) rather than from inside `libspdm_req_key_update.c` / `libspdm_rsp_key_update_ack.c`. The state captured in these events is read from the **real library structs** after calling the actual session-management functions.

To exercise these events from inside the real protocol handler code:
- Set up two paired `libspdm_context_t` instances (requester + responder)
- Implement synchronous loopback callbacks: requester's `send_message` calls responder's `libspdm_get_response_key_update` inline
- This will exercise `libspdm_req_key_update.c` and `libspdm_rsp_key_update_ack.c` for all key-update events

The current approach ensures that the **state transitions** (key epoch changes, seq resets) come from the real library functions, which is what the TLA+ trace validation checks.
