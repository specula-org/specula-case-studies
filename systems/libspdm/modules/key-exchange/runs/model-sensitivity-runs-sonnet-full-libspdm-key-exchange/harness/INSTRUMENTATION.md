# Instrumentation Guide

Reference for the Phase 3 (validation) agent to adjust trace instrumentation.

---

## Instrumentation Points

All emit calls are guarded by `#ifdef TLA_TRACE_ENABLED`. The header is at
`artifact/libspdm/include/tla_trace.h`.

| Event | File (in artifact/libspdm/) | Line |
|---|---|---|
| `req_send_key_exchange` | `library/spdm_requester_lib/libspdm_req_key_exchange.c` | 533 |
| `rsp_handle_key_exchange` | `library/spdm_responder_lib/libspdm_rsp_key_exchange.c` | 594 |
| `req_send_finish` | `library/spdm_requester_lib/libspdm_req_finish.c` | 538 |
| `rsp_derive_data_keys` | `library/spdm_responder_lib/libspdm_rsp_finish_rsp.c` | 775 |
| `rsp_encode_failure` (F3 path) | `library/spdm_responder_lib/libspdm_rsp_finish_rsp.c` | 748, 760 |
| `rsp_commit_established` (non-HITC) | `library/spdm_responder_lib/libspdm_rsp_receive_send.c` | 782 |
| `rsp_commit_established` (HITC) | `library/spdm_responder_lib/libspdm_rsp_receive_send.c` | 839 |
| `rsp_decode_secured_message` | `library/spdm_secured_message_lib/libspdm_secmes_encode_decode.c` | 660 |

---

## Event Coverage

All 8 instrumented event types appear in at least one trace:
- `req_send_key_exchange` — all 3 traces
- `rsp_handle_key_exchange` — all 3 traces
- `req_send_finish` — all 3 traces
- `rsp_derive_data_keys` — all 3 traces
- `rsp_commit_established` — all 3 traces
- `req_send_app_data` — `app_data.ndjson`
- `rsp_decode_secured_message` — `app_data.ndjson`
- `rsp_encode_failure` — **NOT in traces** (requires fault injection; only triggered
  when `libspdm_calculate_th2_hash` or `libspdm_generate_session_data_key` fails).
  To trigger: inject an error return from one of these functions before line 748 of
  `libspdm_rsp_finish_rsp.c`.

---

## Adding a New Field to an Existing Event

1. Identify the event's macro in `tla_trace.h` (e.g., `TLA_EMIT_RSP_HANDLE_KEY_EXCHANGE`).
2. Add the new parameter to the macro signature and the `fprintf` format string.
3. Add a corresponding `extern` declaration if a new global is needed (update
   `tla_trace_globals.c` to define it).
4. At the call site in the C source, compute the new value and pass it as the extra argument.
5. If the field needs to be validated in `Trace.tla`, add a `ValidateXxx` helper and
   conjunct it into the appropriate `TraceXxx` action.

Example: to add `"cert_chain_size"` to `rsp_handle_key_exchange`, edit
`libspdm_rsp_key_exchange.c:594` and the macro at `tla_trace.h` line ~51.

---

## Adding a New Event Type

Copy the pattern from an existing macro in `tla_trace.h`:
```c
#define TLA_EMIT_MY_NEW_EVENT(session_id, field1, field2) \
    do { if (g_tla_trace_fp) { \
        fprintf(g_tla_trace_fp, \
            "{\"tag\":\"trace\",\"ts\":%llu,\"event\":\"my_new_event\"," \
            "\"session_id\":%d,\"field1\":%d,\"field2\":%s}\n", \
            (unsigned long long)tla_now_ns(), \
            (int)(session_id), (int)(field1), (field2)); \
        fflush(g_tla_trace_fp); \
    }} while(0)
```

Add the no-op variant after `#else`:
```c
#define TLA_EMIT_MY_NEW_EVENT(...)  do {} while(0)
```

---

## Moving a Capture Point (before vs after)

The emit call is a single macro call. Move it earlier (before the operation) or later
(after) by relocating it in the C source. The key constraint: **all fields used as
macro arguments must be in scope at the call site**.

---

## Rebuild and Re-run After Changes

```bash
# From the repo root (libspdm-key-exchange/)
bash harness/apply.sh            # re-copy header + test sources
cd artifact/libspdm
cmake --build build_trace --target trace_test -- -j$(nproc)
cmake --build build_trace --target copy_sample_key
pushd build_trace/bin
./trace_test /path/to/traces/    # re-collect traces
popd
```

After collecting new traces, validate with TLC:
```bash
cd spec
JSON=../traces/<name>.ndjson \
  java -cp /home/ubuntu/Specula/lib/tla2tools.jar:/home/ubuntu/Specula/lib/CommunityModules-deps.jar \
  tlc2.TLC -config Trace.cfg Trace.tla
```

---

## Spec Adjustments Made During Phase 2.5

Two fixes were needed to make TLC trace validation pass:

1. **`spec/base.tla` line 176**: Changed `req_slot \in CertSlots` to
   `req_slot \in 0..MaxCertSlots`. The `MUT_NONE` mode legitimately uses slot 0
   (NO_SLOT), which was outside the original `CertSlots = 1..MaxCertSlots` range.

2. **`spec/Trace.tla`**: All post-state validators (`ValidateSessionState`, etc.) were
   changed to use primed variables (`session_state'`, `latest_session_id'`, etc.)
   so they check the POST-state, not the pre-state. Also added
   `WF_TraceVars(TraceNext)` to `TraceSpec` to suppress spurious liveness
   counterexamples from infinite stuttering.

---

## Key Globals (defined in tla_trace_globals.c)

| Global | Type | Purpose |
|---|---|---|
| `g_tla_trace_fp` | `FILE *` | Trace file handle; `NULL` disables all emits |
| `g_tla_last_session_raw_id` | `uint32_t` | Raw 32-bit session_id of most-recently allocated session; used by `rsp_decode_secured_message` to find TLA+ slot 1 |
