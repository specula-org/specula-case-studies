# SPDM Chunking Trace Harness

Trace collection harness for libspdm chunking protocol (responder-side).

## Structure

```
harness/
├── README.md                    # This file
├── INSTRUMENTATION.md           # Modification guide for Phase 3
├── CMakeLists.txt              # Build configuration
├── apply.sh                    # Apply instrumentation and collect traces
├── clean.sh                    # Revert instrumentation
└── src/
    ├── tla_trace.h             # Trace module header
    ├── tla_trace.c             # Trace module implementation
    └── test_chunking.c         # Test scenarios
```

## Quick Start

### Generate Traces

```bash
cd /home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/libspdm-chunking
bash harness/apply.sh
```

Output: `traces/trace.ndjson` (NDJSON format, one event per line)

### Clean Up

```bash
bash harness/clean.sh
```

## Trace Events

The harness generates four types of trace events:

### 1. ChunkSendInit
- **When**: Initiates a new chunked transfer
- **Fields**: message size, capacity, first chunk size, state snapshot
- **Count in trace**: 4

### 2. ChunkSendContinuation
- **When**: Processes continuation chunk
- **Fields**: sequence number, bytes transferred, chunk size, state snapshot
- **Count in trace**: 3

### 3. ReceiveInterruption
- **When**: Non-chunk command received during transfer (interrupts chunking)
- **Fields**: command type, state before clear
- **Count in trace**: 1

### 4. ErrorDuringReassembly
- **When**: Error during reassembly, state cleared
- **Fields**: state after error and cleanup
- **Count in trace**: 1

**Total Events**: 9

## Event Coverage

- **ChunkSendInit**: ✓ (4 events)
- **ChunkSendContinuation**: ✓ (3 events)
- **ReceiveInterruption**: ✓ (1 event)
- **ErrorDuringReassembly**: ✓ (1 event)

All specification actions are covered by at least one trace event.

## Test Scenarios

The test harness includes four scenarios:

1. **Two-Chunk Transfer** (normal case)
   - Initiates chunking with first chunk
   - Completes with second (final) chunk
   - Events: ChunkSendInit, ChunkSendContinuation

2. **Interruption During Transfer**
   - Starts chunking transfer
   - Interrupts with non-chunk command (e.g., GET_VERSION)
   - Events: ChunkSendInit, ReceiveInterruption

3. **Error During Reassembly**
   - Initiates chunking
   - Simulates error condition
   - Events: ChunkSendInit, ErrorDuringReassembly

4. **Three-Chunk Transfer** (extended case)
   - Multiple continuation chunks
   - Events: ChunkSendInit, ChunkSendContinuation (×2)

## Trace Format

Each line is a JSON object following NDJSON format:

```json
{
  "eventName": "ChunkSendInit",
  "timestamp": "2026-06-04T10:43:04.027Z",
  "nodeId": "responder",
  "state": {
    "chunk_context": { "send": true, "get": false, "seq_no": 0, "bytes_transferred": 0 },
    "large_message_size": 512,
    "large_message_capacity": 1024,
    "large_message_valid": true,
    "chunk_phase": "INIT",
    "seq_no_wrap_error": true
  },
  "message": { "chunk_size": 256 }
}
```

**Key Fields**:
- `eventName`: Action name from spec (must match Trace.tla)
- `timestamp`: Real ISO 8601 timestamp
- `nodeId`: "responder" (single node)
- `state`: All TLA+ variables from base spec
- `message`: Message-specific fields (empty if none)

## Instrumentation Points

The following source files have been instrumented:

1. **libspdm_rsp_chunk_send_ack.c**
   - Line ~158: ChunkSendInit trace
   - Line ~210: ChunkSendContinuation trace
   - Line ~260: ErrorDuringReassembly trace

2. **libspdm_rsp_receive_send.c**
   - Line ~582: ReceiveInterruption trace

See `INSTRUMENTATION.md` for detailed modification guide.

## Modifying Instrumentation

To adjust instrumentation during Phase 3 (trace validation):

1. **Edit source files** in `artifact/libspdm/library/spdm_responder_lib/`
2. **Update trace calls** or add new fields as needed
3. **Rebuild**: `bash harness/apply.sh`
4. **Verify**: Check `traces/trace.ndjson` for new format

See `INSTRUMENTATION.md` for detailed instructions on adding fields, moving capture points, or adding new event types.

## Debugging

### View trace content:
```bash
cat traces/trace.ndjson | jq . | head -50
```

### Count events:
```bash
jq -r '.eventName' traces/trace.ndjson | sort | uniq -c
```

### Validate JSON:
```bash
cat traces/trace.ndjson | jq . > /dev/null && echo "Valid JSON"
```

## Next Steps

Pass `traces/trace.ndjson` to Phase 3 (Trace Validation workflow) for validation against the TLA+ spec.

See `../spec/Trace.tla` for the validator spec and expected event structure.
