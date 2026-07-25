# Instrumentation Guide: SPDM KEY_EXCHANGE / FINISH Protocol

This document guides Phase 3 agents on how to adjust instrumentation when trace validation reveals issues.

## Quick Start

To rebuild and re-run after modifying instrumentation:

```bash
bash harness/apply.sh
bash harness/run.sh
```

Traces are written to `traces/*.ndjson`.

---

## Instrumentation Points

### 1. REQ_SEND_KEY_EXCHANGE
**Files**: `artifact/libspdm/library/spdm_requester_lib/libspdm_req_key_exchange.c` (lines 300-400)

**Current state captured**: `requesterState.state`, `capabilities_req`

**To modify**: 
- Add fields to state_json: Edit the call to `tla_trace_emit_event()` in the KEY_EXCHANGE send path
- Capture additional message fields: Add to the message_json parameter

**Expected in trace**: Event with requester state "KEX_SENT", message type "KEY_EXCHANGE_REQ"

### 2. RESP_RECEIVE_KEY_EXCHANGE
**Files**: `artifact/libspdm/library/spdm_responder_lib/libspdm_rsp_key_exchange.c` (lines 50-350)

**Current state captured**: `responderState.state`, `sessionType[session_id]`, `sessionIDPoolCount`

**Critical for Family 3**: This is where session IDs are allocated. The `session_id_pool_count` field tracks allocation.

**To modify**:
- Capture pre-allocation state: Insert emit call before `sessionIDCounter` is incremented
- Capture post-allocation state: Insert emit call after session is added to pool

**Expected in trace**: Event with responder state "KEX_SENT", allocated session_id, session type "DHE"

### 3. REQ_RECEIVE_KEY_EXCHANGE
**Files**: `artifact/libspdm/library/spdm_requester_lib/libspdm_req_key_exchange.c` (lines 500-700)

**Current state captured**: `requesterState.state`, `sessions[session_id].state`, `dheKeysAgreed`, `transcriptHashKEX`, `capabilitiesValidated`

**Critical for Family 2, 4, 5**: Validation happens here.

**To modify**:
- Add validation results: Include `heartbeat_period_valid`, `mut_auth_bits_valid`, `slot_id_valid` in the state_json
- Add transcript hash: Capture `transcriptHashKEX[session_id]` value

**Expected in trace**: Event with requester state "KEX_RECEIVED", validation results

### 4. REQ_SEND_FINISH
**Files**: `artifact/libspdm/library/spdm_requester_lib/libspdm_req_finish.c` (lines 50-150)

**Current state captured**: `requesterState.state`, `sessionType[session_id]`, `transcriptHashFINISH`

**Critical for Family 1**: Session type consistency check.

**Expected in trace**: Event with requester state "FINISH_SENT", session_type "DHE" or "PSK_DHE"

### 5. RESP_RECEIVE_FINISH
**Files**: `artifact/libspdm/library/spdm_responder_lib/libspdm_rsp_finish_rsp.c` (lines 50-300)

**Current state captured**: `responderState.state`, `sessions[session_id].state`, `hmacVerified`

**Critical for Family 2, 5**: HMAC verification and opaque_length validation.

**To modify**:
- Add opaque_length validation: Include `opaque_length_valid` in state_json if present
- Capture HMAC verification result: Add `hmacVerified` flag

**Expected in trace**: Event with responder state "FINISH_SENT", hmacVerified=true

### 6. REQ_RECEIVE_FINISH
**Files**: `artifact/libspdm/library/spdm_requester_lib/libspdm_req_finish.c` (lines 85-150)

**Current state captured**: `requesterState.state`, `sessions[session_id].state`

**Critical for Family 1**: Transcript hash prefix property check.

**To modify**:
- Add transcript consistency: Include `transcriptHashKEX` and `transcriptHashFINISH` in state_json for comparison

**Expected in trace**: Event with requester state "HANDSHAKING", transcript consistency verified

### 7. KEY_EXCHANGE_ERROR
**Files**: `artifact/libspdm/library/spdm_requester_lib/libspdm_req_key_exchange.c` (lines 744-878)

**Current state captured**: `error_reason`, `session_id_freed`

**Critical for Family 3**: Session ID leak detection.

**To modify**:
- Add error context: Include which validation failed (opaque_length, signature, HMAC)
- Track session state: Capture session state before/after error path

**Error paths to instrument**:
- Line ~760: Opaque length validation failure
- Line ~800: Signature verification failure  
- Line ~850: HMAC mismatch

### 8. FINISH_ERROR
**Files**: `artifact/libspdm/library/spdm_requester_lib/libspdm_req_finish.c` (entire function)

**Current state captured**: `error_reason`, `session_id_freed`

**Critical for Family 3**: THE KEY BUG. This function has NO cleanup code, so session IDs are always leaked.

**Note**: When emitting FINISH_ERROR, `session_id_freed` should ALWAYS be FALSE to confirm the bug.

**To detect the bug**:
- Emit FINISH_ERROR with `session_id_freed=false` whenever FINISH processing fails
- The trace should show `sessionIDPoolCount` never decrements

---

## How to Add a New Field to an Event

1. **Identify the code location** where the state change happens
2. **Read the implementation state** (e.g., `session_info->state`, `context->sessionID`)
3. **Format as JSON** (e.g., `"state":"KEX_RECEIVED"`)
4. **Update the emit call** to include the new field in `state_json`:
   ```c
   char state_buf[512];
   snprintf(state_buf, sizeof(state_buf),
       "{\"requester_state\":\"%s\",\"session_id\":%d,\"new_field\":%d}",
       state_str, session_id, new_value);
   tla_trace_emit_event(&trace_ctx, "REQ_RECEIVE_KEY_EXCHANGE", session_id, state_buf, NULL);
   ```

---

## How to Add a New Event Type

1. **Define the event name** in the instrumentation spec (e.g., "NEW_EVENT")
2. **Identify the trigger point** in the source code
3. **Call the emit function**:
   ```c
   tla_trace_emit_event(&trace_ctx, "NEW_EVENT", session_id, state_json, message_json);
   ```
4. **Update Trace.tla** with an event predicate and action wrapper:
   ```tla
   NewEventEvent == IsNodeEvent("NEW_EVENT", SomeRole)
   WrapNewEvent == /\ NewEventEvent /\ NewAction /\ ValidatePostState /\ l' = l + 1
   ```

---

## How to Move a Capture Point

**Before emission (pre-state)**: Emit right before the state change

```c
// Emit before assigning session_id
tla_trace_emit_event(&ctx, "BEFORE_ALLOC", 0, state_before, NULL);
session_id = allocate_id();
```

**After emission (post-state)**: Emit right after the state change

```c
// Emit after assigning session_id
session_id = allocate_id();
tla_trace_emit_event(&ctx, "AFTER_ALLOC", session_id, state_after, NULL);
```

**Rule**: Instrumentation spec dictates which — always check `instrumentation-spec.md` section 2 for "Trigger Point".

---

## Rebuild Cycle

After modifying instrumentation in the artifact:

```bash
# Re-apply patches and recompile
bash harness/apply.sh

# Rerun tests and regenerate traces
bash harness/run.sh

# Verify new traces
ls -la traces/*.ndjson
wc -l traces/*.ndjson

# Run trace validation
cd spec && tlc -config Trace.cfg Trace.tla
```

---

## Trace Format Checklist

Every trace event must include:

- ✓ `"tag": "trace"` (required by Trace.tla)
- ✓ Real `"ts"` (epoch nanoseconds, not synthetic)
- ✓ `"event"` object with `"name"`, `"nid"`, `"session_id"`
- ✓ `"state"` object with all mapped variables
- ✓ `"msg"` object (if applicable to this action)

**Example**:
```json
{"tag":"trace","ts":1234567890000,"event":{"name":"REQ_SEND_KEY_EXCHANGE","nid":"requester","session_id":0,"state":{"requester_state":"KEX_SENT","capabilities_req":[]},"msg":{"type":"KEY_EXCHANGE_REQ","nonce":"0xabcd1234"}}}
```

---

## Common Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| Validation fails: "state mismatch" | Emitted state doesn't match actual implementation state | Verify the code location where state is read. Compare with Trace.tla ValidatePostState. |
| "event not found in trace" | Event not being emitted | Check the instrumentation point in the source. Add `printf` debug to verify code path is hit. |
| "timestamp in wrong order" | Events emitted out of order | Use a mutex when emitting (already in tla_trace.c). |
| Field "session_id_freed" always false | Expected for FINISH_ERROR (it's the bug!). For KEY_EXCHANGE_ERROR, check error path cleanup. | Verify error handling code actually calls cleanup. |

---

## Testing & Validation

To check if instrumentation is working:

```bash
# 1. Rebuild
bash harness/apply.sh && bash harness/run.sh

# 2. Spot-check traces
head -5 traces/scenario_1_successful_handshake.ndjson | jq .

# 3. Count events by type
grep -o '"name":"[^"]*"' traces/*.ndjson | cut -d'"' -f4 | sort | uniq -c

# 4. Run TLC validation
cd spec && tlc -deadlock Trace Trace.cfg
```

---

## Files Modified by Instrumentation

When apply.sh or patches are applied, the following files are copied/modified:

- `artifact/libspdm/tla_trace.h` ← trace module header
- `artifact/libspdm/tla_trace.c` ← trace module implementation
- `artifact/libspdm/library/spdm_requester_lib/libspdm_req_key_exchange.c` ← instrumented
- `artifact/libspdm/library/spdm_requester_lib/libspdm_req_finish.c` ← instrumented
- `artifact/libspdm/library/spdm_responder_lib/libspdm_rsp_key_exchange.c` ← instrumented
- `artifact/libspdm/library/spdm_responder_lib/libspdm_rsp_finish_rsp.c` ← instrumented

To revert, run:
```bash
cd artifact/libspdm && git checkout -- . && rm -f tla_trace.{h,c}
```

---

## Questions?

Refer to:
- **Instrumentation Spec**: `spec/instrumentation-spec.md`
- **Trace Spec**: `spec/Trace.tla`
- **Base Spec**: `spec/base.tla`
- **Harness Guide**: `../../.claude/skills/harness-generation/guide.md`
