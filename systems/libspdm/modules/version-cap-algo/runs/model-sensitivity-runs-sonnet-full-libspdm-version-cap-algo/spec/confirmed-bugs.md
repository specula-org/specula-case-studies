# Confirmed Bugs: libspdm VCA Handshake

**System**: libspdm VERSION/CAPABILITIES/NEGOTIATE_ALGORITHMS (VCA) handshake  
**Phase**: 4 — Bug Confirmation  
**Run date**: 2026-06-09  

---

## BUG-F4: Transcript Corruption on GET_CAPABILITIES Error Return Path

- **Source**: MC (7-state counterexample, TranscriptCoherence violation)
- **Status**: REPRODUCED
- **Severity**: High
- **Location**: `library/spdm_responder_lib/libspdm_rsp_capabilities.c:443-455`

**Description**: `libspdm_get_response_capabilities()` appends the GET_CAPABILITIES
request to `message_a` (line 443) before attempting to append the response (line 449).
If the response append fails (LIBSPDM_STATUS_BUFFER_FULL), the function returns an
error response but leaves the request in `message_a` without a corresponding response.
Any subsequent retry appends the request a second time, permanently corrupting the VCA
transcript used for downstream signature verification.

**Trigger scenario**: A responder whose `message_a` buffer is nearly full (e.g., from
a prior partial exchange) receives a valid GET_CAPABILITIES request. The request fits
in the remaining buffer space, but the CAPABILITIES response does not. The responder
sends an error response, but `message_a` is left dirty.

**Developer intent investigation**: Open GitHub issue #524 (since 2021) explicitly
acknowledges this pattern: "the request message is appended to message_a before
generating the response; if response generation fails, there is no rollback mechanism."
The issue is known and unfixed. No developer commentary indicates this is intentional.

**Reproduction test**: `repro/test_bug_f4_transcript.c` — Level 2 (State Injection)

**Reproduction result**: PASS

```
=== BUG-F4: Transcript Corruption on GET_CAPABILITIES Error Path ===
Escalation level: 2 (State Injection — pre-fill message_a)

Responder message_a before fill: used=12 / cap=210
Responder message_a after fill:  used=190 / cap=210
GET_CAPABILITIES request needs 20 bytes, response needs 20 bytes
Available space: 20 bytes (fits request but not request+response)

libspdm_send_spdm_request[0] msg SPDM_GET_CAPABILITIES(0xe1), size (0x14):
0000: 12 e1 00 00 00 00 00 00 06 00 00 00 00 12 00 00 00 12 00 00
libspdm_append_managed_buffer 0x14 fail, rest 0x0 only
libspdm_receive_spdm_response[0] msg SPDM_ERROR(0x7f), size (0x4):
0000: 12 7f 05 00
Requester get_capabilities returned: 0x8001000a (ERROR)

Responder transcript.message_a.buffer_size:
  Before GET_CAPABILITIES: 190 bytes
  After  GET_CAPABILITIES: 210 bytes
  Delta: 20 bytes (GET_CAPABILITIES request = 20 bytes)

BUG-F4 CONFIRMED: Transcript corruption detected!
  The GET_CAPABILITIES exchange FAILED (error response sent),
  but the request was appended to message_a (delta=20 = request size).
  The response was NOT appended (transcript is now incoherent).
  Any retry would append the request a second time, corrupting message_a.
  Downstream KEY_EXCHANGE would compute a wrong transcript hash.
```

Key evidence: `message_a.buffer_size` grew from 190 to 210 bytes (by exactly
`sizeof(spdm_get_capabilities_request_t)` = 20 bytes) despite the exchange failing.
The error message "libspdm_append_managed_buffer 0x14 fail, rest 0x0 only" confirms
the response append failed, leaving the transcript with the request but not the response.

**Recommendation**: Rollback `message_a` to the pre-append size before returning the
error response, or buffer both request and response appends and commit only on
full success (two-phase append). The simplest fix: save `message_a.buffer_size` before
the request append and restore it on any error path below line 443.

---

## BUG-F2: Responder Capability Flags Not Self-Validated

- **Source**: MC (7-state counterexample, CapabilityCompatibility violation)
- **Status**: REPRODUCED
- **Severity**: High
- **Location**: `library/spdm_responder_lib/libspdm_rsp_capabilities.c:223-228` (check applied only to requester flags), `library/spdm_responder_lib/libspdm_rsp_capabilities.c:273-274` (responder flags taken without coherence check)

**Description**: `libspdm_get_response_capabilities()` validates the requester's
capability flags via `libspdm_check_request_flag_compatibility()` (line 223) but
never applies this check to the responder's own `local_context.capability.flags`
before advertising them in the CAPABILITIES response. A misconfigured responder
with MAC_CAP=1 but KEY_EX_CAP=0 and PSK_CAP=0 (which violates the SPDM 1.1+
rule that MAC requires KEY_EX or PSK) sends a CAPABILITIES response without error,
leaving both sides in different connection states.

**Trigger scenario**: An application configures a libspdm responder context with
`SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MAC_CAP` set but without `KEY_EX_CAP` or
`PSK_CAP`. Any requester initiating a VCA handshake will receive a CAPABILITIES
response with incoherent flags; the requester's `validate_responder_capability()`
detects the violation and terminates with INVALID_MSG_FIELD, while the responder
is already in AFTER_CAPABILITIES state. Both sides are now in different protocol
states, making the session unrecoverable without a full reset.

**Developer intent investigation**: The modeling brief notes this as CR1: "missing
KEY_EX_CAP rejection when neither CERT nor PUB_KEY_ID is set." The `validate_responder_capability()`
function in `libspdm_req_get_capabilities.c` (line 89-91) shows the asymmetry
explicitly: it validates the responder's flags for the exact rule that is missing
in the responder itself. No issue, PR, or comment in the codebase suggests this
asymmetry is intentional. The engineering principle violated: if a rule is enforced
for incoming flags (requester's), it must equally be enforced for outgoing flags
(responder's own).

**Reproduction test**: `repro/test_bug_f2_rsp_flags.c` — Level 0 (Pure black-box)

**Reproduction result**: PASS

```
=== BUG-F2: Responder Capability Flags Not Self-Validated ===
Escalation level: 0 (Pure black-box — no state injection)

Responder configured with incoherent flags:
  MAC_CAP=1, KEY_EX_CAP=0, PSK_CAP=0
  SPDM spec: 'If KEY_EX_CAP=0 and PSK_CAP=0, then MAC_CAP must be 0'

VERSION phase: OK (conn_state=1)

libspdm_receive_spdm_response[0] msg SPDM_CAPABILITIES(0x61), size (0xc):
0000: 11 61 00 00 00 00 00 00 80 00 00 00
GET_CAPABILITIES returned: 0x80010005
  Requester connection_state: 1
  Responder connection_state: 2 (AFTER_CAPABILITIES=2)
  Responder local flags (what it advertised): 0x00000080
    MAC_CAP=1, KEY_EX_CAP=0, PSK_CAP=0 (INCOHERENT)

BUG-F2 CONFIRMED: Responder flag incoherence not caught by responder!
  The responder sent CAPABILITIES with MAC_CAP=1 but no KEY_EX/PSK (SUCCESS).
  The REQUESTER detected the incoherence (LIBSPDM_STATUS_INVALID_MSG_FIELD).
  The responder is in AFTER_CAPS state; the requester is NOT.
  Protocol is deadlocked — both sides are in different connection states.
```

Key evidence: CAPABILITIES response bytes `80 00 00 00` = flags 0x80 = MAC_CAP=1.
The requester returned 0x80010005 (LIBSPDM_STATUS_INVALID_MSG_FIELD) while
the responder advanced to connection_state=2 (AFTER_CAPABILITIES). The protocol
is now deadlocked with no shared reset mechanism.

**Recommendation**: Add a self-validation call in `libspdm_get_response_capabilities()`,
immediately before line 273 (computing `response_flags`):
```c
if (!libspdm_check_request_flag_compatibility(
        spdm_context->local_context.capability.flags,
        spdm_request->header.spdm_version)) {
    return libspdm_generate_error_response(spdm_context,
                                           SPDM_ERROR_CODE_UNSPECIFIED, 0,
                                           response_size, response);
}
```

---

## BUG-F1: base_asym_algo Selected Without Enabling Capability

- **Source**: MC (10-state counterexample, NegotiatedCoherence violation)
- **Status**: REPRODUCED
- **Severity**: Medium
- **Location**: `library/spdm_responder_lib/libspdm_rsp_algorithms.c:739-742` (unconditional assignment), `library/spdm_responder_lib/libspdm_rsp_algorithms.c:927-950` (gating check incomplete)

**Description**: `libspdm_get_response_algorithms()` at lines 739-742 sets
`spdm_response->base_asym_sel` unconditionally via `libspdm_prioritize_algorithm()`.
The validation at lines 927-950 checks that `base_asym_sel != 0` when CERT, CHAL,
MEAS_CAP_SIG, or KEY_EX capabilities are enabled — but never zeroes `base_asym_sel`
when none of those capabilities are set. Historical fix #1189 added the "non-zero
when needed" check but missed the complementary "zero when not needed" check.
The result is an incoherent NEGOTIATED state where `connection_info.algorithm.base_asym_algo`
is non-zero despite no capability requiring asymmetric algorithms.

**Trigger scenario**: Both requester and responder have no asym-requiring capabilities
(CERT_CAP=0, CHAL_CAP=0, MEAS_CAP_SIG=0, KEY_EX_CAP=0) but both have non-zero
`base_asym_algo` configured in their local context (a common misconfiguration when
copying context setup from a fully-capable peer). The NEGOTIATE_ALGORITHMS exchange
succeeds on both sides, producing a NEGOTIATED state with `base_asym_algo = RSAPSS_3072`
and capability flags = 0. Any downstream code that checks `base_asym_algo != 0`
as a proxy for "asymmetric operations are available" would incorrectly proceed with
cert/signature operations.

**Developer intent investigation**: The modeling brief identifies this as MC1.
Fix #1189 (closed PR) added the validation at lines 927-950 ("base_asym must be
non-zero when asym-requiring cap is set") but contains no comment or code handling
the inverse case. The asymmetry in the fix suggests the "zero when not needed"
check was simply overlooked, not a deliberate trade-off. Engineering principle
violated: if "A requires B" is enforced, "~A requires ~B" must also be enforced
for the invariant to hold in both directions.

**Reproduction test**: `repro/test_bug_f1_asym_no_cap.c` — Level 0 (Pure black-box)

**Reproduction result**: PASS

```
=== BUG-F1: base_asym_algo Selected Without Enabling Capability ===
Escalation level: 0 (Pure black-box — SPDM v1.0, no capabilities, non-zero asym algo)

Setup:
  SPDM version: v1.0
  Requester caps: 0x0 (no CERT/CHAL/KEY_EX/PSK)
  Responder caps: 0x0 (no CERT/CHAL/KEY_EX/PSK)
  Both sides: base_asym_algo = RSAPSS_3072 (0x00000008)

VERSION:   OK (negotiated v1.0)
CAPABILITIES: OK (both sides: flags=0)

libspdm_receive_spdm_response[0] msg SPDM_ALGORITHMS(0x63), size (0x24):
0000: 10 63 00 00 24 00 00 00 00 00 00 00 08 00 00 00 01 00 00 00 ...
base_asym - 0x00000008    ← non-zero despite no enabling cap

NEGOTIATE_ALGORITHMS returned: 0x0 (SUCCESS)

Post-handshake state (responder side):
  rsp conn_state:               3 (NEGOTIATED=3)
  rsp capability.flags:         0x00000000 (no CERT/CHAL/KEY_EX)
  rsp algorithm.base_asym_algo: 0x00000008 (BUG: non-zero, expected 0)
  rsp algorithm.base_hash_algo: 0x00000001

BUG-F1 CONFIRMED: Incoherent negotiated state!
  The NEGOTIATE_ALGORITHMS exchange SUCCEEDED (both sides: NEGOTIATED state).
  But the negotiated base_asym_algo=0x00000008 is non-zero
  while NO asym-requiring capability (CERT/CHAL/MEAS_SIG/KEY_EX) is enabled.
  Root cause: libspdm_rsp_algorithms.c:739-742 sets base_asym_sel unconditionally.
  Lines 927-950 check 'non-zero when needed' but NOT 'zero when not needed'.
```

Key evidence: ALGORITHMS response bytes `08 00 00 00` at offset 12 = `base_asym_sel = 0x8`
(RSAPSS_3072). Both sides reach NEGOTIATED (conn_state=3) with capability.flags=0x0
but base_asym_algo=0x00000008. The invariant `(CERT∨CHAL∨MEAS_SIG∨KEY_EX) ⟺ base_asym≠0`
is violated.

**Recommendation**: In `libspdm_get_response_algorithms()`, after the unconditional
`base_asym_sel` assignment at lines 739-742, add a conditional zero-out:
```c
if (!libspdm_is_capabilities_flag_supported(spdm_context, false, 0,
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CERT_CAP) &&
    !libspdm_is_capabilities_flag_supported(spdm_context, false, 0,
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_CHAL_CAP) &&
    !libspdm_is_capabilities_flag_supported(spdm_context, false, 0,
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MEAS_CAP_SIG) &&
    !libspdm_is_capabilities_flag_supported(spdm_context, false,
        SPDM_GET_CAPABILITIES_REQUEST_FLAGS_KEY_EX_CAP,
        SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_KEY_EX_CAP)) {
    spdm_response->base_asym_sel = 0;
}
```

---

## F3: AlgTableMirroring — No Bug (Clean)

- **Source**: Code Review (no counterexample; BFS exhausted 602 states with no violation)
- **Status**: FALSE POSITIVE (spec enforces invariant by construction)
- **Note**: Not subject to bug-confirmation (no MC counterexample; code-review × already-explained)

The spec enforces `struct_alg_types = req_types` directly as an equality guard in
`RspHandleNegotiateAlgorithms`. Historical fix (commit `941f0ae0`) addressed the
original mirroring bug. F3 is clean.

---

## Summary

| Bug ID | Status      | Escalation | Confidence |
|--------|-------------|------------|------------|
| BUG-F4 | REPRODUCED  | Level 2    | High       |
| BUG-F2 | REPRODUCED  | Level 0    | High       |
| BUG-F1 | REPRODUCED  | Level 0    | High       |
| F3     | FALSE POSITIVE | N/A     | N/A        |
