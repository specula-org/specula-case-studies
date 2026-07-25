# Instrumentation Spec: Autobahn BFT

Action-to-code mapping for trace harness generation. Each spec action maps to one or more source code locations where trace events must be emitted.

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "tag": "trace",
  "ts": "<monotonic_ns>",
  "event": {
    "name": "<spec_action_name>",
    "nid": "<server_id>",
    "state": {
      "slot": "<u64>",
      "view": "<u64>",
      "votedPrepare": "<u64>",
      "votedConfirm": "<u64>",
      "committed": "<value_string|nil>",
      "highQCView": "<u64>",
      "highQCValue": "<value_string|nil>",
      "highPropView": "<u64>",
      "highPropValue": "<value_string|nil>"
    },
    "msg": {
      "author": "<server_id>",
      "slot": "<u64>",
      "view": "<u64>",
      "value": "<value_string>"
    }
  }
}
```

### State Fields (captured at every event)

| Impl Field | TLA+ Variable | Getter |
|-----------|---------------|--------|
| `self.views[slot]` | `views[nid][slot]` | `core.rs` HashMap `self.views` keyed by slot |
| `self.last_voted_consensus` | `votedPrepare[nid][slot]` | `core.rs:1448` HashSet `(Slot, View)` — extract view for the given slot |
| (no impl field) | `votedConfirm[nid][slot]` | Not tracked in impl (Bug DA-6); trace must add shadow variable |
| `self.committed_slots[slot]` | `committed[nid][slot]` | `core.rs` committed slot value or nil |
| `self.high_qcs[slot].view` | `highQCView[nid][slot]` | `core.rs:1483` ConsensusMessage view from `self.high_qcs` |
| `self.high_qcs[slot].value` | `highQCValue[nid][slot]` | Value from the ConsensusMessage in `self.high_qcs` |
| `self.high_proposals[slot].view` | `highPropView[nid][slot]` | `core.rs:1452` ConsensusMessage view from `self.high_proposals` |
| `self.high_proposals[slot].value` | `highPropValue[nid][slot]` | Value from the ConsensusMessage in `self.high_proposals` |

### Message Fields (event-specific)

| Impl Field | TLA+ Field | Notes |
|-----------|-----------|-------|
| `message.author` | `msg.author` | Public key of sender, mapped to server ID |
| `message.slot` | `msg.slot` | Slot number |
| `message.view` | `msg.view` | View number |
| `message.proposal` (DAG tip) | `msg.value` | Abstracted to value string (e.g., "v1") |

## Section 2: Action-to-Code Mapping

### 2.1 SendPrepare

| Field | Value |
|-------|-------|
| **Spec action** | `SendPrepare` |
| **Code location** | `core.rs:993-1090` (`set_consensus_proposal`) |
| **Trigger point** | After Prepare message is constructed and broadcast (`core.rs:1055-1060`) |
| **Trace event name** | `SendPrepare` |
| **Fields** | state snapshot + msg (author=self, slot, view, value=proposal) |
| **Notes** | Only honest leaders call this. The proposal value is the DAG tip hash — must map to abstract "v1"/"v2" consistently within a run. |

### 2.2 ReceivePrepare

| Field | Value |
|-------|-------|
| **Spec action** | `ReceivePrepare` |
| **Code location** | `core.rs:1406-1466` (`process_prepare_message`) |
| **Trigger point** | After vote is recorded (`core.rs:1448` — `last_voted_consensus.insert`) and highProp updated (`core.rs:1452`) |
| **Trace event name** | `ReceivePrepare` |
| **Fields** | state snapshot (post-action) + msg (author=message.author, slot, view, value) |
| **Notes** | State snapshot MUST be post-action (after `last_voted_consensus.insert` and `high_proposals` update). The `msg.author` is the Prepare sender, NOT the receiver. Shadow variable for `votedConfirm` must also be captured. |

### 2.3 SendConfirm

| Field | Value |
|-------|-------|
| **Spec action** | `SendConfirm` |
| **Code location** | `core.rs` in `process_vote` → QCMaker aggregation → Confirm creation |
| **Trigger point** | After PrepareQC forms (2f+1 votes) and Confirm message is broadcast |
| **Trace event name** | `SendConfirm` |
| **Fields** | state snapshot + msg (slot, view, value=QC's proposal) |
| **Notes** | Trace at the point where the system decides to send Confirm (not fast commit). The value attached to Confirm is the one the leader chooses — Family 1 bug means QC doesn't bind to a specific value. |

### 2.4 ReceiveConfirm

| Field | Value |
|-------|-------|
| **Spec action** | `ReceiveConfirm` |
| **Code location** | `core.rs:1468-1496` (`process_confirm_message`) |
| **Trigger point** | After highQC update (`core.rs:1483`) |
| **Trace event name** | `ReceiveConfirm` |
| **Fields** | state snapshot (post-action) + msg (slot, view, value) |
| **Notes** | Bug DA-6: no duplicate guard. The shadow `votedConfirm` variable must be tracked by the harness itself (increment on each call). State snapshot must be post-action (after `self.high_qcs` update). |

### 2.5 SendCommit

| Field | Value |
|-------|-------|
| **Spec action** | `SendCommit` |
| **Code location** | `core.rs` in `process_vote` → QCMaker aggregation → Commit creation (slow path) |
| **Trigger point** | After ConfirmQC forms (2f+1 votes) and Commit message is broadcast |
| **Trace event name** | `SendCommit` |
| **Fields** | state snapshot + msg (slot, view, value=committed value) |
| **Notes** | Must distinguish from SendFastCommit. This is the slow path: QC formed from Confirm votes, not Prepare votes. |

### 2.6 SendFastCommit

| Field | Value |
|-------|-------|
| **Spec action** | `SendFastCommit` |
| **Code location** | `aggregators.rs:135-150` (fast path detection in QCMaker) |
| **Trigger point** | After PrepareQC with N=3f+1 votes detected and Commit message is broadcast |
| **Trace event name** | `SendFastCommit` |
| **Fields** | state snapshot + msg (slot, view, value=committed value) |
| **Notes** | Fast path: all N servers voted Prepare. The aggregator at `aggregators.rs:143` checks `voters.len() >= self.committee.quorum_threshold()` but with the full committee. Must emit a different event name than SendCommit to distinguish paths. |

### 2.7 ReceiveCommit

| Field | Value |
|-------|-------|
| **Spec action** | `ReceiveCommit` |
| **Code location** | `core.rs:1517-1588` (`process_commit_message`) |
| **Trigger point** | After commit is recorded (`core.rs:1545` — slot committed) |
| **Trace event name** | `ReceiveCommit` |
| **Fields** | state snapshot (post-action) + msg (slot, view, value) |
| **Notes** | Bug DA-14: no check for already-committed slot. The trace should capture the committed value in post-state. If slot was already committed, this will show overwrite. |

### 2.8 SendTimeout

| Field | Value |
|-------|-------|
| **Spec action** | `SendTimeout` |
| **Code location** | `core.rs:1705-1776` (`local_timeout_round`) |
| **Trigger point** | After Timeout message is constructed with highQC and highProp evidence (`core.rs:1743-1751`) |
| **Trace event name** | `SendTimeout` |
| **Fields** | state snapshot (slot, view, highQCView, highQCValue, highPropView, highPropValue) |
| **Notes** | No msg fields needed (timeout is about local state). The state snapshot must capture current slot and view BEFORE any view change. Bug DA-2: Timeout::digest() hashes nothing — irrelevant for tracing. |

### 2.9 AdvanceView

| Field | Value |
|-------|-------|
| **Spec action** | `AdvanceView` |
| **Code location** | `core.rs:1816-1825` (TC formation in `handle_timeout`) |
| **Trigger point** | After `views.insert(timeout.slot, timeout.view + 1)` at `core.rs:1820` |
| **Trace event name** | `AdvanceView` |
| **Fields** | state snapshot (post-action view) + `prevView` (the view that was advanced from) |
| **Notes** | State snapshot must be post-action (new view = v+1). The `prevView` field in the event is needed so the trace spec knows which timeout set to check. |

### 2.10 GeneratePrepareFromTC

| Field | Value |
|-------|-------|
| **Spec action** | `GeneratePrepareFromTC` |
| **Code location** | `core.rs:1856-1914` (`generate_prepare_from_tc`) |
| **Trigger point** | After winning proposal is selected and new Prepare is broadcast |
| **Trace event name** | `GeneratePrepareFromTC` |
| **Fields** | state snapshot + msg (slot, view, value=selected proposal) |
| **Notes** | Bug DA-5: winning_view = timeout.view (wrong). The trace captures what value the leader ACTUALLY selected, which is what the spec validates. |

### 2.11 EnterSlot

| Field | Value |
|-------|-------|
| **Spec action** | `EnterSlot` |
| **Code location** | `core.rs:1433-1440` (timer start in `process_prepare_message`) |
| **Trigger point** | When a server first processes a message for a slot it hasn't entered yet |
| **Trace event name** | `EnterSlot` |
| **Fields** | state snapshot (slot=entered slot, view=1) |
| **Notes** | EnterSlot is implicit in the implementation — it happens when the first Prepare for a new slot arrives and the server starts the timer. Emit when `self.views` first gets an entry for this slot. |

## Section 3: Special Considerations

### 3.1 Value Abstraction

The implementation uses DAG tip hashes as proposal values. For trace validation, these must be mapped to abstract values ("v1", "v2", etc.). Strategy:
- Assign abstract names in order of first encounter within a run
- Use a global mapping (e.g., `HashMap<Digest, String>`) initialized at harness start
- Ensure consistent mapping: same digest always maps to same abstract value

### 3.2 Server ID Mapping

Implementation uses public keys (`PublicKey`) as server identifiers. Map to "s1", "s2", "s3", "s4" in order of the committee configuration (sorted BTreeMap keys in `leader.rs:41`).

### 3.3 Shadow Variable: votedConfirm

The implementation does NOT track Confirm vote deduplication (Bug DA-6). The trace harness must add a shadow `HashMap<(Slot, View), bool>` that records whether this server has already voted Confirm for each (slot, view). Emit the last Confirm-voted view in the state snapshot as `votedConfirm`.

### 3.4 Byzantine Servers

Trace validation runs with `Byzantine = {}` (no Byzantine servers). Byzantine actions are not traced — they're only used in model checking. If a traced run includes Byzantine behavior, those events should be filtered out or the trace is invalid for validation.

### 3.5 Concurrent Slots

Autobahn runs up to K=4 concurrent slots. Each trace event must include the `slot` field. State snapshots are per-slot. The harness must capture state for the specific slot being acted upon, not a global snapshot.

### 3.6 Async Runtime

Autobahn uses Tokio async runtime. Events from different slots and different network handlers may interleave. The trace must be serialized (e.g., using a channel to a dedicated writer task) to ensure NDJSON lines appear in causal order. Use `core.rs` mutex (`self.store.write()`) boundaries as natural serialization points.

### 3.7 Vote Accumulation

Vote counting in the implementation happens inside `QCMaker` (aggregators.rs). Individual vote arrivals from other servers are processed inside `process_vote`. The trace harness should emit events for vote processing that the local node performs, but silent actions in the trace spec handle vote accumulation by non-observed servers.

### 3.8 Message Set vs Bag

The base spec uses a message SET (not bag). Messages with identical content are deduplicated. The implementation may process duplicate messages, but the spec's set semantics mean the trace should not emit duplicate identical events.
