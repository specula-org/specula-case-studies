# Instrumentation Guide: libspdm Encapsulated Mutual Auth

## Overview

This harness instruments three libspdm source files to emit NDJSON trace events
for TLA+ trace validation.  All events carry `"tag":"trace"` and record the
pre/post-action state of the encap context (`cur_op`, `request_id`,
`response_state`).

## Files Modified

| File | Function(s) | Events emitted |
|------|------------|----------------|
| `library/spdm_responder_lib/libspdm_rsp_encap_response.c` | `libspdm_process_encapsulated_response`, `libspdm_get_response_encapsulated_request`, `libspdm_get_response_encapsulated_response_ack`, `libspdm_init_basic_mut_auth_encap_state`, `libspdm_init_mut_auth_encap_state` | `init_encap_state`, `get_encapsulated_request`, `deliver_encap_digests`, `deliver_encap_certificate`, `encap_not_ready`, `encap_error` |
| `library/spdm_requester_lib/libspdm_req_challenge.c` | `libspdm_try_challenge` | `verify_responder` |
| `library/spdm_responder_lib/libspdm_rsp_encap_challenge.c` | `libspdm_process_encap_response_challenge_auth` | `deliver_encap_challenge_auth` |

## Trace Library

`tla_trace.h` is a header-only library gated by `LIBSPDM_TRACE_ENCAP`:

- Define `TLA_TRACE_DEFINE_GLOBALS` in exactly ONE translation unit (the test binary) before including.
- All other TUs that include `tla_trace.h` get `extern` declarations of the globals.
- Set `g_tla_trace_file` to an open `FILE*` before any instrumented code runs.
- Set `g_tla_rsp_ctx` to the Responder's context when the Requester calls `libspdm_challenge`.

## Event Descriptions

### `init_encap_state`
Emitted at the end of `libspdm_init_basic_mut_auth_encap_state` or
`libspdm_init_mut_auth_encap_state`.  The `variant` field encodes the op
sequence (`BASIC_CERT`, `BASIC_PK`, `WITH_ENCAP_REQUEST`, `WITH_GET_DIGESTS`).

### `verify_responder`
Emitted from `libspdm_try_challenge` (Requester side) immediately after
`connection_state = AUTHENTICATED` is set, and only when
`SPDM_CHALLENGE_AUTH_RESPONSE_ATTRIBUTE_BASIC_MUT_AUTH_REQ` is set.
This event is the TLA+ evidence for the Family-2 invariant: the Requester
must NOT allow the Requester to be considered authenticated until the
Responder has verified the Requester (i.e., encap must complete first).

**To capture this event**, the full challenge loopback must be exercised:
call `libspdm_challenge(req_ctx, ...)` with a loopback transport that routes
responses through the Responder context (`rsp_ctx`).  Set `g_tla_rsp_ctx =
rsp_ctx` before the call so the Responder's encap state is emitted.

The current test scenarios (`trace_basic_cert`, `trace_basic_pk`) use the
Responder-direct approach and do NOT emit `verify_responder`.  A future
`trace_with_challenge_loopback` scenario can add it.

### `get_encapsulated_request`
Emitted from `libspdm_get_response_encapsulated_request` after
`libspdm_process_encapsulated_response` returns SUCCESS.  Captures the
state transition as the Responder advances from op-code 0 to the first
op in the sequence.

### `deliver_encap_digests`
Emitted from `libspdm_process_encapsulated_response` after
`libspdm_process_encap_response_digest` returns SUCCESS, `request_id` has
been incremented, and `libspdm_encap_move_to_next_op_code` has run.
`cur_op_after` reflects the next op-code (GET_CERTIFICATE or CHALLENGE).

### `deliver_encap_certificate`
Same timing as `deliver_encap_digests` but only when `need_continue == false`
(full cert chain received).  The `cert_chain_received_after: true` field
signals the TLA+ model that `peer_used_cert_chain` has been populated.

### `deliver_encap_challenge_auth`
Emitted from `libspdm_process_encap_response_challenge_auth` immediately
after `libspdm_set_connection_state(AUTHENTICATED)` and before
`*need_continue = false`.  Hardcodes `cur_op_after=0` and
`response_state_after="NORMAL"` since CHALLENGE is always the last op.

### `encap_not_ready`
Emitted when the Requester responds with `SPDM_ERROR_CODE_RESPONSE_NOT_READY`.
`cur_op_after=0` (op code cleared) and `response_state_after="NORMAL"` (the
caller sets NORMAL via the `encap_request_size == 0` path).

### `encap_error`
Emitted in two error paths:
1. `libspdm_get_response_encapsulated_request`: error processing first DELIVER
2. `libspdm_get_response_encapsulated_response_ack`: error processing subsequent DELIVERs

In BOTH cases, `response_state` has already been set to NORMAL.  The critical
field is `cur_op_after` which captures the op-code LEFT in the context (NOT
cleared on error) — this is the Family-4 invariant violation.

## Running

```bash
# Step 1: apply instrumented sources
harness/apply.sh

# Step 2: configure libspdm with LIBSPDM_TRACE_ENCAP
cd artifact/libspdm
mkdir build && cd build
cmake .. -DARCH=x64 -DTOOLCHAIN=GCC -DTARGET=Debug -DCRYPTO=mbedtls \
         -DDEVICE=sample -DCMAKE_C_FLAGS="-DLIBSPDM_TRACE_ENCAP"

# Step 3: add subdirectory to unit_test/CMakeLists.txt:
echo 'add_subdirectory(test_spdm_tla_trace)' >> unit_test/CMakeLists.txt

# Step 4: build and run
make tla_encap_test
unit_test/test_spdm_tla_trace/tla_encap_test ../../traces/

# Or use the convenience script:
harness/run.sh
```

## Trace file format

Each file contains one JSON object per line (NDJSON).  Every line has:

```json
{
  "tag": "trace",
  "ts": 1234567890,
  "event": "<name>",
  "cur_op": 1,
  "request_id": 0,
  "response_state": "PROCESSING_ENCAP",
  "variant": "BASIC_CERT",
  "resp_authenticated": false,
  "cur_op_after": 1,
  "request_id_after": 0,
  "response_state_after": "PROCESSING_ENCAP"
}
```

Op-code integer mapping:

| Integer | Op | SPDM constant |
|---------|-----|---------------|
| 0 | OP_NONE | (terminator) |
| 1 | OP_GET_DIGESTS | `SPDM_GET_DIGESTS` |
| 2 | OP_GET_CERTIFICATE | `SPDM_GET_CERTIFICATE` |
| 17 (0x11) | OP_CHALLENGE | `SPDM_CHALLENGE` |
