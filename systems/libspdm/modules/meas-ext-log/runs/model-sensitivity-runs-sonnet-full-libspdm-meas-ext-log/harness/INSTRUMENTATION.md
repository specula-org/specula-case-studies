# Instrumentation Guide

## Overview

This harness instruments 3 libspdm source files to emit NDJSON trace events for TLA+
trace validation of the SPDM MEL paged-transfer protocol.

## Files Modified

### 1. `library/spdm_requester_lib/libspdm_req_negotiate_algorithms.c`

**Emit point**: After line ~727 (end of if/else block), inside `libspdm_try_negotiate_algorithms`.

**Event**: `negotiate_algorithms` — captures `mel_spec_wire`, `mel_spec_conn`,
`has_session_cap`, `conn_state`.

**Where to adjust**: Search for `tla_emit_negotiate_algorithms` in the file.
To move capture of `mel_spec_wire` earlier, see the line `mel_spec_wire = spdm_response->mel_specification_sel;` near line 441.

### 2. `library/spdm_requester_lib/libspdm_req_get_measurement_extension_log.c`

**Emit point 1** (send events): After `spdm_request_size = sizeof(...)` in the do-while loop,
before `LIBSPDM_DEBUG`. Gated on `spdm_request->offset == 0` vs `> 0`.

**Events**: `send_get_mel_first_chunk`, `send_get_mel_next_chunk`

**Emit point 2** (process events): After `mel_size_internal += spdm_response->portion_length`,
inside the do-while loop.

**Events**: `process_mel_first_chunk_resp`, `process_mel_next_chunk_resp`

**Where to adjust**: Search for `tla_emit_send_get_mel` or `tla_emit_process_mel` in the file.

### 3. `library/spdm_responder_lib/libspdm_rsp_measurement_extension_log.c`

**Emit point 1** (generation tracking + mel_update): Before and after `libspdm_measurement_extension_log_collection` call. Resets `g_mel_generation_counter = 0` on offset=0, increments on offset>0, then emits `mel_update`.

**Emit point 2** (respond events): After `spdm_response->remainder_length = ...`, gated on offset == 0.

**Events**: `mel_update`, `respond_get_mel_first_chunk`, `respond_get_mel_next_chunk`

**Where to adjust**: Search for `g_mel_generation_counter` or `tla_emit_respond_get_mel` in the file.

## Trace Module

**`harness/src/tla_trace.h`** — Header included by all instrumented files.

**`harness/src/tla_trace.c`** — Implements all emit functions. Key globals:
- `g_tla_trace_file` — FILE* for current trace; set to NULL when no tracing active
- `g_tla_seq` — monotonic event counter
- `g_mel_generation_counter` — tracks HAL call generation across chunk requests

## Adding a New Field to an Event

1. Add the field parameter to the emit function signature in `tla_trace.h`
2. Add a `%...` format spec and argument to the `fprintf` call in `tla_trace.c`
3. Pass the new value at each call site in the instrumented library file
4. Add the field mapping to `Trace.tla` (e.g., `/\ new_field' = TraceLog[l].new_field`)

## Adding a New Event Type

1. Add a new `tla_emit_*` function in `tla_trace.h` and `tla_trace.c`
2. Add the call site in the appropriate library file
3. Add a `TraceNewAction` wrapper in `Trace.tla` and include it in `TraceNext`

## Rebuilding After Changes

```bash
# Re-apply instrumentation (idempotent):
bash harness/apply.sh

# Rebuild only the test binary (fast, ~10s):
cmake --build artifact/libspdm/build --target test_mel_trace -- -j$(nproc)

# Run trace scenarios:
artifact/libspdm/build/bin/test_mel_trace traces/

# Full rebuild + run:
bash harness/run.sh
```

## Scenarios and Expected Event Counts

| Trace file | Scenarios | Events |
|---|---|---|
| `trace_negotiate_no_session_cap.ndjson` | negotiate_algorithms, no PSK/KEY_EX | 1 |
| `trace_negotiate_session_cap.ndjson` | negotiate_algorithms, PSK cap set | 1 |
| `trace_single_chunk.ndjson` | Single-chunk MEL transfer (MEL=63B, chunk_size=4596B) | 3 |
| `trace_multi_chunk.ndjson` | 6-chunk transfer with mel_update (MEL=63B, chunk_size=12B) | 23 |

**Total**: 28 events across 4 trace files. All 8 event types covered.

## Troubleshooting

**Build error: `tla_trace.h` not found**: Run `bash harness/apply.sh` to copy it to `artifact/libspdm/include/`.

**`test_mel_trace` fails with status 0x4**: Likely a context setup error. Check `has_session_cap` flags and algorithm settings in `mel_trace_test.c`.

**Missing events in trace**: Check `g_tla_trace_file != NULL` at the emit point. Ensure `tla_trace_open(path)` was called before `libspdm_get_measurement_extension_log`.

**mel_generation off by one**: Check the `g_mel_generation_counter` reset at `offset == 0` in `libspdm_rsp_measurement_extension_log.c`.
