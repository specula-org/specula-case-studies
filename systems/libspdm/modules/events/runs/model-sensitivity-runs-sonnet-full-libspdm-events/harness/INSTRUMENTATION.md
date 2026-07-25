# INSTRUMENTATION.md — Phase 3 Guide

TLA+ trace instrumentation for libspdm SPDM 1.3 event subscription.

## Overview

Instrumentation is 100% guarded by `#ifdef TLA_TRACE_ENABLED` / `#endif` so the
library builds and behaves identically in non-trace mode.  When the flag is set,
each SPDM state transition emits one NDJSON line on stdout with
`"tag":"trace"` so it can be replayed by `spec/Trace.tla`.

## File map

```
harness/
  src/
    tla_trace.h        — emit API: tla_emit_*(…) declarations + state helpers
    tla_trace.c        — emit implementation (writes JSON to stdout)
    tla_scenarios.c    — three test scenarios (cmocka groups)
    tla_trace_main.c   — cmocka test runner entry point
    CMakeLists.txt     — builds test_tla_trace; sets TLA_TRACE_ENABLED for target
  apply.sh             — copies src/ → artifact/unit_test/test_tla_trace/;
                         wires test into unit_test/CMakeLists.txt;
                         injects global TLA_TRACE_ENABLED into top-level CMakeLists.txt
  run.sh               — apply → cmake build → run → report
  INSTRUMENTATION.md   — this file

artifact/libspdm/
  CMakeLists.txt       — TLA_TRACE_ENABLED added globally (before add_subdirectory)
  library/spdm_responder_lib/
    libspdm_rsp_key_exchange.c           — tla_emit_key_exchange()
    libspdm_rsp_receive_send.c           — tla_emit_handle_finish(), tla_emit_terminate_session()
    libspdm_rsp_subscribe_event_types_ack.c — tla_emit_subscribe_event_types()
    libspdm_rsp_event_ack.c              — tla_emit_send_event_version_match/mismatch()
    libspdm_rsp_encap_response.c         — tla_emit_init_encap_send_event()
    libspdm_rsp_encap_send_event.c       — tla_emit_handle_encap_send_event(), tla_emit_process_encap_event_ack()
  os_stub/debuglib/debuglib.c            — ASSERT → EXIT (value 3)

patches/instrumentation.patch           — diff of all artifact changes (for re-applying)
traces/
  happy_path.ndjson                      — 25 events
  encap_flow.ndjson                      — 28 events
  bug_families.ndjson                    — 26 events
spec/Trace.tla                           — TLA+ trace validation spec
```

## Build workflow

```bash
# 1. Copy harness sources into artifact and enable global compile define
bash harness/apply.sh

# 2. Configure (first time only; reuse build dir afterwards)
cmake -S artifact/libspdm -B build \
    -DARCH=x64 -DTOOLCHAIN=GCC -DTARGET=Debug -DCRYPTO=mbedtls \
    -DGCOV=OFF -DDEVICE=sample -DCMAKE_BUILD_TYPE=Debug

# 3. Build only the trace binary
cmake --build build --target test_tla_trace -j$(nproc)

# 4. Run (must cd to sample_key so cert paths resolve)
mkdir -p traces
cd artifact/libspdm/unit_test/sample_key
TLA_TRACES_DIR=$(pwd)/../../../../traces ./../../../../build/bin/test_tla_trace
```

Or simply: `bash harness/run.sh`

## Critical: global TLA_TRACE_ENABLED

The six instrumented library files are compiled as part of `spdm_responder_lib`,
a separate static library target from `test_tla_trace`.  The define **must** be
set at the top-level `CMakeLists.txt` before the `add_subdirectory` calls that
build the library, otherwise all `tla_emit_*` call sites compile out and every
trace has only 1 event (just the cmocka test-start sentinel).

`apply.sh` injects this block into `artifact/libspdm/CMakeLists.txt` if absent:

```cmake
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/unit_test/test_tla_trace/tla_trace.h")
    add_compile_definitions(TLA_TRACE_ENABLED)
    include_directories("${CMAKE_CURRENT_SOURCE_DIR}/unit_test/test_tla_trace")
endif()
```

## Critical: apply.sh before every rebuild

`harness/src/` files are the canonical source.  `apply.sh` copies them to
`artifact/libspdm/unit_test/test_tla_trace/`.  The cmake build uses the **artifact**
copies.  Any edit to `harness/src/*.c` or `harness/src/*.h` must be followed by
`bash harness/apply.sh` before `cmake --build`.

## Instrumentation points

### 1. HandleKeyExchange — `libspdm_rsp_key_exchange.c`

Fires at the end of `libspdm_get_response_key_exchange()` after
`libspdm_set_session_state(…, LIBSPDM_SESSION_STATE_HANDSHAKING)`.

```c
#ifdef TLA_TRACE_ENABLED
{
    bool tla_with_event_all =
        ((spdm_request->header.spdm_version >= SPDM_MESSAGE_VERSION_13) &&
         ((spdm_request->session_policy &
           SPDM_KEY_EXCHANGE_REQUEST_SESSION_POLICY_EVENT_ALL_POLICY) != 0));
    tla_emit_key_exchange(tla_with_event_all);
}
#endif
```

State captured: `session_state=HANDSHAKE`, `subscription_state`, `event_all_policy`,
`subscribe_types_sent`.

### 2. HandleFinish — `libspdm_rsp_receive_send.c`

Fires inside `libspdm_process_request()` when session transitions to ESTABLISHED:

```c
#ifdef TLA_TRACE_ENABLED
if (session_state == LIBSPDM_SESSION_STATE_ESTABLISHED) {
    tla_emit_handle_finish();
}
#endif
```

State captured: `session_state=ESTABLISHED`.

### 3. TerminateSession — `libspdm_rsp_receive_send.c`

Fires at the start of `libspdm_responder_dispatch_session_message()` when a
session teardown is detected (session_state → NOT_STARTED):

```c
#ifdef TLA_TRACE_ENABLED
tla_emit_terminate_session();
#endif
```

State captured: `session_state=NOT_STARTED`, `response_state`, `subscription_state`.

### 4. HandleSubscribeEventTypes — `libspdm_rsp_subscribe_event_types_ack.c`

Fires at end of `libspdm_get_response_subscribe_event_types_ack()`:

```c
#ifdef TLA_TRACE_ENABLED
tla_emit_subscribe_event_types();
#endif
```

State captured: `subscription_state`, `subscribe_types_sent`.

### 5. HandleSendEventVersionMatch / Mismatch — `libspdm_rsp_event_ack.c`

Two separate emit points in `libspdm_get_response_event_ack()` depending on
version comparison result:

```c
#ifdef TLA_TRACE_ENABLED
tla_emit_send_event_version_mismatch();   // version check failed
...
tla_emit_send_event_version_match();      // version check passed
#endif
```

State captured: `direct_send_active`, `last_send_event_response`.

### 6. InitEncapSendEvent — `libspdm_rsp_encap_response.c`

Fires at end of `libspdm_init_send_event_encap_state()`:

```c
#ifdef TLA_TRACE_ENABLED
tla_emit_init_encap_send_event();
#endif
```

State captured: `response_state=PROCESSING_ENCAP`, `encap_event_in_flight`.

### 7. HandleEncapSendEvent — `libspdm_rsp_encap_send_event.c`

Fires at end of `libspdm_get_encap_request_send_event()`:

```c
#ifdef TLA_TRACE_ENABLED
tla_emit_handle_encap_send_event();
#endif
```

State captured: `encap_event_in_flight`, `response_state`.

### 8. ProcessEncapEventAck — `libspdm_rsp_encap_send_event.c`

Fires at end of `libspdm_process_encap_response_event_ack()`:

```c
#ifdef TLA_TRACE_ENABLED
tla_emit_process_encap_event_ack();
#endif
```

State captured: `response_state`, `encap_event_in_flight`.

## NDJSON trace format

Each trace line:

```json
{"tag":"trace","event":"HandleKeyExchange","params":{"with_event_all":true},
 "post":{"session_state":"HANDSHAKE","subscription_state":"SUB_ALL",
         "event_all_policy":true,"subscribe_types_sent":0,
         "response_state":"NORMAL","encap_event_in_flight":false,
         "direct_send_active":false,"last_send_event_response":"NONE"}}
```

Not all fields are relevant to every event; `spec/Trace.tla` selects only
the fields validated by each `TraceHandle*` predicate.

## TLA+ validation

Each trace is validated with `spec/Trace.tla` against the base spec `spec/base.tla`.

```bash
# Via MCP tool (mcp__tla-trace-debugger__run_trace_validation):
#   trace_file = "traces/happy_path.ndjson"
#   spec_file  = "spec/Trace.tla"
#   invariants = ["TraceMatched"]
```

Key design decisions in `Trace.tla`:

| Decision | Why |
|---|---|
| `VARIABLE faultVarsTrace` at top | SANY doesn't resolve forward variable references |
| `Validate*` predicates use primed vars | Post-state check; unprimed checks pre-state (always false) |
| `TraceTerminal` stutter action | Prevents false TLC deadlock after cursor l passes Len(TraceLog) |
| `WF_vars(TraceNext)` in TraceSpec | Prevents trivial liveness counterexample (system never advances) |
| `Json` in EXTENDS | `ndJsonDeserialize` is in CommunityModules Json.tla, not IOUtils.tla |

## Re-applying patches to a fresh libspdm tree

```bash
# 1. Restore clean artifact
git -C artifact/libspdm checkout -- .

# 2. Re-apply source instrumentation
patch -p1 -d artifact/libspdm < patches/instrumentation.patch

# 3. Re-apply harness + CMake wiring
bash harness/apply.sh
```

## Extending instrumentation for Phase 3

To add a new trace event:

1. **Add emit function** to `harness/src/tla_trace.h` and `tla_trace.c`:
   ```c
   void tla_emit_my_new_event(void);
   ```
2. **Add instrumentation** to the relevant `artifact/libspdm/library/` file,
   guarded by `#ifdef TLA_TRACE_ENABLED`:
   ```c
   #ifdef TLA_TRACE_ENABLED
   tla_emit_my_new_event();
   #endif
   ```
3. **Add action** to `spec/base.tla` (`MyNewEvent` action + `Next` disjunct)
4. **Add trace wrapper** to `spec/Trace.tla` (`TraceMyNewEvent` predicate +
   `TraceNext` disjunct)
5. **Run** `bash harness/apply.sh && cmake --build build --target test_tla_trace -j$(nproc)`
6. **Validate** with `mcp__tla-trace-debugger__run_trace_validation`

## State variable → C field mapping

| TLA+ variable | libspdm C field |
|---|---|
| `session_state` | `spdm_context->session_info[n].session_state` (via `libspdm_get_session_state`) |
| `response_state` | `spdm_context->response_state` |
| `subscription_state` | `spdm_context->session_info[n].event_subscription_state` |
| `event_all_policy` | `spdm_context->session_info[n].session_policy & EVENT_ALL_POLICY` |
| `subscribe_types_sent` | `spdm_context->session_info[n].subscribe_event_types_sent` |
| `encap_event_in_flight` | `spdm_context->encap_context.encap_event_in_flight` |
| `direct_send_active` | `spdm_context->send_event_context.direct_send_active` |
| `last_send_event_response` | `spdm_context->send_event_context.last_response` |

## Known issues / caveats

- **`last_spdm_request_session_id_valid` reset**: Must set
  `ctx->last_spdm_request_session_id_valid = false` at the start of each
  `do_key_exchange()` call.  Without this, a second KEX in the same cmocka
  test group will see a stale `true` value (left by the session-level message
  handler in the previous scenario) and `libspdm_get_response_key_exchange`
  returns `UNSUPPORTED_REQUEST`.

- **Sample key directory**: The binary must be run from
  `artifact/libspdm/unit_test/sample_key/` so relative cert paths
  (`ecp256/bundle_responder.certchain.der` etc.) resolve.  `run.sh` handles
  this automatically.

- **LIBSPDM_ASSERT behaviour**: `os_stub/debuglib/debuglib.c` has been changed
  to use `LIBSPDM_DEBUG_LIBSPDM_ASSERT_EXIT` (value 3) as the default, so
  assert failures exit with a non-zero code instead of looping forever.
