# Instrumentation Specification for libspdm-measurements

**Target**: libspdm SPDM GET_MEASUREMENTS implementation  
**Trace Format**: NDJSON (one JSON event per line)  
**Spec**: base.tla (base spec), Trace.tla (trace validation)  
**Category**: A (Distributed/Message-Passing) — single global trace sequence

---

## Section 1: Trace Event Schema

### Event Envelope (Common to All Events)

```json
{
  "event_name": "<action_name>",
  "role": "requester" | "responder",
  "timestamp_ns": <uint64>,
  "spdm_version": 0x10 | 0x11 | 0x12 | 0x13,
  "state": { ... }
}
```

**Fields**:
- `event_name`: Must match a TLA+ action name in Trace.tla (e.g., "BuildGetMeasurementsRequest")
- `role`: "requester" or "responder" — must match current endpoint role
- `timestamp_ns`: Nanosecond timestamp (for causality; not used by spec but helpful for debugging)
- `state`: Complete endpoint state snapshot (see State Fields below)

### State Fields (Captured at Every Event)

These fields must be captured after each instrumented action completes. They map to TLA+ variables in base.tla:

| State Field | TLA+ Variable | Description | Capture Point |
|-----------|---------------|-----------|---|
| `role` | `role` | "requester" or "responder" | Static for endpoint |
| `spdm_version` | `spdm_version` | Negotiated version (0x10-0x13) | After version negotiation |
| `session_id` | `session_id` | Established session ID (or 0 for unsecured) | After session setup |
| `session_established` | `session_state = "SESSION_ESTABLISHED"` | Boolean: true if session is active | After EstablishSession or ReceiveGetMeasurementsRequest |
| `request_format_version` | `request_format_version` | Version format of sent/received request | At or before ReceiveGetMeasurementsRequest |
| `response_format_version` | `response_format_version` | Version format of response | At or after SendGetMeasurementsResponse |
| `req_message_type` | `req_message.type` | "IDLE", "GET_MEASUREMENTS", etc. | After message is built or received |
| `resp_message_type` | `resp_message.type` | "IDLE", "MEASUREMENTS", etc. | After message is built or received |
| `message_m_state` | `message_m_state` | "empty", "has_request", "has_request_and_response", "signature_computed" | After each transcript operation |
| `transcript_appended_count` | `transcript_appended_count` | Number of appends to message M | After each append |
| `message_m_reset_done` | `message_m_reset_done` | Boolean: true if reset completed | After ResetTranscriptAfterSignature |
| `signature_computed` | `computed_signature` | Boolean: true if signature generated | After ComputeSignature |
| `opaque_data_enabled` | `opaque_data_validation_enabled` | Boolean: version-dependent | After ReceiveGetMeasurementsRequest |
| `opaque_data_validated` | `opaque_data_validated` | Boolean: validation completed | If validation step executed |
| `requester_context_sent` | `requester_context_sent` | 8-byte context (0 if none) | After BuildGetMeasurementsRequest |
| `requester_context_received` | `requester_context_received` | Echoed context from response | After SendGetMeasurementsResponse |
| `requester_context_validated` | `requester_context_validated` | Boolean: context match verified | After ValidateContextEcho |
| `slot_id_used` | `slot_id_used` | Selected slot ID (0x00-0x07, 0xF, or 0xFF) | After ValidateSlotIDForSignature or VerifyMeasurementSignature |
| `slot_id_validated` | `slot_id_validated` | Boolean: slot validation completed | After ValidateSlotIDForSignature or VerifyMeasurementSignature |
| `session_validated` | `session_validated` | Boolean: session checks completed | After ReceiveGetMeasurementsRequest |
| `capabilities_verified` | `capabilities_verified` | Boolean: capability checks completed | After ReceiveGetMeasurementsRequest |
| `has_sig_cap` | Contains "MEAS_CAP_SIG" in `capabilities` | Boolean: endpoint supports signing | After session/capability validation |
| `cert_available` | `cert_chain_available[slot]` | Array of booleans per slot | After slot validation or setup |
| `pubkey_available` | `public_key_available` | Boolean: public key provision available | After setup |

---

## Section 2: Action-to-Code Mapping

### Requester Actions

#### A. NegotiateVersionRequester

| Aspect | Value |
|--------|-------|
| **Spec Action** | `base!NegotiateVersionRequester(v)` |
| **Code Location** | `libspdm/src/responder_lib/libspdm_rsp_version.c:XXX` (version negotiation entry point) |
| **Trigger Point** | **After** GET_VERSION / NEGOTIATE_ALGORITHMS exchange, before GET_MEASUREMENTS |
| **Trace Event Name** | `"NegotiateVersionRequester"` |
| **Fields to Capture** | `spdm_version`, `request_format_version` |
| **Notes** | v=`context->connection_info.version.spdm_version` after negotiation. Precondition: version must be >= current (no downgrade). |

#### B. BuildGetMeasurementsRequest

| Aspect | Value |
|--------|-------|
| **Spec Action** | `base!BuildGetMeasurementsRequest(sig, ctx)` |
| **Code Location** | `libspdm/src/requester_lib/libspdm_req_get_measurements.c:168-335` (build request) |
| **Trigger Point** | **Before** sending GET_MEASUREMENTS request; after this action, message is built and ready to send |
| **Trace Event Name** | `"BuildGetMeasurementsRequest"` |
| **Fields to Capture** | `req_message_type = "GET_MEASUREMENTS"`, `request_format_version`, `requester_context_sent`, `signature_requested` (from request.request_attribute) |
| **Notes** | Extract: `sig = (request->request_attribute & SPDM_GET_MEASUREMENTS_REQUEST_ATTRIBUTE_GENERATE_SIGNATURE) != 0`; `ctx = requester_context` (8 bytes, or 0 if NULL); Capture context value before request is sent. |

#### C. ValidateContextEcho

| Aspect | Value |
|--------|-------|
| **Spec Action** | `base!ValidateContextEcho` |
| **Code Location** | `libspdm/src/requester_lib/libspdm_req_get_measurements.c:511-517` |
| **Trigger Point** | **After** receiving response, **before** appending to transcript; this validates context match |
| **Trace Event Name** | `"ValidateContextEcho"` |
| **Fields to Capture** | `requester_context_sent`, `requester_context_received`, `requester_context_validated = (sent == received)`, `request_format_version` |
| **Notes** | For v1.3+: verify `resp->requester_context == sent_context` (8-byte constant-time comparison). For v<1.3: context_validated = TRUE (no context field). Capture context values and boolean outcome. |

#### D. VerifyMeasurementSignature

| Aspect | Value |
|--------|-------|
| **Spec Action** | `base!VerifyMeasurementSignature(slot)` |
| **Code Location** | `libspdm/src/requester_lib/libspdm_req_get_measurements.c:11-94` (verify_measurement_signature function) |
| **Trigger Point** | **After** signature verification completes (or fails); validate slot ID lookup consistency |
| **Trace Event Name** | `"VerifyMeasurementSignature"` |
| **Fields to Capture** | `slot_id_used` (from response.slot_id_param or 0xF), `slot_id_validated`, `cert_available[slot]` or `pubkey_available` (depending on slot) |
| **Notes** | Slot lookup: if slot < MAX_SLOT_COUNT, use cert_chain[slot]; if slot == 0xF, use peer_public_key_provision. Capture which path was used and success/failure. |

---

### Responder Actions

#### E. NegotiateVersionResponder

| Aspect | Value |
|--------|-------|
| **Spec Action** | `base!NegotiateVersionResponder(v)` |
| **Code Location** | `libspdm/src/responder_lib/libspdm_rsp_measurements.c:79` (version check) |
| **Trigger Point** | **After** receiving GET_MEASUREMENTS request, **before** processing; responder selects response version |
| **Trace Event Name** | `"NegotiateVersionResponder"` |
| **Fields to Capture** | `spdm_version` (negotiated), `response_format_version` (set to negotiated version) |
| **Notes** | v = `context->connection_info.version.spdm_version` (negotiated in prior GET_VERSION). Responder accepts this version or rejects request if version mismatch. |

#### F. EstablishSession

| Aspect | Value |
|--------|-------|
| **Spec Action** | `base!EstablishSession(sid)` |
| **Code Location** | `libspdm/src/responder_lib/libspdm_rsp_measurements.c:128-130` (session state check) |
| **Trigger Point** | **After** KEY_EXCHANGE_RSP completes; sid is established session ID |
| **Trace Event Name** | `"EstablishSession"` |
| **Fields to Capture** | `session_id`, `session_established = true` |
| **Notes** | sid = `context->session_info[i].session_id` after session negotiation. Only instrumented if measurement is for secured session; unsecured path sets session_established = FALSE. |

#### G. ReceiveGetMeasurementsRequest

| Aspect | Value |
|--------|-------|
| **Spec Action** | `base!ReceiveGetMeasurementsRequest` |
| **Code Location** | `libspdm/src/responder_lib/libspdm_rsp_measurements.c:79-166` (input validation) |
| **Trigger Point** | **After** parsing request, **before** measurement collection; validates version, session, capabilities |
| **Trace Event Name** | `"ReceiveGetMeasurementsRequest"` |
| **Fields to Capture** | `request_format_version` (from request.header.spdm_version), `session_validated`, `capabilities_verified`, `opaque_data_enabled`, `has_sig_cap` |
| **Notes** | Capture request version, session state validity, and capability flags (MEAS_CAP_SIG / MEAS_CAP_NO_SIG). opaque_data_enabled = (spdm_version >= SPDM_MESSAGE_VERSION_12). |

#### H. AppendRequestToTranscript

| Aspect | Value |
|--------|-------|
| **Spec Action** | `base!AppendRequestToTranscript` |
| **Code Location** | `libspdm/src/responder_lib/libspdm_rsp_measurements.c:494-497` |
| **Trigger Point** | **After** appending request to message_m; this is the first transcript build step |
| **Trace Event Name** | `"AppendRequestToTranscript"` |
| **Fields to Capture** | `message_m_state = "has_request"`, `transcript_appended_count = 1` |
| **Notes** | This is the first of multiple non-atomic steps (Family 3). Capture state transition from empty to has_request. |

#### I. AppendResponseToTranscript

| Aspect | Value |
|--------|-------|
| **Spec Action** | `base!AppendResponseToTranscript` |
| **Code Location** | `libspdm/src/responder_lib/libspdm_rsp_measurements.c:505-506` |
| **Trigger Point** | **After** appending partial response (without signature) to message_m |
| **Trace Event Name** | `"AppendResponseToTranscript"` |
| **Fields to Capture** | `message_m_state = "has_request_and_response"`, `transcript_appended_count = 2` |
| **Notes** | Second non-atomic step (Family 3). Crash window: if crash occurs here, message_m contains partial state. |

#### J. ValidateSlotIDForSignature

| Aspect | Value |
|--------|-------|
| **Spec Action** | `base!ValidateSlotIDForSignature(slot)` |
| **Code Location** | `libspdm/src/responder_lib/libspdm_rsp_measurements.c:421-449` (slot validation) |
| **Trigger Point** | **Before** signature generation (only if signature requested); validates slot ID and cert/key availability |
| **Trace Event Name** | `"ValidateSlotIDForSignature"` |
| **Fields to Capture** | `slot_id_used` (from response.slot_id_param or param2 bits), `slot_id_validated = true`, `cert_available[slot]` or `pubkey_available` |
| **Notes** | Extract slot from param: if bit 4 of param2 set (v1.2+), use lower bits; else use full param. Validate 0x00-0xF range. Check cert chain for slot < SPDM_MAX_SLOT_COUNT, public_key for 0xF. |

#### K. ComputeSignature

| Aspect | Value |
|--------|-------|
| **Spec Action** | `base!ComputeSignature` |
| **Code Location** | `libspdm/src/responder_lib/libspdm_rsp_measurements.c:517-527` (signature generation) |
| **Trigger Point** | **After** signature is computed over L1/L2 transcript |
| **Trace Event Name** | `"ComputeSignature"` |
| **Fields to Capture** | `message_m_state = "signature_computed"`, `signature_computed = true` |
| **Notes** | Non-atomic step 3 (Family 3). Crash window: if crash occurs after compute but before reset, next request sees stale M. |

#### L. ResetTranscriptAfterSignature

| Aspect | Value |
|--------|-------|
| **Spec Action** | `base!ResetTranscriptAfterSignature` |
| **Code Location** | `libspdm/src/responder_lib/libspdm_rsp_measurements.c:529` (message_m reset) |
| **Trigger Point** | **After** message_m is reset to empty state |
| **Trace Event Name** | `"ResetTranscriptAfterSignature"` |
| **Fields to Capture** | `message_m_state = "empty"`, `message_m_reset_done = true`, `transcript_appended_count = 0` |
| **Notes** | Final step in signature flow (Family 3). Must happen after signature compute, not before. Ensures next measurement request starts with clean transcript. |

#### M. SendGetMeasurementsResponse

| Aspect | Value |
|--------|-------|
| **Spec Action** | `base!SendGetMeasurementsResponse(context_echo)` |
| **Code Location** | `libspdm/src/responder_lib/libspdm_rsp_measurements.c:79-533` (full function, response build at end) |
| **Trigger Point** | **After** response is fully built and ready to send (after signature if requested) |
| **Trace Event Name** | `"SendGetMeasurementsResponse"` |
| **Fields to Capture** | `resp_message_type = "MEASUREMENTS"`, `requester_context_received` (echoed context for v1.3+), `response_format_version` |
| **Notes** | For v1.3+: capture echoed context value (must be 8 bytes, even if all zeros). For v<1.3: requester_context_received = 0. Capture response format version and any error codes. |

---

## Section 3: Special Considerations

### 3.1 Non-Atomic Operations and Crash Windows

**Family 3 (Transcript Atomicity)** — Signature generation is split into three operations with crash windows:

1. **AppendRequestToTranscript** — First call to `libspdm_append_message_m()` (line 497)
2. **AppendResponseToTranscript** — Second call to `libspdm_append_message_m()` (line 505)
3. **ComputeSignature** — Signature generation (line 517)
4. **ResetTranscriptAfterSignature** — Reset (line 529)

**Instrumentation requirement**: Emit a separate trace event after each step. Do NOT combine steps. If a crash occurs after step 2 but before step 3, the trace will show `message_m_state = "has_request_and_response"`, and the next measurement request must start with an AppendRequestToTranscript action.

### 3.2 Version-Dependent Code Paths

**Family 1 (Version Divergence)** — Different code paths for v1.0, v1.1, v1.2, v1.3:

- **v1.0**: No slot_id_param, no context
- **v1.1-v1.2**: slot_id_param present, no context
- **v1.3**: slot_id_param present, context present

Capture **actual version used in request and response**, not just negotiated version. If a requester sends v1.0 format to a responder negotiated to v1.3, capture both.

**Instrumentation requirement**: Trace events must capture the actual version format seen, not the negotiated version. Extract from:
- Requester: `spdm_request->header.spdm_version` in BuildGetMeasurementsRequest
- Responder: `spdm_response->header.spdm_version` in SendGetMeasurementsResponse

### 3.3 Session State Asymmetry

**Family 2 (State Validation)** — Session validation differs between unsecured and secured paths:

- **Unsecured session** (session_id == 0): Skip session_info lookup
- **Secured session** (session_id != 0): Validate session_info is populated and state == ESTABLISHED

**Instrumentation requirement**: Capture `session_established = (session_id != NULL_SESSION_ID && session_info[session_id].state == ESTABLISHED)` at both endpoints. Trace should show whether session checks were performed.

### 3.4 Capability Flag Asymmetry

**Family 2 (Capabilities)** — Different capabilities checked depending on signature_requested:

- **sig_requested = TRUE**: Check for MEAS_CAP_SIG
- **sig_requested = FALSE**: Check for MEAS_CAP_NO_SIG

**Instrumentation requirement**: Capture which capability was requested and which was verified. Extract from request attribute flags and response capability bitmap.

### 3.5 Opaque Data Validation Conditional

**Family 4 (Opaque Data)** — Validation only in v1.2+:

- **v1.0-v1.1**: Opaque data parsed without validation (accept any structure)
- **v1.2-v1.3**: Opaque data structure validated (element count, padding, etc.)

**Instrumentation requirement**: Capture `opaque_data_validation_enabled = (spdm_version >= SPDM_MESSAGE_VERSION_12)` and whether validation actually occurred. If validation fails, capture the error.

### 3.6 Requester Context (v1.3 Only)

**Family 5 (Context Binding)** — Context echo-back validation:

- **v1.0-v1.2**: No context field (treat as 0)
- **v1.3**: 8-byte context in request and response, requester validates echo

**Instrumentation requirement**:
- In BuildGetMeasurementsRequest: Capture the 8-byte context value (or 0 if v<1.3 or NULL)
- In ValidateContextEcho: Capture sent + received contexts and boolean validation result
- Use constant-time comparison (libspdm_consttime_is_mem_equal); capture the boolean outcome, not individual byte comparisons

### 3.7 Slot ID Resolution

**Family 6 (Slot Consistency)** — Two key lookup paths:

- **slot < SPDM_MAX_SLOT_COUNT**: Use certificate chain (libspdm_asym_get_cert_public_key)
- **slot == 0xF**: Use public key provision (peer_public_key_provision)

**Instrumentation requirement**:
- Capture which slot was used (from request param for responder, response param for requester)
- Capture which key source was available/used (cert_chain[slot] or public_key_provision)
- Both requester and responder must use the same slot ID for signature verification to succeed

### 3.8 Bootstrap State and Initial Traces

**Bootstrap**: The trace spec (`Trace.tla`) initializes from the first trace event. The first event must contain:

```json
{
  "event_name": "BuildGetMeasurementsRequest" OR "NegotiateVersionRequester",
  "role": "requester" or "responder",
  "spdm_version": 0x10 | 0x11 | 0x12 | 0x13,
  "session_established": true | false,
  "session_id": 0 or actual session ID,
  "request_format_version": 0x10 | 0x11 | 0x12 | 0x13,
  "response_format_version": same as above,
  "cert_available": [true/false, true/false, ...] for each slot,
  "pubkey_available": true | false
}
```

If the first event is missing any of these fields, `TraceInit` will fail to match. Ensure bootstrap state is complete.

### 3.9 Silent Actions in Trace Validation

Silent actions (Trace.tla: `TraceSilentCrash`) fire without consuming trace events. These are used to model behavior that cannot be directly observed in the trace.

**When to use**: If a crash occurs in the real execution but is not explicitly instrumented, the trace validator can infer it by checking state transitions. For example, if message_m_state jumps from "has_request_and_response" to "empty" without an explicit ResetTranscriptAfterSignature event, the silent crash action handles it.

**Constraint**: Silent actions must have tight guards to avoid state space explosion. The guard `(message_m_state /= "empty" /\ TraceLog[l].message_m_state = "empty")` ensures crash only fires when state resets unexpectedly.

---

## Section 4: Summary

**Instrumentation Checklist**:

- [ ] Every action in base.tla has a corresponding trace event name
- [ ] State fields are captured after each action completes
- [ ] Version-dependent logic is instrumented (v1.0 vs v1.3)
- [ ] Non-atomic operations (transcript building) are separate trace events
- [ ] Session state (unsecured vs secured) is captured correctly
- [ ] Capability flags are captured (which capability was checked)
- [ ] Slot ID resolution (cert vs public key) is captured
- [ ] Context (v1.3+) is captured and validated separately
- [ ] Crash/recovery scenarios are detectable (state snapshot shows pre/post crash)
- [ ] Bootstrap state includes all required fields

**Output Format**:
```
../traces/trace.ndjson (or specified via -I IOEnv.JSON=<file>)
```

One JSON object per line, fields in any order. Use null for missing fields (e.g., `"requester_context_received": null` if v<1.3).

---

## Reference

- **Base Spec**: base.tla (variables, actions, invariants)
- **Trace Spec**: Trace.tla (action wrappers, silent actions, validation)
- **Source Code**: libspdm/src/responder_lib/libspdm_rsp_measurements.c, libspdm/src/requester_lib/libspdm_req_get_measurements.c
- **SPDM Spec**: DSP0274 v1.3.2 (GET_MEASUREMENTS message format)
