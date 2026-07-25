# MongoDB Session Catalog - Trace Harness (Phase 2.5)

This directory contains the trace harness for MongoDB session catalog verification via TLA+ model checking and trace validation.

## Directory Structure

```
harness/
├── src/
│   ├── tla_trace.h              # Trace emitter library (header)
│   ├── tla_trace.cpp            # Trace emitter implementation
│   ├── test_harness.cpp         # Test scenarios that generate traces
│   └── CMakeLists.txt           # CMake build configuration
├── run.sh                       # Master build and trace collection script
├── INSTRUMENTATION.md           # Guide for integrating real instrumentation
├── README.md                    # This file
└── build/                       # Build artifacts (generated)
```

## Quick Start

Build and generate traces in one command:

```bash
cd harness
bash run.sh
```

This will:
1. Build the C++ trace emission library and test harness
2. Run 5 test scenarios covering different protocol paths
3. Validate trace JSON format
4. Output traces to `../traces/`

## Output

Generated traces are saved to:

```
../traces/scenario_1.ndjson    # Basic checkout/release
../traces/scenario_2.ndjson    # Kill workflow
../traces/scenario_3.ndjson    # Parent-child reaping
../traces/scenario_4.ndjson    # Concurrent sessions
../traces/scenario_5.ndjson    # Complex interleaving
```

Each trace is valid NDJSON (one JSON object per line) with events matching the TLA+ spec.

## Event Types

Trace events correspond to TLA+ spec actions:

| Event | Scenario | Purpose |
|-------|----------|---------|
| `CheckOutSession` | All | Session checkout for operation or kill |
| `Kill` | 2, 4, 5 | Kill a checked-out session |
| `ReleaseSession` | All | Release a checked-out session |
| `CreateChildSession` | 3 | Create a child transaction session |
| `ScanSessionsForReap` | 3 | Begin scanning sessions for reaping |
| `FinishReap` | 3 | Complete reap scan |

## Integration with Real MongoDB

This harness uses simulated trace generation (test scenarios) to produce representative traces quickly. To integrate real instrumentation:

1. Read `INSTRUMENTATION.md` for step-by-step instructions
2. Modify MongoDB source code at the instrumentation points listed
3. Add trace emit calls to key functions in `session_catalog.cpp`
4. Rebuild MongoDB and re-run its integration tests with the trace emitter enabled
5. Validate generated traces against `../spec/Trace.tla`

## Trace Format

Each event is a JSON object with the following structure:

```json
{
  "event": "<event_name>",
  "timestamp": <nanoseconds_since_epoch>,
  "sessionId": "<session_id>",
  "state": {
    "sessionState": "<AVAILABLE|CHECKED_OUT|KILLING|KILLED>",
    "killsRequested": <count>,
    "markedForReap": <boolean>,
    "reapMode": "<EXCLUSIVE|NONEXCLUSIVE>",
    "checkoutOpCtx": "<opCtx_id_or_NULL>",
    "cacheState": "<state>"
  },
  /* Event-specific fields (e.g., forKill, marked_for_reap, etc.) */
}
```

## Testing

To test trace generation without modification:

```bash
# Build only
cd harness
cd build && cmake ../src && make

# Run specific scenario
./test_harness ../traces/test.ndjson 1

# Run all scenarios
./test_harness ../traces/test.ndjson all
```

## Validation Against Spec

After generating or collecting traces, validate them with the TLA+ spec:

```bash
cd spec
java -Xmx4g -cp /path/to/tlatools/tla2tools.jar tlc.TLC \
    -config Trace.cfg \
    -tool \
    Trace.tla
```

Or use the validation-workflow skill:

```bash
/validation-workflow \
    --spec spec/Trace.tla \
    --config spec/Trace.cfg \
    --trace traces/scenario_1.ndjson
```

## Troubleshooting

### Build Fails

- Ensure `cmake` (3.10+) and `g++` (C++17) are available
- Check that `nlohmann/json` is installed: `apt-get install nlohmann-json3-dev`

### Trace Validation Fails

- Verify event names match spec exactly (case-sensitive)
- Check timestamps are monotonically increasing (real time, not synthetic)
- Ensure state fields (sessionState, killsRequested, etc.) are consistent with implementation behavior

### Missing Events in Traces

- Increase test scenario complexity
- Add scenarios that exercise code paths not covered by existing tests
- See `test_harness.cpp` for examples of how to add new scenarios

## Next Steps

1. **Phase 3 Trace Validation**: Run validation-workflow skill to check traces against Trace.tla
2. **Real Instrumentation**: Follow INSTRUMENTATION.md to integrate with actual MongoDB code
3. **Iteration**: Fix instrumentation issues discovered during trace validation

## References

- **Instrumentation Spec**: `../spec/instrumentation-spec.md`
- **Trace Spec**: `../spec/Trace.tla`
- **Base Spec**: `../spec/base.tla`
- **Phase 2.5 Guide**: `../../.claude/skills/harness-generation/guide.md`
