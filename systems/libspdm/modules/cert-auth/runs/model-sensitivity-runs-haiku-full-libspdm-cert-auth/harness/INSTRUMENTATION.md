# Instrumentation Guide

## Overview

This document describes the instrumentation points for libspdm-cert-auth trace collection. All instrumentation is applied via a single patch file: `harness/patches/instrumentation.patch`.

## Instrumentation Points

### 1. RequesterSendChallenge
**File**: `library/spdm_requester_lib/libspdm_req_challenge.c`
**Location**: Before line 147 (before `libspdm_send_spdm_request`)
**Event**: `requester_send_challenge`
**Captures**: 
- slot_id, version (from request header)
- nonce (32 bytes, hex string)
- context (32 bytes if SPDM 1.3+, hex string or null)
- State: authentication_phase transitions to ONE_WAY_STARTED

### 2. ResponderHandleChallenge
**File**: `library/spdm_responder_lib/libspdm_rsp_challenge_auth.c`
**Location**: Before line 344 (before final return, after message handling)
**Event**: `responder_handle_challenge`
**Captures**:
- slot_id (from request param1)
- key_source: "cert_chain" if slot_id != 0xFF, else "public_key_only"
- nonce (32 bytes, hex string) generated at line ~225
- message_c_len: length of transcript after appending
- context_echo: request context if SPDM 1.3+
- State: connection_state and authentication_phase set based on mutual_auth_req flag

### 3. RequesterHandleChallengeAuth
**File**: `library/spdm_requester_lib/libspdm_req_challenge.c`
**Location**: Before line 380 (after signature verification, before connection state is set)
**Event**: `requester_handle_challenge_auth`
**Captures**:
- slot_id (from original request)
- key_source: determined from slot_id == 0xFF check at line 249
- responder_nonce: from response (32 bytes, hex string)
- context_match: boolean indicating whether context echo verification succeeded
- State: connection_state set to AUTHENTICATED (critical race point for Family 1)

**CRITICAL**: Line 380 sets connection_state to AUTHENTICATED, but the mutual auth response is sent at line 416. This creates a race condition.

### 4. ResponderHandleEncapChallenge
**File**: `library/spdm_responder_lib/libspdm_rsp_encap_challenge.c`
**Location**: In function `libspdm_get_encap_request_challenge`, before line 78 (before return)
**Event**: `responder_handle_encap_challenge`
**Captures**:
- message_mut_c_len: length of mutual auth transcript after appending
- State: active_transcript = MUTUAL_AUTH, connection_state unchanged

### 5. RequesterHandleEncapChallengeAuth
**File**: `library/spdm_requester_lib/libspdm_req_challenge.c`
**Location**: After `libspdm_encapsulated_request()` returns successfully (line 416-423)
**Event**: `requester_handle_encap_challenge_auth`
**Captures**:
- State: authentication_phase transitions to FULLY_AUTHENTICATED

## State Variables

The TLA+ spec uses "shadow" variables that don't exist directly in C code:

| TLA+ Variable | Implementation Source | How to Update |
|---|---|---|
| `authentication_phase` | Shadow state based on context and mutual_auth flags | Set in trace emit calls; in code, infer from BASIC_MUT_AUTH_REQ flag and state transitions |
| `key_source` | Implicit from slot_id check (slot_id == 0xFF) | Set at hash verification point |
| `connection_state` | `spdm_context->connection_info.connection_state` | Read directly from context |

## Making Changes to Instrumentation

### To add a new field to an event:

1. Add it to the trace emit function signature in `harness/src/tla_trace.h`
2. Update the corresponding emit function in `harness/src/tla_trace.c` to include it in the JSON output
3. Add the field capture at the instrumentation point in the source code

**Example**: To add `signature_valid` field to `requester_handle_challenge_auth`:

```c
// In tla_trace.h
void tla_emit_requester_handle_challenge_auth(
    uint64_t timestamp,
    uint8_t slot_id,
    const char *key_source,
    const uint8_t *responder_nonce,
    int context_match,
    int signature_valid,  // NEW
    tla_state_t state_before,
    tla_state_t state_after
);

// In tla_trace.c, update snprintf:
snprintf(msg_buf, sizeof(msg_buf),
         "\"slot_id\":%u,\"key_source\":%s,\"responder_nonce\":\"%s\","
         "\"context_match\":%s,\"signature_valid\":%s",
         slot_id, key_source_json, nonce_hex,
         context_match ? "true" : "false",
         signature_valid ? "true" : "false");  // NEW

// In libspdm_req_challenge.c, at instrumentation point:
tla_emit_requester_handle_challenge_auth(
    ts, slot_id, key_source, (const uint8_t *)nonce,
    !memcmp(ptr, ...),  // context_match
    result,  // signature_valid - NEW
    state_before, state_after
);
```

### To move a capture point:

1. Find the current emit call in the instrumented source
2. Move it to the new location (before/after a different line)
3. Update state_before/state_after values if needed
4. Rebuild with `make clean && make all` in the harness directory
5. Re-run test scenarios to verify trace generation

### To rebuild and test after changes:

```bash
cd harness
make clean
make all
cd ..
./bin/trace_test
```

## Trace Format

All events are NDJSON (one JSON object per line):

```json
{"tag":"trace","event":"<action_name>","node":"<requester|responder>","timestamp":<microseconds>,"state_before":{...},"state_after":{...},"<field1>":<value>,...}
```

Required fields in every event:
- `tag`: always "trace"
- `event`: action name (must match Trace.tla exactly)
- `node`: "requester" or "responder"
- `timestamp`: microseconds since test start (monotonic)
- `state_before`, `state_after`: state snapshots

Optional fields (action-specific):
- `slot_id`, `version`, `nonce`, `context`, `key_source`, `message_c_len`, `context_echo`, `responder_nonce`, `context_match`, `message_mut_c_len`

## State Snapshot Structure

Each `state_before` and `state_after` contains:
- `connection_state`: null/"challenged"/"authenticated"/"fully_authenticated"
- `authentication_phase`: "NONE"/"ONE_WAY_STARTED"/"ONE_WAY_COMPLETE"/"MUTUAL_IN_PROGRESS"/"FULLY_AUTHENTICATED"
- `key_source`: null/"cert_chain"/"public_key_only"

## Category A (Standard Single-File Trace)

This implementation uses Category A approach:
- Single NDJSON file per scenario
- Mutex-protected global trace writer
- Monotonic clock timestamps
- No timebox intervals

All instrumentation is synchronous; no special handling for concurrent operations.

## Testing

The harness includes a test scenario that generates synthetic trace events to verify:
1. JSON format is correct
2. All 5 events are present
3. Event names match spec exactly
4. State transitions make sense
5. Timestamps are sequential

Run tests with: `bash harness/run.sh`

## Integration with Real Protocol Tests

To use real libspdm protocol tests instead of synthetic traces:

1. Uncomment sections in `harness/src/test_trace_scenario.c` marked `// REAL TEST` (once integrated)
2. Link against libspdm library
3. Exercise real protocol flows (CHALLENGE/CHALLENGE_AUTH/ENCAP)
4. Traces are collected automatically from instrumented code paths

Current implementation uses synthetic traces for Phase 2.5 verification only.
