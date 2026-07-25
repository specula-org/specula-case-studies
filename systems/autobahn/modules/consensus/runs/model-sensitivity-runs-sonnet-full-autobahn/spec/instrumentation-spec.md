# Instrumentation Spec — Autobahn BFT

Maps each TLA+ spec action to the source code location where the harness should emit a trace event.

---

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "event": "<action_name>",
  "node":  "<node_id>",
  "slot":  <int|null>,
  "view":  <int|null>,
  "round": <int|null>,
  "proposals":   "<string>|null",
  "voters":      ["<node_id>", ...] | null,
  "highQCView":  <int|null>,
  "winProposals": "<string>|null",
  "parentRound": <int|null>,
  "state": {
    "nodeView":     <int>,
    "prepareVoted": <bool>,
    "confirmVoted": <bool>,
    "committed":    "<string>|null",
    "hsVotedRound": <int>,
    "hsVoteCount":  <int>
  }
}
```

### State Fields (captured at every event)

| JSON field | TLA+ variable | Rust accessor |
|---|---|---|
| `state.nodeView` | `nodeView[n, s]` | `self.views.get(&slot).copied().unwrap_or(0)` |
| `state.prepareVoted` | `prepareVoted[n, s, v]` | `self.last_voted_consensus.contains(&(slot, view))` |
| `state.confirmVoted` | `confirmVoted[n, s, v]` | *(no direct guard; always false until F3 fix)* |
| `state.committed` | `committed[s]` | `self.committed_slots.get(&slot)` |
| `state.hsVotedRound` | `hsVotedRound[n]` | `self.last_voted_round` *(hotstuff)* |
| `state.hsVoteCount` | `hsVoteCount[n, r]` | ghost counter; increment on each vote |

### Message Fields (event-specific)

| JSON field | TLA+ field | Notes |
|---|---|---|
| `proposals` | `proposalContent[s, v]` | Abstract hash of DAG header proposals set |
| `voters` | `prepareQC[s,v]` / `confirmQC[s,v]` | Node IDs from QC.signers |
| `highQCView` | `timeoutHighQC[n,s,v]` | View of high_qc embedded in Timeout; null if absent |
| `winProposals` | `tcFormed[s, v]` | Winning proposals from TC::get_winning_proposals |
| `parentRound` | `hsParentRound[r]` | Parent round in HotStuff block |

---

## Section 2: Action-to-Code Mapping

### `SendPrepare`
- **Code**: `primary/src/core.rs` — leader broadcast in `process_new_dag_header` or wherever the Prepare message is constructed and sent
- **Trigger**: after `ConsensusMessage { msg_type: MsgType::Prepare, ... }` is pushed to the send queue
- **Event name**: `"SendPrepare"`
- **Fields**: `node`, `slot`, `view`, `proposals` (hash of `self.proposals`)
- **Notes**: `proposals` should be a stable hash of the proposals map (e.g. SHA256 of sorted keys); must be consistent across nodes for the same content.

### `CastPrepareVote`
- **Code**: `primary/src/core.rs:1448` — inside `process_prepare_message`, after `self.last_voted_consensus.insert((slot, view))` and before the vote is sent
- **Trigger**: after `last_voted_consensus.insert(...)` (post-vote state)
- **Event name**: `"CastPrepareVote"`
- **Fields**: `node`, `slot`, `view`, `state.prepareVoted` (= TRUE after insert), `state.nodeView`
- **Notes**: F1 — the `voteDigest` is `(slot, view)` only; proposals are excluded. The harness confirms this by noting the vote has no proposal hash.

### `FormPrepareQC`
- **Code**: `primary/src/messages.rs` — in the QC aggregation path, after 2f+1 PrepareVote signatures collected
- **Trigger**: after QC is formed (after threshold is reached in the aggregator)
- **Event name**: `"FormPrepareQC"`
- **Fields**: `slot`, `view`, `voters` (list of signer node IDs), `proposals` (QC's claimed proposals)
- **Notes**: F1 — if Byzantine leader equivocated, `voters` may have voted for different proposals. Capture the proposals field from the QC record itself.

### `SendConfirm`
- **Code**: `primary/src/core.rs` — after `process_prepare_qc` receives a valid PrepareQC and leader constructs Confirm message
- **Trigger**: after Confirm message is pushed to send queue
- **Event name**: `"SendConfirm"`
- **Fields**: `node`, `slot`, `view`

### `CastConfirmVote`
- **Code**: `primary/src/core.rs:1167-1183` — inside `is_valid` for Confirm branch, or in `process_confirm_message` after the validity check passes
- **Trigger**: after ConfirmVote message is constructed (post-state)
- **Event name**: `"CastConfirmVote"`
- **Fields**: `node`, `slot`, `view`, `state.confirmVoted` (= TRUE)
- **Notes**: F3 — there is NO equivocation guard here. The harness should capture this event every time a ConfirmVote is emitted, even if it's a duplicate for the same (slot, view). `state.confirmVoted` should be a ghost counter (incremented each call) to detect double-voting.

### `FormConfirmQC`
- **Code**: `primary/src/messages.rs` — ConfirmQC aggregation, after 2f+1 ConfirmVote signatures collected
- **Trigger**: after ConfirmQC formed
- **Event name**: `"FormConfirmQC"`
- **Fields**: `slot`, `view`, `voters`

### `SendCommit`
- **Code**: `primary/src/core.rs` — leader sends Commit after receiving ConfirmQC
- **Trigger**: after Commit message pushed to send queue
- **Event name**: `"SendCommit"`
- **Fields**: `node`, `slot`, `view`

### `ProcessCommit`
- **Code**: `primary/src/core.rs` — in `process_commit_message`, after `self.committed_slots.insert(slot, proposals)`
- **Trigger**: after commit recorded (post-state)
- **Event name**: `"ProcessCommit"`
- **Fields**: `node`, `slot`, `view`, `state.committed` (proposals hash)

### `CleanSlotPeriods`
- **Code**: `primary/src/core.rs:1612-1617` — `clean_slot_periods` function, after the retain call
- **Trigger**: after `self.consensus_instances.retain(...)` returns
- **Event name**: `"CleanSlotPeriods"`
- **Fields**: `slot` (the committed slot that triggered GC)
- **Notes**: F5 — emit AFTER the retain call so the post-state reflects the buggy removal.

### `SendTimeout`
- **Code**: `primary/src/core.rs` — timeout handler, after Timeout message constructed
- **Trigger**: after Timeout message pushed to send queue
- **Event name**: `"SendTimeout"`
- **Fields**: `node`, `slot`, `view`, `highQCView` (view of `high_qc` field, null if absent)
- **Notes**: F2 — the Timeout digest is empty (messages.rs:1349-1358); capture all fields to show they're not bound by the signature.

### `ByzSendTimeout`
- **Code**: Inject in test harness / adversary stub — not an honest code path
- **Trigger**: when adversary sends a crafted Timeout with arbitrary high_qc
- **Event name**: `"ByzSendTimeout"`
- **Fields**: `node`, `slot`, `view`, `highQCView` (the forged high_qc view)

### `FormTC`
- **Code**: `primary/src/messages.rs:1518-1546` — `TC::verify` / TC aggregation, after f+1 Timeouts collected
- **Trigger**: after TC is formed and `get_winning_proposals` returns
- **Event name**: `"FormTC"`
- **Fields**: `slot`, `view`, `winProposals` (result of `get_winning_proposals`)
- **Notes**: F2 — capture `winProposals` to verify against `ViewChangeSafety`. The buggy `winning_view` variable causes a non-deterministic winner selection.

### `ProcessTC`
- **Code**: `primary/src/core.rs` — after TC received, node advances view
- **Trigger**: after `self.views.insert(slot, new_view)`
- **Event name**: `"ProcessTC"`
- **Fields**: `node`, `slot`, `view` (new view after TC), `state.nodeView`

### `HSMakeVote`
- **Code**: `hotstuff/src/core.rs` — `make_vote` function, after `self.last_voted_round = round`
- **Trigger**: after in-memory voted round updated
- **Event name**: `"HSMakeVote"`
- **Fields**: `node`, `round`, `state.hsVotedRound` (= round), `state.hsVoteCount` (ghost counter)
- **Notes**: F4 — the state update is in-memory only; no disk write. Capture BEFORE any async context switch.

### `HSProcessBlock`
- **Code**: `hotstuff/src/core.rs:327` — `process_block`, after the commit condition check
- **Trigger**: after `if b0.round + 1 == b1.round { self.commit(b0).await?; }` executes
- **Event name**: `"HSProcessBlock"`
- **Fields**: `node`, `round` (current block round = r2), `parentRound` (r1)
- **Notes**: F4 — capture b0.round committed (if commit fired) as a separate event or include in state.

### `HSCrashRecover`
- **Code**: Test harness — restart the HotStuff node process/task
- **Trigger**: at node startup / recovery, before any vote is cast
- **Event name**: `"HSCrashRecover"`
- **Fields**: `node`, `state.hsVotedRound` (= 0 after reset, showing non-persistence)
- **Notes**: F4 — the reset to 0 is the observable effect of the non-persistence bug.

---

## Section 3: Special Considerations

### Proposal Hashing
`proposals` in the spec is abstract (`P1`, `P2`). In the harness, use a stable hash of the `proposals` map (e.g., sorted certificate IDs joined and hashed). The same content must map to the same abstract value across all nodes.

### Confirm Equivocation (F3)
The current implementation has no `confirmVoted` field. For trace validation of F3, add a ghost counter in the harness: a `HashMap<(Slot, View), u32>` that increments each time a ConfirmVote is emitted by the node. Emit this counter as `state.hsVoteCount` (repurposed for Confirm). Add a separate field `state.confirmCount` if both HotStuff and Autobahn traces are needed simultaneously.

### HotStuff / Autobahn Interleaving
The two consensus protocols are in separate crates. The trace log should include events from both, identifiable by event name prefix (`"HS*"` for HotStuff, others for Autobahn). The trace spec's `TraceNext` disjunction handles both.

### Node ID Mapping
Rust code uses peer IDs (public key hashes). The harness should maintain a stable `HashMap<PeerId, NodeId>` mapping to short names (`n1`, `n2`, …). This mapping must be consistent across the test run.

### Async Boundaries
All instrumentation points in Autobahn are inside `async fn` handlers. Capture state immediately before or after the key state mutation (not across an `await` point) to ensure the snapshot is coherent with the action boundary.

### `process_consensus_request` pre-insert (CR1)
`primary/src/core.rs:1302-1315` inserts into `consensus_instances` before calling `is_valid`. If tracing `ProcessConsensusRequest`, capture state AFTER `is_valid` returns (not after insert) to avoid capturing corrupt state from invalid messages.
