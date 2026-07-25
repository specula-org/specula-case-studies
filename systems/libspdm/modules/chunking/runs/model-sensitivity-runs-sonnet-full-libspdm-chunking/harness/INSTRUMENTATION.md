# Instrumentation Guide

Phase 2.5 adjustment notes for libspdm-chunking.

## Instrumented files

| Source file | Events emitted |
|---|---|
| `library/spdm_responder_lib/libspdm_rsp_chunk_send_ack.c` | `chunk_send_first`, `chunk_send_valid`, `chunk_send_invalid_seq` |
| `library/spdm_responder_lib/libspdm_rsp_chunk_response.c` | `chunk_get_served`, `chunk_get_during_send` |
| `library/spdm_responder_lib/libspdm_rsp_receive_send.c` | `large_response_ready` |
| `library/spdm_requester_lib/libspdm_req_handle_error_response.c` | `large_response_error_received`, `chunk_response_processed_valid`, `chunk_response_source_oob`, `transfer_complete_success`, `transfer_complete_overflow` |

All files include `spdm_trace.h` which is installed by `apply.sh` into `artifact/libspdm/include/`.

## Shadow variables

`libspdm_handle_error_large_response` has no persistent fields for requester-side state.
Four local shadow variables were added at function entry:

```c
bool    harness_last_chunk_received  = false;
bool    harness_output_written       = false;
bool    harness_scratch_zeroed       = false;
size_t  harness_response_capacity    = response_capacity;
```

These are updated in-loop and passed to trace macros so the TLA+ validator can check
`req_state`, `last_chunk_received`, `output_written`, `scratch_zeroed`.

## Family bug coverage

| Family | Bug | Triggering scenario | Event |
|---|---|---|---|
| 2 | seq-no mismatch still advances state | `chunk_send_invalid_seq` | `chunk_send_invalid_seq` |
| 3 | overflow returns SUCCESS | `chunk_get_overflow` | `transfer_complete_overflow` |
| 4 | chunk_size OOB source | `chunk_response_source_oob` | `chunk_response_source_oob` |
| 5 | CHUNK_GET during CHUNK_SEND | `chunk_get_during_send` | `chunk_get_during_send` |

## Adjusting instrumentation

- **Emit point changes**: all trace calls are guarded by `#if` blocks added by patch;
  search for `/* TRACE:` comments in each source file to find them.
- **Adding a new event**: add a macro to `harness/src/spdm_trace.h` following the pattern
  of the existing 11 macros, then add the matching `IsEvent("...")` clause in `Trace.tla`.
- **Changing state fields**: `spdm_trace_emit_core` in `spdm_trace.h` holds the full
  field list; update both the function signature and all call sites.
- **Family 4 OOB injection**: `g_inject_oob_first` in `spdm_stubs.c` controls the
  crafted CHUNK_RESPONSE for the OOB scenario. Adjust `rsp->chunk_size` and `*response_size`
  together to change the OOB margin.

## Running

```
bash harness/run.sh          # produces traces/*.ndjson
bash harness/clean.sh        # removes spdm_trace.h from artifact include
```
