# Instrumentation Spec: libspdm-version-cap-algo

Action-to-code mapping for trace instrumentation. This document specifies how to instrument the libspdm source code to generate traces compatible with `Trace.tla`.

---

## Section 1: Trace Event Schema

### Event Envelope (Common to All Events)

Every trace event is a JSON object with:

```json
{
  "event": "<event_name>",
  "timestamp": <unix_ns>,
  "node_id": "<requester|responder>",
  "state_before": { ... },
  "state_after": { ... }
}
```

**Fields**:
- `event` (string): Event name from Action-to-Code Mapping below
- `timestamp` (integer): Event timestamp in nanoseconds (or Wall-clock time)
- `node_id` (string): "requester" or "responder"
- `state_before`: State snapshot **before** action executes (for causal context)
- `state_after`: State snapshot **after** action executes (for post-state validation)

### Common State Fields (Captured at Every Event)

| Field | Type | Description | Source |
|-------|------|-------------|--------|
| `requester_state` | string | Requester FSM state | `requester_state` variable |
| `responder_state` | string | Responder FSM state | `responder_state` variable |
| `version_negotiated` | bool | Version exchange completed? | Connection state flag |
| `capabilities_negotiated` | bool | Capabilities exchange completed? | Connection state flag |
| `algorithms_negotiated` | bool | Algorithms exchange completed? | Connection state flag |
| `negotiated_version` | int | Agreed SPDM version | `connection_info.version` |
| `local_algos_req` | array[int] | Requester's supported algorithms | Requester's `algorithm` table |
| `local_algos_resp` | array[int] | Responder's supported algorithms | Responder's `algorithm` table |

### Event-Specific Fields

| Event Name | Field | Type | Description | Source | Notes |
|-----------|-------|------|-------------|--------|-------|
| `requester_init_version` | N/A | N/A | No additional fields | N/A | Marks start of handshake |
| `requester_receives_version` | `version` | int | VERSION.version_number_list[0] | Received VERSION message | Store version number only |
| `requester_init_capabilities` | N/A | N/A | No additional fields | N/A | |
| `requester_receives_capabilities` | N/A | N/A | No additional fields | N/A | Presence marks receipt |
| `requester_init_algorithms` | `proposed_algos` | array[int] | Algorithms proposed by requester | Constructed NEGOTIATE_ALGORITHMS message | List all proposed algorithm codes |
| `requester_validates_algorithms` | `agreed_algos` | array[int] or int | Algorithm agreed on by responder | Received ALGORITHMS message | Capture `base_asym_algo` from response (or array if multiple) |
| | `algorithms_negotiated` | bool | Did validation succeed? | libspdm_req_negotiate_algorithms.c:529-533 | TRUE if intersection non-empty |
| `responder_handles_version` | N/A | N/A | No additional fields | N/A | Marks receipt of GET_VERSION |
| `responder_sends_version` | `version` | int | VERSION response | Constructed VERSION response | Store version number |
| `responder_handles_capabilities` | N/A | N/A | No additional fields | N/A | Marks receipt of GET_CAPABILITIES |
| `responder_sends_capabilities` | N/A | N/A | No additional fields | N/A | Marks transmission of CAPABILITIES |
| `responder_handles_algorithms` | `proposed_algos` | array[int] | Algorithms proposed by requester | Received NEGOTIATE_ALGORITHMS message | List all received algorithm codes |
| | `prioritization_failed` | bool | Did prioritize_algorithm return 0? | libspdm_rsp_algorithms.c:42-56 | TRUE if no common algorithm |
| `responder_sends_algorithms` | `agreed_algos` | array[int] or int | Algorithm in ALGORITHMS response | Constructed ALGORITHMS message | Store `base_asym_algo` from response |

---

## Section 2: Action-to-Code Mapping

### Requester Actions

#### Action: `RequesterInitVersion`

**Spec**: `base.tla:331-338`

**Code Location**: `libspdm_req_get_version.c:40-230` (overall function)
- **Trigger Point**: Right before sending GET_VERSION message
- **Exact Location**: After constructing message header, before `spdm_send_request()`

**Trace Event Name**: `requester_init_version`

**Fields to Capture**:
- `event`: "requester_init_version"
- `node_id`: "requester"
- `state_before.requester_state`: "requester_init"
- `state_after.requester_state`: "requester_version_sent"

**Code Patch Location**:
```c
// File: libspdm_req_get_version.c
// After line: ~150 (message construction complete, before send)
// Emit trace event:
trace_emit("requester_init_version", state_snapshot());
```

**Notes**: 
- This marks the start of the protocol handshake
- Occurs at most once per connection

---

#### Action: `RequesterReceivesVersion`

**Spec**: `base.tla:340-356`

**Code Location**: `libspdm_req_get_version.c:40-230` (response handling phase)
- **Trigger Point**: After receiving and validating VERSION response, before state update
- **Exact Location**: Inside `spdm_process_response()` for VERSION, after message validation

**Trace Event Name**: `requester_receives_version`

**Fields to Capture**:
- `event`: "requester_receives_version"
- `node_id`: "requester"
- `version`: VERSION message's `version_number_list[0]` field
- `state_before.version_negotiated`: FALSE
- `state_after.version_negotiated`: TRUE
- `state_after.requester_state`: "requester_caps_sent"

**Code Patch Location**:
```c
// File: libspdm_req_get_version.c
// After line: ~180 (VERSION message parsed, version extracted)
// Emit trace event with version:
struct {
    .version = response_message->version_number_list[0]
} event = {...};
trace_emit("requester_receives_version", event, state_snapshot());
```

**Notes**:
- Version field is the SPDM version number (e.g., 0x10 for SPDM 1.0, 0x11 for 1.1)
- Validation at lines 529-533 checks bitwise AND of local vs received version support

---

#### Action: `RequesterInitCapabilities`

**Spec**: `base.tla:358-366`

**Code Location**: `libspdm_req_get_capabilities.c`
- **Trigger Point**: Right before sending GET_CAPABILITIES message
- **Exact Location**: After constructing message, before `spdm_send_request()`

**Trace Event Name**: `requester_init_capabilities`

**Fields to Capture**:
- `event`: "requester_init_capabilities"
- `node_id`: "requester"
- `state_before.requester_state`: "requester_caps_sent"

**Code Patch Location**:
```c
// File: libspdm_req_get_capabilities.c
// After message construction, before send:
trace_emit("requester_init_capabilities", state_snapshot());
```

**Notes**:
- No message-specific fields; presence marks protocol progress

---

#### Action: `RequesterReceivesCapabilities`

**Spec**: `base.tla:368-380`

**Code Location**: `libspdm_req_get_capabilities.c` (response handling)
- **Trigger Point**: After receiving CAPABILITIES message
- **Exact Location**: Inside `spdm_process_response()` for CAPABILITIES

**Trace Event Name**: `requester_receives_capabilities`

**Fields to Capture**:
- `event`: "requester_receives_capabilities"
- `node_id`: "requester"
- `state_before.requester_state`: "requester_caps_sent"
- `state_after.requester_state`: "requester_algo_sent"
- `state_after.capabilities_negotiated`: TRUE

**Code Patch Location**:
```c
// File: libspdm_req_get_capabilities.c
// After CAPABILITIES message received and validated:
trace_emit("requester_receives_capabilities", state_snapshot());
```

---

#### Action: `RequesterInitAlgorithms`

**Spec**: `base.tla:382-395`

**Code Location**: `libspdm_req_negotiate_algorithms.c:73-200`
- **Trigger Point**: Right before sending NEGOTIATE_ALGORITHMS message
- **Exact Location**: After populating algorithm list, before `spdm_send_request()`

**Trace Event Name**: `requester_init_algorithms`

**Fields to Capture**:
- `event`: "requester_init_algorithms"
- `node_id`: "requester"
- `proposed_algos`: Array of algorithm codes from message (base_asym_algo, base_hash_algo, etc.)
- `state_before.requester_state`: "requester_algo_sent"

**Code Patch Location**:
```c
// File: libspdm_req_negotiate_algorithms.c
// After algorithm list construction (lines 130-180), before send:
struct {
    .proposed_algos = [
        request_message->base_asym_algo,
        request_message->base_hash_algo,
        request_message->dhe_algo,
        request_message->aead_algo,
        ...
    ]
} event = {...};
trace_emit("requester_init_algorithms", event, state_snapshot());
```

**Notes**:
- Capture all algorithm codes sent in the message
- Codes are opaque integers (SHA256 = 0x01, ECDSA = 0x01, etc. per SPDM spec)

---

#### Action: `RequesterValidatesAlgorithms`

**Spec**: `base.tla:397-421`

**Code Location**: `libspdm_req_negotiate_algorithms.c:474-541`
- **Trigger Point**: After receiving ALGORITHMS response and performing validation
- **Exact Location**: After lines 529-541 (validation logic), before state finalization

**Trace Event Name**: `requester_validates_algorithms`

**Fields to Capture**:
- `event`: "requester_validates_algorithms"
- `node_id`: "requester"
- `agreed_algos`: `base_asym_algo` from ALGORITHMS response message
- `algorithms_negotiated`: TRUE if bitwise AND(local, response) != 0, FALSE otherwise
- `state_before.requester_state`: "requester_algo_sent"
- `state_after.requester_state`: "requester_complete"

**Code Patch Location**:
```c
// File: libspdm_req_negotiate_algorithms.c
// After validation at lines 529-541:
bool validation_passed = (local_algos & response_algos) != 0;
struct {
    .agreed_algos = response_message->base_asym_algo,
    .algorithms_negotiated = validation_passed
} event = {...};
trace_emit("requester_validates_algorithms", event, state_snapshot());
```

**Notes**:
- Key field: `algorithms_negotiated` determines validation outcome
- This event fires regardless of validation success/failure (both paths traced)
- Corresponds to Family 5 in modeling brief (conditional validation)

---

### Responder Actions

#### Action: `ResponderHandlesVersion`

**Spec**: `base.tla:449-463`

**Code Location**: `libspdm_rsp_version.c:54-127`
- **Trigger Point**: After receiving GET_VERSION message, before state reset
- **Exact Location**: Inside handler, after message validation, before `libspdm_reset_context()`

**Trace Event Name**: `responder_handles_version`

**Fields to Capture**:
- `event`: "responder_handles_version"
- `node_id`: "responder"
- `state_before.responder_state`: any (can arrive in various states due to reset)
- `state_after.responder_state`: "responder_version_resp"
- `state_after.version_negotiated`: FALSE (reset due to Family 4)

**Code Patch Location**:
```c
// File: libspdm_rsp_version.c
// After GET_VERSION received, before reset at line 81:
trace_emit("responder_handles_version", state_snapshot());
libspdm_reset_context();  // This happens next
```

**Notes**:
- Family 4 mechanism: GET_VERSION resets `version_negotiated`, `capabilities_negotiated`, `algorithms_negotiated`
- Can occur mid-handshake (Family 4 fault)

---

#### Action: `ResponderSendsVersion`

**Spec**: `base.tla:465-473`

**Code Location**: `libspdm_rsp_version.c` (response construction)
- **Trigger Point**: Right before sending VERSION response
- **Exact Location**: After constructing response, before `spdm_send_response()`

**Trace Event Name**: `responder_sends_version`

**Fields to Capture**:
- `event`: "responder_sends_version"
- `node_id`: "responder"
- `version`: VERSION response's `version_number_list[0]`
- `state_before.responder_state`: "responder_version_resp"
- `state_after.responder_state`: "responder_caps_resp"
- `state_after.version_negotiated`: TRUE

**Code Patch Location**:
```c
// File: libspdm_rsp_version.c
// After constructing response message (line ~90):
struct {
    .version = response_message->version_number_list[0]
} event = {...};
trace_emit("responder_sends_version", event, state_snapshot());
```

---

#### Action: `ResponderHandlesCapabilities`

**Spec**: `base.tla:475-483`

**Code Location**: `libspdm_rsp_capabilities.c:165-380`
- **Trigger Point**: After receiving GET_CAPABILITIES, before validation
- **Exact Location**: Inside handler, after message received

**Trace Event Name**: `responder_handles_capabilities`

**Fields to Capture**:
- `event`: "responder_handles_capabilities"
- `node_id`: "responder"
- `state_before.responder_state`: "responder_caps_resp"
- `state_after.responder_state`: "responder_algo_resp"

**Code Patch Location**:
```c
// File: libspdm_rsp_capabilities.c
// After GET_CAPABILITIES received and validated:
trace_emit("responder_handles_capabilities", state_snapshot());
```

---

#### Action: `ResponderSendsCapabilities`

**Spec**: `base.tla:485-492`

**Code Location**: `libspdm_rsp_capabilities.c` (response construction)
- **Trigger Point**: Right before sending CAPABILITIES response
- **Exact Location**: After constructing response, before `spdm_send_response()`

**Trace Event Name**: `responder_sends_capabilities`

**Fields to Capture**:
- `event`: "responder_sends_capabilities"
- `node_id`: "responder"
- `state_before.responder_state`: "responder_algo_resp"

**Code Patch Location**:
```c
// File: libspdm_rsp_capabilities.c
// After response construction:
trace_emit("responder_sends_capabilities", state_snapshot());
```

---

#### Action: `ResponderHandlesAlgorithms`

**Spec**: `base.tla:494-551`

**Code Location**: `libspdm_rsp_algorithms.c:557-695`
- **Trigger Point**: After receiving NEGOTIATE_ALGORITHMS message
- **Exact Location**: Inside handler, after parsing proposed algorithms, before assignment to connection state

**Trace Event Name**: `responder_handles_algorithms`

**Fields to Capture**:
- `event`: "responder_handles_algorithms"
- `node_id`: "responder"
- `proposed_algos`: Array of algorithms from NEGOTIATE_ALGORITHMS message
- `prioritization_failed`: TRUE if `PrioritizeAlgorithm()` returned 0 (Family 2)
- `state_before.responder_state`: "responder_algo_resp"
- `state_after.responder_state`: "responder_complete"

**Code Patch Location**:
```c
// File: libspdm_rsp_algorithms.c
// After parsing NEGOTIATE_ALGORITHMS (lines 590-620), before storing in connection:
int prioritized = libspdm_prioritize_algorithm(local_algos, request_message->base_asym_algo);
struct {
    .proposed_algos = [
        request_message->base_asym_algo,
        request_message->base_hash_algo,
        ...
    ],
    .prioritization_failed = (prioritized == 0)
} event = {...};
trace_emit("responder_handles_algorithms", event, state_snapshot());
```

**Notes**:
- Family 1: Direct assignment at line 565-566 without validation (no intersection check)
- Family 2: Prioritization may return 0 if no common algorithm

---

#### Action: `ResponderSendsAlgorithms`

**Spec**: `base.tla:553-561`

**Code Location**: `libspdm_rsp_algorithms.c:724-747`
- **Trigger Point**: Right before sending ALGORITHMS response
- **Exact Location**: After constructing response, before `spdm_send_response()`

**Trace Event Name**: `responder_sends_algorithms`

**Fields to Capture**:
- `event`: "responder_sends_algorithms"
- `node_id`: "responder"
- `agreed_algos`: `base_asym_algo` in ALGORITHMS response
- `state_before.responder_state`: "responder_complete"

**Code Patch Location**:
```c
// File: libspdm_rsp_algorithms.c
// After constructing ALGORITHMS response (lines 730-745):
struct {
    .agreed_algos = response_message->base_asym_algo
} event = {...};
trace_emit("responder_sends_algorithms", event, state_snapshot());
```

**Notes**:
- If prioritization failed (Family 2), `agreed_algos` will be 0

---

## Section 3: Special Considerations

### 1. Version Numbering and Encoding

- SPDM version numbers are encoded as `0x1X` where X is the minor version
- Examples: SPDM 1.0 = 0x10, SPDM 1.1 = 0x11, SPDM 1.2 = 0x12, SPDM 1.4 = 0x14
- In traces, store the version as an integer (not as a separate major/minor pair)

### 2. Algorithm Codes

Algorithm codes follow SPDM DSP0274 specification:
- `base_asym_algo`: 0x0001 = RSA, 0x0002 = ECDSA, etc.
- `base_hash_algo`: 0x01 = SHA-256, 0x02 = SHA-384, 0x03 = SHA-512, etc.
- `dhe_algo`, `aead_algo`, etc.: Follow spec encoding

In traces, store algorithm codes as integers (not symbolic names).

### 3. State Snapshots

Every event's `state_before` and `state_after` should include:
- `requester_state`: Current FSM state of requester
- `responder_state`: Current FSM state of responder
- `version_negotiated`: Boolean flag
- `capabilities_negotiated`: Boolean flag
- `algorithms_negotiated`: Boolean flag
- `negotiated_version`: Agreed version (0 if not yet negotiated)
- `local_algos_req`: Requester's supported algorithms (snapshot at event time)
- `local_algos_resp`: Responder's supported algorithms (snapshot at event time)

### 4. Message Buffer State

Do **not** trace the message buffer itself (messages in-flight). This would create unnecessary clutter. Instead:
- Trace only the semantic state (FSM state, negotiated values)
- Let the sequence of events imply message transmission

### 5. Mid-Handshake GET_VERSION (Family 4 Fault)

When GET_VERSION arrives in state RESPONDER_CAPS_RESP or RESPONDER_ALGO_RESP:
- Event is still `responder_handles_version`
- Note in `state_before` which state the responder was in when reset occurred
- Spec will detect this as a violation of `VersionNegotiatedBeforeCapabilities` invariant (or repair it if the reset is benign)

### 6. Instrumentation Points Summary

| File | Lines | Event Name | Field | Code Location |
|------|-------|-----------|-------|---------------|
| libspdm_req_get_version.c | ~150 | requester_init_version | N/A | Before send |
| libspdm_req_get_version.c | ~180 | requester_receives_version | version | After parse |
| libspdm_req_get_capabilities.c | ~90 | requester_init_capabilities | N/A | Before send |
| libspdm_req_get_capabilities.c | ~130 | requester_receives_capabilities | N/A | After receive |
| libspdm_req_negotiate_algorithms.c | ~150 | requester_init_algorithms | proposed_algos | Before send |
| libspdm_req_negotiate_algorithms.c | ~500 | requester_validates_algorithms | agreed_algos, algorithms_negotiated | After validation |
| libspdm_rsp_version.c | ~80 | responder_handles_version | N/A | Before reset |
| libspdm_rsp_version.c | ~110 | responder_sends_version | version | Before send |
| libspdm_rsp_capabilities.c | ~200 | responder_handles_capabilities | N/A | After receive |
| libspdm_rsp_capabilities.c | ~350 | responder_sends_capabilities | N/A | Before send |
| libspdm_rsp_algorithms.c | ~620 | responder_handles_algorithms | proposed_algos, prioritization_failed | Before assignment |
| libspdm_rsp_algorithms.c | ~745 | responder_sends_algorithms | agreed_algos | Before send |

### 7. Trace Output Format

Emit traces as NDJSON (one JSON object per line):

```json
{"event":"requester_init_version","timestamp":1234567890123456789,"node_id":"requester","state_before":{...},"state_after":{...}}
{"event":"requester_receives_version","timestamp":1234567890123456800,"node_id":"requester","version":16,"state_before":{...},"state_after":{...}}
```

---

## References

- **Spec Actions**: See `base.tla` for action definitions
- **Trace Spec**: See `Trace.tla` for event matching and validation logic
- **SPDM Spec**: DSP0274 (Distributed Management Task Force)
- **libspdm Source**: `/artifact/libspdm/` in repo root
