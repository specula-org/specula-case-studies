# Modeling Brief: libspdm — VERSION / CAPABILITIES / NEGOTIATE_ALGORITHMS

## 1. System Overview

- **System**: DMTF/libspdm — C reference library for the Security Protocol and Data Model (SPDM) protocol, used in PCIe CMA, MCTP, storage, and TCP transports
- **Language**: C, ~3275 LOC across the six core VCA protocol files
- **Category**: **Category A (Distributed / Message-Passing)** — three-phase request-response handshake between a Requester and a Responder; correctness requires both parties to agree on a consistent (version, capability, algorithm) triple before any session can be established
- **Protocol**: SPDM VCA handshake (DSP0274 §§ 8.1–8.4): GET_VERSION → VERSION → GET_CAPABILITIES → CAPABILITIES → NEGOTIATE_ALGORITHMS → ALGORITHMS
- **Key architectural choices**:
  - Connection state machine: `NOT_STARTED → AFTER_VERSION → AFTER_CAPABILITIES → NEGOTIATED`
  - Transcript `message_a` is built by appending each request+response pair; it seeds all subsequent signature/hash operations
  - Requester and Responder maintain **separate** capability-compatibility validators (`validate_responder_capability` vs `libspdm_check_request_flag_compatibility`), which have historically drifted from each other
  - `NEGOTIATE_ALGORITHMS` carries a variable-length struct table; Param1 encodes the count of AlgType entries; request and response must mirror each other exactly
  - A version-specific mask must be applied to capability flags before storing/sending; this is handled by `libspdm_mask_capability_flags`, introduced late (v3.x)
- **Concurrency model**: Single-threaded, request-response. No background goroutines; all state transitions happen synchronously within each handler

---

## 2. Bug Families

### Family 1: Version × Capability × Algorithm Coherence (HIGH)

**Mechanism**: Three independently-negotiated dimensions — SPDM version, capability flags, algorithm selections — must form a mutually consistent triple after VCA completes. Many bugs arise because one dimension is not correctly conditioned on another: version-specific flag bits leak across versions, algorithm fields are selected without checking the enabling capability, or the enabling-capability check uses the wrong capability constant.

**Evidence**:
- Historical: `a3e5b996` — capability flags not masked to negotiated version; later-version bits leak (fix #2796)
- Historical: `b7d13b32` — version-gated CAPABILITIES fields (ct_exponent, data_transfer_size) sent on wrong version (fix #2412)
- Historical: `ce2f118f` / `7e63eb24` — base_hash_algo and base_asym_algo required unconditionally; should be gated on capability set (fix #1189)
- Historical: `22132e7b` — measurement_specification_sel populated when MEAS_CAP=0 (fix #2531)
- Historical: `76c537f3` (2026-03-30, recent!) — measurement_specification_sel not set when MEL_CAP=1, MEAS_CAP=0 (fix #3600)
- Code analysis: `libspdm_rsp_algorithms.c:718-731` — MEL_CAP-only path sets measurement_specification_sel but does not validate measurement_hash_algo
- Code analysis: `libspdm_req_negotiate_algorithms.c:461-465` — measurement_hash_algo validated for structural validity only; no intersection check against locally supported set

**Affected code paths**:
- `libspdm_mask_capability_flags()` — applied at send/receive of CAPABILITIES
- `libspdm_get_response_algorithms()` → algorithm selection logic (lines 555-730)
- `libspdm_return_status libspdm_try_negotiate_algorithms()` → response validation (lines 451-600)
- `libspdm_check_request_flag_compatibility()` in `libspdm_rsp_capabilities.c`

**Suggested modeling approach**:
- Variables: `negotiated_version`, `req_cap_flags`, `rsp_cap_flags`, `algo_selection` (tuple of base_hash, base_asym, dhe, aead, measurement_spec)
- Actions: `SendGetVersion/HandleVersion`, `SendGetCapabilities/HandleCapabilities`, `SendNegotiateAlgorithms/HandleAlgorithms` — each updates one dimension
- Invariant: In `NEGOTIATED` state, algorithm fields are non-zero iff their enabling capability is set in the responder's capability flags, and all fields are within the allowed set for `negotiated_version`

**Priority**: High
**Rationale**: 8+ historical bugs sharing this mechanism; the most recent fix (`76c537f3`) is from 2026-03-30 — this area is still being actively patched. The triple (version, cap, algo) interacts across all three VCA messages; a single TLA+ state machine can check the coherence invariant efficiently.

---

### Family 2: Capability Compatibility Asymmetry (HIGH)

**Mechanism**: The Requester and Responder maintain separate, mirrored validators for capability flag legality. A flag combination that one side considers valid may be accepted or rejected differently by the other side — creating scenarios where one endpoint advances its state machine believing the negotiation is valid while the other would reject it if it re-evaluated.

**Evidence**:
- Historical: `772afc1c` — size checks inverted (`>` instead of `<`) in CAPABILITIES response handler; undersized requests pass, correctly-sized requests rejected (fix #1812)
- Historical: `9b636f5f` — MAC_CAP requirement not enforced when KEY_EX_CAP or PSK_CAP is set; logic inverted (fix #2944)
- Historical: `e0f4e941` — responder rejects valid MUT_AUTH_CAP=1 and KEY_EX_CAP=1 combinations (fix #1603)
- Code analysis: `libspdm_rsp_capabilities.c:70` — responder rejects `PSK_CAP==3` (requester full PSK) which is a valid combination per `spdm.h:247`; requester's own validator correctly allows PSK_CAP=3 outgoing
- Code analysis: `libspdm_rsp_capabilities.c:116` — responder missing check: when neither CERT_CAP nor PUB_KEY_ID_CAP is set, KEY_EX_CAP should also be rejected; requester's `validate_responder_capability` enforces this, responder validator does not
- Issues: #37, #1603, #1986, #2944, #2972 (all confirmed, all fixed except open items)

**Affected code paths**:
- `libspdm_check_request_flag_compatibility()` — `libspdm_rsp_capabilities.c` (responder validator)
- `validate_responder_capability()` / `libspdm_check_response_flag_compatibility()` — `libspdm_req_get_capabilities.c` (requester validator)

**Suggested modeling approach**:
- Variables: `req_cap_flags`, `rsp_cap_flags`, each modeled as a subset of {KEY_EX, PSK, CERT, MUT_AUTH, ENCRYPT, MAC, ...}
- Actions: `SendGetCapabilities` (requester picks any subset in local_req_flags), `HandleGetCapabilities` (responder validates req_cap_flags; accepts/rejects), `SendCapabilities` (responder picks rsp_cap_flags), `HandleCapabilities` (requester validates)
- Invariant: `CapabilityCompatibility` — if a pair (req_flags, rsp_flags) leads to `AFTER_CAPABILITIES`, then both flags sets must satisfy the spec's compatibility table; in particular, MAC_CAP required when KEY_EX or PSK is enabled; PSK_CAP ∈ {0,1,2} for requester; KEY_EX requires CERT or PUB_KEY_ID when no PSK

**Priority**: High
**Rationale**: 5+ distinct confirmed bugs, all arising from the same asymmetry pattern. The PSK_CAP==3 and KEY_EX-without-cert issues from deep code analysis may be unfixed defects. TLA+ can systematically enumerate all flag-pair combinations that should reach AFTER_CAPABILITIES vs. be rejected.

---

### Family 3: NEGOTIATE_ALGORITHMS Struct Table Protocol Conformance (HIGH)

**Mechanism**: The `NEGOTIATE_ALGORITHMS` request carries Param1 (count) `AlgType` struct table entries; the `ALGORITHMS` response must mirror exactly those entries — neither more nor fewer. Multiple bugs arose from hardcoded counts (always 4), unconditional inclusion of zero-support entries, and failure to validate mirroring.

**Evidence**:
- Historical: `941f0ae0` — responder always returns 4 RespAlgStruct entries; must mirror only what requester sent (fix #2344)
- Historical: `2ee1e372` — requester sends all 4 ReqAlgStruct even for unsupported capabilities (fix #2344)
- Historical: `065fb17b` — responder accepts AlgStruct with alg_supported=0; stores 0 as negotiated algorithm
- Historical: `655afd25` — no range check on alg_type in struct table parser; out-of-range types silently skipped
- Historical: `5d704f66` — extended algorithm count check off-by-one; accepts 1 ext_algo instead of requiring 0
- Issue: #2344 (confirmed, fixed); #2950 (OPEN — AlgSupported reserved bits not masked before validation)

**Affected code paths**:
- `libspdm_send_request()` / `libspdm_try_negotiate_algorithms()` — request construction and struct table count
- `libspdm_get_response_algorithms()` — response struct table construction and mirroring
- Struct table parser loop in both files (alg_type switch, monotonicity check, alg_supported check)

**Suggested modeling approach**:
- Variables: `req_alg_types` (set of types requester includes), `rsp_alg_types` (set of types responder returns), `selected_algs` (map from type to selected value)
- Actions: `SendNegotiateAlgorithms` (requester populates req_alg_types for non-zero capabilities), `HandleNegotiateAlgorithms` (responder parses and builds rsp_alg_types), `HandleAlgorithms` (requester validates mirroring)
- Invariant: `AlgTableMirroring` — after NEGOTIATED, `rsp_alg_types == req_alg_types`; for each type, `selected_alg[type] != 0`

**Priority**: High
**Rationale**: Cluster of 5+ related bugs; issue #2950 (reserved bits check) is still open. The struct table mirroring invariant is precise and TLA+-expressible. This is a structural protocol property that goes beyond "are the checks correct" — it concerns whether both sides agree on the same algorithm selection at all.

---

### Family 4: Transcript Integrity on VCA Error Paths (MEDIUM)

**Mechanism**: The VCA transcript (`message_a`) is built by appending request and response for each of the three handshake messages. In the implementation, the request is appended before the response is generated; if response generation fails (e.g., out-of-memory, policy violation discovered mid-construction), the transcript already contains the request without a corresponding response. There is no rollback mechanism; the issue has been open since 2021.

**Evidence**:
- Issue #524 (OPEN since 2021) — responder appends request before knowing if response will succeed; no rollback on error
- Code analysis: `libspdm_req_get_capabilities.c:397-447` — BUFFER_TOO_SMALL error return leaves `message_a` dirty; retry would double-append the request
- Historical: `issue #2610` — incorrect message sizes used in transcript append (fixed, confirms transcript bugs happen here)

**Affected code paths**:
- All three VCA responder handlers: `libspdm_rsp_version.c`, `libspdm_rsp_capabilities.c`, `libspdm_rsp_algorithms.c`
- `libspdm_req_get_capabilities.c:397-447` — requester error path

**Suggested modeling approach**:
- Variables: `transcript_req_appended [bool]`, `transcript_rsp_appended [bool]` per VCA phase
- Actions: Split each handler into `AppendRequest`, `GenerateResponse` (may fail), `AppendResponse` as separate steps
- Invariant: `TranscriptCoherence` — in any reachable state, transcript contains matched (request, response) pairs; a lone appended request with no response is only acceptable in `NOT_STARTED` state

**Priority**: Medium
**Rationale**: Open bug since 2021 (issue #524). Non-trivial to fix because it requires either transactional transcript management or redesigning append ordering. TLA+ can confirm whether a partial transcript can lead to two endpoints deriving different `message_a` values.

---

### Family 5: Version-Gated Error Response Encoding (LOW)

**Mechanism**: Error responses to VCA messages must carry specific SPDM version numbers in the header (e.g., `VERSION_MISMATCH` in response to `GET_VERSION` must be encoded at SPDM 1.0). Multiple handlers historically used the wrong error code or wrong version field in the error response header. The same error condition produced different error codes across different message handlers.

**Evidence**:
- Historical: `8ac807bc` — error response to bad GET_VERSION must use 1.0; used current session version instead
- Historical: `e3c555b3` / `f59c2903` — INVALID_REQUEST returned instead of VERSION_MISMATCH across 12+ handlers
- Issues: #163, #509, #2867 (some open, wrong error code for HANDSHAKE_IN_THE_CLEAR path)
- Issue #3022 (CLOSED) — RequestResync error with v1.0 header rejected by requester before error code was checked

**Priority**: Low (TLA+); Medium (code review)
**Rationale**: Not a good TLA+ target — the correctness property is about error message formatting, not protocol safety. A strict requester would reject these responses anyway. The behavior is observable as interoperability failures, not safety violations.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Version × capability × algorithm coherence | Family 1: still being actively fixed as of 2026-03; defines correctness of final negotiated state | `negotiated_version`, `rsp_cap_flags`, `algo_selection` variables; invariant checks coherence at NEGOTIATED state |
| Capability flag compatibility (both sides) | Family 2: requester and responder validators have diverged; PSK_CAP/KEY_EX asymmetry may be unfixed | Separate `req_validates_rsp_flags` and `rsp_validates_req_flags` actions; compare accepted flag sets |
| NEGOTIATE_ALGORITHMS struct table mirroring | Family 3: structural protocol property; issue #2950 open | `req_alg_types` and `rsp_alg_types` sets; `AlgTableMirroring` invariant |
| Partial VCA transcript (append-before-generate) | Family 4: open since 2021; easy to miss under normal conditions | Split each handler into AppendRequest / GenerateResponse / AppendResponse steps |
| Crash / context reset between VCA phases | Cross-cutting: GET_VERSION resets context; stale state could affect algorithm fields if context reset is skipped | `libspdm_reset_context` action; check algorithm fields are zeroed before NEGOTIATED |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| Error code selection (VERSION_MISMATCH vs INVALID_REQUEST) | Family 5: formatting issue, not protocol safety; most are fixed upstream |
| Buffer overflow in version negotiation loop (commit `bac39f27`) | Already fixed; re-deriving via TLA+ produces no new information |
| Copy-paste ASSERT bug in `libspdm_rsp_algorithms.c:661` | Implementation defect (wrong field asserted); fix is one-line code review, not a model-checking target |
| Transport / framing layer | Out of scope for VCA; transport-layer bugs do not affect protocol state machine logic |
| Session establishment (KEY_EXCHANGE, PSK) | Downstream of VCA; security vulnerability #2005 is already fixed; separate modeling effort |
| Multi-hop / multi-responder scenarios | SPDM is point-to-point; no cluster membership or multi-server interactions |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Negotiated version tracking | `negotiated_version ∈ {1.0, 1.1, 1.2, 1.3, 1.4}` | Carry negotiated version into capability and algorithm checks | Family 1 |
| Capability flag sets | `req_cap_flags`, `rsp_cap_flags ⊆ CapFlagSet` | Model capability exchange and compatibility validation by both sides | Family 2 |
| Algorithm selection tuple | `algo_selection: AlgType → AlgValue ∪ {0}` | Capture per-type selected algorithm; check non-zero iff capability set | Family 1, 3 |
| AlgType struct table sets | `req_alg_types`, `rsp_alg_types ⊆ AlgTypeSet` | Model which AlgType entries each side sends; mirroring invariant | Family 3 |
| Transcript append tracking | `req_appended[phase]`, `rsp_appended[phase] ∈ BOOLEAN` | Model two-step append; detect lone-request transcript state | Family 4 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| `NegotiatedCoherence` | Safety | In NEGOTIATED state: for each algorithm type T, `algo_selection[T] != 0 ⟺ enabling_cap(T) ∈ rsp_cap_flags ∧ enabling_cap(T) ∈ req_cap_flags` | Family 1 |
| `VersionAlgoScope` | Safety | In NEGOTIATED state: all set bits in `rsp_cap_flags` and `req_cap_flags` are within the allowed mask for `negotiated_version` | Family 1 |
| `CapabilityCompatibility` | Safety | If connection reaches `AFTER_CAPABILITIES`, the pair (req_cap_flags, rsp_cap_flags) satisfies the spec compatibility table (MAC_CAP when KEY_EX or PSK; PSK_CAP ∈ {0,1,2} for requester; etc.) | Family 2 |
| `AlgTableMirroring` | Safety | In NEGOTIATED state: `rsp_alg_types == req_alg_types` (response struct table matches request exactly) | Family 3 |
| `TranscriptCoherence` | Safety | In any state ≠ NOT_STARTED: for each VCA phase P, `req_appended[P] ∧ ¬rsp_appended[P]` is not reachable at any stable state (only transiently during message handling) | Family 4 |
| `VersionProgression` | Safety | Connection state advances monotonically: NOT_STARTED → AFTER_VERSION → AFTER_CAPABILITIES → NEGOTIATED; GET_VERSION resets to NOT_STARTED | Standard state machine |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|-------------------------------|------------|
| MC1 | Is there a (req_cap_flags, rsp_cap_flags, negotiated_version, algo_selection) tuple that reaches NEGOTIATED state but fails `NegotiatedCoherence`? Specifically: can the combination `MEL_CAP=1, MEAS_CAP=0` lead to `measurement_hash_algo==0` while `measurement_specification_sel!=0`? | `NegotiatedCoherence` | Family 1 |
| MC2 | Can the responder's `libspdm_check_request_flag_compatibility` accept a requester `PSK_CAP==3` (both bits set) under the current code, allowing `AFTER_CAPABILITIES` to be reached with a flag combination the spec considers valid? This appears to be an unfixed divergence from the requester's outgoing validator. | `CapabilityCompatibility` | Family 2 |
| MC3 | Can both requester and responder reach NEGOTIATED state with `rsp_alg_types ≠ req_alg_types` if one side omits an AlgType entry that the other still parses from a stale/default field? | `AlgTableMirroring` | Family 3 |
| MC4 | With transcript append split into AppendRequest/AppendResponse steps, is there an error-return path in any VCA handler that leaves `req_appended[P]=true, rsp_appended[P]=false` in a state reachable from `AFTER_CAPABILITIES`? | `TranscriptCoherence` | Family 4 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|------------------------|
| TV1 | `libspdm_rsp_capabilities.c:70` — responder incorrectly rejects `PSK_CAP==3` from requester | Unit test: send GET_CAPABILITIES with PSK_CAP bits 10+11 both set; expect acceptance, not INVALID_REQUEST |
| TV2 | `libspdm_req_get_capabilities.c:357-363` — OOB read on `supported_algorithms->length` before size check | Fuzz/unit test: send CAPABILITIES response of exactly `sizeof(spdm_capabilities_response_t)` bytes with PARAM1_SUPPORTED_ALGORITHMS bit set; check no out-of-bounds access |
| TV3 | `libspdm_rsp_algorithms.c:661` — ASSERT guards `kem_alg` instead of `req_pqc_asym_alg` (copy-paste) | Code review + targeted unit test: inject `req_pqc_asym_alg > UINT16_MAX`; assert should fire but does not |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR1 | `libspdm_rsp_capabilities.c:116` — responder capability validator missing `key_ex_cap` check in no-cert/no-pub-key path (present in requester's counterpart at `req_get_capabilities.c:125`) | Audit both validators side-by-side; submit PR aligning responder check with requester |
| CR2 | Issue #2950 (OPEN) — `AlgSupported` field not masked to remove reserved bits before validation; could cause spurious validation failures with conformant peers using reserved-bit-set values | Read `libspdm_rsp_algorithms.c` struct table parser; add `& KNOWN_BITS_MASK` before validation |
| CR3 | Issue #3599 (OPEN) — `SupportedAlgorithms` variable block: no minimum size check before dereferencing `supported_algorithms->length`; no upper-bound validation of the length value | Audit `libspdm_req_get_capabilities.c:357-363`; add `response_size >= min_expected_size` check before deref |

---

## 7. Reference Pointers

- **Key source files**:
  - `library/spdm_requester_lib/libspdm_req_get_version.c` (230 lines)
  - `library/spdm_responder_lib/libspdm_rsp_version.c` (127 lines)
  - `library/spdm_requester_lib/libspdm_req_get_capabilities.c` (512 lines)
  - `library/spdm_responder_lib/libspdm_rsp_capabilities.c` (487 lines)
  - `library/spdm_requester_lib/libspdm_req_negotiate_algorithms.c` (780 lines)
  - `library/spdm_responder_lib/libspdm_rsp_algorithms.c` (1139 lines)
- **GitHub issues**: #524 (transcript, open), #2950 (AlgSupported reserved bits, open), #3599 (SupportedAlgorithms parse, open); #2344, #2796, #1189, #2531 (closed, key reference context for Families 1–3)
- **Connection state enum**: `include/library/spdm_common_lib.h:201-223` (`NOT_STARTED`, `AFTER_VERSION`, `AFTER_CAPABILITIES`, `NEGOTIATED`)
- **Reference spec**: DSP0274 (SPDM) §§ 8.1–8.4, Tables 4–22
- **Bug archaeology coverage**: 21 bug-fix commits analyzed in depth; 35+ GitHub issues deeply read; 3 open issues confirmed as unfixed defects (MC2 candidate, TV2 candidate, CR2, CR3)
