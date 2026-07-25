# Instrumentation Spec: libspdm-cert-auth

Maps TLA+ spec actions to source code for trace collection via harness instrumentation.

## Section 1: Trace Event Schema

### Event Envelope
Each trace event is a JSON object with:
- `event`: string (event name, matches spec action)
- `node`: string ("requester" or "responder")
- `timestamp`: integer (microseconds since test start)
- `state_before`: object (captured state fields before action)
- `state_after`: object (captured state fields after action)

### State Fields (Captured at Every Event)
Mapping from implementation to TLA+ variables:

| Implementation Field | TLA+ Variable | Get Location | Notes |
|---|---|---|---|
| `context->connection_state` | `connection_state` | context->connection_state | Per-endpoint |
| `context->spdm_version` | `spdm_version` | context->spdm_version | Negotiated version |
| `local_context.message_c` | `message_c` | spdm_context->transcript.message_c | Transcript buffer |
| `local_context.message_mut_c` | `message_mut_c` | spdm_context->transcript.message_mut_c | Mutual auth transcript |
| `local_context.authentication_phase` | `authentication_phase` | Shadow field (not in code) | Must instrument |
| `challenge_context.slot_id` | `slot_id` | request->slot_id or challenge_context->slot_id | Current operation |
| `challenge_context.responder_nonce` | `responder_nonce` | Nonce buffer (ptr) | 32 bytes |
| `challenge_context.requester_nonce` | `requester_nonce` | Nonce buffer (ptr) | 32 bytes |

### Message Fields (Event-Specific)
Capture only for CHALLENGE/CHALLENGE_AUTH messages:

| Message Field | TLA+ Field | Format | Example |
|---|---|---|---|
| `slot_id` | slot_id | uint8 | 0-7 or 0xFF |
| `version` | spdm_version | uint8 | 1-4 (SPDM 1.0-1.3) |
| `nonce` | nonce | bytes (32) | hex string |
| `context` | requester_context | bytes (32) | hex or null |
| `signature` | signature_valid | bool | true/false |

## Section 2: Action-to-Code Mapping

### Action 1: `RequesterSendChallenge`

| Field | Value |
|---|---|
| **Spec Action** | RequesterSendChallenge |
| **Code Location** | `library/spdm_requester_lib/libspdm_req_challenge.c:119-211` |
| **Trigger Point** | After line 127 (nonce generation), before message send |
| **Trace Event Name** | `requester_send_challenge` |
| **Fields to Capture** | slot_id, version, nonce, context (if 1.3+) |
| **Bug Families** | 1, 3, 4, 6 |

**Implementation Flow**:
1. Line 119-127: Generate requester nonce (Family 4)
2. Line 134-143: Handle request context for SPDM 1.3+ (Family 6)
3. Line 196-213: Validate slot_id per version (Family 3)
4. Send CHALLENGE message

**Capture Points**:
- Pre-action: `connection_state`, `spdm_version`
- During: `requester_nonce` (after generation), `slot_id` (from parameter), `requester_context` (if set)
- Post-action: confirm `authentication_phase = "ONE_WAY_STARTED"`

**Notes**:
- SPDM 1.3+ only: context field will be set. For earlier versions, set to null.
- Nonce size: 32 bytes, capture as hex string.
- Version validation at line 196-213 has version-specific logic; capture the version negotiated.

---

### Action 2: `ResponderHandleChallenge`

| Field | Value |
|---|---|
| **Spec Action** | ResponderHandleChallenge |
| **Code Location** | `library/spdm_responder_lib/libspdm_rsp_challenge_auth.c:95-342` |
| **Trigger Point** | After line 342 (state reset), before return |
| **Trace Event Name** | `responder_handle_challenge` |
| **Fields to Capture** | slot_id, key_source (CERT_CHAIN vs PUBLIC_KEY_ONLY), nonce, context_echo |
| **Bug Families** | 1, 2, 3, 4, 5, 6 |

**Implementation Flow**:
1. Line 95-126: Validate slot_id per version (Family 3)
2. Line 199-220: Select hash source (cert chain vs public key) based on slot_id (Family 5)
3. Line 225-230: Generate responder nonce (Family 4)
4. Line 291-295: Echo request context (Family 6, SPDM 1.3+)
5. Line 312-326: Append to message_c transcript (Family 2)
6. Line 336-338: Check mutual_auth_req flag, set connection_state (Family 1)
7. Line 341-342: Reset message buffers

**Capture Points**:
- Pre-action: `slot_id` (from CHALLENGE message), `authentication_phase`
- During:
  - After line 220: `key_source` (PUBLIC_KEY_ONLY if 0xFF, else CERT_CHAIN)
  - After line 230: `responder_nonce` (32 bytes, hex)
  - After line 295: `requester_context_in_response` (if SPDM 1.3+)
  - After line 326: `message_c` length (transcript size)
- Post-action: 
  - `connection_state` (AUTHENTICATED or CHALLENGED)
  - `authentication_phase` (ONE_WAY_COMPLETE or MUTUAL_IN_PROGRESS)

**Notes**:
- Slot validation at line 117-126 checks SPDM 1.3+ key usage bits; capture separately if error.
- Key source selection at line 199-220 is critical for Family 5.
- Message buffer reset at line 341-342 happens AFTER response generation; capture state before reset.
- Line 336-338 behavior: if mutual_auth_req flag is NOT set in request, set AUTHENTICATED; otherwise stay in mutual auth phase.

---

### Action 3: `RequesterHandleChallengeAuth`

| Field | Value |
|---|---|
| **Spec Action** | RequesterHandleChallengeAuth |
| **Code Location** | `library/spdm_requester_lib/libspdm_req_challenge.c:249-380` |
| **Trigger Point** | After line 380 (state set to AUTHENTICATED), before encap request send |
| **Trace Event Name** | `requester_handle_challenge_auth` |
| **Fields to Capture** | slot_id, key_source, nonce, context_match |
| **Bug Families** | 1, 5, 6 |

**Implementation Flow**:
1. Line 249-258: Verify hash based on key source (Family 5)
2. Line 265-267: Store responder nonce
3. Line 336-346: Verify context echo via constant-time comparison (Family 6)
4. **Line 380: Set connection_state to AUTHENTICATED** (Family 1 BUG POINT)
5. Line 389: Issue encapsulated mutual auth request (if requested)

**Capture Points**:
- Pre-action: `connection_state` (should be CHALLENGED)
- During:
  - After line 258: `key_source` (PUBLIC_KEY_ONLY if 0xFF, else CERT_CHAIN)
  - After line 267: `responder_nonce` (from response)
  - After line 346: `requester_context_in_response` (echo result)
- Post-action:
  - **CRITICAL**: `connection_state` should be AUTHENTICATED (Family 1 race point)
  - `authentication_phase` should match responder's phase (won't, if mutual_auth_req)

**Notes**:
- **CRITICAL BUG POINT (Family 1)**: Line 380 sets AUTHENTICATED before encapsulated mutual auth completes (line 389).
  This creates a state race: requester thinks AUTHENTICATED, responder may still expect mutual auth.
  Capture this state transition explicitly.
- Context echo verification (line 340) uses `libspdm_consttime_is_mem_equal()`.
  Capture whether comparison succeeded (true/false).
- Encapsulated request is sent at line 389, which happens AFTER state already set. 
  This is the race condition.

---

### Action 4: `ResponderHandleEncapChallenge`

| Field | Value |
|---|---|
| **Spec Action** | ResponderHandleEncapChallenge |
| **Code Location** | `library/spdm_responder_lib/libspdm_rsp_encap_challenge.c:62-75` |
| **Trigger Point** | After line 75 (message appended), before return |
| **Trace Event Name** | `responder_handle_encap_challenge` |
| **Fields to Capture** | transcript_type, message_size |
| **Bug Families** | 2 |

**Implementation Flow**:
1. Line 62-75: Reset message buffer, append encapsulated challenge to message_mut_c (Family 2)
2. Generate encapsulated response

**Capture Points**:
- Pre-action: `active_transcript` (should be MAIN or MUTUAL_AUTH)
- During:
  - After line 75: `active_transcript = MUTUAL_AUTH`, `message_mut_c` size
  - Ensure `message_c` is not corrupted (capture both buffers)
- Post-action: `message_mut_c` length should match expectation

**Notes**:
- **Family 2**: Ensure separate transcript isolation. Capture both `message_c` and `message_mut_c` to detect cross-contamination.
- The buffer reset at line 62 is intentional (new request starts new transcript).
- No message send here; this is request processing, response generated in-place.

---

### Action 5: `RequesterHandleEncapChallengeAuth`

| Field | Value |
|---|---|
| **Spec Action** | RequesterHandleEncapChallengeAuth |
| **Code Location** | `library/spdm_req_challenge.c` (after line 389) |
| **Trigger Point** | After mutual auth response processing, before return |
| **Trace Event Name** | `requester_handle_encap_challenge_auth` |
| **Fields to Capture** | authentication_phase, connection_state |
| **Bug Families** | 1, 2 |

**Implementation Flow**:
1. Process encapsulated challenge response
2. Update authentication_phase to FULLY_AUTHENTICATED
3. Finalize mutual auth

**Capture Points**:
- Pre-action: `authentication_phase` (should be ONE_WAY_COMPLETE)
- Post-action: 
  - `authentication_phase = FULLY_AUTHENTICATED`
  - `connection_state = FULLY_AUTH`
  - Both sides should now agree

**Notes**:
- **Family 1**: This is where the race resolves. Both sides should be in FULLY_AUTHENTICATED state.
  Capture state agreement between requester and responder.
- **Family 2**: Verify that mutual auth response uses correct transcript (message_mut_c).

---

## Section 3: Special Considerations

### Implementation State Shadows

The TLA+ spec introduces variables that don't exist directly in the C code:

| TLA+ Variable | Why Not in Code | How to Capture |
|---|---|---|
| `authentication_phase` | Code only checks individual flags (BASIC_MUT_AUTH_REQ, etc.) | Create shadow variable to track phase: NONE → ONE_WAY_STARTED → ONE_WAY_COMPLETE → MUTUAL_IN_PROGRESS → FULLY_AUTHENTICATED |
| `active_transcript` | Code doesn't explicitly track which transcript is active | Track at message buffer append points (message_c vs message_mut_c) |
| `key_source` | Implicit in code path (slot_id == 0xFF check) | Set when path is taken (line 199 for CERT_CHAIN, line 202 for PUBLIC_KEY) |

### Version-Specific Logic

Multiple code paths check version >= SPDM_VERSION_13. Capture version context:
- Line 97-101 (responder): validates slot_id for all versions, but line 117-126 has SPDM 1.3+ specific checks
- Line 134-143 (requester): request context only for 1.3+
- Line 291-295 (responder): context echo only for 1.3+

### Race Condition Timing (Family 1)

The race between `RequesterHandleChallengeAuth` and `ResponderHandleEncapChallenge` requires:
1. Capture exact timestamp of when requester sets AUTHENTICATED (line 380)
2. Capture exact timestamp of when responder enters MUTUAL_IN_PROGRESS (line 338)
3. Compare: if requester's timestamp < responder's mutual start, state race is observable

Use high-resolution clock (e.g., `clock_gettime(CLOCK_MONOTONIC)`) for timing.

### Nonce Size and Format

- Nonce size: 32 bytes (SPDM spec constant SPDM_NONCE_SIZE)
- Capture as hex string for readability
- Example: `"nonce": "a1b2c3d4..."`

### Context Field (SPDM 1.3+)

- Context size: 32 bytes (SPDM 1.3 spec)
- Capture as hex string
- If version < 1.3, set to `null` in trace
- Echo point: requester_context_in_response must equal requester_context after line 295

### Signature Field

- The spec simplifies signature verification to a boolean check (`signature_valid`)
- In reality, signatures are cryptographically verified
- For instrumentation: capture a boolean indicating whether verification succeeded
- This is sufficient for protocol-level race detection; crypto bugs are out of scope

### Error Cases

If any action fails (e.g., signature verification fails at line 265):
- Still emit a trace event (with `success: false`)
- Capture the error code
- Continue (spec allows failure paths)

---

## Trace JSON Example

```json
{"event": "requester_send_challenge", "node": "requester", "timestamp": 1000, "slot_id": 0, "version": 1, "nonce": "a1b2c3d4...", "context": null, "state_before": {"connection_state": "null", "authentication_phase": "NONE"}, "state_after": {"connection_state": "null", "authentication_phase": "ONE_WAY_STARTED"}}
{"event": "responder_handle_challenge", "node": "responder", "timestamp": 2000, "slot_id": 0, "key_source": "cert_chain", "nonce": "d4c3b2a1...", "message_c_len": 150, "state_before": {"connection_state": "null"}, "state_after": {"connection_state": "challenged", "authentication_phase": "MUTUAL_IN_PROGRESS"}}
{"event": "requester_handle_challenge_auth", "node": "requester", "timestamp": 3000, "slot_id": 0, "key_source": "cert_chain", "context_match": true, "state_before": {"connection_state": "challenged"}, "state_after": {"connection_state": "authenticated", "authentication_phase": "ONE_WAY_COMPLETE"}}
```

---

## Phase 2.5 Checklist: Coverage Mapping

| Brief §2 Family | Invariant | Hunt Config | Capture Points |
|---|---|---|---|
| Family 1 (State Race) | StateConsistency | MC_hunt_family1.cfg | Line 380 (requester) vs Line 338 (responder) |
| Family 2 (Transcript Isolation) | TranscriptIntegrity | MC_hunt_family2.cfg | message_c vs message_mut_c at lines 326, 75 |
| Family 3 (Slot ID Validation) | SlotIDMatch | MC_hunt_family3.cfg | Line 97-101, 117-126 per version |
| Family 4 (Nonce Freshness) | NonceFreshness | MC_hunt_family4.cfg | Line 230 responder, line 119 requester |
| Family 5 (Key Source Consistency) | KeySourceConsistency | MC_hunt_family5.cfg | Line 199/202 (responder) vs line 249-258 (requester) |
| Family 6 (Context Echo) | ContextEcho | MC_hunt_family6.cfg | Line 295 (responder), line 340 (requester verification) |

All 6 families are instrumented. Each hunt config targets one family with tight bounds.

