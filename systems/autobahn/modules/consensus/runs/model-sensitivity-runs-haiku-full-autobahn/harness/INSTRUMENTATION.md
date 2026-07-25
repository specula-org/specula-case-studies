# Autobahn BFT Instrumentation Guide

This guide describes how the Autobahn BFT consensus implementation has been instrumented to emit TLA+ trace events for formal verification.

## System Overview

**Autobahn** is a DAG-based Byzantine Fault Tolerant consensus protocol that combines Narwhal (data availability) with a HotStuff-style 3-phase BFT layer. The instrumentation maps Autobahn's message-handling operations to HotStuff-style spec actions.

## Trace Module Location

- **File**: `primary/src/tla_trace.rs`
- **Type**: Rust module providing NDJSON trace emission
- **Pattern**: Mutex-protected global trace writer (Category A: distributed system)

## Instrumentation Points

### 1. Voting Safety (CheckVoteSafety → SendVote)

**Code Location**: `primary/src/core.rs`

**Operation**: When a node receives a valid proposal, it votes by:
1. Checking safety against persistent storage
2. Persisting the voted round
3. Broadcasting vote message

**Trace Events**:
- `CheckVoteSafety`: Validates that round > persistentLastVotedRound
- `PersistVoteRound`: Writes voted round to durable storage
- `SendVote`: Broadcasts vote message to all nodes

**Implementation Notes**:
- The spec models voting as three separate atomic actions to capture non-atomic windows
- `persistentLastVotedRound` is stored in RocksDB (store/src/lib.rs)
- `lastVotedRound` is in-memory in Core struct

### 2. QC Processing and Round Advance

**Code Location**: `primary/src/core.rs` (handle_proposal method)

**Operation**: After receiving enough votes, leader processes QC and advances round

**Trace Events**:
- `ProcessQCFromProposal`: Marks QC processing started
- `AdvanceRoundFromQC`: Pending round advance (before atomic commit)
- `CommitRoundAdvance`: Commits round advance to state

**Implementation Notes**:
- `qcProcessing` shadow field tracks whether QC is in-flight
- `pendingRoundAdvance` tracks the target round before commit
- These shadow fields are not in the actual Autobahn code but are modeled in the spec

### 3. Timeout and TC Handling

**Code Location**: `primary/src/aggregators.rs` (TCMaker)

**Operation**: When timeout quorum (f+1) is reached, new round is triggered

**Trace Events**:
- `AddTimeoutToTC`: Each timeout is added to TC aggregator
- `AdvanceRoundViaTC`: TC round advance commits to state

**Implementation Notes**:
- `tcRound` tracks which round's TC is being assembled
- `tcSignatures` is a set of nodes that sent timeouts for this round

### 4. Proposal Generation

**Code Location**: `primary/src/proposer.rs`

**Operation**: Leader generates a new proposal (called from vote/timeout/TC handlers)

**Trace Events**:
- `GenerateProposal`: Proposal message generated and sent

**Implementation Notes**:
- `proposedRounds` shadows which rounds this leader has proposed
- Idempotency: second call for same round should be no-op
- Three call sites: handle_vote, handle_timeout, handle_tc

### 5. Crash and Recovery

**Code Location**: `primary/src/core.rs` (initialization and error handling)

**Operation**: Node crashes (loss of in-memory state) and recovers (reload from disk)

**Trace Events**:
- `Crash`: Node marked crashed, in-memory state lost
- `Recover`: Node recovers, persistent state reloaded

**Implementation Notes**:
- Crash is modeled as signal delivery or panic
- Recovery reads `persistentLastVotedRound` from store
- After recovery: `lastVotedRound` = `persistentLastVotedRound` (restore from disk)

## State Capture Mapping

When emitting trace events, capture these state variables:

| Spec Variable | Implementation | Capture Point |
|---------------|----------------|---|
| `round` | Core::round (Slot in Autobahn) | After round commit |
| `lastVotedRound` | Core in-memory or in vote context | During voting |
| `persistentLastVotedRound` | Store (RocksDB) | After write_last_voted() |
| `highQC` | Core::high_qcs map | In QC processing |
| `qcProcessing` | Shadow field (not in code) | Set/cleared around process_qc() |
| `pendingRoundAdvance` | Shadow field (not in code) | During advance_round() |
| `tcRound` | Core::tc_makers map | In timeout handling |
| `crashed` | Shadow field (test-only) | On crash/recovery |

## Adding New Events

To add instrumentation for a new event:

1. **Define event structure** in `tla_trace.rs`:
   ```rust
   pub fn emit_my_event(node: String, state: Value, msg: Option<Value>) {
       emit_event("MyEvent", node, state, msg);
   }
   ```

2. **Call from implementation**:
   ```rust
   // In primary/src/core.rs or other module
   tla_trace::emit_my_event("s1".to_string(), state_snapshot, None);
   ```

3. **Update Trace.tla**:
   - Add event handler in Trace.tla: `MatchMyEvent`
   - Add validation in `ValidatePostState`

4. **Add to instrumentation spec**:
   - Document action-to-code mapping
   - List fields to capture

## Rebuilding After Changes

```bash
# Apply instrumentation
bash harness/apply.sh

# Build with instrumentation
cd artifact/autobahn/primary
cargo build

# Run tests to generate traces
timeout 120 cargo test --lib -- --nocapture

# Collect traces
ls traces/*.ndjson
```

## Known Limitations

1. **DAG vs HotStuff**: Autobahn is DAG-based (Narwhal layer) but spec is HotStuff-style. Mapping is approximate at consensus layer.

2. **Shadow Fields**: Variables like `qcProcessing`, `pendingRoundAdvance` are not directly in Autobahn code but are modeled in spec. Instrumentation uses implicit tracking.

3. **Async Operations**: Message handlers run in tokio tasks. Trace timestamps may not perfectly capture causal ordering in high-concurrency scenarios.

4. **Test-Only**: Crash/Recovery instrumentation is primarily for test scenarios, not production code paths.

## Troubleshooting Trace Validation

If trace validation fails in Phase 3:

1. **"Event not found"**: Check event name matches exactly (case-sensitive)
2. **"State field missing"**: Ensure captured state has all required fields from `instrumentation-spec.md`
3. **"Field type mismatch"**: Verify numeric types (round should be u64, not string)
4. **"Impossible post-state"**: Check that action preconditions match spec (e.g., CheckVoteSafety requires round > persistentLastVotedRound)

For detailed debugging, check the trace file format with:
```bash
head traces/*.ndjson | jq .
```

## References

- Base spec: `spec/base.tla`
- Trace spec: `spec/Trace.tla`
- Instrumentation spec: `spec/instrumentation-spec.md`
- Source code: `artifact/autobahn/primary/src/`
