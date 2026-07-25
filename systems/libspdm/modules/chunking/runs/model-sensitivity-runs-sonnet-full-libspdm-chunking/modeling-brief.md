# Modeling Brief: libspdm Large-Message Chunking / Reassembly

**Target**: DMTF/libspdm — SPDM large-message chunking (DSP0274 §11.x)  
**Language**: C  
**Core LOC (chunking paths only)**: ~1,200 lines across 5 files  
**Analysis date**: 2026-06-08

---

## 1. System Overview

libspdm is the DMTF reference implementation of the Security Protocol and Data Model (SPDM) specification. The large-message chunking subsystem allows protocol messages that exceed a peer's `DataTransferSize` to be transmitted as a sequence of fixed-size `CHUNK_SEND` or `CHUNK_RESPONSE` messages. The protocol is defined in SPDM 1.2+; SPDM 1.4 widened `chunk_seq_no` from `uint16_t` to `uint32_t`.

**Category: A (Distributed / Message-Passing)**. Justification: both sides implement a stateful protocol with explicit message types (`CHUNK_SEND`, `CHUNK_SEND_ACK`, `CHUNK_GET`, `CHUNK_RESPONSE`), sequential handshakes, per-transfer handles and sequence numbers, and reassembly state. Safety properties are about protocol-level invariants across message exchanges, not about shared-memory concurrency.

**Two orthogonal transfer flows** (each has distinct state in `libspdm_chunk_context_t`):
- **CHUNK_SEND flow**: Requester sends large request in fragments → Responder accumulates → Responder sends `CHUNK_SEND_ACK` with optional embedded response
- **CHUNK_GET flow**: Responder produces large response → Requester learns handle via `LARGE_RESPONSE` error → Requester issues `CHUNK_GET` per fragment → Requester reassembles

**Concurrency model**: Single-threaded per-context; no goroutines or locks. Atomicity boundary is one call to `libspdm_build_response()` (responder) or one iteration of the CHUNK_SEND/CHUNK_GET dispatch loop (requester). Requests arrive sequentially; the main hazards are **control-flow ordering within a handler** and **protocol-level state machine gaps across messages**.

**Key source files**:
- `library/spdm_requester_lib/libspdm_req_send_receive.c` — requester CHUNK_SEND flow
- `library/spdm_requester_lib/libspdm_req_handle_error_response.c` — requester CHUNK_GET flow  
- `library/spdm_responder_lib/libspdm_rsp_chunk_send_ack.c` — responder CHUNK_SEND_ACK handler
- `library/spdm_responder_lib/libspdm_rsp_chunk_response.c` — responder CHUNK_RESPONSE handler
- `library/spdm_responder_lib/libspdm_rsp_receive_send.c` — responder dispatch & large-response storage

---

## 2. Bug Families

### Family 1: Transfer Termination Condition Incompleteness

**Mechanism**: The chunking protocol requires two independent conditions to mark a transfer complete — (a) total declared bytes received and (b) `LAST_CHUNK` flag set on the final chunk. The implementation gates loop exit and success on (a) alone, never requiring (b).

**Evidence**:
- Code analysis: `libspdm_req_handle_error_response.c:457–459` — the do-while loop exits when `large_response_size_so_far >= large_response_size` OR when `LAST_CHUNK` is set. A responder that sends all declared bytes without ever setting `LAST_CHUNK` causes the loop to exit on the byte-count condition; the post-loop check at lines 462–473 only validates byte counts, not the flag. The transfer is treated as successful.
- Historical: Issue #2875 fixed a related issue (seq-no wrap-around), showing the termination logic has been a repeated correctness site.
- Historical: Issue #3577 (fixed 2026-06-05) found that any interrupting request was incorrectly clearing chunk state — another termination-condition boundary case.

**Affected code paths**: `libspdm_req_handle_error_response.c:457–473`

**Suggested modeling approach**:
- Variables: `last_chunk_received: bool` tracking whether `LAST_CHUNK` was set on the chunk where `bytes_so_far == total_size`
- Actions: `ProcessChunkResponse(seqNo, chunkSize, data, isLast)` — split into two variants: one that sets `last_chunk_received` and one that doesn't, both leaving `bytes_so_far == total_size`
- Invariant: `TransferCompleteImpliesLastChunk`: SUCCESS return from CHUNK_GET flow implies `last_chunk_received = true`

**Priority**: High  
**Rationale**: Genuine open question about a currently unvalidated protocol property; the fix is non-trivial (must add a post-loop check for LAST_CHUNK), and the mechanism has a track record of related bugs.

---

### Family 2: Control-Flow Ordering Allows State Mutation After Error Detection

**Mechanism**: A validation check sets an error status but does not short-circuit the subsequent `if/else-if/else` chain in the same function body. The copy/accumulation logic executes despite the prior error, advancing shared state (buffer contents, `chunk_bytes_transferred`, `chunk_seq_no`) before the error is finally surfaced.

**Evidence**:
- Code analysis: `libspdm_rsp_chunk_send_ack.c:166–203` — the sequence-number check at line 166 is a standalone `if` block that sets `status = LIBSPDM_STATUS_INVALID_MSG_FIELD` but does NOT prevent the independent `if/else-if/else` chain at line 170 from entering its `else` branch (line 191) and executing `libspdm_copy_mem` + `chunk_seq_no` update at lines 193–199. The data copy and state advance happen with the wrong seq-no before `IS_ERROR(status)` fires at line 230.
- Historical: Issue #3573 (fixed 2026-04-01) shows a related control-flow issue in `libspdm_get_response_chunk_send()` where a validation failure triggered a proper `CHUNK_SEND_ACK + EarlyErrorDetected` response but then returned an error status, causing the caller to overwrite it with `UNSUPPORTED_REQUEST`. Same structural pattern: error detection and response construction were de-coupled from control flow.
- Historical: Issue #2145 (chunk size check used wrong `data_transfer_size`) shows the seq-no / size validation path has been a repeated site for correctness bugs.

**Affected code paths**: `libspdm_rsp_chunk_send_ack.c:160–230`

**Suggested modeling approach**:
- Split the `ChunkSendReceived` action into two sub-actions: `ChunkSendReceivedValid` (all checks pass → copy + advance state) and `ChunkSendReceivedInvalidSeqNo` (seq-no wrong → no state mutation, return error immediately)
- Variables: no new variables needed; the existing `chunk_seq_no`, `chunk_bytes_transferred`, `large_message` buffer pointer
- Invariant: `NoStateAdvanceOnSeqNoMismatch`: if `incoming_seq_no ≠ expected_seq_no`, then `chunk_bytes_transferred'= chunk_bytes_transferred` (unchanged)

**Priority**: High  
**Rationale**: Confirmed code-level bug with real protocol semantics — copy executing with wrong seq-no violates the SPDM protocol invariant that the accumulation buffer is only modified by in-order, validated chunks.

---

### Family 3: Reassembly Output Validity After Transfer Completion

**Mechanism**: When the requester's CHUNK_GET reassembly loop finishes and the accumulated large response is larger than the caller's output buffer, the implementation silently returns SUCCESS without writing any output, without zeroing the sensitive scratch buffer, and without setting the output size — leaving the caller with stale, potentially-zero output and a success status.

**Evidence**:
- Code analysis: `libspdm_req_handle_error_response.c:462–473` — the post-loop `if/else-if` chain has no `else` branch for `large_response_size > response_capacity`. When this condition holds, `libspdm_copy_mem` is skipped, `*inout_response_size` is not updated, `libspdm_zero_mem(large_response, large_response_size)` is not called (scratch buffer retains plaintext), and `return status` at line 475 returns `LIBSPDM_STATUS_SUCCESS`. The caller receives a success code with stale output.
- Historical: Issue #3189 (fixed Feb 2026) was a boundary-case variant in the same function — `large_response_size` could be smaller than expected when embedded in `CHUNK_SEND_ACK`. Shows this function has a history of edge cases in the bounds-checking branch.

**Affected code paths**: `libspdm_req_handle_error_response.c:462–475`

**Suggested modeling approach**:
- Variables: `response_fits: bool` computed as `large_response_size ≤ response_capacity`
- Actions: split `TransferComplete` into `TransferCompleteSuccess` (fits → copy + zero scratch) and `TransferCompleteBufferOverflow` (does not fit → error status + zero scratch)
- Invariant: `SuccessImpliesOutputWritten`: `status = SUCCESS` implies `output_written = true AND scratch_zeroed = true`

**Priority**: High  
**Rationale**: Silent success with missing output violates the basic contract that callers rely on — confirmed by code reading; the missing `else` branch is unambiguous.

---

### Family 4: Source-Length Unbounded in Reassembly Copy

**Mechanism**: The `chunk_size` field in a `CHUNK_RESPONSE` is responder-controlled and is used directly as the source-length argument to `libspdm_copy_mem` without being validated against the actual number of bytes received in the response message (`response_size - header_overhead`). The only bounds check guards the destination accumulator, not the source read.

**Evidence**:
- Code analysis: `libspdm_req_handle_error_response.c:449–451` — `libspdm_copy_mem(large_response + offset, dst_remaining, chunk_ptr, spdm_response->chunk_size)`. Lines 416–419 check `chunk_size + large_response_size_so_far ≤ large_response_size` (destination overrun), but there is no check that `spdm_response->chunk_size ≤ response_size - sizeof(spdm_chunk_response_response_t)` (source overrun). A malicious or buggy responder can set `chunk_size` to exceed the actual payload bytes in the response message, causing a read past the end of the received buffer.
- Historical: Issue #2631 (OSS-Fuzz heap-buffer-overflow) found an analogous source-read-past-end in `libspdm_get_response_chunk_send()` via a fuzzer-generated first-chunk with a minimal message size. The fuzz corpus has been seeded for this; similar patterns exist on the requester side.

**Affected code paths**: `libspdm_req_handle_error_response.c:449–451`

**Suggested modeling approach**:
- Variables: `received_msg_size: nat` tracking actual bytes in the received message
- Actions: `ProcessChunkResponse` precondition requires `chunk_size ≤ received_msg_size - header_overhead`
- Invariant: `SourceBoundedness`: every accepted `chunk_size` satisfies `chunk_size ≤ received_msg_size - sizeof(CHUNK_RESPONSE_HEADER)`

**Priority**: High  
**Rationale**: Over-read from a received message buffer exposes adjacent protocol state in the scratch area. The category (source-read unbounded by actual received length) is distinct from the already-fixed destination-write overflow in #2631.

---

### Family 5: Mutual Exclusion Asymmetry Between CHUNK_SEND and CHUNK_GET

**Mechanism**: The responder's `CHUNK_SEND_ACK` handler checks `get.chunk_in_use` and rejects a new CHUNK_SEND if CHUNK_GET is in progress. The inverse check is absent: the `CHUNK_RESPONSE` handler does not check `send.chunk_in_use`, so a CHUNK_GET arriving mid-CHUNK_SEND is accepted without error. The SEND context is only cleared when the next non-CHUNK_GET request arrives; the intermediate window leaves both chunk contexts simultaneously active.

**Evidence**:
- Code analysis: `libspdm_rsp_chunk_send_ack.c:90–95` — `if (spdm_context->chunk_context.get.chunk_in_use) { return UNEXPECTED_REQUEST; }`. `libspdm_rsp_chunk_response.c:98–103` — no corresponding `send.chunk_in_use` check.
- Code analysis: `libspdm_rsp_receive_send.c:562–582` — SEND context is aborted when `chunk_in_use && request != CHUNK_SEND`, but this fires only on the NEXT request after the CHUNK_GET, leaving a window where CHUNK_GET proceeds and the SEND context is still live.
- Historical: Issue #3577 (fixed Jun 2026) fixed the related case where any non-CHUNK_GET request during a CHUNK_GET transfer incorrectly cleared state. The asymmetric exclusion was not addressed by that fix.

**Affected code paths**: `libspdm_rsp_chunk_response.c:98–150`, `libspdm_rsp_chunk_send_ack.c:90–95`, `libspdm_rsp_receive_send.c:562–582`

**Suggested modeling approach**:
- Variables: `send_in_progress: bool`, `get_in_progress: bool` in responder state
- Actions: `ChunkGetArrivesDuringSend` — models the interleaved arrival; check whether this can be accepted and whether subsequent state is consistent
- Invariant: `SingleDirectionAtATime`: NOT (send_in_progress AND get_in_progress) at any stable state

**Priority**: Medium  
**Rationale**: The asymmetry is confirmed, but the abort mechanism provides partial mitigation. The question is whether the window between accepting a CHUNK_GET and clearing SEND context allows a detectable safety violation (e.g., partial CHUNK_SEND data being assembled into the wrong response).

---

## 3. Modeling Recommendations

### 3.1 Model (with rationale)

| What | Why | How |
|------|-----|-----|
| Seq-no as explicit guard precondition | Family 2: state must not advance on seq-no mismatch | Split `ChunkSendReceived` into valid/invalid variants; only valid variant modifies `chunk_bytes_transferred` and `chunk_seq_no` |
| `LAST_CHUNK` flag as independent transfer-complete condition | Family 1: byte count alone is insufficient for transfer termination | Add `last_chunk_flag: bool` variable to `ProcessChunkResponse`; make success action require both byte count AND flag |
| Caller buffer capacity as a model variable | Family 3: silent success when buffer too small | Track `response_capacity` as a spec parameter; `TransferComplete` success requires `large_response_size ≤ response_capacity` |
| Source-length bound check in reassembly copy | Family 4: `chunk_size` must be bounded by actual received message size | Add precondition `chunk_size ≤ received_size - overhead` to `ProcessChunkResponse` action |
| Dual `chunk_in_use` flags with symmetric exclusion | Family 5: GET arrives during SEND | Model both `send_in_use` and `get_in_use`; check GET handler precondition matches SEND handler's symmetry |

### 3.2 Do Not Model (with rationale)

| What | Why |
|------|-----|
| `chunk_handle` double-increment | Implementation-level arithmetic bug (handle is uint8_t, wraps harmlessly); fix is a one-line assignment change; no protocol safety implication |
| `large_message_capacity` never set for GET context | Missing assignment bug — compile-readable; the zero-mem call is a no-op but causes no incorrect protocol behavior |
| Uninitialized `message`/`message_size` in unexpected-buffer path | C UB bug with a code comment acknowledging it; better addressed by test or sanitizer |
| `chunk_seq_no` type mismatch across v1.2/v1.4 structs | Wire-format serialization detail; the internal state is always `uint32_t`, and existing version branches handle the truncation; no protocol reachability gap |
| Transport-layer padding causing `decoded_message_size > data_transfer_size` | Already fixed in #3344; implementation-detail edge case involving transport codec, not protocol logic |
| Chunk size arithmetic underflow when `data_transfer_size < 12` | Protocol-layer validation (CAPABILITIES negotiation) should prevent this; modeled at implementation boundary |

---

## 4. Proposed Extensions

| Extension | Variables | Purpose | Bug Family |
|-----------|-----------|---------|------------|
| `last_chunk_received` | `last_chunk_received: Bool` | Track whether final chunk carried `LAST_CHUNK` flag | Family 1 |
| `seq_no_guard_separation` | `expected_seq_no: Nat`, `incoming_seq_no: Nat` | Model seq-no check as distinct precondition from data-copy action | Family 2 |
| `output_written` | `output_written: Bool`, `scratch_zeroed: Bool` | Track whether caller output and scratch buffer were updated on completion | Family 3 |
| `received_msg_size` | `received_msg_size: Nat` | Bound `chunk_size` against actual received bytes in each CHUNK_RESPONSE | Family 4 |
| `dual_in_use` | `send_in_use: Bool`, `get_in_use: Bool` | Symmetric mutual exclusion modeling | Family 5 |

---

## 5. Proposed Invariants

| Invariant | Type | Description | Targets |
|-----------|------|-------------|---------|
| `TransferCompleteImpliesLastChunk` | Safety | SUCCESS from CHUNK_GET flow requires `last_chunk_received = true` | Family 1 |
| `NoStateAdvanceOnSeqNoMismatch` | Safety | If `incoming_seq_no ≠ expected_seq_no`, then `chunk_bytes_transferred` is unchanged | Family 2 |
| `SuccessImpliesOutputWritten` | Safety | SUCCESS from CHUNK_GET flow requires `output_written = true` and `scratch_zeroed = true` | Family 3 |
| `SourceBoundedness` | Safety | Every accepted `chunk_size` ≤ `received_msg_size - sizeof(CHUNK_RESPONSE_HEADER)` | Family 4 |
| `SingleDirectionAtATime` | Safety | NOT (`send_in_use` ∧ `get_in_use`) at any state reachable without a protocol error | Family 5 |
| `SeqNoMonotone` | Safety | `chunk_seq_no` increments exactly by 1 per accepted chunk; never decrements or jumps | Families 1, 2 |
| `LargeMessageSizeConsistent` | Safety | `large_message_size` declared in seq-no 0 chunk equals the value used throughout the transfer | Families 3, 4 |

---

## 6. Findings Pending Verification

### 6.1 Model-Checkable

| ID | Description | Expected invariant violation | Bug Family |
|----|-------------|------------------------------|------------|
| MC1 | Can a requester's CHUNK_GET flow return SUCCESS when the final chunk had all declared bytes but LAST_CHUNK was never set? | `TransferCompleteImpliesLastChunk` | Family 1 |
| MC2 | When a CHUNK_SEND arrives with `chunk_seq_no ≠ expected_seq_no + 1`, can `chunk_bytes_transferred` and the accumulation buffer advance? | `NoStateAdvanceOnSeqNoMismatch` | Family 2 |
| MC3 | Can the requester's CHUNK_GET loop return SUCCESS to the caller with `*inout_response_size` unchanged and `inout_response` unmodified? | `SuccessImpliesOutputWritten` | Family 3 |
| MC4 | Can a responder-controlled `chunk_size` field exceed `received_msg_size - header_overhead`, making `libspdm_copy_mem` read past the received buffer? | `SourceBoundedness` | Family 4 |
| MC5 | Can a CHUNK_GET request complete successfully while `send_in_use` is true, leaving both chunk directions simultaneously active? | `SingleDirectionAtATime` | Family 5 |

### 6.2 Test-Verifiable

| ID | Description | Suggested test approach |
|----|-------------|------------------------|
| TV1 | `chunk_handle` is incremented twice per completed exchange (`rsp_receive_send.c:658` + `rsp_chunk_response.c:213`) | Unit test: perform N complete chunked GET exchanges; assert handle advanced by N, not 2N |
| TV2 | `large_message_capacity` is never assigned in the GET context; `libspdm_zero_mem(get_info->large_message, get_info->large_message_capacity)` is always a no-op | Unit test: write known pattern to large_message buffer; complete a CHUNK_GET exchange; verify pattern is zeroed |
| TV3 | Uninitialized `message`/`message_size` in `libspdm_send_request` when request is outside all known buffer regions | Sanitizer (ASAN/MSan) test: call `libspdm_send_request` with a request buffer allocated independently of the SPDM context |

### 6.3 Code-Review-Only

| ID | Description | Suggested action |
|----|-------------|-----------------|
| CR1 | `libspdm_generate_error_response` return value is discarded at `rsp_chunk_send_ack.c:63`, `:71`, `:109` (other sites in the same file use `return func(...)`) | Align the three sites with the consistent pattern; add return-value check |
| CR2 | SPDM_ERROR responses bypass `spdm_version` validation in both CHUNK_SEND loop (`req_send_receive.c:487–497`) and CHUNK_GET loop (`handle_error_response.c:343–347`), while non-error responses check version | Check version before dispatching on error code, consistent with non-error path |
| CR3 | `handle_error_response.c:536–568`: CHUNK_SEND_ACK with `EARLY_ERROR_DETECTED` processes and stores the embedded error without verifying `param2 == send_info->chunk_handle` | Add handle validation on the EARLY_ERROR_DETECTED path, matching the check at line 570 for the normal path |
| CR4 | v1.4 (`>= SPDM_MESSAGE_VERSION_14`) CHUNK_GET loop has no `max_chunk_data_transfer_size` bound and no upper-limit on `chunk_seq_no`; comment says "wrap not considered in spdm 1.4+" without spec citation | Document or add a spec reference; add an explicit sanity upper-bound check proportional to `large_response_size / min_data_transfer_size` |

---

## 7. Reference Pointers

**Key source files**:
- Requester CHUNK_GET: `library/spdm_requester_lib/libspdm_req_handle_error_response.c` (~300 lines, CHUNK_GET loop at ~L270–475)
- Requester CHUNK_SEND: `library/spdm_requester_lib/libspdm_req_send_receive.c` (~800 lines, CHUNK_SEND loop at ~L360–620)
- Responder CHUNK_SEND_ACK: `library/spdm_responder_lib/libspdm_rsp_chunk_send_ack.c` (~240 lines)
- Responder CHUNK_RESPONSE: `library/spdm_responder_lib/libspdm_rsp_chunk_response.c` (~220 lines)
- Responder dispatch: `library/spdm_responder_lib/libspdm_rsp_receive_send.c` (~700 lines, large-response storage at ~L650–680)
- Context state structures: `include/internal/libspdm_common_lib.h:496–510` (`libspdm_chunk_info_t`, `libspdm_chunk_context_t`)

**Key protocol structures** (`include/industry_standard/spdm.h`):
- CHUNK_SEND pre-1.4: `spdm_chunk_send_request_t` (L1399–1409), `chunk_seq_no: uint16_t`
- CHUNK_SEND 1.4: `spdm_chunk_send_request_14_t` (L1411–1420), `chunk_seq_no: uint32_t`
- CHUNK_RESPONSE pre-1.4: `spdm_chunk_response_response_t` (L1459–1469)
- CHUNK_RESPONSE 1.4: `spdm_chunk_response_response_14_t` (L1471–1480)
- `LAST_CHUNK` flag: `SPDM_CHUNK_GET_RESPONSE_ATTRIBUTE_LAST_CHUNK = (1 << 0)` in `header.param1`
- Handle: always `header.param2` (uint8_t in 4-byte SPDM message header)

**Key GitHub issues / PRs**:
- #3573 / PR #3576: EarlyErrorDetected CHUNK_ACK overwritten by UNSUPPORTED_REQUEST (same Family 2 structural pattern)
- #2631 / PR #2622: OSS-Fuzz heap-buffer-overflow in CHUNK_SEND_ACK first-chunk (analogous source-bounds issue)
- #2875 / PR #2952: seq-no wrap-around bug and fix (evidence of termination-condition bug-proneness)
- #3577 / PR #3615: chunk state cleared on any interrupting request (related to Family 5 abort path)
- #3598 / PR #3608: CHUNK_RESPONSE handle correlation check was missing (now fixed; neighbor of Family 4)
- #3189 / PR #3492: `large_response_size` floor too strict in error handler (same function as Families 3, 4)

**Reference spec**: DSP0274 (SPDM Specification), §11 "Chunking Protocol". The SPDM 1.4 chunk message structures are the authoritative reference for field layouts and `LAST_CHUNK` semantics.
