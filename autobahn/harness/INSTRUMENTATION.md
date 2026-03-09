# Autobahn BFT Instrumentation Guide

Guide for adjusting instrumentation during trace validation (Phase 3).

## Architecture

Instrumentation uses a **copy-and-patch** approach:
- `harness/src/tla_trace.rs` → copied into `primary/src/tla_trace.rs`
- `harness/patches/core_instrumentation.patch` → applied to `primary/src/core.rs`
- `apply.sh` also patches `lib.rs` to register the module and fixes rocksdb build

## Trace Module (`tla_trace.rs`)

- **`try_init()`**: Checks `TLA_TRACE_FILE` env var, opens trace file if set
- **`is_active()`**: Returns true if tracing initialized
- **`nid(pk)`**: Maps PublicKey to "s1"/"s2"/etc. (assigned by first encounter order)
- **`abstract_value(digest)`**: Maps proposal digest to "v1"/"v2"/etc.
- **`emit_*()`**: One function per spec action (emit_send_prepare, emit_receive_prepare, etc.)
- **`make_state()`**: Creates a state snapshot JSON value
- Thread-safe via `OnceLock<Mutex<TraceWriter>>`

## Instrumentation Points in core.rs

| Location (after patch) | Event Name | Trigger Point |
|------------------------|-----------|---------------|
| `process_prepare_message`, after `last_voted_consensus.insert` | `ReceivePrepare` | After voting on Prepare |
| `process_confirm_message`, after `high_qcs.insert` | `ReceiveConfirm` | After voting on Confirm |
| `process_commit_message`, after `committed_slots.insert` | `ReceiveCommit` | After committing |
| `process_vote`, `qc_maker.try_fast == true` branch | `SendFastCommit` | After fast PrepareQC forms |
| `process_vote`, `qc_maker.try_fast == false` branch | `SendConfirm` | After slow PrepareQC forms |
| `process_vote`, Confirm QC formed | `SendCommit` | After ConfirmQC forms (via ride-share) |
| `send_consensus_req`, Prepare match | `SendPrepare` | Before broadcasting Prepare |
| `send_consensus_req`, Confirm match | `SendConfirm` | Before broadcasting Confirm (direct path) |
| `send_consensus_req`, Commit match | `SendCommit` | Before broadcasting Commit (direct path) |
| `local_timeout_round`, after Timeout created | `SendTimeout` | After timeout message created |
| `handle_timeout`, after `views.insert` | `AdvanceView` | After TC forms and view advances |
| `generate_prepare_from_tc`, after prepare created | `GeneratePrepareFromTC` | After TC-based proposal created |

## Shadow Variable: voted_confirm_shadow

Added field `voted_confirm_shadow: HashMap<Slot, View>` to Core struct. Updated in `process_confirm_message` after `high_qcs.insert`. This tracks Bug DA-6 (missing duplicate guard for Confirm votes).

## State Fields Captured

From Core internal state at each event:

| Field | Source |
|-------|--------|
| `slot` | Action parameter |
| `view` | `self.views.get(&slot)` |
| `votedPrepare` | `self.last_voted_consensus.contains(&(slot, view))` → view or 0 |
| `votedConfirm` | `self.voted_confirm_shadow.get(&slot)` |
| `committed` | `self.committed_slots.contains_key(&slot)` |
| `highQCView` | `self.high_qcs.get(&slot)` → view field |
| `highPropView` | `self.high_proposals.get(&slot)` → view field |

## Known Limitation: Value Tracking

The current instrumentation emits `"?"` for proposal values. This is because proposal values (DAG tip digests) are embedded deep in the `ConsensusMessage::Prepare { proposals: HashMap<PublicKey, Proposal> }` structure, and abstracting them to "v1"/"v2" requires tracking across the full consensus flow.

**To fix**: At each emit point, extract the proposal digest from the ConsensusMessage and call `tla_trace::abstract_value(&digest_bytes)`. The `abstract_value` function already handles the mapping.

## How to Add a New Field

1. Add the field to `tla_state()` helper method in `core.rs`
2. Add the field to `make_state()` in `tla_trace.rs`
3. Update `Trace.tla` `ValidatePostState` to check the new field
4. Rebuild: `cargo build -p primary`

## How to Add a New Event

1. Add an `emit_*` function to `tla_trace.rs` (copy pattern from existing)
2. Add `if tla_trace::is_active() { ... }` block at the trigger point in `core.rs`
3. Add a corresponding `*IfLogged` action wrapper to `Trace.tla`
4. Add the wrapper to `TraceNext` disjunction

## How to Move a Capture Point

Move the `if tla_trace::is_active() { ... }` block to the new location in `core.rs`. If moving from before→after an operation, the state snapshot will change — ensure `Trace.tla` validates the correct (pre or post) state.

## Rebuild and Re-run

```bash
# Apply instrumentation (if not already applied)
bash harness/apply.sh

# Build
cd artifact/autobahn-artifact && cargo build -p primary

# Run with tracing
TLA_TRACE_FILE=../../traces/trace.ndjson cargo test -p primary -- --nocapture
```

Or use the all-in-one script:
```bash
bash harness/run.sh
```

## Generating Traces from Multi-Node Cluster

The existing unit tests only exercise single-node message processing. For a full consensus trace, run a local 4-node cluster:

1. Generate keys and committee config (use `node generate_keys`)
2. Start 4 primary nodes with `TLA_TRACE_FILE` set
3. Send transactions via the benchmark client
4. Collect trace files from each node
5. Use one node's trace for validation (Trace.tla handles non-observed servers via silent actions)
