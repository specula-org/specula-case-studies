# Instrumentation Guide — libspdm GET_MEASUREMENTS

Quick reference for the Phase 3 agent to adjust instrumentation when trace validation reveals issues.

---

## How to apply and rebuild

```bash
# 1. Apply instrumented sources + create test directory
bash harness/apply.sh

# 2. Build (from repo root)
cd artifact/libspdm/build
ninja spdm_trace_test

# 3. Run and collect traces
cd artifact/libspdm/build/bin
./spdm_trace_test /path/to/traces/
```

Or run everything in one shot:
```bash
bash harness/run.sh
```

After editing a patched source file in `harness/patches/src/`, re-run `bash harness/apply.sh`
and then rebuild. The patch copies overwrite the artifact sources directly.

---

## Instrumentation point locations

All paths below are relative to `artifact/libspdm/` (equivalently `harness/patches/src/`).

| Event | File (patches/src/) | Line | Trigger |
|-------|---------------------|------|---------|
| `negotiate_version` | `libspdm_rsp_algorithms.c` | 1148 | After `connection_state = NEGOTIATED` in `libspdm_return_algorithms` |
| `reset_context` | `libspdm_com_context_data.c` | 2983 | At return of `libspdm_reset_context` |
| `need_resync` | `libspdm_rsp_handle_response_state.c` | 24 | Entry of `NEED_RESYNC` branch in `libspdm_check_response_state` |
| `responder_generate_signature` | `libspdm_rsp_measurements.c` | 54 | After `libspdm_reset_message_m` in `libspdm_generate_measurement_signature` |
| `l1l2_computation_failure` | `libspdm_rsp_measurements.c` | 68 | Inside `if (!result)` branch after L1/L2 calculation failure |
| `responder_append_request` | `libspdm_rsp_measurements.c` | 546 | After request appended to `message_m` in `libspdm_get_response_measurements` |
| `responder_build_response` | `libspdm_rsp_measurements.c` | 577 | After response appended to `message_m` (before signature generation) |
| `requester_send_get_measurements` | `libspdm_req_get_measurements.c` | 379 | Before `libspdm_send_spdm_request` in `libspdm_try_get_measurement` |
| `requester_parse_response_sig` | `libspdm_req_get_measurements.c` | 574 | After all size checks in the `generate_signature` branch |
| `requester_verify_signature` | `libspdm_req_get_measurements.c` | 614 | After `libspdm_reset_message_m` on successful signature verification |
| `requester_parse_response_nosig` | `libspdm_req_get_measurements.c` | 722 | After nonce and opaque reads in the no-signature branch |
| `complete_exchange` | `libspdm_req_get_measurements.c` | 851 | Just before `libspdm_release_receiver_buffer` / function return |

---

## Adding a field to an existing event

Each emit call builds `tla_data` and `tla_post` strings via `snprintf`. To add a field:

1. Open the file at the line shown above.
2. Extend the format string and add the corresponding variable to the `snprintf` call.
3. Make sure the new variable is in scope at that point (the surrounding function's locals are available).

Example — adding `num_blocks` to `requester_parse_response_nosig` at line 722:
```c
snprintf(tla_data, sizeof(tla_data),
         "{\"session_id\":%u,\"meas_len\":%u,\"opaque_len\":%u,"
         "\"response_size\":%zu,\"num_blocks\":%u}",
         (unsigned)tla_sid, (unsigned)measurement_record_data_length,
         (unsigned)opaque_length, spdm_response_size,
         (unsigned)number_of_blocks);   /* new field */
```

---

## Adding a new event type

Copy the pattern from any existing emit block. The minimal pattern:

```c
/* TLA+ trace: <event_name> */
{
    char tla_data[128], tla_post[128];
    snprintf(tla_data, sizeof(tla_data), "{\"field\":%u}", (unsigned)some_var);
    snprintf(tla_post, sizeof(tla_post), "{\"state_field\":%u}", (unsigned)ctx_field);
    tla_trace_emit("<event_name>", tla_data, tla_post);
}
```

Rules:
- `tla_data` = pre-action inputs / parameters
- `tla_post` = post-action state snapshot
- Buffer size: 128 bytes is usually enough; bump to 256 if you have many fields
- Event name must match the `IsEvent` predicate in `spec/Trace.tla` exactly

---

## Moving a capture point (before → after)

The trigger column in the table above says whether the emit is before or after the key operation.
To move it, cut and paste the `{ char tla_data[...] ... tla_trace_emit(...); }` block to the
desired position. Nothing else changes — all variables are stack-local and stay in scope within
the same function.

---

## Pair counter (`message_m` pair count)

`tla_trace.c` maintains `g_msg_m_pairs` — a global counter of `{req, resp}` pairs appended to
the global `message_m` transcript. The responder increments it on `responder_append_request` and
resets it on `responder_generate_signature` / `requester_verify_signature` / `reset_context`.

- `tla_trace_incr_pairs()` — increment
- `tla_trace_get_pairs()` — read current value (used in `message_m_global_len` / `message_m_session_len` fields)
- `tla_trace_reset_pairs()` — reset to 0 (called when transcript is cleared)

When session support is added, a per-session counter would be needed; currently only the global
transcript is tracked.

---

## Trace module API (`harness/src/tla_trace.h`)

```c
void tla_trace_init(const char *path);          /* open file */
void tla_trace_emit(const char *event,
                    const char *data_json,
                    const char *post_json);     /* write one NDJSON line */
void tla_trace_fini(void);                      /* flush and close */
void tla_trace_incr_pairs(void);
void tla_trace_reset_pairs(void);
int  tla_trace_get_pairs(void);
```

`tla_trace.h` is installed to `artifact/libspdm/include/` by `apply.sh` and is included at the
top of each instrumented library file via `#include "tla_trace.h"`.

---

## Coverage notes

Events NOT in current traces (not triggered by test scenarios):
- `establish_session` — session establishment path not exercised (no KEY_EXCHANGE in harness)
- `l1l2_computation_failure` — requires injecting a bad cert to force L1/L2 failure

All other events (`negotiate_version`, `reset_context`, `need_resync`,
`responder_generate_signature`, `responder_append_request`, `responder_build_response`,
`requester_send_get_measurements`, `requester_parse_response_sig`, `requester_verify_signature`,
`requester_parse_response_nosig`, `complete_exchange`) appear in at least one trace file.
