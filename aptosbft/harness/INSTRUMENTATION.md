# Aptos BFT (Jolteon) Instrumentation Guide

Guide for adjusting instrumentation during trace validation (Phase 3).

## Architecture

Instrumentation uses a **copy-and-patch** approach:
- `harness/src/tla_trace.rs` → copied into `consensus/src/tla_trace.rs`
- `harness/src/tla_trace_scenario.rs` → copied into `consensus/src/round_manager_tests/tla_trace_scenario.rs`
- `apply.sh` patches `lib.rs` and `round_manager_tests/mod.rs` to register the modules

## Trace Module (`tla_trace.rs`)

- **`init(path, server_map)`**: Opens trace file and sets up PeerId → TLA+ name mapping
- **`emit_event(name, nid, round, epoch, state, msg)`**: Writes one NDJSON line
- **`nid(author_hex)`**: Maps hex PeerId to "s1"/"s2"/etc.
- **`is_active()`**: Returns true if tracing initialized
- Thread-safe via `OnceLock<Mutex<TraceWriter>>`
- Activated by calling `init()` in test setup (not env var)

## Instrumentation Points

All emit calls are in `tla_trace_scenario.rs` (the test scenario), not in the production source. The test intercepts RoundManager events via the existing test harness (`RoundManagerTest`) and emits trace events from the test code.

| Emit Site (line) | Event Name | Description |
|-----------------|-----------|-------------|
| 94 | `Propose` | After proposal generated |
| 115 | `ReceiveProposal` | After proposal processed by node |
| 132 | `CastVote` | After node casts a vote |
| 152 | `ReceiveVote` | After vote processed, QC may form |
| 185 | `FormQC` | After quorum certificate formed |
| 202 | `ReceiveQC` | After node processes a QC |
| 234 | `Commit` | After block ordered/committed |
| 270 | `Timeout` | After timeout processed |

## State Fields Captured

From `safety_data` and `block_store` at each event:

| Field | Source |
|-------|--------|
| `lastVotedRound` | `persistent_storage.safety_data().last_voted_round` |
| `preferredRound` | `persistent_storage.safety_data().preferred_round` |
| `oneChainRound` | `persistent_storage.safety_data().one_chain_round` |
| `highestTimeoutRound` | `persistent_storage.safety_data().highest_timeout_round` |
| `currentRound` | `round_state.current_round()` |
| `highestQCRound` | `sync_info().highest_quorum_cert().certified_block().round()` |
| `highestOrderedRound` | `sync_info().highest_ordered_round()` |
| `committedRound` | `block_store.commit_root().round()` |

## How to Add a New Field

1. Add the field to the `state` JSON object in the `emit_event()` call in `tla_trace_scenario.rs`
2. Access the value through the test harness's `RoundManagerTest` API
3. Rebuild: `cd artifact/aptos-core && cargo test -p aptos-consensus --no-run`

## How to Add a New Event

1. Find where the event occurs in the test scenario flow
2. Add a `tla_trace::emit_event(...)` call with appropriate state capture
3. The test harness provides `node.round_manager` access for state queries

## How to Move a Capture Point

Since all instrumentation is in the test scenario (not production code), moving a capture point means reordering the `emit_event()` call relative to the test's action sequence. The state snapshot reflects the test harness state at the time of the call.

## Rebuild and Re-run

```bash
# Apply instrumentation (if not already applied)
bash harness/apply.sh

# Run trace test
cd artifact/aptos-core
TLA_TRACE_FILE=../../traces/trace.ndjson \
cargo test -p aptos-consensus -- tla_trace_basic_consensus --nocapture --test-threads=1
```

Or use the all-in-one script:
```bash
bash harness/run.sh
```

## Known Limitations

- **Test-side instrumentation**: Emit calls are in the test scenario, not in the production `round_manager.rs`. This means only code paths exercised by the test are traced.
- **Single test scenario**: Only `tla_trace_basic_consensus` exists. More scenarios needed for round change, timeout, and multi-epoch coverage.
- **State access**: Some fields require reaching into internal structures through the test harness API, which may break on upstream updates.
