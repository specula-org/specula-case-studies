# Modeling Brief: libspdm Measurement Extension Log (MEL)

**Target**: SPDM MEL chunked transfer protocol
**Category**: A (Distributed / Message-Passing)
**Language**: C
**Reference**: DMTF SPDM 1.3+ specification
**Scope**: Requester and Responder MEL protocol interactions

---

## System Category

**Category A: Distributed / Message-Passing**

Justification: MEL is an SPDM protocol where a Requester initiates GET_MEASUREMENT_EXTENSION_LOG messages to a Responder, which responds with MEASUREMENT_EXTENSION_LOG responses. The protocol involves network message exchange with chunked data transfer, not concurrent/lock-free operations.

---

## System Architecture

### Requester Side
- **Entry Point**: `libspdm_get_measurement_extension_log()` (libspdm_req_get_measurement_extension_log.c)
- **Core Logic**: `libspdm_try_get_measurement_extension_log()`
- **Operation**: Loops requesting MEL chunks (offset/length) until all data received
- **State**: Maintains `offset`, `mel_size_internal`, `remainder_length`, `total_responder_mel_buffer_length`

### Responder Side
- **Entry Point**: `libspdm_get_response_measurement_extension_log()` (libspdm_rsp_measurement_extension_log.c)
- **Core Logic**: Validates request parameters, fetches MEL via `libspdm_measurement_extension_log_collection()`
- **Operation**: Slices MEL at requested offset/length, returns portion + remainder_length
- **State**: Protocol state checks, capability negotiation

### Protocol Flow
1. Requester sends GET_MEASUREMENT_EXTENSION_LOG(offset, length)
2. Responder validates, collects full MEL, calculates offset slice
3. Responder returns: portion_length, remainder_length, data
4. Requester accumulates data, checks if more chunks needed
5. Loop until remainder_length == 0 or buffer full

---

## Bug Families

### BF1: Offset/Length Arithmetic Overflow

**Mechanism**: 
- Offset and length are both `uint32_t` 
- Requester (line 135): `remainder_length = spdm_mel_len - (length + offset)` — unchecked addition can overflow
- Requester (line 205-206): Validity check uses `spdm_request->offset + spdm_response->portion_length + spdm_response->remainder_length`, three additions without overflow guard
- Responder (line 132): `(uint64_t)offset + length` cast happens AFTER arithmetic; `offset >= spdm_mel_len` check at line 126 does not prevent overflow in line 132 subtraction

**Evidence**:
- Requester line 99-100: `offset` and `length` unpacked from untrusted request
- Requester line 109-113: `spdm_request->offset` used directly in next iteration
- Responder line 126-130: Check `offset >= spdm_mel_len` but no guard for `offset + length` overflow in the subsequent calculation line 133

**Potential Impact**: 
- If offset or length exceed MEL bounds, subtraction at line 133 or 135 could wrap around (though 64-bit cast at 132 mitigates some risk)
- Integer overflow leading to incorrect remainder_length calculation
- Infinite loop if remainder_length wraps to large value

**Priority**: HIGH

### BF2: Remainder Length Consistency Validation

**Mechanism**:
- Requester expects remainder_length to be consistent across requests (line 205-210 check)
- Responder calculates: `remainder_length = spdm_mel_len - (length + offset)` (line 135)
- If MEL size changes between responder calls, or responder inconsistency, remainder_length could be invalid
- Requester line 205-206: Check is `<` (less than total), but this allows remainder to shrink — no explicit check that it equals expected value

**Evidence**:
- Responder line 115-124: MEL is fetched fresh each time `libspdm_measurement_extension_log_collection()` is called — no guarantee of immutability between requests
- Requester line 203-204: On first response, `total_responder_mel_buffer_length = portion_length + remainder_length` is computed and stored
- Requester line 205-210: Subsequent responses check `offset + portion_length + remainder_length < total`, but this is inconsistent — should be `==` not `<`

**Potential Impact**:
- Responder returning different MEL size in second request causes inconsistency
- Requester loop termination based on stored `total_responder_mel_buffer_length` may never match actual response
- Off-by-one in chunk boundary detection

**Priority**: HIGH

### BF3: Loop Termination Condition Race

**Mechanism**:
- Requester loop (line 242-243): `while (mel_size_internal < sizeof(spdm_measurement_extension_log_dmtf_t) + measurement_extension_log->mel_entries_len)`
- This assumes `measurement_extension_log->mel_entries_len` is immutable while loop runs
- But `measurement_extension_log` points into the buffer being reassembled (`measure_exten_log`)
- If received data is incomplete or malformed, `mel_entries_len` field may be garbage on first iteration

**Evidence**:
- Requester line 228-231: Data is copied into `measure_exten_log` at offset `mel_size_internal`
- Line 241: `measurement_extension_log = (spdm_measurement_extension_log_dmtf_t *)measure_exten_log` — points into buffer
- Line 242-243: Loop condition dereferences `measurement_extension_log->mel_entries_len` without validating header was fully received

**Potential Impact**:
- First MEL header (8 bytes: number_of_entries, mel_entries_len, reserved) might not be fully received
- Loop reads uninitialized or partial `mel_entries_len`, causing wrong termination condition
- Off-by-one or infinite loop if partial header received

**Priority**: MEDIUM

### BF4: Request Offset Continuity

**Mechanism**:
- Requester sets next request offset based on previous response: `spdm_request->offset = (uint32_t)mel_size_internal` (line 109)
- This assumes `mel_size_internal` reflects cumulative bytes received
- Requester line 113: If `spdm_request->offset == 0`, use full `length`; else `LIBSPDM_MIN(length, remainder_length)`
- But after first request, the offset may not align with responder's expectations if portion_length < requested length

**Evidence**:
- Requester line 109-114: Next offset calculated as cumulative `mel_size_internal`
- If responder intentionally returns less data than requested (e.g., capping at max_mel_block_length), requester's offset continues linearly
- Responder line 108-110: `max_mel_block_length` can limit response, causing requester offset to skip bytes if not handled correctly

**Potential Impact**:
- Responder sees offset that doesn't align with previous response boundaries
- Data corruption or gaps in reassembled MEL if offset/length bookkeeping diverges

**Priority**: MEDIUM

### BF5: Response Validation Gap — Portion Length vs Request Length

**Mechanism**:
- Responder line 152-153: Sets `portion_length = length` after clamping at line 108-110
- Requester line 179-184: Validates `portion_length <= requested length` and `portion_length > 0`
- But requester doesn't verify that responder honored the exact requested length when capacity allowed
- If responder under-returns (portion_length < length requested), and then returns remainder_length implying full MEL is known, inconsistency arises

**Evidence**:
- Responder line 108-110: `if (length > max_mel_block_length) { length = max_mel_block_length; }`
- Requester line 111-114: Logic assumes responder will return min(requested_length, remainder_length)
- But if responder returns less without explanation (no specific error), requester may not detect the mismatch

**Potential Impact**:
- Silent data loss if responder returns fewer bytes than requested
- Requester loop may terminate prematurely thinking all data received

**Priority**: MEDIUM

### BF6: Unsigned Integer Subtraction Underflow

**Mechanism**:
- Requester line 132-134: `if (((uint64_t)offset + length) > spdm_mel_len)` then clamp length
- But responder has already returned `spdm_mel_len` as `offset >= spdm_mel_len` check (line 126-130)
- If responder's MEL size (spdm_mel_len) is 0, or offset is exactly at boundary, line 135 subtracts and stores in uint32_t remainder

**Evidence**:
- Responder line 86-91: Checks MEL spec/hash_algo are set, but doesn't validate MEL collection returned non-zero
- Responder line 113-114: `spdm_mel = NULL; spdm_mel_len = 0` initialized
- Responder line 115-124: If `libspdm_measurement_extension_log_collection()` returns false, generates error
- But if it returns true with `spdm_mel_len = 0`, line 126 check fails to catch it (0 >= 0 is true, so no error, but then offset = 0 proceeds)
- Requester line 133: After receiving, `length = (uint32_t)(spdm_mel_len - offset)` — but `spdm_mel_len` is responder's reported size, not validated against portion_length

**Potential Impact**:
- Empty MEL (spdm_mel_len = 0) accepted without error
- Requester may loop indefinitely if responder keeps returning 0 bytes with non-zero remainder

**Priority**: LOW-MEDIUM

---

## Verification Strategy

### Model Checking (TLA+)
- **Model Scope**: Requester-Responder MEL exchange for a single GET_MEASUREMENT_EXTENSION_LOG operation
- **Key Variables**: 
  - Requester: offset, mel_size_internal, remainder_length, total_responder_mel_buffer_length, request/response msg state
  - Responder: MEL buffer (abstracted as size), offset, portion_length, remainder_length
- **Invariants**:
  - BF1: No arithmetic overflow in offset+length combinations
  - BF2: remainder_length consistency across requests
  - BF3: Loop termination within bounded iterations
  - BF4: Offset continuity and alignment
  - BF5: portion_length correctness
  - BF6: No underflow in unsigned arithmetic

### Trace Validation
- Instrument responder to emit: `{offset, mel_collected_len, portion_len, remainder_len}`
- Instrument requester to emit: `{req_offset, req_length, recv_portion, recv_remainder, mel_size_so_far}`
- Validate state transitions match spec invariants

### Out of Scope (for now)
- Full cryptographic validation of MEL signatures
- Session establishment and security protocol
- Transport layer (buffer management is modeled abstractly)

---

## Reference Code Locations

**Responder**:
- `libspdm_get_response_measurement_extension_log()`: libspdm_rsp_measurement_extension_log.c lines 10–160
- Key checks: lines 34–97 (parameter validation), lines 115–124 (MEL collection), lines 126–135 (offset/length logic)

**Requester**:
- `libspdm_try_get_measurement_extension_log()`: libspdm_req_get_measurement_extension_log.c lines 23–252
- Key loops: lines 93–243 (main chunking loop)
- Key arithmetic: lines 99–100, 109–114, 135, 202–210, 217–233, 242–243

---

## Modeling Decisions

### Included
1. Chunked transfer protocol with offset/length/remainder
2. Arithmetic bounds checking (or lack thereof)
3. Consistency validation of remainder_length
4. Loop termination logic
5. Buffer accumulation order

### Excluded
1. Cryptographic operations (hash, signature)
2. Session security (only model successful authenticated state)
3. Transport / NIC-level issues
4. Memory allocation failures (assume buffers sufficiently sized)
5. Multi-threaded responder scenarios (assume single-threaded responder)

### Simplifications
- MEL content modeled as opaque byte array of abstract size
- libspdm_measurement_extension_log_collection() modeled as returning fixed MEL size (test case: MEL mutating between calls is future extension)
- No modeling of response_state transitions; assume NORMAL state throughout

---

## Expected TLA+ Spec Extensions

### BF1: Arithmetic Overflow
- Action: Calculate offset + length, catch overflow guard (or lack)
- Invariant: `offset + length <= 2^32 - 1` OR error returned

### BF2: Remainder Consistency
- Action: On each response, validate remainder matches prior calculation
- Invariant: `total_responder_mel_buffer_length` unchanged across requests

### BF3: Header Completeness
- Action: Track mel_size_internal >= sizeof(MEL header) before reading header fields
- Invariant: Loop condition only dereferences mel_entries_len after header fully received

### BF4: Offset Alignment
- Action: Verify next offset equals prior offset + prior portion_length
- Invariant: No gaps or overlaps in byte ranges requested

### BF5: Portion Length Validation
- Action: Check portion_length against requested length and responder capacity
- Invariant: portion_length <= requested && portion_length + offset <= MEL size

### BF6: Underflow Guard
- Action: Check spdm_mel_len > 0 before subtraction
- Invariant: remainder_length calculated only from non-empty MEL

---

## Summary

This is a **protocol correctness** analysis focused on integer arithmetic, state consistency, and loop termination in chunked data transfer. The main risks are off-by-one errors, arithmetic overflow, and responder inconsistency. TLA+ model checking will expose interleaving orders (e.g., remainder_length field changes, premature loop exit) that unit tests cannot reliably trigger.
