# libspdm-secured-message Trace Harness

This directory contains the instrumentation harness for collecting execution traces from the libspdm secured message implementation for TLA+ formal verification.

## Directory Structure

```
harness/
├── src/
│   ├── tla_trace.h                 # Trace emission library header
│   ├── tla_trace.c                 # Trace emission implementation
│   ├── tla_test_scenario.c         # Simple test scenario (optional)
│   └── ...                         # Additional test scenarios
├── patches/
│   └── instrumentation.patch       # Git patch with all instrumentation
├── apply.sh                        # Script to apply patches and prepare build
├── run.sh                          # Main script to build and collect traces
├── INSTRUMENTATION.md              # Detailed instrumentation guide
└── README.md                       # This file
```

## Quick Start

### 1. Prepare the Instrumentation

```bash
cd /home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/libspdm-secured-message

# Copy trace module to artifact
cp harness/src/tla_trace.h artifact/libspdm/include/
cp harness/src/tla_trace.c artifact/libspdm/library/spdm_secured_message_lib/

# Now manually apply the instrumentation points listed in harness/INSTRUMENTATION.md
# to the source files mentioned there
```

### 2. Build the Instrumented Library

```bash
cd artifact/libspdm

# Configure CMake
cmake -B build \
  -DARCH=x64 \
  -DTOOLCHAIN=GCC \
  -DCRYPTO=openssl \
  -DTARGET=Debug \
  -DENABLE_BINARY_BUILD=1 \
  -DCOMPILED_LIBCRYPTO_PATH=/usr/lib/x86_64-linux-gnu \
  -DCOMPILED_LIBSSL_PATH=/usr/lib/x86_64-linux-gnu

# Build
cmake --build build --parallel $(nproc)
```

### 3. Collect Traces

After instrumentation and build, run:

```bash
bash harness/run.sh
```

This will execute test scenarios and collect NDJSON trace files to `traces/` directory.

## Instrumentation Overview

The harness instruments 7 protocol actions as specified in `spec/instrumentation-spec.md`:

1. **TransitionToEstablished** - Session state transition to established
2. **CompleteZeroization** - Secret clearing after state transition
3. **EncodeSecuredMessage** - Message encryption with sequence number increment
4. **AttemptDecodeFirstEndian** - Endianness determination at first decode
5. **InitiateKeyUpdate** - Key update initiation with backup setup
6. **ConfirmKeyUpdate** - Key update confirmation (implicit)
7. **RollbackToBackupKey** - Rollback to backup key on failed decryption

Each action produces an NDJSON trace event with:
- Event name
- Role (requester/responder)
- Session ID
- Real timestamp (monotonic nanoseconds)
- Current state snapshot
- Action-specific message fields

## Trace Format

Example trace events:

```json
{"tag":"trace","event":"transition_to_established","role":"requester","session_id":"sid_0","timestamp":1000000000,"message":{"session_state_before":1,"session_state_after":2,"secrets_cleared_after":false}}
{"tag":"trace","event":"encode_message","role":"requester","session_id":"sid_0","timestamp":1000001000,"state":{"session_state":2,"request_seq_num":0},"message":{"sequence_number_before":0,"sequence_number_after":1,"key_used":"key_0","cipher_text_size":34}}
```

## Instrumentation Points

Detailed instrumentation locations and implementation instructions are in `INSTRUMENTATION.md`.

Key files to patch:
- `library/spdm_secured_message_lib/libspdm_secmes_context_data.c`
- `library/spdm_secured_message_lib/libspdm_secmes_encode_decode.c`
- `library/spdm_secured_message_lib/libspdm_secmes_session.c`

## Trace Module API

The trace emission library provides these functions:

```c
void tla_trace_init(const char *trace_file);
void tla_trace_emit_transition_to_established(const char *role, const char *session_id, ...);
void tla_trace_emit_complete_zeroization(const char *role, const char *session_id, ...);
void tla_trace_emit_encode_message(const char *role, const char *session_id, ...);
void tla_trace_emit_decode_first_endian(const char *role, const char *session_id, ...);
void tla_trace_emit_initiate_key_update(const char *role, const char *session_id, ...);
void tla_trace_emit_confirm_key_update(const char *role, const char *session_id, ...);
void tla_trace_emit_rollback_backup_key(const char *role, const char *session_id, ...);
void tla_trace_shutdown(void);
```

All functions are thread-safe (mutex-protected) and emit real timestamps.

## Building Without Full Test Suite

If the full CMake build with tests fails due to missing dependencies:

1. The trace module (tla_trace.c/h) can be compiled standalone
2. Individual test components can be built and linked separately
3. A minimal test harness can be created that doesn't require the full CMake setup

See the comments in `run.sh` for fallback approaches.

## Validating Traces

Once traces are collected, validate them against the spec:

```bash
# Using TLA+ trace validation tools
mcp__tla-trace-debugger__run_trace_validation \
  --spec-file spec/Trace.tla \
  --config-file spec/Trace.cfg \
  --trace-file traces/scenario_basic.ndjson \
  --work-dir spec/
```

## Next Steps After Instrumentation

1. **Patch source code** with the 7 instrumentation points from INSTRUMENTATION.md
2. **Update CMakeLists.txt** to include tla_trace.c in build
3. **Build and test** with `bash harness/run.sh`
4. **Validate traces** against Trace.tla spec
5. **Iterate** - if validation fails, adjust capture points per INSTRUMENTATION.md

## Troubleshooting

**Q: Trace file is empty or missing**
- Verify tla_trace_init() is called before any events
- Check that instrumented functions are actually executed by test scenarios
- Verify emit functions are called at correct code locations

**Q: Traces don't validate against spec**
- Check event names match exactly (case-sensitive)
- Verify state fields are present and have reasonable values
- Ensure timestamps are monotonically increasing
- Verify all required events are present in trace

**Q: Build fails due to missing dependencies**
- libspdm requires mbedtls or openssl - install libssl-dev
- cmocka library tests can be disabled by not calling add_subdirectory
- See CMakeLists.txt for build configuration options

## References

- `spec/instrumentation-spec.md` - Action-to-code mapping
- `spec/Trace.tla` - TLA+ trace specification
- `spec/base.tla` - Protocol specification
- `/home/ubuntu/Specula/.claude/skills/harness-generation/guide.md` - Harness generation methodology
