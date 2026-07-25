# Instrumentation Notes — libspdm session lifecycle

## Overview

This harness instruments libspdm 4.0.0 post-handshake session management to emit
NDJSON execution traces for TLA+ trace validation.  The traces cover:
- HEARTBEAT / HEARTBEAT_ACK
- KEY_UPDATE (single direction and all-keys)
- END_SESSION / END_SESSION_ACK

## Architecture

Two SPDM contexts are created in the same process:

- **req_ctx** — requester side; its `send_message` callback routes each outgoing
  message into the real rsp_ctx responder, so both sides' instrumentation fires in
  one logical execution.
- **rsp_ctx** — responder side; allocated with identical initial AEAD session secrets
  (deterministic KDF ensures both contexts derive the same keys independently).

Session secrets are injected directly via `libspdm_session_info_init` rather than
running the full key-exchange handshake.

## Modified files

| File | Events added |
|------|-------------|
| `library/spdm_requester_lib/libspdm_req_key_update.c` | `req_send_update_key`, `req_send_update_all_keys`, `req_recv_key_update_ack`, `req_recv_verify_ack` |
| `library/spdm_responder_lib/libspdm_rsp_key_update_ack.c` | `rsp_recv_update_key`, `rsp_recv_update_all_keys`, `rsp_recv_verify_new_key` |
| `library/spdm_requester_lib/libspdm_req_end_session.c` | `req_send_end_session`, `req_recv_end_session_ack` |
| `library/spdm_responder_lib/libspdm_rsp_end_session_ack.c` | `rsp_recv_end_session` |
| `library/spdm_requester_lib/libspdm_req_heartbeat.c` | `req_send_heartbeat`, `req_recv_heartbeat_ack` |
| `library/spdm_responder_lib/libspdm_rsp_heartbeat.c` | `rsp_recv_heartbeat` |
| `library/spdm_responder_lib/libspdm_rsp_receive_send.c` | `rsp_decode_with_backup_key`, `rsp_encode_end_session_ack_success` |

New files added to artifact/libspdm:
- `include/tla_trace.h` — shared header for `g_tla` state and `TLA_EMIT*` macros
- `unit_test/test_spdm_tla_trace/tla_trace.c` — `tla_state_t` definition and emit impl
- `unit_test/test_spdm_tla_trace/trace_test.c` — three test scenarios
- `unit_test/test_spdm_tla_trace/CMakeLists.txt` — build definition

## Event ordering invariant

`req_send_*` events are emitted **before** calling `libspdm_send_spdm_request`.
This ensures that when the `send_message` callback fires (which routes into the
responder and emits `rsp_recv_*`), the causal order in the trace is correct:
requester-send appears before responder-receive.

## Shadow state counters

libspdm has no integer key-generation counter.  `g_tla.req_tx_gen` and
`g_tla.rsp_rx_gen` are maintained as external shadow counters:

- `req_tx_gen` incremented in `req_recv_key_update_ack` (new TX key activated)
- `rsp_rx_gen` incremented in `rsp_recv_update_key` / `rsp_recv_update_all_keys` /
  `rsp_decode_with_backup_key`

## Building

```
bash harness/run.sh
```

Requirements: GCC, CMake ≥ 3.5, OpenSSL dev (`libssl.a`, `libcrypto.a`).

Override with environment variables:
```
ARCH=x64 TOOLCHAIN=GCC CRYPTO=openssl \
LIBCRYPTO=/path/to/libcrypto.a LIBSSL=/path/to/libssl.a \
bash harness/run.sh
```

## Trace output

Three files in `traces/`:
- `trace_heartbeat.ndjson` — 21 events: 4× heartbeat + 1× key_update_single + end_session
- `trace_key_update_single.ndjson` — 24 events: 4× key_update_single + end_session
- `trace_key_update_all_keys.ndjson` — 24 events: 4× key_update_all_keys + end_session

Each line: `{"tag":"trace","ts":"N","event":"name","state":{...}[,"msg":{...}]}`
