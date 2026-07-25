# CometBFT Instrumentation Specification

## Phase 4: Action-to-Code Mapping

This document specifies how to instrument the CometBFT source code to produce traces compatible with the trace spec (`Trace.tla`).

**Note**: All line references are from the snapshot at `/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/cometbft/artifact/cometbft/` (analyzed via code_analysis skill).

---

## Section 1: Trace Event Schema

### Event Envelope (Common to All Events)

Every trace event is a JSON object with:

```json
{
  "eventName": "EnterPrevote",      // String name matching spec action
  "nodeID": "v1",                   // Validator ID (or node identifier)
  "timestamp": 1234567890,          // Unix timestamp (ns resolution preferred)
  
  // State snapshot (captured at trigger point)
  "height": 1,
  "round": 0,
  "step": "prevote",
  "proposedBlock": 1,
  "lockedBlock": null,
  "lockedRound": -1,
  "validBlock": null,
  "validRound": -1,
  
  // Message fields (event-specific, optional)
  "voteHeight": null,
  "voteRound": null,
  "voteType": null,
  "voteBlockID": null,
  "extension": null,
  "sender": null,
  "receiver": null
}
```

### State Fields (Captured at Every Event)

Map each spec variable to implementation getter/field:

| TLA+ Variable | Go Code | Capture Method |
|---|---|---|
| `heightRound[v].height` | `cs.Height` | Direct field access (consensus/state.go:67) |
| `heightRound[v].round` | `cs.Round` | Direct field access (consensus/state.go:68) |
| `step[v]` | `cs.Step` | Enum mapping: RoundStepNewHeight → "newheight", etc. (consensus/types/types.go) |
| `proposedBlock[v]` | `cs.ProposalBlock` | Block ID or hash (consensus/state.go:78) |
| `lockedBlock[v]` | `cs.LockedBlock` | Block ID or hash (consensus/state.go:79) |
| `lockedRound[v]` | `cs.LockedRound` | Direct field (consensus/state.go:80) |
| `validBlock[v]` | `cs.ValidBlock` | Block ID or hash (consensus/state.go:81) |
| `validRound[v]` | `cs.ValidRound` | Direct field (consensus/state.go:82) |

### Vote Message Fields

| TLA+ Field | Go Code | Location |
|---|---|---|
| `voteHeight` | `vote.Height` | consensus/types/vote.go:30 |
| `voteRound` | `vote.Round` | consensus/types/vote.go:31 |
| `voteType` | `vote.Type` | Enum: PrevoteType → "prevote", PrecommitType → "precommit" |
| `voteBlockID` | `vote.BlockID` | consensus/types/vote.go:32 |
| `extension` | `vote.Extension` | consensus/types/vote.go:34 (precommit only) |

---

## Section 2: Action-to-Code Mapping

### Action: EnterNewRound

**Spec action**: `EnterNewRound(v)` (base.tla:110-119)

**Code location**: `consensus/state.go:1428-1462` (enterNewRound)

**Trigger point**: After lock acquisition in `receiveRoutine()` at consensus/state.go:800

**Trace event name**: `"EnterNewRound"`

**State snapshot timing**: **AFTER** transition (capture new step=RoundStepPropose)

**Fields to capture**:
- `height`, `round`, `step`, `proposedBlock` (must be NULL_BLOCK after transition)
- `lockedBlock`, `lockedRound`, `validBlock`, `validRound`

**Notes**:
- Called only when `step == RoundStepNewHeight` (line 1431)
- Reset `ProposalBlock` to nil (line 1435)
- Increment round OR height depending on Round == 0 condition (lines 1446-1450)

**Instrumentation point**:
```go
// consensus/state.go:1450 (after step transition)
if cs.tryAddVote(...) {
    cs.Step = RoundStepPropose
    // <<< INSERT: Emit "EnterNewRound" event here
}
```

---

### Action: EnterPrevote

**Spec action**: `EnterPrevote(v)` (base.tla:121-133)

**Code location**: `consensus/state.go:1464-1515` (enterPrevote)

**Trigger point**: After entering prevote step

**Trace event name**: `"EnterPrevote"`

**State snapshot timing**: **AFTER** step transition to RoundStepPrevote

**Fields to capture**:
- `height`, `round`, `step` (must be RoundStepPrevote)
- `proposedBlock` (may be ValidBlock, LockedBlock, or nil)
- `lockedBlock`, `lockedRound`, `validBlock`, `validRound`

**Notes**:
- Line 1467: Check `cs.LockedRound >= 0` (is locked)
- Lines 1485-1508: Choose proposedBlock based on ValidBlock, LockedBlock, or nil
- Family 2 target: Lock consistency check (lockValid[v])

**Instrumentation point**:
```go
// consensus/state.go:1510 (after step transition)
cs.Step = RoundStepPrevote
// <<< INSERT: Emit "EnterPrevote" event here
```

---

### Action: EnterPrecommit

**Spec action**: `EnterPrecommit(v)` (base.tla:135-151)

**Code location**: `consensus/state.go:1517-1607` (enterPrecommit)

**Trigger point**: After entering precommit step

**Trace event name**: `"EnterPrecommit"`

**State snapshot timing**: **AFTER** lock/unlock decision

**Fields to capture**:
- `height`, `round`, `step` (must be RoundStepPrecommit)
- `lockedBlock`, `lockedRound` (may change due to polka check)
- `validBlock`, `validRound`

**Notes**:
- Family 2 target: Lock acquisition (lines 1604-1621)
- Check 2/3 prevotes for LockedBlock (line 1605)
- Family 5 target: Byzantine behavior (invalid block validation at line 1608)

**Instrumentation point**:
```go
// consensus/state.go:1600 (after lock state update)
cs.Step = RoundStepPrecommit
// <<< INSERT: Emit "EnterPrecommit" event here
```

---

### Action: AddVote

**Spec action**: `AddVote(v, vote)` (base.tla:161-174)

**Code location**: `consensus/state.go:2238-2348` (addVote) — split into two phases per Family 1

**Trigger point**: After vote is added to vote set (line 2348)

**Trace event name**: `"AddVote"`

**State snapshot timing**: **AFTER** vote added to `rs.Votes[...]`

**Fields to capture**:
- Vote metadata: `voteHeight`, `voteRound`, `voteType`, `voteBlockID`, `extension`
- State: `height`, `round`, `step`
- No change to spec state, but log for vote history

**Notes**:
- Family 1 target: Vote acceptance ordering (lines 2250-2269, 2264-2269 for duplicates)
- Line 2325: Vote extension signature verification
- Line 2329: Application-level extension validation
- Line 2348: Add to vote set (after all checks pass)

**Instrumentation points** (two events per Family 1 split):

1. **CheckVote** (before acceptance checks):
```go
// consensus/state.go:2250 (before duplicate check)
// <<< INSERT: Log "CheckVote" with vote metadata
```

2. **AddVote** (after vote set update):
```go
// consensus/state.go:2348 (after adding to vote set)
// <<< INSERT: Emit "AddVote" event with full state snapshot
```

---

### Action: ReceiveProposal

**Spec action**: `ReceiveProposal(v, proposal)` (base.tla:193-199)

**Code location**: `consensus/state.go:2006-2068` (defaultSetProposal)

**Trigger point**: After proposal is received and stored in `cs.Proposal`

**Trace event name**: `"ReceiveProposal"`

**State snapshot timing**: **AFTER** `cs.Proposal` is set

**Fields to capture**:
- Proposal metadata: `height`, `round` (from proposal)
- `proposedBlock` (the block from proposal)
- Full state: `step`, `lockedBlock`, `lockedRound`, `validBlock`, `validRound`

**Notes**:
- Family 3 target: Non-atomic proposal receipt (lines 2006-2068)
- Line 2047-2048: Initialize `ProposalBlockParts` if nil
- Line 2008: TODO comment about double proposals (CR1 in brief §6.3)

**Instrumentation point**:
```go
// consensus/state.go:2065 (after proposal storage)
cs.Proposal = proposal
// <<< INSERT: Emit "ReceiveProposal" event here
```

---

### Action: ReceiveBlockPart

**Spec action**: `ReceiveBlockPart(v, h, r)` (base.tla:201-208)

**Code location**: `consensus/state.go:2073-2149` (addProposalBlockPart)

**Trigger point**: After block part is added to assembly (line 2135)

**Trace event name**: `"ReceiveBlockPart"`

**State snapshot timing**: **AFTER** part added, no state change yet

**Fields to capture**:
- Metadata: `height`, `round` (from proposal context)
- State snapshot (no change expected)

**Notes**:
- Family 3 target: Block assembly race (lines 2073-2149)
- Line 2135: Add part to `cs.ProposalBlockParts`
- Line 2141: Comment: "possible to receive complete proposal blocks for future rounds"

**Instrumentation point**:
```go
// consensus/state.go:2135 (after part addition)
cs.ProposalBlockParts.AddPart(part)
// <<< INSERT: Emit "ReceiveBlockPart" event if assembly complete
```

---

### Action: HandleCompleteProposal

**Spec action**: `HandleCompleteProposal(v)` (base.tla:210-217)

**Code location**: `consensus/state.go:2151-2184` (handleCompleteProposal)

**Trigger point**: After proposal block is fully assembled and unmarshalled

**Trace event name**: `"HandleCompleteProposal"`

**State snapshot timing**: **AFTER** `cs.ProposalBlock` is set

**Fields to capture**:
- `height`, `round`, `step`, `proposedBlock` (updated)
- `lockedBlock`, `lockedRound`

**Notes**:
- Family 3 target: Completed proposal handling (lines 2151-2184)
- Called from reactor receive loop after lock re-acquisition (reactor.go:928-932)
- Line 2176: Risk of stale proposal if round has advanced

**Instrumentation point**:
```go
// consensus/state.go:2176 (after block unmarshalling)
cs.ProposalBlock = block
// <<< INSERT: Emit "HandleCompleteProposal" event here
```

---

### Action: UnlockOnPol

**Spec action**: `UnlockOnPol(v)` (base.tla:234-255)

**Code location**: `consensus/state.go:2396-2423` (vote reception, POL unlock)

**Trigger point**: When detecting polka for different block and unlocking

**Trace event name**: `"UnlockOnPol"`

**State snapshot timing**: **AFTER** unlock

**Fields to capture**:
- `height`, `round`, `lockedBlock` (must be NULL after), `lockedRound` (must be -1)
- `validBlock`, `validRound`

**Notes**:
- Family 2 target: POL-based unlock logic (lines 2409-2423)
- Triggered by 2/3 prevotes for block B in round R > LockedRound
- Line 2416: Check `polRound < rs.Round` before unlocking

**Instrumentation point**:
```go
// consensus/state.go:2420 (after unlock decision)
cs.LockedBlock = nil
cs.LockedRound = -1
// <<< INSERT: Emit "UnlockOnPol" event here
```

---

### Action: UpdateValidBlock

**Spec action**: `UpdateValidBlock(v)` (base.tla:257-266)

**Code location**: `consensus/state.go:2427-2432` (vote reception, ValidBlock update)

**Trigger point**: When updating ValidBlock after detecting new polka

**Trace event name**: `"UpdateValidBlock"`

**State snapshot timing**: **AFTER** ValidBlock/ValidRound update

**Fields to capture**:
- `validBlock`, `validRound` (updated)
- `height`, `round`, `step`

**Notes**:
- Family 2 target: ValidBlock consistency (lines 2427-2432)
- Update ValidBlock when seeing higher polka

**Instrumentation point**:
```go
// consensus/state.go:2431 (after update)
cs.ValidBlock = block
cs.ValidRound = round
// <<< INSERT: Emit "UpdateValidBlock" event here
```

---

### Action: CheckVoteExtension

**Spec action**: `CheckVoteExtension(v, vote)` (base.tla:268-282)

**Code location**: `consensus/state.go:2296-2345` (addVote with extension checks)

**Trigger point**: After extension signature verification (line 2325)

**Trace event name**: `"CheckVoteExtension"`

**State snapshot timing**: **BEFORE** adding vote (captures pre-state)

**Fields to capture**:
- Vote: `voteHeight`, `voteRound`, `voteType`, `voteBlockID`, `extension`
- State: `height`, `round`, `step`
- Extension validation status (explicit flag)

**Notes**:
- Family 7 target: Extension validation (lines 2296-2345)
- Line 2297: Check `VoteExtensionsEnabled(vote.Height)` (consensus/state.go)
- Line 2325: `vote.VerifyExtension(chainID, val.PubKey)`
- Line 2329: `blockExec.VerifyVoteExtension(...)` (application validation)

**Instrumentation point**:
```go
// consensus/state.go:2325 (after signature verification)
if err := vote.VerifyExtension(...) {
    // <<< INSERT: Emit "CheckVoteExtension" event here
}
```

---

### Action: CrashAndRecover

**Spec action**: `CrashAndRecover(v)` (base.tla:321-331)

**Code location**: `consensus/state.go:186-192` (NewState with recovery)

**Trigger point**: After recovery from crash (state reconstruction complete)

**Trace event name**: `"CrashAndRecover"`

**State snapshot timing**: **AFTER** LastCommit reconstruction

**Fields to capture**:
- Recovery metadata: `recoveryMode` (set to "recovered")
- State snapshot: full state (height, round, step, locks, etc.)

**Notes**:
- Family 4 target: Recovery consistency (lines 186-192, 592-631)
- Line 186: Branch on `offlineStateSyncHeight != 0`
- Line 592: `reconstructSeenCommit()` path
- Line 617: `votesFromExtendedCommit()` path (with vote extensions)
- Panic paths (lines 595, 620, 713) must be logged (or not reached in correct execution)

**Instrumentation point**:
```go
// consensus/state.go:191 (after recovery completion)
cs.recoveryMode = "recovered"
// <<< INSERT: Emit "CrashAndRecover" event here
```

---

### Action: ByzantineEquivocateProposal (Family 5)

**Spec action**: `ByzantineEquivocateProposal(v, ...)` (base.tla:290-305)

**Code location**: Byzantine behavior (faulty proposer sends conflicting proposals)

**Trigger point**: When Byzantine proposer sends two different proposals for same (H,R)

**Trace event name**: `"ByzantineEquivocateProposal"`

**State snapshot timing**: **AFTER** both proposals are sent

**Fields to capture**:
- Metadata: `height`, `round`, two `blockIDs`
- Byzantine node ID

**Notes**:
- Family 5 target: Byzantine equivocation detection (consensus/reactor.go:247)
- May not have explicit instrumentation in correct-path code
- Can be logged at detector side (evidence verification)

---

### Action: ByzantineEquivocateVote (Family 5)

**Spec action**: `ByzantineEquivocateVote(v, ...)` (base.tla:307-318)

**Code location**: Byzantine behavior (faulty validator sends conflicting votes)

**Trigger point**: When Byzantine validator sends two different votes for same (H,R,T)

**Trace event name**: `"ByzantineEquivocateVote"`

**State snapshot timing**: **AFTER** conflict is detected

**Fields to capture**:
- Vote metadata: `voteHeight`, `voteRound`, `voteType`, two different `blockIDs`
- Byzantine node ID

**Notes**:
- Family 5 target: Byzantine vote detection (evidence/verify.go:100)
- Evidence is reported when conflicting votes are found
- Log at evidence detection point

---

## Section 3: Special Considerations

### Bootstrap State

The implementation's initial state may differ from `Init` in the spec:
- **Height**: Usually starts at 1 (consensus/state.go:184)
- **Round**: Starts at 0 (consensus/state.go:185)
- **Step**: Starts at RoundStepNewHeight
- **Locks**: All validators start unlocked

Capture bootstrap state before first event in trace.

### Goroutine Interleaving

CometBFT uses multiple goroutines:
- **receiveRoutine** (main state machine, holds `cs.mtx`)
- **gossipDataRoutine**, **gossipVotesRoutine** (separate locks, no `cs.mtx`)
- **TimeoutTicker** (separate goroutine)

**Instrumentation rule**: Only instrument events inside `cs.mtx` lock (receiveRoutine). Gossip events are internal to reactor and do not affect spec state.

### Non-Atomic Persistence (WAL)

The Write-Ahead Log (WAL) at `consensus/wal.go` writes term, vote, proposal sequentially. For crash recovery:
- Capture state **after** lock re-acquisition (post-crash)
- WAL provides atomicity for recovery, not for the spec model
- Focus on recovered state, not WAL internals

### Vote Extension Serialization

Vote extensions at `consensus/types/vote.go:34` may be:
- `nil` (no extension)
- `[]byte` (application-specific data)

**Capture rule**:
- If extension is non-nil, serialize to hex string
- If extension is nil, use null value in JSON
- Match with spec's `NULL_PROOF` constant

### State Access

Some state requires accessor functions or reflection:

| State | Access Method | Example |
|---|---|---|
| `cs.Height`, `cs.Round`, `cs.Step` | Direct field | `cs.Height` |
| `cs.ProposalBlock` | Nil check + type assertion | `if cs.ProposalBlock != nil { blockID = ... }` |
| `cs.Votes[h][r]` | HeightVoteSet accessor | `cs.Votes.Prevotes(r).BitArray()` |
| `cs.LockedBlock` | Nil check | `if cs.LockedBlock != nil { ... }` |

---

## Summary: Instrumentation Checklist

For each action in Section 2:

1. ✓ Identify code location(s) in Go source
2. ✓ Determine trigger point (which line to insert hook)
3. ✓ Choose state snapshot timing (before/after)
4. ✓ List all fields to capture
5. ✓ Handle edge cases (nil values, serialization, locks)
6. ✓ Test trace emission (manually run with logging enabled)
7. ✓ Validate trace against Trace.tla

---

**Next Phase**: Use this spec to generate instrumentation harness (`harness-generation` skill).

