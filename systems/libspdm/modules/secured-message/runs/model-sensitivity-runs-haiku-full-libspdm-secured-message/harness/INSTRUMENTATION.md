# Instrumentation Guide for libspdm-secured-message

This document explains how to instrument the libspdm-secured-message library to emit TLA+ trace events.

## Instrumentation Approach

The instrumentation follows a **Category A** (message-passing) pattern with mutex-protected global trace output using NDJSON format.

## Instrumentation Points

### 1. TransitionToEstablished
**File**: `library/spdm_secured_message_lib/libspdm_secmes_context_data.c`  
**Function**: `libspdm_secured_message_set_session_state` (line 30-44)  
**Location**: After line 37 (state assignment), before line 41 (clear_handshake_secret call)

**Instrumentation**:
```c
if (session_state == LIBSPDM_SESSION_STATE_ESTABLISHED) {
    // ADD THIS LINE:
    // tla_trace_emit_transition_to_established("requester", "sid", session_state_before, LIBSPDM_SESSION_STATE_ESTABLISHED, false);
    
    libspdm_clear_handshake_secret(secured_message_context);
    libspdm_clear_master_secret(secured_message_context);
}
```

**Fields to emit**:
- session_state_before: previous state (usually HANDSHAKING)
- session_state_after: ESTABLISHED
- secrets_cleared_after: false (not yet cleared)

### 2. CompleteZeroization  
**File**: `library/spdm_secured_message_lib/libspdm_secmes_session.c`  
**Function**: `libspdm_clear_handshake_secret` (line 467-480)  
**Location**: After line 476 (after all zero_mem calls)

**Instrumentation**:
```c
void libspdm_clear_handshake_secret(void *spdm_secured_message_context)
{
    // ...
    libspdm_zero_mem(&(secured_message_context->handshake_secret),
                     sizeof(libspdm_session_info_struct_handshake_secret_t));
    
    // ADD THIS LINE:
    // tla_trace_emit_complete_zeroization("responder", "sid", state_ptr, false, true);
    
    secured_message_context->requester_backup_valid = false;
    secured_message_context->responder_backup_valid = false;
}
```

### 3. EncodeSecuredMessage
**File**: `library/spdm_secured_message_lib/libspdm_secmes_encode_decode.c`  
**Function**: `libspdm_encode_secured_message` (line 63-200+)  
**Location**: Around lines 173-182 (sequence number increment)

**Instrumentation pattern**:
```c
// CAPTURE BEFORE:
uint64_t seq_num_before = secured_message_context->application_secret.request_data_sequence_number;

// Existing code:
if (is_request_message) {
    secured_message_context->application_secret.request_data_sequence_number++;
}

// CAPTURE AFTER AND EMIT:
// tla_trace_emit_encode_message("requester", "sid", state_ptr, 
//                               seq_num_before, seq_num_before + 1, 
//                               "key_0", iv, 12, cipher_text_size);
```

### 4. AttemptDecodeFirstEndian
**File**: `library/spdm_secured_message_lib/libspdm_secmes_encode_decode.c`  
**Function**: `libspdm_decode_secured_message` (decoding path)  
**Location**: Lines 487-521 (endianness determination block)

**Instrumentation**:
```c
if (!is_sequence_number_endian_determined(...) && (sequence_number == 1)) {
    // Capture endian_before
    uint8_t endian_before = secured_message_context->sequence_number_endian;
    
    if (result) {
        if (secured_message_context->sequence_number_endian == ...) {
            secured_message_context->sequence_number_endian = ...;
        }
    } else {
        // ... retry with opposite endian ...
        if (result) {
            secured_message_context->sequence_number_endian = swap_endian(...);
        }
    }
    
    // EMIT AFTER DETERMINATION:
    // tla_trace_emit_decode_first_endian("responder", "sid", state_ptr,
    //                                    response_seq_before, response_seq_after,
    //                                    endian_before, endian_after,
    //                                    1, result);
}
```

### 5. InitiateKeyUpdate
**File**: `library/spdm_secured_message_lib/libspdm_secmes_session.c`  
**Function**: `libspdm_create_update_session_data_key` (line 357-407)  
**Location**: After line 407 (backup_valid flag set)

**Instrumentation**:
```c
if (action == LIBSPDM_KEY_UPDATE_ACTION_REQUESTER) {
    // ... backup and key update logic ...
    secured_message_context->requester_backup_valid = true;
    
    // EMIT HERE:
    // tla_trace_emit_initiate_key_update("requester", "sid", state_ptr,
    //                                   PHASE_IDLE, PHASE_PENDING,
    //                                   true, "old_key", "new_key");
}
```

### 6. ConfirmKeyUpdate
**File**: `library/spdm_secured_message_lib/libspdm_secmes_encode_decode.c` (implicit)  
**Trigger**: After both sides use new key successfully

**Note**: ConfirmKeyUpdate is implicit in the real implementation. It happens when:
- Key update phase is PENDING
- A message is successfully processed with the new key
- Backup is cleared

This requires detecting the transition in `libspdm_activate_update_session_data_key` or after successful encode/decode with new key.

### 7. RollbackToBackupKey
**File**: `library/spdm_secured_message_lib/libspdm_secmes_session.c`  
**Function**: `libspdm_activate_update_session_data_key` (line 491-560)  
**Location**: When `use_new_key=false` and backup_valid is true (lines 499-530)

**Instrumentation**:
```c
if (!use_new_key) {
    if ((action == LIBSPDM_KEY_UPDATE_ACTION_REQUESTER) &&
        secured_message_context->requester_backup_valid) {
        // EMIT BEFORE ROLLBACK:
        // uint8_t old_phase = /* current key_update_phase */;
        // tla_trace_emit_rollback_backup_key("requester", "sid", state_ptr,
        //                                    old_phase, PHASE_IDLE,
        //                                    "new_key", "backup_key", true);
        
        // ... copy backup back ...
    }
}
```

## Adding Instrumentation: Step-by-Step

1. **Copy trace module to artifact**:
   ```bash
   cp harness/src/tla_trace.h artifact/libspdm/include/
   cp harness/src/tla_trace.c artifact/libspdm/library/spdm_secured_message_lib/
   ```

2. **Modify the 7 functions** listed above to add emit calls at the specified locations

3. **Update CMakeLists.txt** to compile tla_trace.c:
   - Add `library/spdm_secured_message_lib/tla_trace.c` to the source list

4. **Add include in instrumented files**:
   - Add `#include "tla_trace.h"` after the existing includes in each modified file

5. **Rebuild and test**:
   ```bash
   cd artifact/libspdm
   cmake -B build
   cmake --build build
   ```

## State Capture

When emitting trace events, capture the context state:
- `session_state`: current session state
- `request_seq_num`: request sequence number
- `response_seq_num`: response sequence number
- `sequence_number_endian`: current endian setting
- `endian_determined_at`: sequence number when endian was locked
- `key_update_phase`: key update phase (IDLE, PENDING, CONFIRMED, ROLLBACK)
- `backup_valid`: whether backup key is valid
- `application_secret`: symbolic ID of current key
- `application_secret_backup`: symbolic ID of backup key
- `secrets_cleared`: whether handshake secrets have been zeroized

## Key Challenges

1. **Session ID tracking**: The real system uses numeric session IDs. Map these to string IDs ("sid_1", "sid_2") consistently.

2. **Role determination**: Some functions don't know their role directly. Infer from context:
   - `libspdm_encode_secured_message(is_request_message=true)` → "requester"
   - `libspdm_encode_secured_message(is_request_message=false)` → "responder"

3. **Key identification**: Keys are binary blobs. Use version counters:
   - Initial key: `"key_0"`
   - After first update: `"key_v1"`
   - After rollback: `"key_0"` (reverted)

4. **Minimal state capture**: Not all functions have access to full context. Capture what's available; leave empty/zero for unavailable fields.

## Testing the Instrumentation

Run the test scenario and verify:
1. Trace file is created at expected path
2. Each line is valid JSON with `"tag": "trace"`
3. Event names match spec (transition_to_established, encode_message, etc.)
4. State fields are present and reasonable values
5. Timestamps are monotonically increasing

Example validation:
```bash
# Check trace file exists and has events
tail -5 traces/scenario_basic.ndjson
# Count events by type
grep "encode_message" traces/scenario_basic.ndjson | wc -l
```
