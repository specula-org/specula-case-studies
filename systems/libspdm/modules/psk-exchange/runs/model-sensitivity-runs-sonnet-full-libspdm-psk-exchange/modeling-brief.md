# Modeling Brief: libspdm PSK-Based Session Establishment

## 1. System Overview

- **System**: libspdm (DMTF/libspdm) — C reference implementation of the SPDM (Security Protocol and Data Model) specification
- **Version analyzed**: snapshot in artifact/libspdm (~1,969 LOC across 4 core PSK files)
- **Category**: **Category A (Distributed / Message-Passing)** — the PSK exchange is a 2–4 message cryptographic handshake protocol between a Requester and Responder, with state transitions driven by message receipt. All correctness risks are protocol-logic (message acceptance guards, transcript computation, key derivation ordering), not concurrent memory access.
- **Protocol**: SPDM PSK-based session establishment (DSP0274 §9): PSK_EXCHANGE → PSK_EXCHANGE_RSP → (optional) PSK_FINISH → PSK_FINISH_RSP
- **Key architectural choices**: Session state transitions are split between individual message handlers and a dispatch layer (`libspdm_rsp_receive_send.c`). The `secured_message_version` for DSP0277 is negotiated via opaque data inside the SPDM handshake messages. The integrator provides opaque data generation via callback hooks.
- **Concurrency model**: Single-threaded; no goroutines or locks. All "concurrent" hazards are message-ordering races (e.g., requester vs. responder state diverge if a step is missing or out of order).

---

## 2. Bug Families

### Family 1: Missing Opaque Data Enforcement Allows Session with `secured_message_version = 0`

**Mechanism**: When the PSK_EXCHANGE request has zero-length opaque data, the responder skips the entire version negotiation block and initializes `secured_message_version = 0`. For SPDM ≥ 1.2 the spec (DSP0277) mandates that the opaque field carry the `SupportedVersionData` element, but libspdm never rejects a request with `opaque_length = 0` in 1.2+ mode. The session is assigned with `version = 0`, so all subsequent DSP0277 secured messages may use incorrect framing.

**Evidence**:
- Historical: Open bug **Issue #1993** ("Handling of key exchange opaque data") — maintainer jyao1 writes "we need: 1) force integrator to register secured_message_version, 2) check the existence of opaque data." steven-bellock agrees: "require secured message versions and opaque data to establish a secure session."
- Code: `libspdm_rsp_psk_exchange_rsp.c:272` — `secured_message_version = 0` default, never updated when `opaque_length == 0`
- Code: `libspdm_rsp_psk_exchange_rsp.c:274` — entire opaque data block guarded by `if (spdm_request->opaque_length != 0)`, no version-1.2+ enforcement
- Code: `libspdm_rsp_psk_exchange_rsp.c:371` — `libspdm_assign_session_id(..., secured_message_version, ...)` called unconditionally with `version = 0`

**Affected code paths**:
- `libspdm_get_response_psk_exchange()` — responder handler for PSK_EXCHANGE
- `libspdm_try_send_receive_psk_exchange()` — requester mirroring code; requester would also set `secured_message_version` from a zero-length or absent opaque in response

**Suggested modeling approach**:
- Variables: `has_opaque_data` (bool), `negotiated_version` per session
- Actions: `SendPskExchange(with_opaque | without_opaque)`, `RecvPskExchangeRsp`, derive handshake keys
- Invariant: `SessionEstablished → has_opaque_data = true` (for spdm_version ≥ 1.2)
- Granularity: one action for PSK_EXCHANGE send, one for PSK_EXCHANGE_RSP receive — opaque presence is a parameter

**Priority**: **High**
**Rationale**: Confirmed open bug (#1993) with maintainer consensus; allows a spec-violating session configuration; directly affects secured message protocol negotiation

---

### Family 2: Opaque Data Triple-Call Race — `secured_message_version` Extraction vs. Transcript Contribution

**Mechanism**: The integrator's `libspdm_psk_exchange_rsp_opaque_data()` callback is invoked three separate times during a single PSK_EXCHANGE_RSP handler execution:
1. Call 1 (line 287): `NULL` output — probe for required buffer size
2. Call 2 (line 317): response buffer used as temp storage — extract `secured_message_version`
3. Call 3 (line 432): `ptr` — write final opaque data into actual response

The `secured_message_version` used for session setup (line 371) comes from call 2; the HMAC and transcript include data from call 3. If the integrator callback is stateful or non-deterministic (e.g., timestamp-based nonce, counter-based version list), calls 2 and 3 may return different opaque data, causing the responder to use version V₂ while the requester (which sees the call-3 response) extracts version V₃ ≠ V₂.

**Evidence**:
- Code: `libspdm_rsp_psk_exchange_rsp.c:287,317,432` — three invocations of the same callback
- Code: `libspdm_rsp_key_exchange.c:406,435,708` — identical triple-call pattern in KEY_EXCHANGE responder, confirming this is a shared architectural risk
- Open Issue #1993: flag "opaque data is silently ignored" touches this same integration surface
- `libspdm_rsp_psk_exchange_rsp.c:349` — `libspdm_zero_mem(response, *response_size)` zeroes the temp buffer from call 2 before call 3 writes to ptr, ensuring call 3 data is independent of call 2

**Affected code paths**:
- `libspdm_get_response_psk_exchange()` (PSK path)
- `libspdm_get_response_key_exchange()` (KEY_EXCHANGE path, same mechanism)

**Suggested modeling approach**:
- Model `GenerateOpaqueData` as nondeterministic, returning one of `{V_a, V_b}` per invocation
- Variables: `responder_version` (from call 2), `transcript_opaque` (from call 3)
- Invariant: `SessionEstablished → requester_negotiated_version = responder_negotiated_version`
- Granularity: split `BuildPskExchangeRsp` into `ProbeOpaqueSize`, `TempFetchOpaque` (version extraction), `FinalWriteOpaque` — allows model to explore divergence

**Priority**: **Medium**
**Rationale**: Requires non-deterministic integrator callback to trigger; not exploitable in default libspdm builds; but is the correct TLA+ abstraction for the "opaque data shapes the session" mechanism

---

### Family 3: Code Path Inconsistency — Wrong Command Code in MAC_CAP Error Response

**Mechanism**: The MAC_CAP capability check in the PSK_EXCHANGE responder was copied from the KEY_EXCHANGE handler without updating the command code constant. The error response uses `SPDM_KEY_EXCHANGE` instead of `SPDM_PSK_EXCHANGE` as param2.

**Evidence**:
- Code: `libspdm_rsp_psk_exchange_rsp.c:147` — `SPDM_KEY_EXCHANGE` in PSK handler
- Code: `libspdm_rsp_key_exchange.c:261` — `SPDM_KEY_EXCHANGE` correct in KEY_EXCHANGE handler
- Code: `libspdm_rsp_psk_exchange_rsp.c:113,136` — same check uses correct `SPDM_PSK_EXCHANGE` elsewhere in the same function

**Affected code paths**: `libspdm_get_response_psk_exchange()` MAC_CAP guard

**Priority**: **Low** (copy-paste defect; wrong field in error message but no safety impact)

---

### Family 4: Asymmetric Opaque Data Bounds Checking in PSK_FINISH

**Mechanism**: The requester side validates that PSK_FINISH_RSP opaque data does not exceed `SPDM_MAX_OPAQUE_DATA_SIZE` (`libspdm_req_psk_finish.c:292`). The responder side parses the PSK_FINISH request opaque length but only checks for total message size consistency without an explicit `> SPDM_MAX_OPAQUE_DATA_SIZE` reject. The same gap exists in the non-PSK FINISH handler.

**Evidence**:
- Code: `libspdm_req_psk_finish.c:292` — `if (opaque_data_size > SPDM_MAX_OPAQUE_DATA_SIZE)`
- Code: `libspdm_rsp_psk_finish_rsp.c:175-190` — only checks `request_size < fixed + opaque_size`; no explicit max-bound guard
- Open Issue #3597 (OPEN) and related #3592: "inconsistent check placement/strictness across symmetric paths"

**Affected code paths**: `libspdm_get_response_psk_finish()` opaque data parsing section (SPDM ≥ 1.4)

**Priority**: **Low** (spec uses "should"; patch PR #3606 in progress)

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Opaque data presence as nondeterministic input | Family 1: session with version=0 reachable when opaque absent | Parameter `has_opaque: BOOLEAN` on PSK_EXCHANGE send action |
| `secured_message_version` as explicit state variable per session | Family 1 + 2: version mismatch is the shared failure mode | Add `session_version: Nat` to session record |
| Opaque data callback as nondeterministic oracle | Family 2: triple-call race only visible when callback can return different values | Abstract `OpaqueGenerate` as `version ∈ {V1, V2}` |
| Full 4-message state machine (NOT_STARTED → HANDSHAKING → ESTABLISHED) | Ground truth for all families; dispatch-layer state transition correctness | Map to TLA+ `session_state` variable per session |
| Session ID assignment and lifecycle | Historical: session ID leak bugs (#476, #2090) are fixed, but the mechanism is subtle | Include `session_free` action triggered on error |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| Cryptographic correctness of HMAC/TH hash | TLA+ cannot verify crypto primitives; assume HMAC is unforgeable |
| Watchdog timer / heartbeat expiry | Implementation detail (wall-clock time); not relevant to session establishment correctness |
| Opaque data bounds check asymmetry (Family 4) | Hardening gap, not a reachable invariant violation; better addressed by code review / fuzzing |
| MAC_CAP wrong error code (Family 3) | Copy-paste error in error response; does not affect state machine reachability |
| Transport framing (MCTP, PCI-DOE) | Below the PSK protocol layer; correctness properties hold regardless of transport |
| Concurrent sessions | Single-threaded model is faithful to libspdm's single-context architecture |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| `has_opaque` per PSK_EXCHANGE | `has_opaque: BOOLEAN` | Track whether version negotiation data was present | Family 1 |
| `session_version` per session | `session_version: {0, V_VALID}` | Detect zero-version sessions reaching ESTABLISHED | Family 1 |
| Opaque callback nondeterminism | `opaque_result: {V_a, V_b}` per call | Model triple-call divergence | Family 2 |
| Responder vs. requester negotiated version | `rsp_version, req_version` per session | Invariant: must be equal after establishment | Family 2 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| `ValidVersionOnEstablish` | Safety | If `session_state = ESTABLISHED ∧ spdm_version ≥ 1.2`, then `session_version ≠ 0` | Family 1 |
| `VersionAgreement` | Safety | For any established session: `requester_session_version = responder_session_version` | Family 2 |
| `NoEstablishWithoutHmacVerify` | Safety | Session cannot reach ESTABLISHED unless the PSK_EXCHANGE_RSP HMAC was verified by the requester | Standard |
| `PskFinishRequiredIfContext` | Safety | If `PSK_CAP_RESPONDER_WITH_CONTEXT`, session does not reach ESTABLISHED without a PSK_FINISH round trip | Protocol structure |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|------------------------------|------------|
| MC1 | Can a PSK session reach ESTABLISHED with `secured_message_version = 0` in SPDM 1.2+ mode, by sending PSK_EXCHANGE with zero-length opaque data? | `ValidVersionOnEstablish` | Family 1 |
| MC2 | If the integrator's opaque-data callback returns version `V_a` on the second invocation and version `V_b ≠ V_a` on the third, do requester and responder assign different versions to the same session? | `VersionAgreement` | Family 2 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|------------------------|
| TV1 | `opaque_length >= *responder_opaque_data_size` off-by-one: buffer exactly sized to opaque data returns BUFFER_TOO_SMALL | Unit test: pass buffer of exactly `opaque_length` bytes; expect success not error |
| TV2 | Zero-opaque PSK_EXCHANGE on SPDM 1.2+ connection: currently accepted; per spec should be rejected | Unit test with forced `spdm_request->opaque_length = 0` on 1.2 connection |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR1 | `libspdm_rsp_psk_exchange_rsp.c:147` — MAC_CAP error response uses `SPDM_KEY_EXCHANGE` instead of `SPDM_PSK_EXCHANGE` | One-line fix: change constant to `SPDM_PSK_EXCHANGE` |
| CR2 | `libspdm_rsp_psk_finish_rsp.c:175-190` — missing explicit `> SPDM_MAX_OPAQUE_DATA_SIZE` check | Add explicit bound check; see open PR #3606 |

---

## 7. Reference Pointers

- **Core source files**:
  - `library/spdm_responder_lib/libspdm_rsp_psk_exchange_rsp.c` (561 lines) — PSK_EXCHANGE_RSP responder
  - `library/spdm_responder_lib/libspdm_rsp_psk_finish_rsp.c` (319 lines) — PSK_FINISH_RSP responder
  - `library/spdm_requester_lib/libspdm_req_psk_exchange.c` (662 lines) — PSK_EXCHANGE requester
  - `library/spdm_requester_lib/libspdm_req_psk_finish.c` (427 lines) — PSK_FINISH requester
  - `library/spdm_responder_lib/libspdm_rsp_receive_send.c:764-827` — dispatch-layer session state transitions
  - `library/spdm_secured_message_lib/libspdm_secmes_context_data.c:30-43` — `libspdm_secured_message_set_session_state` (clears handshake keys on ESTABLISHED)
  - `library/spdm_secured_message_lib/libspdm_secmes_session.c:227-330` — `libspdm_generate_session_data_key`

- **Key GitHub issues**:
  - **#1993** (OPEN, bug): "Handling of key exchange opaque data" — confirms Family 1 mechanism
  - **#3597** (OPEN) / **#3592** (OPEN): PSK_FINISH opaque length bounds check asymmetry — confirms Family 4
  - **#2150** (CLOSED, question): "Session State Transition After FINISH_RSP" — confirms dispatch-layer handles ESTABLISHED transition
  - **#613** (CLOSED, bug): "libspdm_start_watchdog enablement" — confirms watchdog placement history
  - **#476** (CLOSED, bug): Session ID leak in PSK_EXCHANGE error path — fixed
  - **#1851** (CLOSED, bug): Requester context validation — resolved by spec clarification
  - **#2268** (CLOSED, bug): PSK_EXCHANGE param1/param2 mix-up — fixed

- **Reference spec**: DSP0274 (SPDM specification), DSP0277 (SPDM secured message layer); version 1.2.1 relevant for opaque data requirements
