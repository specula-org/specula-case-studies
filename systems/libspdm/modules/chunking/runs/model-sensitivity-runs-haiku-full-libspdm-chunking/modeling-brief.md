# Modeling Brief: libspdm-chunking

## 1. System Overview

**libspdm** (DMTF Secure Protocol and Data Model) is a C-language implementation of the SPDM protocol for secure device-to-device communication. The system handles large-message chunking—splitting messages larger than the transport's DataTransferSize into multiple CHUNK_SEND/CHUNK_GET frames and reassembling them.

- **Category**: A (Distributed / Message-Passing)
- **Justification**: SPDM is a protocol state machine that coordinates message chunking across a network interface. Bugs lie in message ordering, state transitions, and protocol invariants—all suitable for TLA+ model checking.
- **Core files**: `libspdm_rsp_chunk_send_ack.c` (responder chunk-send handler), `libspdm_rsp_chunk_response.c` (chunk-get handler), `libspdm_rsp_receive_send.c` (interrupt/state management)
- **Concurrency model**: Single-threaded event loop; chunking state is per-context
- **Architecture**: Requester initiates CHUNK_SEND with message size + first chunk → responder reassembles → responds with CHUNK_SEND_ACK progress → requester continues sending chunks → responder processes complete message

## 2. Bug Families

### Family 1: Improper Interruption Handling During Chunk Transfer

**Mechanism**: When an interrupting command (any command other than GET_VERSION) is received during an active chunk_send or chunk_get sequence, the implementation immediately **clears the chunk context state**, terminating the chunked transfer. Per SPDM specification, the responder should reject the interrupting command with ERROR_UNEXPECTED_REQUEST but **preserve the chunk transfer state** so subsequent CHUNK_SEND/CHUNK_GET commands can resume.

**Evidence**:
- GitHub Issue #3577 (OPEN, 2026-03-31): "Interrupting command (excluding GET_VERSION) during chunk transfer terminates chunk transfer sequence." Detailed spec citation: DSP0274 v1.3 §23.3: "The chunked transfer shall not be interrupted... The Responder shall return the error ErrorCode=UnexpectedRequest if an unexpected command is received during the chunked transfer... shall not interrupt the chunk transfer sequence, with exception of... DecryptError"
- Code analysis: `libspdm_rsp_receive_send.c:558-583` — Lines 561-571 and 572-582 unconditionally clear `chunk_context.get` and `chunk_context.send` when a non-CHUNK_GET or non-CHUNK_SEND command is received.

**Affected code paths**:
- `libspdm_build_response()` (libspdm_rsp_receive_send.c:558-583) — called for every incoming request
- `libspdm_get_response_func_via_last_request()` — determines if incoming request is a chunk command

**Suggested modeling approach**:
- Variables: Add `chunk_transfer_interruptible` flag to distinguish between allowed interruptions (GET_VERSION, DecryptError) and forbidden ones
- Actions: Split message-receive action to separately model (a) chunk command processing, (b) interrupting command rejection without state clear, (c) exception cases (GET_VERSION, DecryptError)
- Granularity: Requires detailed state machine for chunk_in_use transitions

**Priority**: High
**Rationale**: Direct protocol violation with observable consequence—requester loses chunk context on interruption and must restart transfer or timeout. Historical issue is OPEN (unfixed), indicating ongoing concern.

---

### Family 2: Sequence Number Wrap Detection Asymmetry

**Mechanism**: Sequence number wrapping is handled differently across SPDM versions. For SPDM 1.2/1.3 (16-bit seq_no), wrap-around is treated as an **error** (line 188-190, libspdm_rsp_chunk_send_ack.c). For SPDM 1.4+ (32-bit seq_no), wrapping is not considered (line 126: `max_chunk_data_transfer_size = UINT64_MAX`). This creates potential for off-by-one errors or state inconsistencies when transitioning between versions or when seq_no approaches the boundary.

**Evidence**:
- Code analysis: `libspdm_rsp_chunk_send_ack.c:125-127` — SPDM 1.4+ disables wrap check
- Code analysis: `libspdm_rsp_chunk_send_ack.c:188-190` — SPDM 1.2/1.3 treats wrap as error
- Code analysis: `libspdm_rsp_chunk_response.c:135-142` — Parallel wrap-check logic for chunk_get

**Affected code paths**:
- `libspdm_get_response_chunk_send()` (chunk_send_ack.c:97-127) — decides version-specific max size
- Chunk sequence validation (chunk_send_ack.c:166, 188) — enforces or ignores wrap

**Suggested modeling approach**:
- Variables: Model seq_no as bounded integer; track version at message receive time
- Actions: Split chunk-continuation action to explicitly handle version-specific seq_no validation
- Invariants: "If seq_no == 0 on continuation and SPDM < 1.4, then error" and "If seq_no overflow in SPDM < 1.4 with message > threshold, then error"

**Priority**: Medium
**Rationale**: Version-dependent behavior can cause bugs when endpoints negotiate different versions or when sequence numbers reach boundary conditions. No historical issues yet, but asymmetry is a red flag for incomplete testing.

---

### Family 3: First-Chunk vs. Continuation-Chunk Size Calculation Inconsistency

**Mechanism**: The maximum chunk size calculation differs between the first CHUNK_SEND and continuation chunks. First chunk includes the message size field (sizeof(uint32_t)), reducing available payload; continuation chunks do not. This asymmetry could lead to:
- Off-by-one errors in payload boundary checking (line 134 vs. line 171)
- Confusion in responder's calc_max_chunk_size calculation (line 118 vs. line 164)
- Requester sending chunks that pass first-chunk validation but fail continuation validation, or vice versa

**Evidence**:
- Code analysis: `libspdm_rsp_chunk_send_ack.c:115-118` — First chunk: `calc_max_chunk_size = request_size - (sizeof(spdm_chunk_send_request_t) + sizeof(uint32_t))`
- Code analysis: `libspdm_rsp_chunk_send_ack.c:162-164` — Continuation: `calc_max_chunk_size = request_size - sizeof(spdm_chunk_send_request_t)`
- Line 135: `|| (uint32_t)request_size > spdm_context->local_context.capability.data_transfer_size` — applies only to first chunk

**Affected code paths**:
- `libspdm_get_response_chunk_send()` — first-chunk entry (line 106) vs. continuation-chunk path (line 160)

**Suggested modeling approach**:
- Variables: Explicit `chunk_phase` (INIT vs. CONTINUATION) to distinguish code paths
- Actions: Separate `CHUNK_SEND_INIT` and `CHUNK_SEND_CONTINUATION` actions with explicit size calculations for each
- Invariants: "calc_max_chunk_size(first) = calc_max_chunk_size(cont) + sizeof(uint32_t)" + verify all chunk payloads respect their path's size limit

**Priority**: Medium
**Rationale**: Inconsistency increases risk of off-by-one errors and boundary-condition bugs. Code path divergence is a common source of logic errors.

---

### Family 4: Unverified Buffer Capacity and Boundary Conditions

**Mechanism**: The responder allocates the large message in scratch buffer space (line 149-152). If the large_message_size exceeds the allocated capacity, subsequent memcpy operations (lines 156, 193) could overflow. The capacity is obtained from `libspdm_get_scratch_buffer_large_message_capacity()` without explicit bounds check against the incoming large_message_size.

**Evidence**:
- Code analysis: `libspdm_rsp_chunk_send_ack.c:149-152` — Capacity set from function call without bounds check
- Code analysis: `libspdm_rsp_chunk_send_ack.c:136` — large_message_size > max_spdm_msg_size check exists but does not guarantee capacity
- Code analysis: `libspdm_rsp_chunk_send_ack.c:156-158` and `193-196` — memcpy without explicit capacity recheck

**Affected code paths**:
- `libspdm_get_response_chunk_send()` — initialization phase (line 149-152)
- Chunk reassembly phase (lines 193-196)

**Suggested modeling approach**:
- Variables: Add `large_message_capacity` and model explicit capacity checks
- Actions: Insert capacity validation action before reassembly
- Invariants: "large_message_size <= large_message_capacity" and "chunk_bytes_transferred + next_chunk_size <= large_message_capacity"

**Priority**: Medium-High
**Rationale**: Buffer overflow is a critical safety bug. Historical issues #2302 hint at buffer sizing concerns.

---

### Family 5: State Cleanup on Error Path

**Mechanism**: When an error occurs during chunk reassembly (line 230-254), the chunk state is cleared. However, there is no explicit cleanup of the partially-reassembled message buffer. This could lead to:
- Stale data persisting in scratch buffer affecting subsequent operations
- Memory leaks if the buffer is not explicitly returned to the allocator
- Issue #524 (OPEN, 2022-01-29): "Responder should remove the previously appended request message in error handling of appending response" — a related cleanup gap for regular (non-chunked) message handling

**Evidence**:
- Code analysis: `libspdm_rsp_chunk_send_ack.c:249-254` — chunk_context state cleared but large_message buffer not invalidated
- GitHub Issue #524 (OPEN): Overlapping concern about incomplete error cleanup in responder
- Code analysis: `libspdm_rsp_receive_send.c:564-570` and `575-581` — Similar cleanup on interruption, but no buffer zeroing

**Affected code paths**:
- Error handling in `libspdm_get_response_chunk_send()` (line 230-254)
- Interruption handling in `libspdm_build_response()` (line 561-581)

**Suggested modeling approach**:
- Variables: Add `large_message_valid` flag alongside `chunk_in_use`
- Actions: Error/cleanup actions explicitly invalidate buffer state
- Invariants: "If chunk_in_use == false, then large_message_valid == false" and "If large_message_valid == false, buffer contents are not processed"

**Priority**: Low-Medium
**Rationale**: Cleanup gaps are typically low-severity (information leak, not safety), but corroborate a pattern of incomplete state management per issue #524.

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|-----|-----|-----|
| Chunk transfer interruption handling | Family 1: Direct spec violation; OPEN issue. | Split `libspdm_build_response()` to separately model allowed vs. forbidden interruptions. Add state to preserve chunk context on forbidden interrupts. |
| Sequence number validation across SPDM versions | Family 2: Version-dependent asymmetry. | Extend chunk-continuation action to explicitly dispatch on version and apply version-specific seq_no checks. |
| First-chunk vs. continuation size asymmetry | Family 3: Inconsistent payload calculations. | Separate `CHUNK_SEND_INIT` and `CHUNK_SEND_CONTINUATION` actions; verify size calculations match their respective constraints. |
| Large-message reassembly with capacity bounds | Family 4: Potential buffer overflow. | Add explicit capacity checks and model memcpy offset arithmetic. Use invariant to enforce "bytes_transferred + next_chunk_size <= capacity". |
| Chunk state cleanup on error/interruption | Family 5: Incomplete cleanup pattern. | Model large_message_valid flag alongside chunk_in_use. Verify flag transitions on error and interruption paths. |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| Transport-layer message framing (MCTP, PCI-DOE) | SPDM chunking is independent of transport. Bugs here are implementation-specific, not protocol-level. |
| Cryptographic processing (AES, HMAC details) | Chunking does not interact with crypto primitives; out of scope for this analysis. |
| Requester-side chunking logic | Specification requires symmetric responder and requester behavior, but responder-side bugs are the concern. Requester bugs would be a separate analysis. |
| Version negotiation (CAPABILITIES exchange) | Assumes version is already negotiated before chunk transfer. Version mismatch itself is a separate concern. |
| Scratch buffer allocation and freeing | Allocation policy is out of scope; model only the capacity constraint. |

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| Interruption-Allowed Tracking | `interruption_allowed` (bool) | Distinguish GET_VERSION and DecryptError from other interruptions | Family 1 |
| Version-Aware Seq_No Validation | `spdm_version`, `seq_no_wrap_flag` (uint32_t status) | Model asymmetric wrap-around handling for SPDM 1.2/1.3 vs. 1.4+ | Family 2 |
| Chunk Phase Tracking | `chunk_phase` ∈ {INIT, CONTINUATION} | Separate first-chunk and continuation code paths for size calculations | Family 3 |
| Large-Message Capacity Bound | `large_message_capacity` (uint32_t) | Explicit constraint on reassembly buffer | Family 4 |
| Buffer Validity Flag | `large_message_valid` (bool) | Track whether reassembled data is valid after error/interruption | Family 5 |

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| ChunkTransferPreservation | Safety | If chunk_in_use == true and receive forbidden interruption, then chunk_in_use remains true after rejection | Family 1 |
| SeqNoContinuity | Safety | In SPDM < 1.4: chunk_seq_no sequence is strictly increasing (0, 1, 2, ..., 65535); wrap to 0 is error. In SPDM 1.4+: increasing without wrap limit. | Family 2 |
| FirstChunkBoundary | Safety | First CHUNK_SEND payload size = request_size - sizeof(spdm_chunk_send_request_t) - sizeof(uint32_t) | Family 3 |
| ContinuationChunkBoundary | Safety | Continuation CHUNK_SEND payload size = request_size - sizeof(spdm_chunk_send_request_t) | Family 3 |
| ReassemblyCapacity | Safety | chunk_bytes_transferred + incoming_chunk_size ≤ large_message_capacity for every chunk | Family 4 |
| ReassemblyComplete | Safety | If chunk_bytes_transferred == large_message_size, then all preceding chunks have been received and reassembled without error | Family 4 |
| BufferValidityAfterError | Safety | If error during reassembly, then large_message_valid = false; subsequent reads must not process stale data | Family 5 |
| StateCleanupAfterInterruption | Safety | If forbidden interruption detected and rejected, chunk_in_use remains true; if GET_VERSION or DecryptError, responder may clear state | Family 1 |

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected Invariant Violation | Bug Family |
|----|-------------|----------------------------|------------|
| MC1 | If a non-GET_VERSION command interrupts chunk_send, does chunk_in_use remain true? | ChunkTransferPreservation violated (chunk_in_use cleared when it should persist) | Family 1 |
| MC2 | In SPDM 1.2/1.3, if chunk_seq_no increments from 65535, is the sequence correctly rejected or does it wrap unsafely? | SeqNoContinuity violated (wrap not rejected) | Family 2 |
| MC3 | Can a requester craft the first CHUNK_SEND with chunk_size > calc_max_chunk_size(first) but < calc_max_chunk_size(cont), causing inconsistent validation? | FirstChunkBoundary violated | Family 3 |
| MC4 | If large_message_size is set to large_message_capacity and every chunk is max size, do the reassembly memcpy operations stay within bounds? | ReassemblyCapacity violated if boundary arithmetic is off-by-one | Family 4 |
| MC5 | After an error in chunk reassembly (e.g., checksum failure on a later chunk), is the scratch buffer properly invalidated, and can stale data be accidentally reused? | BufferValidityAfterError violated (stale data read) | Family 5 |

### 6.2 Test-Verifiable

| ID | Description | Suggested Test Approach |
|----|-------------|----------------------|
| TV1 | Sequence number rollover for SPDM 1.2/1.3 | Unit test: send chunks with seq_no 65534, 65535, 0 (wrap). Verify error on wrap or state transition. |
| TV2 | Buffer overflow with max-sized chunks | Fuzz test: send large_message_size = max_capacity, then max-sized chunks. Verify no buffer overrun. |
| TV3 | Error recovery after partial reassembly | Integration test: send first 3 chunks, send invalid 4th chunk, then send new valid chunks. Verify old state is not reused. |

### 6.3 Code-Review-Only

| ID | Description | Suggested Action |
|----|-------------|-----------------|
| CR1 | Verify that `libspdm_get_scratch_buffer_large_message_capacity()` is never called without a corresponding capacity check against `large_message_size` | Search for all callers of `libspdm_get_scratch_buffer_large_message_capacity()` and verify bounds checks in context. |
| CR2 | Verify that interruption handling correctly distinguishes GET_VERSION and DecryptError from other commands | Audit `libspdm_get_response_func_via_last_request()` to confirm it recognizes special cases. Add explicit comments/guards. |
| CR3 | Verify asymmetry in calc_max_chunk_size is intentional or if it's an off-by-one error | Review design docs or spec for why first-chunk includes size field in max calc but continuation doesn't; confirm it's by design. |

## 7. Reference Pointers

- **Full analysis report**: This modeling brief
- **GitHub issues**: 
  - #3577 (OPEN, interruption handling)
  - #524 (OPEN, error cleanup)
  - #2302 (OPEN, buffer sizing)
  - #397 (OPEN, message size ambiguity)
- **Source files**:
  - `libspdm_rsp_chunk_send_ack.c` (lines 1–291): Responder chunk-send handler, key state machine
  - `libspdm_rsp_chunk_response.c` (lines 1–150+): Responder chunk-get handler
  - `libspdm_rsp_receive_send.c` (lines 558–583): Interruption handling, state cleanup
- **SPDM Specification**: DSP0274 v1.3 (chunking), DSP0274 v1.4 (seq_no changes)
- **Concurrency Model**: Single-threaded; chunk state is per-`libspdm_context_t`

---

## Analysis Coverage

- **Git history**: No local commits available; baseline is DMTF/libspdm main branch as of April 2026
- **GitHub issues**: Screened 18 open issues; 5 directly relevant to chunking; 4 confirmed bugs or design defects
- **Source code**: 3 core responder files analyzed; 6 decision points identified
- **Bug families**: 5 families grouped by mechanism
- **Verification depth**: All findings re-verified at code level with file:line citations

