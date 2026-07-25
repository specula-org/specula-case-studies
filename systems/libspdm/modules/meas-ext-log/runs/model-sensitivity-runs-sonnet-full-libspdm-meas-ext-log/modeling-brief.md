# Modeling Brief: libspdm — SPDM Measurement Extension Log (MEL)

## 1. System Overview

- **System**: DMTF/libspdm — C reference implementation of the SPDM (Security Protocol and Data Model) specification (DSP0274), used in PCIe/CXL device attestation
- **Language**: C, ~500 LOC core MEL logic (`libspdm_req_get_measurement_extension_log.c` + `libspdm_rsp_measurement_extension_log.c`); ~3000 LOC supporting infrastructure
- **Category**: **Category A (Distributed / Message-Passing)** — SPDM is a binary request-response protocol exchanged between a Requester and a Responder over PCIe DOE, MCTP, or TCP transports. The MEL transfer is a multi-round-trip paged protocol; correctness depends on the sequence and consistency of messages across round-trips.
- **Protocol**: SPDM 1.3+ GET_MEASUREMENT_EXTENSION_LOG / MEASUREMENT_EXTENSION_LOG — offset/length paged bulk-read of the Responder's Measurement Extension Log, following the same chunking model as GET_CERTIFICATE.
- **Key architectural choices**:
  - MEL data is produced entirely by a HAL callback (`libspdm_measurement_extension_log_collection`); no MEL state is cached in `libspdm_context_t` between requests.
  - Loop termination on the Requester side uses `mel_entries_len` read from the partially-accumulated caller buffer — not from a header-complete guard.
  - MEL specification negotiation (`mel_specification_sel`) during NEGOTIATE_ALGORITHMS is validated only inside a `KEY_EX_CAP || PSK_CAP` capability branch; the validation is silently skipped when neither capability is present.
  - A `libspdm_mask_mel_specification()` function (intended to sanitize the `mel_spec` wire value against a version-specific bitmask) is defined but never called anywhere.
- **Concurrency model**: Single-threaded, synchronous request-response; no goroutines or locks. Protocol bugs arise from multi-round-trip state inconsistency, not concurrent access.

---

## 2. Bug Families

### Family 1: Multi-Chunk MEL Consistency — No Snapshot Between Chunks (HIGH)

**Mechanism**: The MEL transfer protocol requires multiple GET_MEL round-trips for large logs (offset-based paging). The Responder calls `libspdm_measurement_extension_log_collection` fresh on every request without caching the result. If the MEL changes between a first-chunk request and a second-chunk request, the Requester assembles a chimeric log composed of data from different MEL generations. Separately, the Requester's loop termination reads `mel_entries_len` (bytes 4–7 of the MEL header) from the partially-accumulated caller buffer before confirming that a full 16-byte header has been received — a small first chunk causes the loop to exit using uninitialized or stale data.

**Evidence**:
- Code analysis: `libspdm_rsp_measurement_extension_log.c:113-124` — `spdm_mel = NULL; spdm_mel_len = 0;` followed by fresh `libspdm_measurement_extension_log_collection(...)` on every call; no epoch/generation tracking in `libspdm_context_t`
- Code analysis: `libspdm_req_get_measurement_extension_log.c:241-243` — `measurement_extension_log->mel_entries_len` is read from `measure_exten_log` (caller buffer) without first ensuring `mel_size_internal >= sizeof(spdm_measurement_extension_log_dmtf_t)` (16 bytes)
- Code analysis: same file, lines 202-210 — the Requester only detects MEL *shrinkage* mid-transfer (`< total_responder_mel_buffer_length`); MEL *growth* silently goes undetected, meaning a two-chunk exchange can mix data from two MEL generations without triggering any error
- Historical: issue #3310 (closed) — similar TOCTOU-style memory leak in `libspdm_get_measurement` where transcript context was not properly scoped to request lifetime; same mechanism of per-request re-initialization without state preservation

**Affected code paths**:
- `libspdm_try_get_measurement_extension_log` — Requester main loop (req file, lines 93–251)
- `libspdm_get_response_measurement_extension_log` — Responder handler (rsp file, lines 10–162)
- `libspdm_measurement_extension_log_collection` — HAL callback (measlib.h:189, sample: `os_stub/spdm_device_secret_lib_sample/meas.c:800-830`)

**Suggested modeling approach**:
- Variables: `mel_generation [Responder -> Nat]` — incremented whenever MEL content changes; `mel_snapshot [Responder -> MEL_DATA]` — snapshot taken at first-chunk request time; `mel_offset [Requester -> Nat]` — current accumulated offset
- Actions: `GetMelFirstChunk` (Requester offset==0, Responder serves from current MEL generation), `GetMelNextChunk` (Requester offset>0, Responder serves from potentially DIFFERENT generation), `MelUpdate` (Responder's MEL changes at any time)
- Invariant target: `MelConsistency` — all chunks delivered to Requester in a single transfer share the same `mel_generation`
- Also model the "partial header" path: a first chunk with `portion_length < 16` causes the Requester to evaluate `mel_entries_len` from uninitialized data

**Priority**: High
**Rationale**: This is a genuine protocol-level safety question: the spec (DSP0274 1.3+) requires all chunks of a single GET_MEL exchange to be consistent, but the implementation has no mechanism to enforce this. TLA+ can directly explore the state space where `MelUpdate` fires between chunks. The partial-header issue is a concrete trigger condition for the broken loop termination.

---

### Family 2: mel_spec Negotiation Validation Bypass (MEDIUM)

**Mechanism**: The `mel_specification_sel` field returned in the ALGORITHMS response is supposed to be validated by the Requester. However, this validation (in `libspdm_req_negotiate_algorithms.c`) is nested inside a `KEY_EX_CAP || PSK_CAP` capability block. If neither capability is advertised by either side, the entire mel_spec validation block is unreachable — an invalid or zero `mel_specification_sel` passes silently. Additionally, `libspdm_mask_mel_specification()` (designed to sanitize the wire value against the `SPDM_MEL_SPECIFICATION_13_MASK = 0x01` bitmask) is defined and declared but never invoked anywhere. The Responder also stores the raw unvalidated `mel_specification` from the request at `spdm_rsp_algorithms.c:713-714` before computing the negotiated value.

**Evidence**:
- Code analysis: `libspdm_req_negotiate_algorithms.c:663-696` — mel_spec validation at lines 681-696 is inside `if (KEY_EX_CAP || PSK_CAP)` block; unreachable without either capability
- Code analysis: `libspdm_com_support.c:380-385` — `libspdm_mask_mel_specification` defined; grep confirms zero call sites across the entire codebase
- Code analysis: `libspdm_rsp_algorithms.c:713-714` — `connection_info.algorithm.mel_spec = spdm_request->mel_specification` (raw, unmasked); overwritten at lines 993-994 with the negotiated value, but the raw store happens first with no validation
- Issue #2947 (OPEN) — "Basic capability and algorithm checks are missing" — identifies the same general pattern of inconsistent capability/algorithm pairing checks

**Affected code paths**:
- `libspdm_send_receive_negotiate_algorithms` (Requester, `libspdm_req_negotiate_algorithms.c:681-696`)
- `libspdm_get_response_algorithms` (Responder, `libspdm_rsp_algorithms.c:710-776`)

**Suggested modeling approach**:
- Variables: `mel_spec_local [Node -> {0,1}]`, `mel_spec_conn [Node -> {0,DMTF,INVALID}]`, `has_key_ex_or_psk [Node -> BOOL]`
- Actions: `NegotiateAlgorithms` with two variants — `NegotiateWithSessionCap` (validation fires), `NegotiateWithoutSessionCap` (validation skipped, raw value stored)
- Invariant target: `MelSpecValid` — after any successful NEGOTIATE_ALGORITHMS, `connection_info.algorithm.mel_spec` is either 0 or `SPDM_MEL_SPECIFICATION_DMTF` (never an unrecognized value)
- Trigger condition: `mel_specification_sel` set to `0x03` (hypothetical future value) when `KEY_EX_CAP = 0 && PSK_CAP = 0`

**Priority**: Medium
**Rationale**: The bypass path is reachable in a configuration where SPDM is used for measurement-only (no key exchange, no PSK) — exactly the profile where MEL is most relevant (attestation-only endpoints). The dead mask function suggests the feature was planned but never wired in.

---

### Family 3: Missing Pre-Send Validation and Dual-Field Consistency (MEDIUM)

**Mechanism**: Multiple validation checks are absent at both the Requester and Responder sides: (a) the Requester never verifies `mel_spec != 0` before sending GET_MEASUREMENT_EXTENSION_LOG (the Responder would reject it, but the Requester wastes a round-trip and receives an unexpected error); (b) neither side validates that `number_of_entries` is consistent with `mel_entries_len` (both fields describe MEL size independently); (c) the `param1`/`param2` reserved fields in the request are never checked. This follows a recurring pattern across the SPDM implementation.

**Evidence**:
- Code analysis: `libspdm_req_get_measurement_extension_log.c:52-77` — connection state, version, and MEL_CAP are checked, but `connection_info.algorithm.mel_spec == 0` is not
- Code analysis: `spdm.h:884-891` — `spdm_measurement_extension_log_dmtf_t` has both `number_of_entries` (count) and `mel_entries_len` (byte length); inconsistency is undetected by either side
- Code analysis: `os_stub/spdm_device_secret_lib_sample/meas.c:64,72` — test helper sets `number_of_entries = mel_index` BEFORE `mel_index++`, producing logs where `number_of_entries = actual_count - 1` (confirmed off-by-one)
- Issue #2425 (OPEN) — requester should check `DMTFSpecMeasurementValueType` of received measurement blocks; same pattern: field present in protocol structures but not validated
- Issue #1434/#1435 (OPEN) — requester/responder should check reserved measurement indices; same pattern across measurements protocol

**Affected code paths**:
- `libspdm_try_get_measurement_extension_log` (requester, pre-request validation phase)
- `libspdm_get_response_measurement_extension_log` (responder, request validation phase)
- `libspdm_measurement_extension_log_collection` (HAL, sample at `meas.c`)

**Suggested modeling approach**:
- Not the primary TLA+ target — this is better suited to code review and test-level checking
- However, the `number_of_entries` vs `mel_entries_len` inconsistency DOES interact with Family 1 (the loop termination uses `mel_entries_len` not `number_of_entries`)

**Priority**: Medium (code review); Low (TLA+)

---

### Family 4: MEL Entry Bounds and Sample Implementation Safety (LOW)

**Mechanism**: The sample HAL implementation iterates over MEL entries by advancing a pointer based on `dmtf_spec_measurement_value_size` from each entry's header without checking that the pointer stays within the MEL buffer. The sample also calls `libspdm_generate_mel` even when invoked for a size-only probe (measurement_block == NULL), creating unnecessary mutation of the global buffer.

**Evidence**:
- Code analysis: `os_stub/spdm_device_secret_lib_sample/meas.c:259-280` — unbounded `mel_entry` pointer advance in HEM computation loop
- Code analysis: same file, lines 218-227 — `libspdm_generate_mel` called before the null check for `measurement_block`

**Priority**: Low
**Rationale**: The sample implementation is illustrative; HAL integrators are expected to provide their own. Not a good TLA+ target — pure code-level concern.

---

## 3. Modeling Recommendations

### 3.1 Model

| What | Why | How |
|------|-----|-----|
| MEL generation / snapshot | Family 1: fresh collection per request enables chimeric log assembly | `mel_generation` counter + `MelUpdate` action that increments it; `Snapshot` taken at first-chunk offset |
| Chunk consistency invariant | Family 1: core safety property | `MelConsistency`: all portions received in one logical transfer share the same generation |
| Partial-header loop condition | Family 1: loop terminates based on partially-received header field | Model `portion_length < sizeof(header)` as a valid first-chunk response; check loop termination logic |
| mel_spec negotiation with/without session cap | Family 2: bypass path when no KEY_EX/PSK | Two `NegotiateAlgorithms` variants controlled by `has_session_cap` boolean |
| mel_spec validity invariant | Family 2: wire value can be left unmasked | `MelSpecValid` invariant after successful negotiation |

### 3.2 Do Not Model

| What | Why |
|------|-----|
| Sample implementation bounds checks | Family 4: HAL-level concern, not protocol logic; integrators provide their own HAL |
| reserved fields (param1/param2) | Family 3: implementation robustness, not protocol state space |
| `number_of_entries` vs `mel_entries_len` independently | Family 3: no known cross-layer interaction beyond the loop condition (already in Family 1) |
| Cryptographic signing of MEL | Not in current SPDM spec (MEL has no signature, unlike GET_MEASUREMENTS); adding it would model a hypothetical future protocol |
| Session establishment | Out of scope; MEL operates post-negotiation; session state can be abstracted as "established or not" |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| MEL generation tracking | `mel_generation [Responder -> Nat]`, `mel_epoch_at_chunk1 [Session -> Nat]` | Capture that MEL can change between chunks | Family 1 |
| Partial-header path | (extend first-chunk action to allow `portion_length < 16`) | Model requester loop using stale `mel_entries_len` | Family 1 |
| Session capability flag | `has_session_cap [Requester -> BOOL]` | Gate mel_spec validation on capability presence | Family 2 |
| mel_spec state | `mel_spec_conn [Node -> {UNSET, DMTF, INVALID}]` | Track negotiated vs. stored value | Family 2 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| MelConsistency | Safety | All MEASUREMENT_EXTENSION_LOG portions in a single GET_MEL exchange come from the same MEL generation | Family 1 |
| MelHeaderComplete | Safety | Requester evaluates `mel_entries_len` only after `mel_size_internal >= sizeof(spdm_measurement_extension_log_dmtf_t)` | Family 1 |
| MelSpecValid | Safety | After NEGOTIATE_ALGORITHMS completes, `connection_info.algorithm.mel_spec ∈ {0, SPDM_MEL_SPECIFICATION_DMTF}` regardless of capability flags | Family 2 |
| MelSpecPreSend | Safety | GET_MEASUREMENT_EXTENSION_LOG is only issued when `connection_info.algorithm.mel_spec != 0` | Family 2, 3 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Family |
|----|-------------|------------------------------|--------|
| MC1 | If the MEL changes between the first-chunk request (offset=0) and a second-chunk request (offset>0), can the Requester assemble a structurally valid but semantically inconsistent log? | MelConsistency | 1 |
| MC2 | If the first MEASUREMENT_EXTENSION_LOG response has `portion_length < sizeof(spdm_measurement_extension_log_dmtf_t)` (e.g., 8 bytes), does the Requester loop terminate correctly or use an uninitialized `mel_entries_len`? | MelHeaderComplete | 1 |
| MC3 | Can a Responder returning `mel_specification_sel = 0x03` (unrecognized value) cause the Requester to proceed with GET_MEL when KEY_EX_CAP=0 and PSK_CAP=0? | MelSpecValid | 2 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|------------------------|
| TV1 | Requester sends GET_MEL when `mel_spec == 0` (not negotiated) | Unit test: clear `mel_specification_sel` after negotiation, call `libspdm_get_measurement_extension_log`, expect `UNSUPPORTED_CAP` or similar |
| TV2 | `number_of_entries` vs `mel_entries_len` inconsistency in MEL header | Unit test: construct a MEL where `number_of_entries = 5` but `mel_entries_len` encodes only 3 entries; verify neither side rejects |
| TV3 | MEL content changes between chunk 1 and chunk 2 | Integration test with dynamic MEL HAL: change the MEL data between first and second GET_MEL request; verify the assembled buffer is flagged or rejected |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR1 | `libspdm_mask_mel_specification` is dead code — never called at requester or responder side | Wire it into `libspdm_req_negotiate_algorithms.c` at line 441 and `libspdm_rsp_algorithms.c` at line 714 |
| CR2 | Requester has no `mel_spec != 0` precondition check before sending GET_MEL | Add check analogous to responder-side check at `libspdm_rsp_measurement_extension_log.c:86-91` |
| CR3 | `param1`/`param2` reserved fields in GET_MEL request not validated by Responder | Add check returning `SPDM_ERROR_CODE_INVALID_REQUEST` if non-zero, consistent with other handlers |
| CR4 | `generate_mel_entry_test` sets `number_of_entries = mel_index` before increment — off-by-one | Fix: assign `mel_index` after `mel_index++` (line 72 before line 64 assignment) |
| CR5 | Sample MEL HEM computation loop (`meas.c:259-280`) advances `mel_entry` pointer without bounds check against `m_libspdm_mel` buffer | Add guard: `if ((uint8_t*)mel_entry + entry_size > (uint8_t*)measurement_extension_log + spdm_mel_len) break;` |

---

## 7. Reference Pointers

- **Core MEL files**:
  - `library/spdm_requester_lib/libspdm_req_get_measurement_extension_log.c` (Requester, 282 lines)
  - `library/spdm_responder_lib/libspdm_rsp_measurement_extension_log.c` (Responder, 163 lines)
- **Supporting files**:
  - `library/spdm_requester_lib/libspdm_req_negotiate_algorithms.c` — mel_spec validation at lines 681-696
  - `library/spdm_responder_lib/libspdm_rsp_algorithms.c` — mel_spec storage at lines 713-714, 770-776, 993-994
  - `library/spdm_common_lib/libspdm_com_support.c:380-385` — dead mask function
  - `os_stub/spdm_device_secret_lib_sample/meas.c` — sample HAL MEL collection
  - `include/industry_standard/spdm.h:884-891, 962-964, 1580-1604` — MEL wire structures and constants
- **Unit tests**:
  - `unit_test/test_spdm_requester/get_measurement_extension_log.c`
  - `unit_test/test_spdm_responder/measurement_extension_log.c`
  - `unit_test/test_spdm_responder/error_test/measurement_extension_log_err.c`
- **GitHub issues (DMTF/libspdm)**:
  - #3584 (closed, security) — unsigned integer casting bug in MEL responder at line 132; fixed in current code
  - #2987 (closed) — incorrect error data in MEL responder `UNSUPPORTED_REQUEST`; fixed in current code
  - #2425 (open) — requester should validate `DMTFSpecMeasurementValueType` (same validation gap pattern as Family 3)
  - #1434/#1435 (open) — missing reserved measurement index checks (same pattern)
  - #2947 (open) — basic capability/algorithm pairing checks missing (same pattern as Family 2)
  - #3310 (closed) — memory/transcript lifecycle issue in `libspdm_get_measurement` (same TOCTOU-like mechanism as Family 1)
- **Reference specification**: DSP0274 SPDM 1.3 — GET_MEASUREMENT_EXTENSION_LOG section
