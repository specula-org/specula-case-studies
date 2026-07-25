# Bug Report: libspdm VCA Handshake — Model Checking Results

**System**: libspdm VERSION/CAPABILITIES/NEGOTIATE_ALGORITHMS (VCA) handshake  
**Spec**: `spec/base.tla` + `spec/MC.tla`  
**Run date**: 2026-06-09  
**Method**: BFS model checking with reduced-flag configs (collapsed AllCapFlags to 2–6 unique values to avoid 2^16 state explosion); full BFS completed in < 10s per run  

---

## Summary

| Bug ID | Invariant | Result | Severity | Category |
|--------|-----------|--------|----------|----------|
| BUG-F4 | TranscriptCoherence | **CONFIRMED** (Case C) | High | F4: Transcript Integrity |
| BUG-F2 | CapabilityCompatibility | **CONFIRMED** (Case C) | High | F2: Capability Asymmetry |
| BUG-F1 | NegotiatedCoherence | **CONFIRMED** (Case C) | Medium | F1: Version×Algo Coherence |
| F3-OK  | AlgTableMirroring | No violation (600+ states exhausted) | — | F3: Struct Table Mirroring |

---

## BUG-F4: Transcript Corruption on Error Return Paths

**ID**: BUG-F4  
**Severity**: High  
**Category**: F4 — Transcript Integrity on VCA Error Paths  
**Classification**: Case C — Real implementation bug  
**Invariant violated**: `TranscriptCoherence`  
**Counterexample trace length**: 7 states  

### Root Cause

`libspdm_rsp_capabilities.c` (and `libspdm_rsp_algorithms.c`) appends the request message to `message_a` **before** generating the response. If response generation fails at any point, the transcript already contains the request with no corresponding response. There is no rollback mechanism. This is open issue #524 (since 2021).

The spec models this directly via `RspErrorInCapabilities` which sets `req_appended["capabilities"] = TRUE` but leaves `rsp_appended["capabilities"] = FALSE`, then clears the in-flight message.

### Counterexample (7 states)

```
State 1: Initial — all FALSE, conn_state=NOT_STARTED
State 2: MCReqSendGetVersion
         → in_flight_msg=GET_VERSION, req_appended[version]=TRUE
State 3: MCRspHandleGetVersion("v10")
         → in_flight_msg=VERSION, rsp_appended[version]=TRUE
State 4: MCReqHandleVersion
         → conn_state=AFTER_VERSION, rsp_appended[version]=TRUE
State 5: MCReqSendGetCapabilities({"F"})
         → in_flight_msg=GET_CAPABILITIES, req_appended[capabilities]=TRUE
State 6: MCRspErrorInCapabilities             ← FAULT ACTION FIRES
         → in_flight_msg=NONE (cleared), rsp_appended[capabilities]=FALSE (unchanged)
         faultCounters.rspError = 1
State 7: VIOLATION
         in_flight_msg = [type → "NONE"]
         req_appended  = {version:T, capabilities:T, algorithms:F}
         rsp_appended  = {version:T, capabilities:F, algorithms:F}  ← INCOHERENT
```

**Invariant check**: `in_flight_msg = NONE ⟹ ∀ phase: req_appended[phase] ⟹ rsp_appended[phase]`  
Fails: `req_appended["capabilities"] = TRUE` but `rsp_appended["capabilities"] = FALSE`.

### Affected Code

- `library/spdm_responder_lib/libspdm_rsp_capabilities.c:397-447` — BUFFER_TOO_SMALL path leaves `message_a` dirty
- `library/spdm_responder_lib/libspdm_rsp_algorithms.c` — same append-before-generate pattern
- `library/spdm_responder_lib/libspdm_rsp_version.c` — same pattern, though lower severity

### Impact

If error recovery causes the requester to retry GET_CAPABILITIES, the request would be appended **a second time** to `message_a`, producing a different transcript hash than the responder. Any subsequent signature or MAC verification using `message_a` (e.g., in KEY_EXCHANGE) would fail or silently accept a wrong value.

---

## BUG-F2: Responder Capability Flags Not Self-Validated

**ID**: BUG-F2  
**Severity**: High  
**Category**: F2 — Capability Compatibility Asymmetry  
**Classification**: Case C — Real implementation bug  
**Invariant violated**: `CapabilityCompatibility` (third conjunct)  
**Counterexample trace length**: 7 states  

### Root Cause

`libspdm_get_response_capabilities` (`libspdm_rsp_capabilities.c:165`) validates the **requester's** capability flags using `libspdm_check_request_flag_compatibility` (line 223) but does **not** validate the **responder's own** flags for internal consistency. The responder's flags are taken directly from `spdm_context->local_context.capability.flags` and sent without checking coherence rules.

`libspdm_check_request_flag_compatibility` correctly enforces (for the requester's flags):
- If MAC is set, KEY_EX or PSK must be set
- If no KEY_EX and no PSK, MAC/ENCRYPT must not be set

But this function is never called on the responder's own advertised flags.

### Counterexample (7 states)

```
State 1–4: VERSION handshake with v12 (V11Plus)
State 5: MCReqSendGetCapabilities({})
         → requester sends empty flags
State 6: MCRspHandleGetCapabilities({}, {"MAC"})    ← RESPONDER ADVERTISES MAC
         → conn_state = AFTER_CAPS
           rsp_cap_flags = {"MAC"}   (MAC without KEY_EX or PSK)
           in_flight_msg = {type:CAPABILITIES, rsp_flags:{"MAC"}}
State 7: VIOLATION
         conn_state = AFTER_CAPS
         negotiated_version = "v12" (V11Plus)
         rsp_cap_flags = {"MAC"}
         CapabilityCompatibility 3rd conjunct:
           ~HasKeyExCap(rsp) ∧ ~HasPskCap(rsp) ⟹ ~HasMacCap(rsp) ∧ ~HasEncryptCap(rsp)
           TRUE ∧ TRUE ⟹ FALSE  →  VIOLATED
```

### Additional CapabilityCompatibility Paths

A second violation (second conjunct: `KEY_EX_CAP ⟹ CERT_CAP ∨ PUB_KEY_ID_CAP`) also exists but was not reached first by BFS. The responder can similarly advertise `KEY_EX_CAP` without `CERT_CAP` or `PUB_KEY_ID_CAP` since no self-validation is performed. This matches the CR1 finding from the modeling brief.

### Affected Code

- `library/spdm_responder_lib/libspdm_rsp_capabilities.c:165-487` — `libspdm_get_response_capabilities` does not call `libspdm_check_request_flag_compatibility` (or equivalent) on `spdm_context->local_context.capability.flags`
- `library/spdm_responder_lib/libspdm_rsp_capabilities.c:116` — noted in modeling brief as CR1: missing KEY_EX_CAP rejection when neither CERT nor PUB_KEY_ID is set

### Impact

A misconfigured libspdm responder (e.g., MAC_CAP=1, KEY_EX_CAP=0, PSK_CAP=0 in local_context) would advertise an invalid capability combination without any INVALID_REQUEST error. The requester's `validate_responder_capability` may reject this, but only after the capability exchange appears to succeed from the responder's perspective — leaving both sides in different state machine positions.

---

## BUG-F1: `base_asym_algo` Selected Without Enabling Capability

**ID**: BUG-F1  
**Severity**: Medium  
**Category**: F1 — Version × Capability × Algorithm Coherence  
**Classification**: Case C — Real implementation bug  
**Invariant violated**: `NegotiatedCoherence` (fourth conjunct: base_asym_algo coherence)  
**Counterexample trace length**: 10 states  

### Root Cause

`libspdm_rsp_algorithms.c:739-742` sets `base_asym_sel` **unconditionally**:

```c
spdm_response->base_asym_sel = libspdm_prioritize_algorithm(
    asym_priority_table, LIBSPDM_ARRAY_SIZE(asym_priority_table),
    spdm_context->local_context.algorithm.base_asym_algo,
    spdm_context->connection_info.algorithm.base_asym_algo);
```

Lines 927-950 then validate that `base_asym_algo != 0` **when** CERT, CHAL, MEAS_CAP_SIG, or KEY_EX capabilities are set. However, there is **no corresponding check** that zeros `base_asym_algo` when **none** of those capabilities are set. Historical fix #1189 added the "must be non-zero when needed" check but did not add the complementary "must be zero when not needed" check.

Result: if the NEGOTIATE_ALGORITHMS request includes non-zero `base_asym_algo` algorithms AND the local config has matching preferences, the ALGORITHMS response will contain a non-zero `base_asym_sel` even when no capability requiring asym (CERT/CHAL/MEAS_SIG/KEY_EX) is enabled.

### Counterexample (10 states)

```
State 1–4: VERSION handshake with v10
State 5: MCReqSendGetCapabilities({})     — empty caps
State 6: MCRspHandleGetCapabilities({},{})— empty req and rsp caps; conn_state=AFTER_CAPS
State 7: MCReqHandleCapabilities          — accepts empty rsp_caps
State 8: MCReqSendNegotiateAlgorithms({})
State 9: MCRspHandleNegotiateAlgorithms(0, 1, 0, 0, {}, 0, 0, 0, 0)
          ← sh=ALGO_NONE, sa=ALGO_SOME (!)
         conn_state = NEGOTIATED
         rsp_cap_flags = {}   (no CERT, CHAL, MEAS_SIG, KEY_EX)
         base_asym_algo = ALGO_SOME   ← set despite no enabling cap
State 10: VIOLATION
          NegotiatedCoherence 4th conjunct:
          (HasCertCap ∨ CHAL_CAP ∨ MEAS_CAP_SIG ∨ HasKeyExCap) ⟺ base_asym_algo=ALGO_SOME
          FALSE ⟺ TRUE  →  VIOLATED
```

### Note on MEL-Specific F1 Bug

A second NegotiatedCoherence violation path exists (the MC1 bug from the modeling brief):
- rsp_cap_flags has MEL_CAP but NOT MEAS_CAP
- `RspHandleNegotiateAlgorithms` selects `mspec = ALGO_NONE` (implementation may do this since the request has `measurement_hash_algo=0` when only MEL_CAP is set, causing `libspdm_prioritize_algorithm` at line 724 to return 0 via mspec path)  
- NegotiatedCoherence: `(HasMelCap ∨ HasMeasCap) ⟺ mspec=ALGO_SOME` → violated when MEL=1 but mspec=0

This path requires v13+ and a MEL_CAP-bearing rsp_cap_flags. The BFS found the shorter base_asym path first. Both violations map to real implementation issues in `libspdm_rsp_algorithms.c`.

### Affected Code

- `library/spdm_responder_lib/libspdm_rsp_algorithms.c:739-742` — unconditional `base_asym_sel` assignment
- `library/spdm_responder_lib/libspdm_rsp_algorithms.c:927-950` — validates non-zero when needed but never zeros when not needed
- `library/spdm_responder_lib/libspdm_rsp_algorithms.c:718-737` — MEL/MEAS_CAP conditioned mspec but unconditional mhash

### Impact

A NEGOTIATED state with `base_asym_algo != 0` but no CERT/CHAL/KEY_EX capability creates an incoherent negotiation outcome. Downstream session establishment code that checks "is base_asym_algo set?" as a proxy for "do we have asymmetric capabilities?" may incorrectly attempt asymmetric operations and fail or behave unexpectedly.

---

## F3: AlgTableMirroring — No Violation Found

**Invariant**: `AlgTableMirroring`  
**Result**: No violation. 602 distinct states exhausted (full BFS, no states remaining).  

The spec enforces `struct_alg_types = req_types` directly as an equality guard in `RspHandleNegotiateAlgorithms`, making this invariant hold by construction. The requester additionally verifies mirroring in `ReqHandleAlgorithms`. No path can reach NEGOTIATED with mismatched sets. This is consistent with the historical fix (commit `941f0ae0`) having addressed the original mirroring bug.

*Note*: The initial F3 BFS run (without `-deadlock` flag) reported "Deadlock reached" at state 5 — this is the natural end-of-protocol deadlock when `conn_state=NEGOTIATED` and no further actions are enabled (MaxResetLimit=0). Re-running with deadlock suppression (`-deadlock` flag) completed cleanly.

---

## TLC Run Configuration

All runs used reduced-flag configs to avoid the 2^16 SUBSET state explosion:

| Run | Config | AllCapFlags size | SUBSET size | States | Duration |
|-----|--------|-----------------|-------------|--------|---------|
| F4 hunt | MC_hunt_f4_small.cfg | 1 ("F") | 2 | 259 | 5s |
| F2 hunt | MC_hunt_f2_small.cfg | 6 distinct | 64 | 404 | 5s |
| F1 hunt | MC_hunt_f1_small.cfg | 5 distinct | 32 | 28,062 | 6s |
| F3 hunt | MC_hunt_f3_small.cfg | 1 ("F") | 2 | 602 | 2s |

**Why reduction was needed**: The original configs with 16 distinct cap flags produce SUBSET AllCapFlags = 65,536 elements; BFS and simulation mode both hit JVM GC overhead (OOM) during state enumeration. The reduced configs preserve all semantically relevant flag distinctions for each bug family while making the search tractable.

---

## Affected Source Files

| File | Bug IDs |
|------|---------|
| `library/spdm_responder_lib/libspdm_rsp_capabilities.c:165-487` | BUG-F2, BUG-F4 |
| `library/spdm_responder_lib/libspdm_rsp_capabilities.c:49-163` | BUG-F2 (validator not applied to own flags) |
| `library/spdm_responder_lib/libspdm_rsp_algorithms.c:718-742` | BUG-F1 |
| `library/spdm_responder_lib/libspdm_rsp_algorithms.c:927-950` | BUG-F1 (incomplete gating) |

---

## Open Issues Cross-Reference

| Issue | Status | Bug ID |
|-------|--------|--------|
| #524 — transcript dirty on error path | OPEN since 2021 | BUG-F4 (confirmed by MC) |
| CR1 — responder missing KEY_EX check in capability validator | OPEN | BUG-F2 (broader: own-flag coherence) |
| Fix #1189 — base_asym/hash gating (partial) | CLOSED | BUG-F1 (regression: zero-out case missing) |

---

## Phase 4: Bug Confirmation Results

**Confirmation date**: 2026-06-09  
**Full details**: `spec/confirmed-bugs.md`  
**Reproduction tests**: `repro/test_bug_f{1,2,4}_*.c`

### BUG-F4 Confirmation

**Final status**: REPRODUCED (Level 2 — State Injection)

**Code audit**: Confirmed. `libspdm_rsp_capabilities.c:443` appends the request
to `message_a` BEFORE the response is built. If the response append at line 449
fails (BUFFER_FULL), the function returns an error response but `message_a` contains
the request without a corresponding response. `libspdm_reset_message_buffer_via_request_code(GET_CAPABILITIES)`
does NOT reset `message_a` (falls through to the default no-op case), so pre-existing
data in `message_a` is preserved across the failed exchange.

**Developer intent**: Open issue #524 (since 2021) explicitly describes this exact
mechanism. No indication this is intentional. The fix has simply not been implemented.

**Reproduction result (Level 2)**:
- Pre-fill `message_a` to `cap - request_size` bytes (leaving exactly room for the request but not the response)
- Send GET_CAPABILITIES via the requester API
- **Observable**: `message_a.buffer_size` grew from 190 to 210 bytes (delta = 20 = request size) despite the exchange returning an error response
- Debug line: `libspdm_append_managed_buffer 0x14 fail, rest 0x0 only` confirms response append failed after request was appended
- Level 0 not feasible: the buffer is large enough by default; overflow only occurs when buffer is nearly full

**Recommendation**: Save `message_a.buffer_size` before line 443; restore it on
any error path below that line (rollback). Or use a two-phase commit: stage both
appends in a scratch buffer and commit atomically only on full success.

---

### BUG-F2 Confirmation

**Final status**: REPRODUCED (Level 0 — Pure black-box)

**Code audit**: Confirmed. `libspdm_get_response_capabilities()` calls
`libspdm_check_request_flag_compatibility(spdm_request->flags, version)` at line 223
(validates requester flags) but has no equivalent call on
`spdm_context->local_context.capability.flags` (the responder's own advertised flags).
`libspdm_mask_capability_flags()` at line 273 only strips version-invalid bits; it
does not enforce coherence rules (MAC requires KEY_EX or PSK, etc.).
`validate_responder_capability()` in the requester library (line 89-91) implements
exactly the check the responder is missing.

**Developer intent**: No commentary in the codebase indicates this asymmetry is
intentional. The matching function exists in the requester library, suggesting the
omission is an oversight. The bug is broader than the original CR1 finding (which
focused on KEY_EX→CERT), as the same gap affects all multi-flag coherence rules.

**Reproduction result (Level 0)**:
- Configure responder with `SPDM_GET_CAPABILITIES_RESPONSE_FLAGS_MAC_CAP` only (no KEY_EX/PSK)
- SPDM v1.1 VCA handshake via `libspdm_get_capabilities()`
- **Observable**: CAPABILITIES response bytes `80 00 00 00` = MAC_CAP=1 (no error from responder); requester returns `LIBSPDM_STATUS_INVALID_MSG_FIELD` (0x80010005); responder advances to `connection_state=AFTER_CAPABILITIES=2`; requester stays at `connection_state=AFTER_VERSION=1`
- Protocol is deadlocked with both sides in different states

**Recommendation**: Add `libspdm_check_request_flag_compatibility(spdm_context->local_context.capability.flags, version)` before line 273 in `libspdm_get_response_capabilities()`. Return `SPDM_ERROR_CODE_UNSPECIFIED` if it fails.

---

### BUG-F1 Confirmation

**Final status**: REPRODUCED (Level 0 — Pure black-box)

**Code audit**: Confirmed. `libspdm_rsp_algorithms.c:739-742`:
```c
spdm_response->base_asym_sel = libspdm_prioritize_algorithm(
    asym_priority_table, LIBSPDM_ARRAY_SIZE(asym_priority_table),
    spdm_context->local_context.algorithm.base_asym_algo,
    spdm_context->connection_info.algorithm.base_asym_algo);
```
This executes unconditionally. Lines 927-950 guard against "base_asym=0 when needed"
but have no guard for "base_asym≠0 when not needed." The condition checks CERT_CAP,
CHAL_CAP, MEAS_CAP_SIG, KEY_EX_CAP but only in the direction of requiring non-zero;
the complementary zero-out when none of those caps are active is absent.

**Developer intent**: Fix #1189 (closed) added only the "must be non-zero when needed"
check. The PR description does not mention the inverse direction. The omission is a
classic one-sided invariant fix.

**Reproduction result (Level 0)**:
- SPDM v1.0, both sides: capability.flags=0, base_asym_algo=RSAPSS_3072
- Full VCA via `libspdm_negotiate_algorithms()`
- **Observable**: Both sides reach `NEGOTIATED (conn_state=3)`; ALGORITHMS response
  bytes at offset 12 = `08 00 00 00` = `base_asym_sel=0x8` (RSAPSS_3072); requester and
  responder both have `connection_info.algorithm.base_asym_algo=0x00000008` with
  `capability.flags=0x00000000`. The invariant `(CERT∨CHAL∨MEAS_SIG∨KEY_EX) ⟺ base_asym≠0`
  is violated.

**Recommendation**: After the unconditional `base_asym_sel` assignment at line 742,
add a conditional zero-out when no asym-requiring capability is active (see
`spec/confirmed-bugs.md` for the exact code).

---

### F3 Confirmation

**Final status**: FALSE POSITIVE (invariant held by construction)

`AlgTableMirroring` is enforced directly in the TLA+ spec as an equality guard in
`RspHandleNegotiateAlgorithms`. BFS exhausted 602 states with no violation. Historical
fix `941f0ae0` addressed the original mirroring bug; no new instance exists.
