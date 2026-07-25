# Modeling Brief: libspdm Certificate-Based Authentication

## 1. System Overview

**libspdm-cert-auth** is a C implementation of SPDM (Security Protocol and Data Model) certificate-based authentication protocol, focusing on the CHALLENGE/CHALLENGE_AUTH exchange for mutual authentication.

**Category**: Category A (Distributed / Message-Passing)  
**Justification**: SPDM is a request-response protocol with message handlers and state machine transitions. The main risks are protocol logic consistency, message handling, and handshake state synchronization between requester and responder.

**Key Components**:
- Requester side: `libspdm_req_challenge.c` (sends CHALLENGE, receives CHALLENGE_AUTH)
- Responder side: `libspdm_rsp_challenge_auth.c`, `libspdm_rsp_encap_challenge.c` (receives CHALLENGE, generates CHALLENGE_AUTH)
- Shared components: certificate/key management, signature generation/verification, message transcript tracking

**Architectural Features**:
- Version negotiation (SPDM 1.0 through 1.3+) with backward compatibility
- Slot-based certificate handling (specific slots 0-7 or wildcard 0xFF for public-key-only)
- Mutual authentication via encapsulated request/response (optional, SPDM 1.1+)
- Request context (SPDM 1.3+) for replay protection
- Measurement hash inclusion (optional)

---

## 2. Bug Families

### Family 1: State Transition Race in Mutual Authentication

**Mechanism**: When basic mutual authentication is enabled, the responder and requester set their connection state to AUTHENTICATED at different times, creating a window of inconsistency where one endpoint considers the connection authenticated while the other does not.

**Evidence**:
- **Responder** (`libspdm_rsp_challenge_auth.c:336-338`): Sets connection state to AUTHENTICATED only if mutual auth is NOT requested (`if ((auth_attribute & SPDM_CHALLENGE_AUTH_RESPONSE_ATTRIBUTE_BASIC_MUT_AUTH_REQ) == 0)`)
- **Requester** (`libspdm_req_challenge.c:380`): Sets connection state to AUTHENTICATED unconditionally immediately after signature verification, before encapsulated mutual auth request is issued
- The requester then calls `libspdm_encapsulated_request()` at line 389, which happens AFTER state is already AUTHENTICATED

**Affected code paths**:
- `libspdm_get_response_challenge_auth()` (responder)
- `libspdm_try_challenge()` (requester)
- Mutual authentication flow triggered by `SPDM_CHALLENGE_AUTH_RESPONSE_ATTRIBUTE_BASIC_MUT_AUTH_REQ` flag

**Suggested modeling approach**:
- **Variables**: Add explicit authentication phase state (e.g., `authentication_phase`: NONE, ONE_WAY_STARTED, ONE_WAY_COMPLETE, MUTUAL_IN_PROGRESS)
- **Actions**: Split CHALLENGE_AUTH response into separate actions for one-way vs mutual auth paths
- **Invariants**: Ensure both endpoints agree on authentication state before accepting state-dependent messages

**Priority**: High  
**Rationale**: This state inconsistency could allow a sequence where the requester sends messages requiring AUTHENTICATED state while the responder still expects mutual auth to complete. This is both a protocol safety issue and a practical concern for message ordering.

---

### Family 2: Message Transcript Integrity Under Asynchronous Mutual Authentication

**Mechanism**: When mutual authentication is performed via encapsulated request/response, the message transcript used for signature verification could diverge if the encapsulation process resets or modifies transcript state inconsistently.

**Evidence**:
- **Main challenge** (`libspdm_rsp_challenge_auth.c:312-326`): Appends request and response to message buffer `message_c` before generating signature
- **Encapsulated challenge** (`libspdm_rsp_encap_challenge.c:62-75`): Resets message buffer via request code, then appends to `message_mut_c`
- **Responder** (`libspdm_rsp_challenge_auth.c:341-342`): Resets both `message_b` and `message_c` at the end
- The `message_c` buffer is reset BEFORE the response is generated, but the question is: are message buffers properly isolated for the mutual auth path?

**Affected code paths**:
- `libspdm_get_response_challenge_auth()` - main challenge handler
- `libspdm_get_encap_request_challenge()` - encapsulated challenge generation
- `libspdm_process_encap_response_challenge_auth()` - encapsulated challenge response processing

**Suggested modeling approach**:
- **Variables**: Model separate message buffers for main and encapsulated transcripts
- **Actions**: Track which transcript buffer is active at each step (main vs mutual-auth)
- **Invariants**: Ensure signature verification uses the correct transcript for the authentication phase

**Priority**: Medium  
**Rationale**: The implementation appears to handle buffers correctly, but the complexity of dual transcript paths (main CHALLENGE vs encapsulated CHALLENGE for mutual auth) warrants model-checking to ensure no cross-path contamination.

---

### Family 3: Slot ID Validation Consistency Across Version Transitions

**Mechanism**: Different SPDM versions handle slot ID encoding differently, and validation logic has multiple branches. Inconsistent validation could allow invalid slot IDs to be accepted in some paths while rejected in others.

**Evidence**:
- **Responder** (`libspdm_rsp_challenge_auth.c:95-126`): Validates slot_id with version-specific checks
  - Line 97-101: Bounds check for slot_id (must be < SPDM_MAX_SLOT_COUNT or == 0xFF)
  - Line 103-115: Validates that either certificate chain or public key is provisioned
  - Line 117-126: SPDM 1.3+ specific: validates key usage bit mask for multi-key connection
- **Requester** (`libspdm_req_challenge.c:196-213`): Different validation logic
  - Line 196-200: For slot_id 0xFF, checks param1 is 0xF (different representation!)
  - Line 202-212: For specific slot, checks both version-specific format and slot mask in param2
- **Encapsulated mutual auth** (`libspdm_rsp_encap_challenge.c:124-140`): Uses `req_slot_id` from context with similar but distinct validation

**Affected code paths**:
- Main challenge: requester calls with slot_id, responder validates and responds
- Encapsulated challenge: responder sends with req_slot_id, requester validates response

**Suggested modeling approach**:
- **Variables**: Track slot_id validation state and version-specific representation rules
- **Actions**: Model slot_id validation as a separate step with version dispatch
- **Invariants**: Ensure slot_id representation is consistent across SPDM versions; if 0xFF (public key), param1/param2 encoding must match spec

**Priority**: Medium  
**Rationale**: The version-specific slot ID handling is a reasonable design choice, but with multiple codepaths and version-dependent logic, there's risk of TOCTOU-style issues where validation passes in one version check but fails later.

---

### Family 4: Nonce Freshness and Reuse Detection

**Mechanism**: Both responder and requester generate nonces for the challenge-response exchange, but there is no explicit tracking or validation of nonce freshness or uniqueness. A compromised endpoint could potentially reuse nonces.

**Evidence**:
- **Responder** (`libspdm_rsp_challenge_auth.c:225-230`): Generates nonce using `libspdm_get_random_number(SPDM_NONCE_SIZE, ptr)` but no tracking of generated nonces
- **Requester** (`libspdm_req_challenge.c:119-127`): Generates nonce, optionally accepts a provided nonce (`requester_nonce_in`)
- **Requester verification** (`libspdm_req_challenge.c:265-267`): Only stores responder nonce for output, doesn't validate freshness
- No timestamp or sequence number in CHALLENGE message to prevent replay

**Affected code paths**:
- Both requester and responder generate nonces independently
- No nonce tracking data structure in context
- Nonce verification is absent; only certificate hash and signature are verified

**Suggested modeling approach**:
- **Variables**: Track set of recently seen nonces (Bloom filter or set model in TLA+)
- **Actions**: Model nonce generation and verification as separate atomic operations
- **Invariants**: If strict nonce replay prevention is desired, ensure each nonce is unique across all CHALLENGE messages within a time window

**Priority**: Low  
**Rationale**: Nonce reuse by itself is a weakness (enables replay), but in the context of challenge-response with signature verification, the signature is bound to the specific transcript, making exploitation harder. However, it's worth modeling to detect potential replay windows. This is more suitable for testing than TLA+ given the probabilistic nature of cryptographic operations.

---

### Family 5: Certificate Chain vs Public Key Slot Selection Edge Case

**Mechanism**: When slot_id is 0xFF (meaning public-key-only, no certificate chain), the responder and requester use different code paths for hash verification. The requester may have cached a public key that differs from what the responder generates, causing verification failure.

**Evidence**:
- **Responder** (`libspdm_rsp_challenge_auth.c:199-220`): 
  - If slot_id == 0xFF: generates hash of public key (`libspdm_generate_public_key_hash()`)
  - Otherwise: generates hash of certificate chain (`libspdm_generate_cert_chain_hash()`)
  - Returns error if no public key or certificate chain is provisioned
- **Requester** (`libspdm_req_challenge.c:249-258`):
  - If slot_id == 0xFF: verifies public key hash (`libspdm_verify_public_key_hash()`)
  - Otherwise: verifies certificate chain hash (`libspdm_verify_certificate_chain_hash()`)
- **Encapsulated mutual auth** (`libspdm_rsp_encap_challenge.c:124-140`): Similar path selection

**Affected code paths**:
- CHALLENGE with slot_id=0xFF triggers public-key-only path
- If requester's cached public key doesn't match responder's public key at signing time, verification fails
- SPDM 1.3+ multi-key connection mode adds complexity with key usage bit mask validation

**Suggested modeling approach**:
- **Variables**: Separate state for certificate-chain cache vs public-key cache
- **Actions**: Model cache coherency between endpoints' public key/cert chain selections
- **Invariants**: Before signature verification, ensure hash source (cert chain vs public key) is consistent between requester and responder

**Priority**: Medium  
**Rationale**: This is a legitimate design choice (supporting both cert-chain and public-key-only modes), but the divergence in code paths creates opportunity for implementation bugs. The issue is more subtle than obvious and could surface if one endpoint changes its provisioned keys between message send and verification.

---

### Family 6: Request Context Echo Verification (SPDM 1.3+)

**Mechanism**: SPDM 1.3 introduced a request context field to strengthen replay protection. The requester sends a context, and the responder echoes it back. However, the verification uses constant-time comparison, but there's no validation that the context is actually echoed correctly during the handshake.

**Evidence**:
- **Requester sends context** (`libspdm_req_challenge.c:134-143`): 
  - Line 134-139: If SPDM 1.3+, copies `requester_context` into request
  - Line 136: If context is NULL, zeros the buffer
- **Responder echoes context** (`libspdm_rsp_challenge_auth.c:291-295`):
  - Line 291-293: If SPDM 1.3+, copies request context + 1 (offset by header size) into response
- **Requester verifies context** (`libspdm_req_challenge.c:336-346`):
  - Line 340: Uses constant-time comparison `libspdm_consttime_is_mem_equal()` to verify echo
  - Line 341-343: If mismatch, resets transcript and returns error

**Affected code paths**:
- SPDM 1.3+ CHALLENGE messages with request context
- Mutual authentication flow also uses context handling in encapsulated exchange

**Suggested modeling approach**:
- **Variables**: Track requester_context value sent and expected value in response
- **Actions**: Model context echo as a separate operation step
- **Invariants**: If SPDM version >= 1.3, requester_context must be present and match in CHALLENGE_AUTH response

**Priority**: Low  
**Rationale**: The constant-time comparison is defensive and the validation is present. However, the context field is a new feature (1.3+) and the offset calculation (`spdm_request + 1`) could be error-prone in future modifications. Worth including in test coverage but lower priority for model checking.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| **State machine with explicit auth phases** | Family 1: State transition race in mutual auth | Introduce authentication_phase variable: NONE → CHALLENGED → AUTHENTICATED_ONE_WAY → MUTUAL_AUTH_IN_PROGRESS → FULLY_AUTHENTICATED. Split CHALLENGE_AUTH response action into separate cases for mutual vs non-mutual. |
| **Separate message transcripts** | Family 2: Transcript integrity with async mutual auth | Model message_c (main) and message_mut_c (mutual auth) as separate buffers. Track which buffer is active at each step. Verify signature verification uses correct transcript. |
| **Slot ID representation and validation** | Family 3: Slot ID consistency across versions | Introduce explicit slot_id_validation action that enforces version-specific rules. Model slot_id as (slot_value, version) tuple. Include param1/param2 encoding rules per version. |
| **Nonce tracking** | Family 4: Nonce freshness | Track set of nonces used in current session. Verify each new CHALLENGE uses a fresh nonce (not seen before in same session). |
| **Public key vs certificate chain selection** | Family 5: Key source consistency | Model separate hash_source state: CERT_CHAIN or PUBLIC_KEY. Verify both endpoints use same source before signature verification. |
| **Request context echo (SPDM 1.3+)** | Family 6: Replay protection | If modeling SPDM 1.3+, add requester_context_state variable. Verify context is echoed correctly with constant-time check simulation. |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| **Signature generation/verification cryptography** | Cryptographic primitives are out of scope for TLA+. The protocol logic assumes signatures are secure; we model signature verification as a boolean check. Implementation-level crypto bugs are better caught by formal crypto verification tools. |
| **Random number generation internals** | The RNG is assumed to produce uniform random values. Statistical properties are not TLA+ concerns. |
| **Memory safety (buffer overflows, use-after-free)** | C memory safety bugs are better detected by static analysis and fuzzing. TLA+ models state machines, not memory. |
| **Performance / timing side channels** | Timing attacks on crypto operations are orthogonal to protocol logic. The constant-time comparison is a good practice but hard to model in TLA+. |
| **Transport layer** | TCP/MCTP/PCIDoe transport details are abstracted. We model messages as atomic logical units. |
| **Opaque data handling** | Opaque data is intentionally extensible and not protocol-critical. Verification is delegated to callbacks. |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| AuthenticationPhase | `authentication_phase: {NONE, ONE_WAY_STARTED, ONE_WAY_COMPLETE, MUTUAL_IN_PROGRESS, FULLY_AUTHENTICATED}` | Track mutual auth state across endpoints to detect state inconsistency | Family 1 |
| MessageTranscriptIsolation | `active_transcript: {MAIN, MUTUAL_AUTH}`, separate buffers `msg_c, msg_mut_c` | Separate transcripts for main and mutual auth to prevent cross-contamination | Family 2 |
| SlotIDValidation | `slot_id_valid: bool`, `slot_id_version: VersionType` | Enforce version-specific slot ID validation rules | Family 3 |
| NonceTracking | `nonces_seen: Set(Nonce)` | Track nonces to detect reuse | Family 4 |
| KeySourceSelection | `key_source: {CERT_CHAIN, PUBLIC_KEY}` | Track whether challenge hash is from cert chain or public key | Family 5 |
| RequestContextEcho | `req_context_sent: RequestContext`, `req_context_in_response: RequestContext` | Track context values for SPDM 1.3+ replay protection | Family 6 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| **StateConsistency** | Safety | At any point in time, if requester.connection_state == AUTHENTICATED and mutual_auth_requested, then responder.authentication_phase != ONE_WAY_COMPLETE. Mutual auth cannot be "in progress" on one side and "done" on the other. | Family 1 |
| **TranscriptIntegrity** | Safety | If signature verification uses message_c, then message_c must contain exactly (CHALLENGE_REQUEST + CHALLENGE_AUTH_RESPONSE - signature). No other appends or resets occur during signature verification. | Family 2 |
| **SlotIDMatch** | Safety | If CHALLENGE uses slot_id S, then CHALLENGE_AUTH response must reference the same slot S in param1 (possibly in version-specific encoding). | Family 3 |
| **NonceFreshness** | Safety | Each CHALLENGE message in a session must contain a nonce not seen before in that session. | Family 4 |
| **KeySourceConsistency** | Safety | If requester.key_source == CERT_CHAIN, then responder must generate hash from CERT_CHAIN. If requester.key_source == PUBLIC_KEY, then responder must generate hash from PUBLIC_KEY. Both must match. | Family 5 |
| **ContextEcho** | Safety (SPDM 1.3+) | If request contains requester_context C, then response must echo C byte-for-byte in the corresponding position. | Family 6 |
| **SignatureVerification** | Safety | Signature verification succeeds if and only if the signature was generated over the same message transcript (main or mutual auth, depending on phase). | Cross-cutting |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable Findings

| ID | Description | Expected Invariant Violation | Bug Family |
|----|-------------|----------------------------|------------|
| **MC1** | Can a requester set connection_state to AUTHENTICATED while responder is still in encapsulated mutual auth phase, and if so, does the requester accept messages that should be rejected in non-AUTHENTICATED state? | StateConsistency: Requester thinks AUTHENTICATED, responder doesn't | Family 1 |
| **MC2** | If main CHALLENGE transcript is not properly reset before encapsulated mutual auth begins, can the signature verification fail due to transcript corruption? | TranscriptIntegrity: Signature verification uses wrong transcript | Family 2 |
| **MC3** | Does slot_id validation work correctly across SPDM version 1.0, 1.1, 1.2, 1.3 transitions if a connection negotiates different versions? | SlotIDMatch: Version-specific encoding mismatch | Family 3 |
| **MC4** | If a responder reuses the same nonce in two consecutive CHALLENGE_AUTH responses (e.g., due to RNG failure), can the protocol detect it? | NonceFreshness: Duplicate nonce accepted | Family 4 |
| **MC5** | If requester switches from using certificate chain to public-key-only mode mid-connection (e.g., after GET_CERTIFICATE fails), does the hash verification correctly adapt to the new key source? | KeySourceConsistency: Hash mismatch due to source change | Family 5 |
| **MC6** (SPDM 1.3+) | Does the request context echo correctly survive the offset calculation and binary format encoding/decoding? | ContextEcho: Context mismatch in constant-time check | Family 6 |

### 6.2 Test-Verifiable Findings

| ID | Description | Suggested Test Approach |
|----|-------------|----------------------|
| **T1** | Mutual authentication: measure the time window between requester setting AUTHENTICATED state and responder completing mutual auth. Test if messages can be accepted during this window. | Integration test: instrument both sides, send state-dependent messages during window, verify rejection behavior. |
| **T2** | Nonce reuse: mock RNG to return same nonce twice, verify protocol rejects or at least logs warning. | Unit test with RNG mock. |
| **T3** | Slot ID transitions: test CHALLENGE with different slot IDs across version negotiation changes. | Parameterized integration test (version, slot_id) combinations. |
| **T4** | Context echo with padding/alignment: test SPDM 1.3+ context field with various buffer alignments and sizes near maximum. | Fuzzing test with aligned/misaligned context buffers. |

### 6.3 Code-Review-Only Findings

| ID | Description | Suggested Action |
|----|-------------|-----------------|
| **CR1** | Nonce generation: both `libspdm_get_random_number()` calls (responder, requester) assume cryptographically strong randomness. Verify RNG is seeded correctly and not predictable. | Code review: check RNG initialization and entropy source. |
| **CR2** | Certificate loading: `libspdm_context->local_context.local_cert_chain_provision[slot_id]` must be set before CHALLENGE. If not, responder returns error. However, is there a race between loading cert and receiving CHALLENGE? | Code review: ensure mutual exclusion around cert provisioning and CHALLENGE handler. |
| **CR3** | Error path: when signature verification fails (`libspdm_verify_challenge_auth_signature()` returns false), both sides reset `message_c`. Verify that no sensitive data leaks in error paths. | Code review + static analysis: check for timing leaks, exception handling. |
| **CR4** | Backward compatibility: code contains version checks like `>= SPDM_MESSAGE_VERSION_13`. Verify all older branches are still correct for SPDM 1.0, 1.1, 1.2. | Code review: trace all version-conditional code paths. |

---

## 7. Reference Pointers

**Source Code**:
- Responder challenge handler: `library/spdm_responder_lib/libspdm_rsp_challenge_auth.c`
- Requester challenge handler: `library/spdm_requester_lib/libspdm_req_challenge.c`
- Encapsulated mutual auth (responder): `library/spdm_responder_lib/libspdm_rsp_encap_challenge.c`
- Common utilities: `library/spdm_responder_lib/libspdm_rsp_common.c`
- Key exchange (for signature/HMAC logic): `library/spdm_responder_lib/libspdm_rsp_key_exchange.c`

**Header Files**:
- Responder API: `include/library/spdm_responder_lib.h`
- Requester API: `include/library/spdm_requester_lib.h`
- Internal context: `include/internal/libspdm_responder_lib.h`, `include/internal/libspdm_requester_lib.h`

**Protocol Specification**:
- SPDM spec: https://www.dmtf.org/standards/spdm
- SPDM 1.0-1.3 versions define CHALLENGE, CHALLENGE_AUTH, and encapsulated mutual auth

**Related Tests**:
- Unit tests in `unit_test/` directory (if present)
- Integration tests for challenge-response flow

---

## 8. Analysis Summary

**Total Findings**: 6 Bug Families identified

**Distribution**:
- High Priority: 1 (Family 1: State transition race in mutual auth)
- Medium Priority: 3 (Families 2, 3, 5)
- Low Priority: 2 (Families 4, 6)

**Model-Checking Recommendations**:
- Prioritize MC1 (mutual auth state consistency) — highest impact
- MC2, MC3, MC5 are medium complexity, suitable for standard TLA+ model checking
- MC4, MC6 are lower priority but good for defensive coverage

**Implementation Approach**:
The brief recommends a base spec modeling the main CHALLENGE/CHALLENGE_AUTH exchange, then extensions for mutual auth, version-specific behavior, and optional fields. This phased approach allows incremental verification and avoids a monolithic spec.

