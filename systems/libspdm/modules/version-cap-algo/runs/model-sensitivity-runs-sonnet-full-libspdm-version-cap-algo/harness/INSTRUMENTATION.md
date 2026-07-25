# Instrumentation Guide

This document describes the TLA+ trace instrumentation for Phase 3 reference.
All 12 trace events defined in `spec/instrumentation-spec.md` are emitted.

## Files

### Trace API
- `harness/src/tla_trace.h` — function declarations and `TLA_ALG_*` masks
- `harness/src/tla_trace.c` — NDJSON emit implementations

`apply.sh` copies these to:
- `artifact/libspdm/include/tla_trace.h`
- `artifact/libspdm/library/spdm_common_lib/tla_trace.c`

### Test program
- `harness/src/test_vca.c` — 4 test scenarios (loopback transport)

`apply.sh` copies this to:
- `artifact/libspdm/unit_test/test_vca_trace/test_vca_trace.c`

### Instrumented libspdm sources (in `artifact/libspdm/`)
All trace calls are wrapped in `#ifdef TLA_TRACE_ENABLED`.

---

## Emission points

### `library/spdm_requester_lib/libspdm_req_get_version.c`

**`req_send_get_version`** — fires just before `libspdm_send_spdm_request()`,
after the GET_VERSION request struct is fully constructed.
Connection state at this point: `NOT_STARTED`.

**`req_handle_version`** — fires right after
`connection_state = LIBSPDM_CONNECTION_STATE_AFTER_VERSION` is set.
Connection state: `AFTER_VERSION`.

---

### `library/spdm_responder_lib/libspdm_rsp_version.c`

**`rsp_handle_get_version`** — fires right after
`libspdm_set_connection_state(spdm_context, LIBSPDM_CONNECTION_STATE_AFTER_VERSION)`.
`offered_version` = `spdm_response->version_number_entry[0] >> SPDM_VERSION_NUMBER_SHIFT_BIT`.
Connection state: `AFTER_VERSION`.

---

### `library/spdm_requester_lib/libspdm_req_get_capabilities.c`

**`req_send_get_capabilities`** — fires just before `libspdm_send_spdm_request()`,
after the GET_CAPABILITIES request struct is fully constructed.
`req_cap_flags` = `spdm_request->flags`.
Connection state: `AFTER_VERSION`.

**`req_handle_capabilities`** — fires right after
`connection_state = LIBSPDM_CONNECTION_STATE_AFTER_CAPABILITIES`.
`rsp_cap_flags` = `spdm_context->connection_info.capability.flags` (the masked responder flags
stored by `libspdm_mask_capability_flags`).
Connection state: `AFTER_CAPS`.

---

### `library/spdm_responder_lib/libspdm_rsp_capabilities.c`

**`rsp_error_capabilities`** — fires in the error path where
`libspdm_build_response_error` fails (transcript overflow before response append).
Connection state: `AFTER_VERSION`.

**`rsp_handle_get_capabilities`** — fires right after
`libspdm_set_connection_state(spdm_context, LIBSPDM_CONNECTION_STATE_AFTER_CAPABILITIES)`.
- `req_cap_flags` = `spdm_context->connection_info.capability.flags` (requester's flags,
  stored at line 463 in the vanilla source)
- `rsp_cap_flags` = `spdm_response->flags` (responder's masked flags set at line 325)
Connection state: `AFTER_CAPS`.

---

### `library/spdm_requester_lib/libspdm_req_negotiate_algorithms.c`

**`req_send_negotiate_algorithms`** — fires just before `libspdm_send_spdm_request()`,
after `spdm_request_size = spdm_request->length`.
`req_alg_types` mask derived by walking `spdm_request->struct_table[0..param1]`
and ORing the appropriate `TLA_ALG_*` bit per `alg_type`.
Stride: `sizeof(struct_table_t) + sizeof(uint32_t) * (alg_count & 0xF)`.
Connection state: `AFTER_CAPS`.

**`req_handle_algorithms`** — fires right after
`connection_state = LIBSPDM_CONNECTION_STATE_NEGOTIATED`.
Algorithm fields from `spdm_context->connection_info.algorithm.*`.
`rsp_alg_types` mask from walking `spdm_response->struct_table`.
Connection state: `NEGOTIATED`.

---

### `library/spdm_responder_lib/libspdm_rsp_algorithms.c`

**`rsp_error_algorithms`** — fires in the error path where response append fails.
Connection state: `AFTER_CAPS`.

**`rsp_handle_negotiate_algorithms`** — fires right after
`libspdm_set_connection_state(spdm_context, LIBSPDM_CONNECTION_STATE_NEGOTIATED)`.
All algorithm fields from `spdm_context->connection_info.algorithm.*`.
`rsp_alg_types` mask from walking `spdm_response->struct_table`.
Connection state: `NEGOTIATED`.

---

### `context_reset`
NOT emitted from `libspdm_reset_context` (which is called internally by
`libspdm_try_get_version` at the start of every GET_VERSION, which would emit
spurious events). Instead, the test program calls `tla_trace_context_reset(conn_state)`
explicitly before any user-triggered `libspdm_reset_context` call.

---

## Build

```bash
# Apply harness files to libspdm source tree
bash harness/apply.sh

# Configure and build (mbedtls required as a submodule or system install)
cmake -S artifact/libspdm -B build/tla_trace \
    -DARCH=x64 -DTOOLCHAIN=GCC -DTARGET=Debug -DCRYPTO=mbedtls \
    -DTLA_TRACE_ENABLED=ON -DDISABLE_TESTS=0 \
    -DCMAKE_C_FLAGS="-DTLA_TRACE_ENABLED=1" -GNinja
cmake --build build/tla_trace --target test_vca_trace

# Run and collect traces
mkdir -p traces
build/tla_trace/bin/test_vca_trace traces/
```

See `harness/run.sh` for the automated version.

---

## Adjusting instrumentation

**To add a field to an event**: edit the corresponding `tla_trace_*` function in
`harness/src/tla_trace.c`, update the declaration in `harness/src/tla_trace.h`,
re-run `apply.sh`, and rebuild.

**To move an emission point**: find the `#ifdef TLA_TRACE_ENABLED` block in the
relevant source file (listed above) and move it to the desired location.

**To add a new event**: declare a new `tla_trace_*` function in `tla_trace.h`,
implement it in `tla_trace.c`, add the `#ifdef` block in the appropriate source
file, and re-run `apply.sh`.

---

## Trace format quick reference

```json
{"tag":"trace","ts":1234567890,"event":"req_send_get_version","conn_state":"NOT_STARTED",...}
```

- `"tag":"trace"` is MANDATORY on every line (required by `Trace.tla`).
- `"ts"` is nanosecond timestamp from `CLOCK_MONOTONIC`.
- `"conn_state"` is one of: `"NOT_STARTED"`, `"AFTER_VERSION"`, `"AFTER_CAPS"`, `"NEGOTIATED"`.
- Cap flags: JSON arrays like `["CERT_CAP","CHAL_CAP"]`.
- Alg types: JSON objects like `{"ALG_DHE":false,"ALG_AEAD":false,...}`.
- Algorithm scalars: raw `uint32_t` (non-zero → `ALGO_SOME`, zero → `ALGO_NONE`).
