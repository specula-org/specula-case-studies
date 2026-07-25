# Modeling Brief: libspdm GET_MEASUREMENTS / Attestation

## 1. System Overview

- **System**: DMTF/libspdm — reference SPDM protocol implementation in C, ~35k LOC core
- **Target subsystem**: GET_MEASUREMENTS / attestation (DSP0274 §10.11, §10.15)
- **Language**: C (SPDM versions 1.0–1.3)
- **Category**: **Category A (Distributed / Message-Passing)** — stateful request-response protocol between a Requester and Responder, with per-session transcript accumulation, signature-based attestation, and a multi-state connection machine. No concurrency within a single context; hazards arise from multi-message stateful interactions.
- **Key architectural choices**:
  - **Dual transcript context**: `transcript.message_m` (global, non-session) and `session_info->session_transcript.message_m` (per-session), selected by passing `session_info == NULL or non-NULL` to append/reset helpers
  - **L1/L2 construction**: for SPDM ≥ 1.2, `message_a` (VCA transcript) is prepended; otherwise only `message_m` (GET_MEASUREMENTS exchanges) is used
  - **Message_m accumulates across calls**: `libspdm_reset_message_buffer_via_request_code` skips resetting message_m for `SPDM_GET_MEASUREMENTS` (any other request code resets it)
  - **Two build modes**: `LIBSPDM_RECORD_TRANSCRIPT_DATA_SUPPORT=1` (managed buffer) vs. `=0` (streaming hash context); L1/L2 is a buffer concatenation in mode 1 vs. a running hash in mode 0
  - **Signature always resets transcript**: `libspdm_generate_measurement_signature` always calls `libspdm_reset_message_m` after computing L1/L2, even on failure
- **Concurrency model**: Single-threaded per context; library is not thread-safe by design

---

## 2. Bug Families

### Family 1: L1/L2 Transcript Integrity (HIGH)

**Mechanism**: The L1/L2 measurement transcript — which is signed by the Responder and verified by the Requester — can be constructed over different content on each side, causing signature verification to fail or, in the worse direction, succeeding over data that does not accurately reflect the exchange.

**Evidence**:
- Historical (fixed): Issue #2072/PR #2079 — Responder appended `*response_size` (including signature) instead of `*response_size - signature_size` into message_m; signature bytes became part of the signed transcript. Critical correctness bug.
- Historical (fixed): Issue #914/PR #914 — `libspdm_append_message_m` appended VCA into `digest_context_l1l2` on every call rather than once; Requester and Responder (in different build modes) accumulated different hash state.
- Historical (fixed): Issue #2610/PR #2611 — Transport-layer buffer size (with padding) passed to `libspdm_append_message_*` instead of parsed SPDM message size; CHALLENGE_AUTH signature failed because transcript covered wrong byte count.
- Code analysis: `libspdm_generate_measurement_signature` (rsp_measurements.c:36–43) always calls `libspdm_reset_message_m` before checking if `libspdm_calculate_l1l2` succeeded — if calculate fails mid-stream, the transcript is destroyed and cannot be recovered for a retry.
- Code analysis: In digest mode (RECORD_TRANSCRIPT_DATA_SUPPORT=0), `libspdm_calculate_l1l2_hash` calls `libspdm_hash_final()` which consumes the streaming context; a subsequent signature attempt starts with a null context and silently fails.

**Affected code paths**:
- `libspdm_generate_measurement_signature()` (rsp_measurements.c:19–78)
- `libspdm_verify_measurement_signature()` (req_get_measurements.c:11–142)
- `libspdm_calculate_l1l2()` / `libspdm_calculate_l1l2_hash()` (com_crypto_service.c:134–237)
- `libspdm_append_message_m()` / `libspdm_reset_message_m()` (com_context_data.c:1305–1337, 1743–1754)

**Suggested modeling approach**:
- Variables: `message_m_content[Side]` (sequence of (request, response_without_sig) pairs), `message_a_content` (VCA exchange), `l1l2_computed[Side]`
- Actions: Split `HandleGetMeasurements` into `AppendRequest`, `AppendResponse`, `GenerateSignature` (which finalizes and resets message_m). Add `L1L2ComputationFailure` action that resets message_m without completing a signature.
- Invariant: `l1l2_computed[Requester] = l1l2_computed[Responder]` when signature verification passes.

**Priority**: High
**Rationale**: Three independently critical historical bugs share this mechanism. The invariant (both sides compute the same L1/L2) is the core security guarantee of attestation. Three distinct bugs violated it in different ways; the transcript reset-before-failure check is an open question.

---

### Family 2: Measurement Response Structure Parsing (MEDIUM)

**Mechanism**: The MEASUREMENTS response contains multiple sequential variable-size fields (measurement record, nonce, opaque data, requester context, signature). Guards before reading each field are inconsistent between the signature and no-signature code paths, allowing malformed responses to evade size checks.

**Evidence**:
- Historical (fixed): Issue #2449 — opaque data offset calculation in `libspdm_rsp_measurements.c` skipped the measurement record size, writing/reading opaque data at wrong offset. Regression from PR #1991.
- Code analysis (confirmed bug): `libspdm_try_get_measurement` no-signature path (req_get_measurements.c:546–548) checks only `sizeof(response_header) + measurement_record_length + sizeof(uint16_t)` — missing `SPDM_NONCE_SIZE` (32 bytes). Lines 552–558 then immediately read 32 bytes (nonce) + 2 bytes (opaque_length) from beyond the validated range. The signature path at lines 427–429 correctly includes `SPDM_NONCE_SIZE`. Asymmetry is a confirmed bug.
- Historical (fixed): Issue #3584/PR #3585 — unsigned 32-bit wrap before cast to `size_t` in MEL/certificate size calculation bypasses size checks; potential heap overflow.
- Open: Issue #1434 — requester does not validate that received measurement block indices are non-reserved and in ascending order.
- Open: Issue #2425 — requester does not reject invalid `DMTFSpecMeasurementValueType` values in measurement blocks.

**Affected code paths**:
- `libspdm_try_get_measurement()` no-signature response parsing (req_get_measurements.c:545–643)
- `libspdm_try_get_measurement()` signature response parsing (req_get_measurements.c:426–544)
- `libspdm_get_response_measurements()` response assembly (rsp_measurements.c:326–532)

**Suggested modeling approach**:
- Variables: `response_fields[Field -> Value]` (measurement_record_length, nonce, opaque_length, req_context, signature), `parsed_offset`
- Actions: Model field-sequential parsing where each step checks remaining size; inject a `MalformedResponse` action that sets one field to require more bytes than remain.
- Invariant: `AllFieldsWithinBounds` — parsed_offset never exceeds actual response size after any field read.

**Priority**: Medium
**Rationale**: Confirmed missing NONCE_SIZE guard (new finding, not a reproduction of any fixed issue). The signature vs. no-signature path asymmetry is a forward-looking MC question about what a malformed response can force the parser to do.

---

### Family 3: Session/Non-Session Message-M Context Selection (MEDIUM)

**Mechanism**: The library maintains two separate message_m buffers — a global one (for non-session GET_MEASUREMENTS) and a per-session one. Multiple code paths fail to consistently select the right context, and error conditions can leave the wrong context in a dirty state that persists into subsequent measurements.

**Evidence**:
- Open: Issue #3171 — several `libspdm_reset_message_buffer_via_request_code` call sites pass `NULL` for session_info even when inside an active session; in those cases only the global message_m is reset, leaving the session transcript intact.
- Open: Issue #524 — when the Responder appends the request to message_m but then fails to construct the response, there is no rollback — the transcript has the request with no matching response. Spec says the Responder must send either a valid response or an error, but the error path itself may also fail.
- Open: Issue #491 — the SPDM spec says retried requests "shall not be used in transcript calculations" but libspdm has no retry detection; a retried GET_MEASUREMENTS would accumulate the request twice into message_m.
- Code analysis: `libspdm_reset_context()` (com_context_data.c:2942–2957) resets global transcripts (message_m with NULL session_info) but does not iterate over sessions to reset per-session message_m contexts; `libspdm_deinit_context` correctly does both.
- Code analysis: `libspdm_rsp_measurements.c:122` — when session lookup fails (invalid session_id), the code explicitly comments "do not reset message_m because it is unclear which context it should be used" — a known ambiguity in the state machine.

**Affected code paths**:
- `libspdm_get_response_measurements()` — session_info path vs. non-session path (rsp_measurements.c:113–137)
- `libspdm_try_get_measurement()` — session_info-dependent append (req_get_measurements.c:521–528)
- `libspdm_reset_context()` — per-session transcript handling (com_context_data.c:2942–2957)
- `libspdm_responder_handle_response_state()` — NEED_RESYNC clears connection_state but not sessions (rsp_handle_response_state.c:21–31)

**Suggested modeling approach**:
- Variables: `message_m[global]`, `message_m[session_id]`, `active_sessions : SET`, `connection_state`
- Actions: `HandleGetMeasurements(in_session: Bool)` selects the appropriate buffer; `ResetContext` clears global but not per-session; `NeedResync` resets connection_state to NOT_STARTED without removing sessions from `active_sessions`.
- Invariant: `TranscriptConsistency` — if a measurement signature is verified, the message_m content used for verification equals the content used for signing (same session or both non-session).

**Priority**: Medium
**Rationale**: Three open issues share this mechanism. Issue #524 and #491 are explicitly filed as unfixed. The per-session vs. global context ambiguity is acknowledged in comments. TLA+ can exhaustively explore the interleaving of session and non-session GET_MEASUREMENTS calls.

---

### Family 4: Slot ID / Key Binding Invariant (MEDIUM)

**Mechanism**: The `slot_id_param` in GET_MEASUREMENTS identifies which signing key (certificate slot) the Responder should use. Multiple code paths fail to maintain the invariant that the requested slot, the slot reflected in the response, and the key actually used for signing are all consistent.

**Evidence**:
- Historical (fixed): Issue #1621/PR #1622 — `libspdm_verify_measurement_signature` used `0xFF` instead of `0xF` as the raw-public-key slot sentinel; the asymmetric key context was never freed in that path.
- Historical (fixed): Issue #2495 — `slot_id_param` used without checking the Key Usage bit mask in CHALLENGE, GET_MEASUREMENTS, and KEY_EXCHANGE; SPDM 1.3 requires MEASUREMENT_USE bit. Fix: check `local_key_usage_bit_mask[slot_id_param]` (rsp_measurements.c:453–459).
- Code analysis (confirmed bug): `slot_id_param` is a stack variable declared at rsp_measurements.c:91 with no initializer. It is assigned only inside `if (spdm_version >= SPDM_MESSAGE_VERSION_11)` (line 423). For SPDM 1.0 with GENERATE_SIGNATURE, the `else` branch runs (request size excludes slot_id field) and `slot_id_param` is never initialized. It is then passed to `libspdm_generate_measurement_signature` at line 518. In non-multi-key mode `libspdm_slot_id_to_key_pair_id` returns 0 regardless, so practical impact is low; but this is undefined behavior and could misfire in multi-key configurations.
- Code analysis: The key usage check at line 451–459 is guarded by `spdm_version >= SPDM_MESSAGE_VERSION_13 && multi_key_conn_rsp && slot_id_param != 0xF` — if `multi_key_conn_rsp` is false, the key usage bit is never verified even for v1.3.

**Affected code paths**:
- `libspdm_get_response_measurements()` slot_id_param validation (rsp_measurements.c:421–468)
- `libspdm_generate_measurement_signature()` slot_id used for key selection (rsp_measurements.c:57–75)
- `libspdm_verify_measurement_signature()` slot_id used for cert chain selection (req_get_measurements.c:48–94)

**Suggested modeling approach**:
- Variables: `requested_slot`, `response_slot`, `signing_key_slot`, `key_usage[slot] : SET`
- Actions: `HandleGetMeasurementsWithSig` that sets `signing_key_slot` from `slot_id_param`; `VerifyMeasurementSig` that validates `response_slot == requested_slot`.
- Invariant: `SlotBinding` — when signature verification passes, `requested_slot == response_slot` and `signing_key_slot == requested_slot`.

**Priority**: Medium
**Rationale**: The key usage gap (#2495) was a real security bug. The uninitialized slot_id_param for v1.0 is a new finding that could matter in multi-key deployments. The invariant is simple and well-suited for TLA+.

---

### Family 5: NOT_READY Token Replay (LOW)

**Mechanism**: The RESPOND_IF_READY flow uses an 8-bit `current_token` counter that wraps at 256; after 256 NOT_READY responses, old tokens become reusable. A cached request can be replayed by presenting a recycled token even though it was issued for a different request.

**Evidence**:
- Code analysis: `current_token` is `uint8_t` (rsp_handle_response_state.c:44); wraps to 0 after 256 increments; `libspdm_get_response_respond_if_ready` checks only `param2 != error_data.token` (exact match), which a recycled token satisfies.
- Code analysis: `libspdm_get_response_respond_if_ready` zeroes `cache_spdm_request` after calling the handler, but if the handler puts the Responder back into NOT_READY, a new cache is written and then immediately zeroed (rsp_respond_if_ready.c:67–73).

**Affected code paths**:
- `libspdm_responder_handle_response_state()` NOT_READY branch (rsp_handle_response_state.c:33–50)
- `libspdm_get_response_respond_if_ready()` (rsp_respond_if_ready.c:67–73)

**Priority**: Low (TLA+) — Token wraparound requires 256 consecutive NOT_READY cycles, which is unusual; the cached-request replay is limited by what the responder is willing to re-execute. Better handled by code review.

---

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| Dual message_m contexts (global vs. per-session) | Family 3: context selection bugs have caused transcript divergence and are unresolved | Two transcript variables; actions dispatch based on session_id |
| L1/L2 construction sequence | Family 1: three critical historical bugs; signing over correct data is the core safety invariant | Model as ordered sequence: message_a (≥v1.2) + message_m pairs, finalized to l1l2 |
| Transcript accumulation across multiple GET_MEASUREMENTS | Family 1/3: message_m accumulates across calls; reset only on non-measurement requests | `AccumulateRequest/Response` actions that append; `ResetOnOtherRequest` action |
| Response field parsing order | Family 2: missing NONCE_SIZE guard in no-signature path | Model response as tuple of fields with declared sizes; validate offsets sequentially |
| Connection state machine | Family 3: NEED_RESYNC resets state without clearing sessions | Explicit connection_state variable with guarded transitions |
| Slot ID binding | Family 4: requested slot must equal signing slot must equal verification slot | Track `requested_slot`, `signing_slot`, `response_slot` as separate variables |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Crypto internals (RSA/ECDSA/Ed448) | Beyond TLA+ scope; bugs #26, #28 are implementation-only |
| Memory management / leaks | Families 10, 25 (issue numbers) are out of scope for TLA+ |
| Transport layer (MCTP/DOE/TCP) | Not relevant to protocol message semantics |
| RECORD_TRANSCRIPT_DATA_SUPPORT=0 mode specifically | Model the canonical buffer mode; streaming hash bugs require test-level analysis |
| PSK exchange / KEY_EXCHANGE transcript (TH) | Separate transcript family; not within scope of measurements |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Dual transcript context | `message_m_global`, `message_m_session[sid]` | Model session vs. non-session separation | Family 3 |
| L1/L2 finalization | `l1l2_requester`, `l1l2_responder` | Track divergence between sides | Family 1 |
| Response field cursor | `parse_offset`, `response_bytes` | Model sequential field reads with size guards | Family 2 |
| Slot ID tracking | `requested_slot`, `response_slot`, `signing_slot` | Verify slot binding invariant | Family 4 |
| Connection + session state | `connection_state`, `active_sessions` | Model NEED_RESYNC clearing connection but not sessions | Family 3 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| L1L2Agreement | Safety | When MeasurementSigVerified, l1l2_requester = l1l2_responder | Family 1 |
| TranscriptNoSignatureBytes | Safety | message_m never contains the signature field of any MEASUREMENTS response | Family 1, Issue #2072 |
| ParseWithinBounds | Safety | After parsing any response field, parse_offset ≤ response_size | Family 2 |
| SlotBinding | Safety | When MeasurementSigVerified, requested_slot = response_slot = signing_slot | Family 4 |
| SessionConsistency | Safety | If connection_state = NOT_STARTED then active_sessions = {} | Family 3 |
| TranscriptGrowthOnlyMeasurements | Safety | message_m only grows during GET_MEASUREMENTS exchanges; any other request resets it | Family 1/3 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|------------------------------|------------|
| MC1 | Can L1/L2 diverge between requester and responder when a GET_MEASUREMENTS sequence interleaves session and non-session calls — one side using global message_m while the other uses the session buffer — and then a signed measurement is requested? | L1L2Agreement | Family 1, 3 |
| MC2 | If the Responder appends a GET_MEASUREMENTS request to message_m but fails before appending the response (error path), and then the Requester retries, do both the original and retry request appear in message_m — and if so, does the resulting L1/L2 differ from a clean single-exchange? (Open issue #524 + #491) | L1L2Agreement, TranscriptGrowthOnlyMeasurements | Family 3 |
| MC3 | Can a MEASUREMENTS response without signature bypass the response-size minimum check (missing NONCE_SIZE) and cause the requester to interpret nonce bytes as the opaque_length field, leading to opaque data reads beyond the actual response buffer? | ParseWithinBounds | Family 2 |
| MC4 | After NEED_RESYNC resets connection_state to NOT_STARTED while leaving active_sessions non-empty, if the Requester skips GET_VERSION and sends a new non-session GET_MEASUREMENTS, does the Responder accept it (using stale global message_m from before the resync)? | SessionConsistency, L1L2Agreement | Family 3 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|------------------------|
| TV1 | Missing NONCE_SIZE in no-signature response size check (req_get_measurements.c:546–548) | Unit test: send response of size `sizeof(header) + meas_len + 2` (no nonce bytes); verify INVALID_MSG_SIZE returned |
| TV2 | slot_id_param uninitialized for SPDM 1.0 with signature (rsp_measurements.c:91, 518) | Unit test: force SPDM_MESSAGE_VERSION_10, request signature; verify slot 0 is used consistently |
| TV3 | `libspdm_reset_context` does not reset per-session message_m | Unit test: open session, call GET_MEASUREMENTS, then reset_context, open new session, verify session message_m is empty |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR1 | `slot_id_param` stack variable uninitialized for SPDM 1.0 + signature (rsp_measurements.c:91) | Initialize to 0 at declaration or add explicit `else { slot_id_param = 0; }` for v1.0 branch |
| CR2 | `DELIVER_ENCAPSULATED_RESPONSE` resets B/C but not mut_B/mut_C (com_context_data.c:1484–1490), unlike GET_ENCAPSULATED_REQUEST which resets all four | Compare line by line with GET_ENCAPSULATED_REQUEST case; determine if asymmetry is intentional |
| CR3 | `libspdm_set_data(LIBSPDM_DATA_CONNECTION_STATE)` accepts any uint32_t without bounds check or callback (com_context_data.c:489–497) | Add range check against LIBSPDM_CONNECTION_STATE_MAX; call libspdm_set_connection_state to fire callback |
| CR4 | `current_token` uint8_t wraps at 256, potentially allowing RESPOND_IF_READY token replay (rsp_handle_response_state.c:44) | Widen to uint16_t or include request_code in token equality check |

---

## 7. Reference Pointers

**Key source files**:
- `library/spdm_responder_lib/libspdm_rsp_measurements.c` — Responder GET_MEASUREMENTS handler (536 lines)
- `library/spdm_requester_lib/libspdm_req_get_measurements.c` — Requester GET_MEASUREMENTS handler (873 lines)
- `library/spdm_common_lib/libspdm_com_crypto_service.c` — L1/L2 construction (libspdm_calculate_l1l2 lines 134–203)
- `library/spdm_common_lib/libspdm_com_context_data.c` — Transcript reset routing (libspdm_reset_message_buffer_via_request_code lines 1447–1501)
- `library/spdm_responder_lib/libspdm_rsp_handle_response_state.c` — Response state machine (61 lines)

**GitHub issues (DMTF/libspdm)**:
- #2072/#2079 (Family 1 — signature in L1/L2, fixed)
- #914 (Family 1 — VCA added multiple times, fixed)
- #2610/#2611 (Family 1 — transport size in transcript, fixed)
- #2449 (Family 2 — opaque data offset, fixed)
- #524 (Family 3 — transcript rollback impossible, **OPEN**)
- #491 (Family 3 — retry detection missing, **OPEN**)
- #3171 (Family 3 — reset without session_info, **OPEN**)
- #1434 (Family 2 — missing index validation, **OPEN**)
- #2495 (Family 4 — key usage not checked, fixed)
- #1621/#1622 (Family 4 — wrong slot sentinel, fixed)

**Reference specification**: DMTF DSP0274 SPDM specification §10.11 (GET_MEASUREMENTS), §10.15 (measurement record format), §15 (transcript hash calculations, L1/L2)
