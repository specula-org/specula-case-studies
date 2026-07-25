# Instrumentation Specification: Autobahn BFT Consensus

Mapping from TLA+ spec actions to source code locations for trace generation.

---

## Section 1: Trace Event Schema

### Event Envelope (All Events)

Every event in the trace (NDJSON format) must include:

```json
{
  "event": "<action_name>",
  "node": <node_id>,
  "round": <current_round>,
  "timestamp": <nanoseconds>,
  "state": <state_snapshot>
}
```

### State Snapshot Fields (Captured at Every Event)

Spec variable → Implementation source:

| Spec Variable | Implementation | Access Point |
|---------------|----------------|--------------|
| `round` | `core.rs` line 42: `self.round` | Core::round() getter |
| `lastVotedRound` | `core.rs` line 99: `self.last_voted_round` (in-memory) | Core::last_voted_round() getter |
| `persistentLastVotedRound` | `store/lib.rs` line 65: persisted value | Store::read_last_voted() |
| `highQC.round` | `core.rs` line 44: `self.high_qc.round` | Core::high_qc() getter |
| `voteStatus` | `core.rs` line 95-98 (implicit via voting phase) | Core::vote_status() getter [NEW FIELD] |
| `qcProcessing` | `core.rs` line 300: in-flight QC processing flag | Core::is_qc_processing() getter [NEW FIELD] |
| `pendingRoundAdvance` | `core.rs` line 277-289: pending round in advance_round() | Core::pending_round() getter [NEW FIELD] |
| `tcRound` | `aggregator.rs` line 50: tc_makers[round] | TCMaker::current_round() |
| `proposedRounds` | `proposer.rs` line 28: self.leader | Proposer::proposed_rounds() getter [NEW FIELD] |
| `crashed` | [Injected in test harness] | Test state |

---

## Section 2: Action-to-Code Mapping

### Action 1: CheckVoteSafety

**Spec Action**: `CheckVoteSafety(n, r, qcRound)`

**Code Location**:
- Primary: `hotstuff/src/core.rs:103-115`
- Core logic: Lines 107-108 (safety check against persistent state)

**Trigger Point**: **Before** `increase_last_voted_round()` at line 117

**Trace Event Name**: `CheckVoteSafety`

**Fields to Capture**:

| Field | Type | Source | Purpose |
|-------|------|--------|---------|
| `node` | uint32 | `self.name` | Node ID |
| `round` | uint64 | `proposal.round` | Proposed block round |
| `qcRound` | uint64 | `proposal.qc.round` | QC round from proposal |
| `votedRound` | uint64 | `self.last_voted_round` | In-memory voted round before check |
| `persistentVotedRound` | uint64 | `store.read_last_voted()` | Persistent voted round (from storage) |
| `passed` | bool | (result of check) | Whether safety check passed |

**Notes**:
- Safety check: `round > persistentLastVotedRound` AND `qcRound < round`
- Capture state **before** the in-memory update at line 117
- If safety check fails, do not proceed to next action

---

### Action 2: PersistVoteRound

**Spec Action**: `PersistVoteRound(n)`

**Code Location**:
- Primary: `store/src/lib.rs:65-69`
- Caller: `core.rs:118` via `store.write()`

**Trigger Point**: **After** `store.write()` completes successfully

**Trace Event Name**: `PersistVoteRound`

**Fields to Capture**:

| Field | Type | Source | Purpose |
|-------|------|--------|---------|
| `node` | uint32 | `self.name` | Node ID |
| `round` | uint64 | `self.round` | Current round |
| `persistentVotedRound` | uint64 | `store.read_last_voted()` | Value written to persistent storage |
| `writeLatencyUs` | uint64 | `store.write() duration` | Disk write latency (for diagnostics) |

**Notes**:
- Only capture if store.write() succeeds
- If write fails or is interrupted, do not emit this event
- This event marks the atomic boundary for voting safety

---

### Action 3: SendVote

**Spec Action**: `SendVote(n)`

**Code Location**:
- Primary: `core.rs:119-120` (message sending)
- Channel: `hotstuff_tx.send(Vote { ... })`

**Trigger Point**: **After** vote message is enqueued to network channel

**Trace Event Name**: `SendVote`

**Fields to Capture**:

| Field | Type | Source | Purpose |
|-------|------|--------|---------|
| `node` | uint32 | `self.name` | Voting node |
| `round` | uint64 | `vote.round` | Voted round |
| `qcRound` | uint64 | `self.high_qc.round` | High QC round in vote |
| `voteMessage` | struct | `vote` object | Full vote message (for network state) |

**Notes**:
- Emit after message is guaranteed in network (channel enqueued)
- Vote message must include node ID, round, and QC round

---

### Action 4: ProcessQCFromProposal

**Spec Action**: `ProcessQCFromProposal(n, blockRound, qcRound)`

**Code Location**:
- Primary: `core.rs:376` within `handle_proposal()`
- Function: `process_qc()` at line 299-305

**Trigger Point**: **Before** `advance_round()` is called (line 305)

**Trace Event Name**: `ProcessQCFromProposal`

**Fields to Capture**:

| Field | Type | Source | Purpose |
|-------|------|--------|---------|
| `node` | uint32 | `self.name` | Node processing QC |
| `round` | uint64 | `self.round` | Current round before processing |
| `blockRound` | uint64 | `block.round` | Block round from proposal |
| `qcRound` | uint64 | `proposal.qc.round` | QC round from proposal |
| `qcValid` | bool | (validation result) | Whether QC validation passed |

**Notes**:
- QC processing is the first async operation in handle_proposal
- Must happen before round advance to model the non-atomic window
- If QC validation fails, do not proceed to round advance

---

### Action 5: AdvanceRoundFromQC

**Spec Action**: `AdvanceRoundFromQC(n, newRound)`

**Code Location**:
- Primary: `core.rs:277-289`
- Function: `advance_round()` called from line 305

**Trigger Point**: **After** entering `advance_round()` but **before** updating `self.round`

**Trace Event Name**: `AdvanceRoundFromQC`

**Fields to Capture**:

| Field | Type | Source | Purpose |
|-------|------|--------|---------|
| `node` | uint32 | `self.name` | Node advancing round |
| `oldRound` | uint64 | `self.round` | Round before advance |
| `newRound` | uint64 | target round | Round after advance |
| `reason` | string | ("qc" \| "tc") | Whether advance is from QC or TC |

**Notes**:
- Round advance is non-atomic: line 277-289 updates multiple fields
- Capture **before** actual update to model the pending state
- Family 2 extension: pendingRoundAdvance tracks this window

---

### Action 6: CommitRoundAdvance

**Spec Action**: `CommitRoundAdvance(n)`

**Code Location**:
- Primary: `core.rs:280` where `self.round = newRound`
- Part of: `advance_round()` function

**Trigger Point**: **After** `self.round` is updated to new value

**Trace Event Name**: `CommitRoundAdvance`

**Fields to Capture**:

| Field | Type | Source | Purpose |
|-------|------|--------|---------|
| `node` | uint32 | `self.name` | Node |
| `round` | uint64 | `self.round` | New round value |
| `advanceCompl.Us` | uint64 | `advance_round() duration` | Time to complete round advance |

**Notes**:
- This action completes the non-atomic round advance window
- Must follow AdvanceRoundFromQC action
- Atomicity check: qcProcessing must be cleared

---

### Action 7: AddTimeoutToTC

**Spec Action**: `AddTimeoutToTC(n, tcRound, sender)`

**Code Location**:
- Primary: `aggregator.rs:41-50` in `add_timeout()`
- Called from: `core.rs:269` in `handle_timeout()`

**Trigger Point**: **After** timeout is added to TCMaker

**Trace Event Name**: `AddTimeoutToTC`

**Fields to Capture**:

| Field | Type | Source | Purpose |
|-------|------|--------|---------|
| `node` | uint32 | `self.name` | Node receiving timeout |
| `sender` | uint32 | `timeout.from` | Timeout sender node |
| `tcRound` | uint64 | `timeout.round` | Round for which timeout is sent |
| `signatureCount` | uint32 | `self.tc_makers[round].len()` | Number of signatures collected so far |
| `quorumReached` | bool | `signatureCount >= f+1` | Whether quorum of timeouts reached |

**Notes**:
- Timeouts are aggregated in TCMaker per round
- Quorum = f+1 = (NumNodes-1)/3 + 1
- Family 3 extension: tc validation requires proper quorum

---

### Action 8: AdvanceRoundViaTC

**Spec Action**: `AdvanceRoundViaTC(n)`

**Code Location**:
- Primary: `core.rs:269-271` in `handle_timeout()`
- Called after: TC is assembled (quorum of timeouts)

**Trigger Point**: **After** TC round advance commits to state

**Trace Event Name**: `AdvanceRoundViaTC`

**Fields to Capture**:

| Field | Type | Source | Purpose |
|-------|------|--------|---------|
| `node` | uint32 | `self.name` | Node advancing via TC |
| `tcRound` | uint64 | `timeout_cert.round` | TC round |
| `newRound` | uint64 | `tcRound + 1` | New round after TC |
| `tcSignatureCount` | uint32 | `timeout_cert.sigs.len()` | Number of signatures in TC |

**Notes**:
- TC triggers both round advance AND new leader election
- Leader for newRound = `(newRound - 1) % NumNodes + 1`
- Family 3: TC.round must > max(TC.high_qc_rounds)

---

### Action 9: GenerateProposal

**Spec Action**: `GenerateProposal(n)`

**Code Location**:
- Primary: `core.rs:228-231`, `269-271`, `394-396` (three call sites)
- Implementation: `proposer.rs:160-167` in `Proposer::run()`

**Trigger Point**: **After** proposal message is enqueued

**Trace Event Name**: `GenerateProposal`

**Fields to Capture**:

| Field | Type | Source | Purpose |
|-------|------|--------|---------|
| `node` | uint32 | `self.leader.1` in proposer.rs | Proposing leader |
| `round` | uint64 | `proposal.round` | Proposal round |
| `qcRound` | uint64 | `proposal.qc.round` | QC justifying this proposal |
| `callSite` | string | ("handle_vote" \| "handle_timeout" \| "handle_tc") | Which path triggered proposal |
| `proposalMessage` | struct | `proposal` object | Full proposal message |

**Notes**:
- Family 5: proposal idempotency - check call site for duplicates
- Only leader for current round should propose
- proposer.rs line 28 stores Option<(Round, QC, Option<TC>)> - model as single proposal per round
- If two triggers call generate_proposal for same round, second should be idempotent (line 160-161)

---

### Action 10: Crash

**Spec Action**: `Crash(n)`

**Code Location**:
- Not directly in implementation code
- Modeled as: unexpected process termination or panic

**Trigger Point**: At time of crash/panic

**Trace Event Name**: `Crash`

**Fields to Capture**:

| Field | Type | Source | Purpose |
|-------|------|--------|---------|
| `node` | uint32 | Node ID | Crashing node |
| `round` | uint64 | `core.round` | Round at crash time |
| `lastVotedRound` | uint64 | `core.last_voted_round` (in-memory) | In-memory state lost |
| `persistentVotedRound` | uint64 | `store.read_last_voted()` | State persisted to disk |

**Notes**:
- Family 1: model crash as loss of in-memory state
- Persistent storage (if written) survives
- In test harness, inject crash via signal or explicit termination

---

### Action 11: Recover

**Spec Action**: `Recover(n)`

**Code Location**:
- Primary: `core.rs:430-440` (implicit in startup/recovery path)
- Recovery reads: `store.read_last_voted()` from persistent storage

**Trigger Point**: **After** node recovers and reloads persistent state

**Trace Event Name**: `Recover`

**Fields to Capture**:

| Field | Type | Source | Purpose |
|-------|------|--------|---------|
| `node` | uint32 | Node ID | Recovering node |
| `round` | uint64 | `core.round` | Round at recovery (loaded from storage) |
| `recoveredLastVotedRound` | uint64 | `store.read_last_voted()` | Persistent voted round reloaded |
| `recoveryLatencyUs` | uint64 | `recovery_time` | Time to recover from disk |

**Notes**:
- Family 1: after recovery, in-memory state = persistent state
- Must verify: `lastVotedRound >= persistentLastVotedRound` to prevent double-voting
- Recovery must load **all** persistent state before node is online

---

## Section 3: Special Considerations

### Bootstrap State

Implementation startup differs from spec Init:

- Nodes start with round = 0
- Persistent storage may be empty (first start) or loaded from prior session
- In test harness: initialize all nodes before starting consensus

### Shadow Fields for Instrumentation

The following implementation fields are not directly accessible and need shadow fields in instrumentation harness:

| Spec Variable | Shadow Field | Implementation Hack |
|---------------|--------------|---------------------|
| `voteStatus` | `vote_status_shadow` | Add to Core struct for phase tracking |
| `qcProcessing` | `qc_processing_shadow` | Set/clear around line 300-305 |
| `pendingRoundAdvance` | `pending_round_shadow` | Track in advance_round() |
| `proposedRounds` | `proposed_rounds_shadow` | Set in proposer.rs when proposal sent |

These shadow fields should be reset on crash and recovered appropriately.

### Non-Atomic Persistence Windows

Family 1 addresses the non-atomic gap between:
1. **CheckVoteSafety**: line 107-108 reads persistent state
2. **PersistVoteRound**: line 118 calls store.write()

**Gap**: Between these two actions, a crash loses the in-memory decision. Instrumentation must emit separate trace events to model this window.

### Crash Simulation in Test Harness

To trigger crash conditions reliably:

1. Inject at controlled points (e.g., after CheckVoteSafety but before PersistVoteRound)
2. Use signal delivery (SIGTERM) or explicit panic to simulate unexpected termination
3. Emit Crash event **before** process dies
4. Restart process and emit Recover event after loading persistent state

### Concurrent Message Processing

Multiple message handlers run concurrently via tokio-select. Trace events may be interleaved. Instrumentation must:

1. Use high-precision timestamps (nanoseconds from rdtsc or clock_gettime)
2. Include causal ordering (message IDs, correlation IDs)
3. Emit events **at action boundaries**, not inside async operations

### QC and TC Message Filtering

Implementation sends many QC/TC messages via network. For trace validation:

1. Only emit events for QCs/TCs that result in **spec state changes**
2. Filter out redundant or stale messages
3. Focus on "first time this QC/TC advanced the round" events

---

## Section 4: Validation Checklist

Before running harness generation, verify:

- [ ] Every spec action maps to exactly one code location (or list all if multiple)
- [ ] Every code location maps to exactly one spec action
- [ ] Field names in "State Snapshot Fields" match trace JSON keys
- [ ] Trigger points (before/after) are specific and unambiguous
- [ ] Shadow fields are listed if spec variables are not directly accessible
- [ ] Bootstrap state differences are documented
- [ ] Crash/recovery gaps are modeled with separate events

---

## Summary

This instrumentation spec defines the complete mapping between the TLA+ base spec and the Autobahn implementation source code. Use it to:

1. Guide harness generation (Phase 2.5)
2. Design trace event schema
3. Validate that traces match spec logic
4. Debug trace validation failures

For questions during harness generation, refer back to the code locations and field lists in Section 2.
