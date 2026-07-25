# Instrumentation Spec — libspdm MEL paged-transfer

Target: `libspdm` SPDM Measurement Extension Log (MEL)
Spec actions defined in: `spec/base.tla`
Trace spec: `spec/Trace.tla`
Trace files stored in: `traces/` (sibling to `spec/`)

---

## Section 1: Trace Event Schema

### Event envelope (every event)

```json
{
  "event":  "<event_name>",
  "seq":    <monotonic integer, 0-based>,
  "node":   "req" | "rsp"
}
```

`node` indicates which side produced the event. All SPDM MEL events are single-threaded, so `seq` matches file order.

### Shared state fields (captured at every event unless noted)

| JSON field | C source | TLA+ variable | Notes |
|---|---|---|---|
| `conn_state` | `spdm_context->connection_info.connection_state` | `conn_state` | mapped: `NEGOTIATED` → `"negotiated"`, else `"init"` |
| `mel_spec_conn` | `spdm_context->connection_info.algorithm.mel_spec` | `mel_spec_conn` | raw uint32; 0=UNSET, 1=DMTF, other=INVALID |
| `has_session_cap` | `libspdm_is_capabilities_flag_supported(KEY_EX_CAP) \|\| libspdm_is_capabilities_flag_supported(PSK_CAP)` | `has_session_cap` | bool |
| `mel_generation` | counter maintained by test harness (incremented on each HAL callback invocation) | `mel_generation` | not in libspdm_context_t; harness-side tracking |
| `mel_size` | `spdm_mel_len` (inside HAL callback, before return) | `mel_size` | bytes |
| `transfer_state` | derived: `"idle"` before first send, `"pending"` during loop, `"done"` after loop | `transfer_state` | harness-derived |
| `mel_offset` | `mel_size_internal` (local in `libspdm_try_get_measurement_extension_log`) | `mel_offset` | accumulated bytes |

---

## Section 2: Action-to-Code Mapping

### 1. `NegotiateAlgorithmsWithSessionCap` / `NegotiateAlgorithmsWithoutSessionCap`

| Field | Value |
|---|---|
| **Spec actions** | `NegotiateAlgorithmsWithSessionCap`, `NegotiateAlgorithmsWithoutSessionCap` |
| **Event name** | `negotiate_algorithms` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_negotiate_algorithms.c` — after line 697 (end of mel_spec validation block) |
| **Trigger point** | after `connection_info.algorithm.mel_spec` is set and validation completes |
| **Fields captured** | |
| `mel_spec_wire` | `spdm_response->mel_specification_sel` (the raw wire value before masking) |
| `mel_spec_conn` | `spdm_context->connection_info.algorithm.mel_spec` (stored value after validation) |
| `has_session_cap` | evaluated from capability flags at this point |
| `conn_state` | `spdm_context->connection_info.connection_state` |
| **Which action?** | `has_session_cap=true` → `NegotiateAlgorithmsWithSessionCap`; `has_session_cap=false` → `NegotiateAlgorithmsWithoutSessionCap` |
| **Notes** | Capture `mel_spec_wire` from `spdm_response->mel_specification_sel` at `libspdm_req_negotiate_algorithms.c:441` (before it's overwritten by negotiated value). Capture `mel_spec_conn` after line 697. |

---

### 2. `MelUpdate`

| Field | Value |
|---|---|
| **Spec action** | `MelUpdate` |
| **Event name** | `mel_update` |
| **Code location** | `os_stub/spdm_device_secret_lib_sample/meas.c` — entry point of `libspdm_measurement_extension_log_collection` (or the real HAL); emit when this is the 2nd or later call for the same logical transfer |
| **Trigger point** | at the start of `libspdm_measurement_extension_log_collection`, before populating `spdm_mel` and `spdm_mel_len` |
| **Fields captured** | |
| `mel_generation` | harness counter: increment before each call to HAL, emit the new value |
| `mel_size` | `*spdm_mel_len` after the HAL returns |
| **Notes** | A `mel_update` event should only be emitted when the HAL is called for the 2nd+ time in the same transfer (offset > 0 for the request that triggered it). For the first call (offset=0), emit no `mel_update` — that generation is captured in `respond_get_mel_first_chunk`. The harness must track "is this call offset=0 or offset>0" from the surrounding request context. |

---

### 3. `SendGetMelFirstChunk`

| Field | Value |
|---|---|
| **Spec action** | `SendGetMelFirstChunk` |
| **Event name** | `send_get_mel_first_chunk` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_get_measurement_extension_log.c:105-115` |
| **Trigger point** | after `spdm_request->offset = 0` and `spdm_request->length` are set (line 109-111), before `libspdm_send_spdm_request` |
| **Fields captured** | |
| `req_offset` | `spdm_request->offset` (always 0) |
| `req_length` | `spdm_request->length` |
| `conn_state` | connection state |

---

### 4. `RespondGetMelFirstChunk`

| Field | Value |
|---|---|
| **Spec action** | `RespondGetMelFirstChunk` |
| **Event name** | `respond_get_mel_first_chunk` |
| **Code location** | `library/spdm_responder_lib/libspdm_rsp_measurement_extension_log.c:152-158` |
| **Trigger point** | after `spdm_response->portion_length` and `spdm_response->remainder_length` are set (lines 152-153), before return |
| **Fields captured** | |
| `portion_length` | `spdm_response->portion_length` |
| `remainder_length` | `spdm_response->remainder_length` |
| `mel_generation` | harness counter at time of this HAL call (generation 0 for first call) |
| `mel_size` | `spdm_mel_len` inside this invocation |
| **Notes** | This event captures which generation the Responder served. The harness must record `mel_generation` **before** `libspdm_measurement_extension_log_collection` returns so it corresponds to the data copied into the response. |

---

### 5. `ProcessGetMelFirstChunkResp`

| Field | Value |
|---|---|
| **Spec action** | `ProcessGetMelFirstChunkResp` |
| **Event name** | `process_mel_first_chunk_resp` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_get_measurement_extension_log.c:213-243` |
| **Trigger point** | after `mel_size_internal += spdm_response->portion_length` (line 233) and after the loop-continue condition is evaluated (line 241-243) |
| **Fields captured** | |
| `mel_offset` | `mel_size_internal` after line 233 |
| `first_portion_len` | `spdm_response->portion_length` (same as `mel_size_internal` at this point since offset was 0) |
| `transfer_state` | `"done"` if `remainder_length == 0`, else `"pending"` |
| `mel_snapshot_gen` | harness counter: capture the generation of the response just processed |
| **Notes** | Capture AFTER the loop condition at line 241-243 is evaluated, so the spec can model the potential partial-header hazard (first_portion_len < 16). |

---

### 6. `SendGetMelNextChunk`

| Field | Value |
|---|---|
| **Spec action** | `SendGetMelNextChunk` |
| **Event name** | `send_get_mel_next_chunk` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_get_measurement_extension_log.c:109-115` (2nd+ loop iteration) |
| **Trigger point** | after `spdm_request->offset = mel_size_internal` (line 109) before send |
| **Fields captured** | |
| `req_offset` | `spdm_request->offset` (> 0) |
| `req_length` | `spdm_request->length` |

---

### 7. `RespondGetMelNextChunk`

| Field | Value |
|---|---|
| **Spec action** | `RespondGetMelNextChunk` |
| **Event name** | `respond_get_mel_next_chunk` |
| **Code location** | `library/spdm_responder_lib/libspdm_rsp_measurement_extension_log.c:152-158` (2nd+ call) |
| **Trigger point** | after `spdm_response->portion_length` set, before return |
| **Fields captured** | |
| `portion_length` | `spdm_response->portion_length` |
| `remainder_length` | `spdm_response->remainder_length` |
| `mel_generation` | harness counter (may differ from first-chunk generation if `MelUpdate` fired) |
| `mel_size` | `spdm_mel_len` inside this invocation |
| **Notes** | The distinction from `respond_get_mel_first_chunk` is that `offset > 0` in the corresponding request. The harness can gate on `spdm_request->offset != 0` or on which iteration of the responder loop is executing. |

---

### 8. `ProcessGetMelNextChunkResp`

| Field | Value |
|---|---|
| **Spec action** | `ProcessGetMelNextChunkResp` |
| **Event name** | `process_mel_next_chunk_resp` |
| **Code location** | `library/spdm_requester_lib/libspdm_req_get_measurement_extension_log.c:213-243` (2nd+ iteration) |
| **Trigger point** | after `mel_size_internal += spdm_response->portion_length` |
| **Fields captured** | |
| `mel_offset` | `mel_size_internal` after accumulation |
| `transfer_state` | `"done"` if loop exits, else `"pending"` |

---

## Section 3: Special Considerations

### 3.1 mel_generation tracking

`mel_generation` has **no counterpart in `libspdm_context_t`** — the spec introduces it to expose the multi-chunk consistency bug. The harness must maintain a side-channel counter:

```c
static uint32_t mel_generation_counter = 0;

bool patched_mel_collection(...) {
    mel_generation_counter++;   // increment before each real HAL call
    return libspdm_measurement_extension_log_collection(...);
}
```

Emit the current `mel_generation_counter` in every `respond_get_mel_*` event.

### 3.2 Event disambiguation: first vs next chunk

Both `respond_get_mel_first_chunk` and `respond_get_mel_next_chunk` instrument the same function (`libspdm_get_response_measurement_extension_log`). Distinguish by checking the request offset in the surrounding context:

```c
if (spdm_request->offset == 0)
    emit("respond_get_mel_first_chunk", ...)
else
    emit("respond_get_mel_next_chunk", ...)
```

Same distinction applies for `process_mel_first_chunk_resp` vs `process_mel_next_chunk_resp` — gate on `mel_size_internal == 0` before the copy vs `mel_size_internal > 0`.

### 3.3 Partial-header trigger (MC2)

To reproduce the `MelHeaderComplete` violation in a test, configure the mock HAL to return a MEL of exactly 8 bytes (smaller than `MEL_HEADER_SIZE=16`). The single-chunk response will have `portion_length=8, remainder_length=0`. After `ProcessGetMelFirstChunkResp`, `first_portion_len=8 < 16` and the invariant fires.

### 3.4 has_session_cap computation

`has_session_cap` is not a single field; it is the logical OR of two capability flag checks at `libspdm_req_negotiate_algorithms.c:663-670`. Compute it at instrumentation time:

```c
bool has_session_cap =
    libspdm_is_capabilities_flag_supported(ctx, true,
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_KEY_EX_CAP,
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_KEY_EX_CAP) ||
    libspdm_is_capabilities_flag_supported(ctx, true,
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_PSK_CAP,
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_PSK_CAP);
```

### 3.5 mel_spec_wire vs mel_spec_conn

- `mel_spec_wire`: the raw `mel_specification_sel` field from the ALGORITHMS response wire format, before any masking or validation. Read from `spdm_response->mel_specification_sel` at `libspdm_req_negotiate_algorithms.c:441`.
- `mel_spec_conn`: the stored value in `spdm_context->connection_info.algorithm.mel_spec` **after** the validation block at lines 681-696. When `has_session_cap=false`, these will be equal (bypass path). When `has_session_cap=true` and `wire_val=INVALID`, `mel_spec_conn` is not updated (error path, function returns before storage).

### 3.6 Trace file format (example)

```ndjson
{"event":"negotiate_algorithms","seq":0,"node":"req","mel_spec_wire":1,"mel_spec_conn":1,"has_session_cap":true,"conn_state":"negotiated"}
{"event":"send_get_mel_first_chunk","seq":1,"node":"req","req_offset":0,"req_length":12,"conn_state":"negotiated","mel_offset":0}
{"event":"respond_get_mel_first_chunk","seq":2,"node":"rsp","portion_length":12,"remainder_length":8,"mel_generation":0,"mel_size":20}
{"event":"process_mel_first_chunk_resp","seq":3,"node":"req","mel_offset":12,"first_portion_len":12,"transfer_state":"pending","mel_snapshot_gen":0}
{"event":"mel_update","seq":4,"node":"rsp","mel_generation":1,"mel_size":20}
{"event":"send_get_mel_next_chunk","seq":5,"node":"req","req_offset":12,"req_length":12}
{"event":"respond_get_mel_next_chunk","seq":6,"node":"rsp","portion_length":8,"remainder_length":0,"mel_generation":1,"mel_size":20}
{"event":"process_mel_next_chunk_resp","seq":7,"node":"req","mel_offset":20,"transfer_state":"done"}
```
