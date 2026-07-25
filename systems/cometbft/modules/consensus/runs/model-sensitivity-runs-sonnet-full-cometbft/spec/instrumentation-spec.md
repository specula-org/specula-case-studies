# Instrumentation Spec: CometBFT v0.38.19

Maps TLA+ spec actions to implementation source locations for trace harness generation.

---

## Section 1: Trace Event Schema

### 1.1 Event Envelope

```json
{
  "tag": "trace",
  "timestamp": "<ISO8601>",
  "event": {
    "name": "<action_name>",
    "nid": "<validator_address_hex>",
    "state": {
      "height":      <int>,
      "round":       <int>,
      "step":        "<NewHeight|NewRound|Propose|Prevote|PrevoteWait|Precommit|PrecommitWait|Commit>",
      "lockedRound": <int>,
      "lockedValue": "<block_hash_hex_or_nil>",
      "validRound":  <int>,
      "validValue":  "<block_hash_hex_or_nil>"
    },
    "msg": {          // optional — for vote/proposal receive events
      "source": "<validator_address_hex>",
      "dest":   "<validator_address_hex>",
      "value":  "<block_hash_hex_or_NilVote>",
      "round":  <int>,
      "ve":     "<ValidExt|InvalidExt|NoExt>"
    },
    "ext": {          // optional — for Family 1 extension verification events
      "verified": <bool>,
      "bypassed": <bool>
    },
    "evidence": {     // optional — for Family 3 evidence events
      "commonHeight":         <int>,
      "conflictingBlockHash": "<block_hash_hex>"
    },
    "peer": {         // optional — for Family 4 blocksync events
      "id":     "<peer_id>",
      "height": <int>,
      "base":   <int>
    }
  }
}
```

### 1.2 State Fields

| Implementation Field | TLA+ Variable | Access Method |
|---------------------|---------------|---------------|
| `cs.Height` | `height` | `cs.RoundState.Height` |
| `cs.Round` | `round` | `cs.RoundState.Round` |
| `cs.Step` | `step` | `cs.RoundState.Step.String()` → map to TLA+ step name |
| `cs.LockedRound` | `lockedRound` | `cs.RoundState.LockedRound` |
| `cs.LockedBlock.Hash()` | `lockedValue` | hex or `"nil"` if nil |
| `cs.ValidRound` | `validRound` | `cs.RoundState.ValidRound` |
| `cs.ValidBlock.Hash()` | `validValue` | hex or `"nil"` if nil |

**Step string mapping** (RoundStepType.String() → TLA+ step name):
```
RoundStepNewHeight    → "NewHeight"
RoundStepNewRound     → "NewRound"
RoundStepPropose      → "Propose"
RoundStepPrevote      → "Prevote"
RoundStepPrevoteWait  → "PrevoteWait"
RoundStepPrecommit    → "Precommit"
RoundStepPrecommitWait → "PrecommitWait"
RoundStepCommit       → "Commit"
```

### 1.3 Message Fields

| Implementation Field | TLA+ Field | Notes |
|---------------------|------------|-------|
| `vote.ValidatorAddress` | `msg.source` | Hex-encoded 20-byte address |
| Receiving node address | `msg.dest` | Node emitting the trace event |
| `vote.BlockID.Hash` | `msg.value` | Hex or `"NilVote"` for nil-block votes |
| `vote.Round` | `msg.round` | Vote round |
| `vote.Extension` | `msg.ve` | `"ValidExt"` / `"InvalidExt"` / `"NoExt"` |

**Vote extension VE mapping**: capture as one of three abstract values:
- `"NoExt"` — nil precommit (vote.BlockID.IsZero()) or extensions disabled
- `"ValidExt"` — non-nil extension that would pass VerifyVoteExtension
- `"InvalidExt"` — non-nil extension that would fail VerifyVoteExtension

Determining ValidExt vs. InvalidExt requires calling `VerifyVoteExtension` at capture time and recording the result. Only the outcome (pass/fail) is needed, not the raw extension bytes.

---

## Section 2: Action-to-Code Mapping

### 2.1 EnterNewRound
- **Spec action**: `EnterNewRound(i, r)`
- **Code location**: `consensus/state.go:1066-1131`
- **Trigger point**: After `cs.Step = RoundStepNewRound` at line 1114
- **Trace event name**: `"EnterNewRound"`
- **Fields**: `state` (height, round, step="NewRound")
- **Notes**: Round 0 fires immediately after FinalizeCommit advances height. Round >0 fires after timeout or round-skip.

### 2.2 EnterPropose
- **Spec action**: `EnterPropose(i)`
- **Code location**: `consensus/state.go:1157-1266` (enterPropose + defaultDecideProposal)
- **Trigger point**: After `cs.Step = RoundStepPropose` at line 1172, AFTER proposal broadcast if proposer
- **Trace event name**: `"EnterPropose"`
- **Fields**: `state` (height, round, step="Propose"). If proposer, include `msg.value = <proposed block hash>`.
- **Notes**: defaultDecideProposal (line 1209) runs before this event for proposers. Capture proposed value from `cs.ValidBlock.Hash()` or `ChooseValue` result.

### 2.3 ReceiveProposal
- **Spec action**: `ReceiveProposal(i, m)`
- **Code location**: `consensus/state.go:1920-1967` (defaultSetProposal)
- **Trigger point**: After `cs.Proposal = proposal` at line 1957 (only on successful acceptance)
- **Trace event name**: `"ReceiveProposal"`
- **Fields**: `state`, `msg` (source=proposer address, dest=self, value=proposal.BlockID.Hash, round=proposal.Round)
- **Notes**: Do NOT emit for rejected proposals (lines 1932-1953). Self-proposal from proposer: the trace spec handles this as a no-op (proposalBlock already set by EnterPropose).

### 2.4 EnterPrevote
- **Spec action**: `EnterPrevote(i)`
- **Code location**: `consensus/state.go:1334-1420` (enterPrevote + defaultDoPrevote)
- **Trigger point**: After `signAddVote` completes and prevote is sent (line ~1418)
- **Trace event name**: `"EnterPrevote"`
- **Fields**: `state` (step="Prevote"), `msg` (source=self, value=prevoted block hash or "NilVote")
- **Notes**: The msg.value captures which of the 5 prevote paths was taken. "NilVote" for nil-block votes.

### 2.5 ReceivePrevote
- **Spec action**: `ReceivePrevote(i, m)`
- **Code location**: `consensus/state.go:2246-2266` (addVote, prevote section)
- **Trigger point**: After vote is added to vote set at line 2246
- **Trace event name**: `"ReceivePrevote"`
- **Fields**: `state` (including updated lockedRound/lockedValue if unlock occurred), `msg`
- **Notes**: If unlock occurs (lines 2279-2290), capture updated lock state. If ValidBlock updated (lines 2299-2310), capture updated validRound/validValue.

### 2.6 EnterPrevoteWait
- **Spec action**: `EnterPrevoteWait(i)`
- **Code location**: `consensus/state.go:1423-1445`
- **Trigger point**: After `cs.Step = RoundStepPrevoteWait` at line 1445
- **Trace event name**: `"EnterPrevoteWait"`
- **Fields**: `state` (step="PrevoteWait")

### 2.7 EnterPrecommit (5 paths)
- **Spec actions**: All five `EnterPrecommit*` variants
- **Code location**: `consensus/state.go:1459-1578`
- **Trigger point**: After step transition and precommit vote sent (after `signAddVote` returns)
- **Trace event name**: `"EnterPrecommit"`
- **Fields**: `state` (including updated lockedRound/lockedValue), `msg` (source=self, value=precommit value, ve=VE abstract value)
- **Notes**:
  - All 5 paths emit the same event name; trace spec disambiguates by post-state lock values.
  - For non-nil precommits: capture `ve` field as ValidExt/InvalidExt/NoExt.
  - Path 1 (no polka, line 1479): lockedRound unchanged
  - Path 2 (nil polka, line 1505): lockedRound=-1
  - Path 3 (relock, line 1525): lockedRound=current round, same lockedValue
  - Path 4 (new lock, line 1538): lockedRound=current round, NEW lockedValue
  - Path 5 (unknown, line 1559): lockedRound=-1

### 2.8 ReceivePrecommit (Family 1)
- **Spec action**: `ReceivePrecommitConsensus(i, m)`
- **Code location**: `consensus/state.go:2296-2348` (addVote, extension verification block)
- **Trigger point**: After vote is added to vote set (or rejected on ABCI failure)
- **Trace event name**: `"ReceivePrecommit"`
- **Fields**: `state`, `msg` (source, dest, value, round, ve), `ext` (verified, bypassed)
- **Notes** (Family 1):
  - **`ext.verified`**: TRUE if VerifyVoteExtension was called (line 2329) and succeeded.
  - **`ext.bypassed`**: TRUE if the `!bytes.Equal(vote.ValidatorAddress, myAddr)` guard (line 2310) skipped the ABCI call. This is the self-vote bypass bug (Issue #5204).
  - When `m.source == myAddr` (self-vote): `ext.bypassed=true, ext.verified=false`.
  - When `m.source != myAddr` (remote vote): `ext.bypassed=false, ext.verified=<result>`.
  - If ABCI check fails (`ext.verified=false, ext.bypassed=false`): vote NOT added to vote set; emit event anyway to record the rejection.

### 2.9 EnterPrecommitWait
- **Spec action**: `EnterPrecommitWait(i)`
- **Code location**: `consensus/state.go:1584-1610`
- **Trigger point**: After `TriggeredTimeoutPrecommit = true` at line 1604
- **Trace event name**: `"EnterPrecommitWait"`
- **Fields**: `state` (step="PrecommitWait")

### 2.10 HandleTimeoutPropose
- **Spec action**: `HandleTimeoutPropose(i)`
- **Code location**: `consensus/state.go:1003-1009` (handleTimeout, RoundStepPropose case)
- **Trigger point**: When timeout fires and enters prevote
- **Trace event name**: `"HandleTimeoutPropose"`
- **Fields**: `state` (captures PRE-state before enterPrevote; actual step change in subsequent EnterPrevote event)

### 2.11 HandleTimeoutPrevote
- **Spec action**: `HandleTimeoutPrevote(i)`
- **Code location**: `consensus/state.go:1011-1016` (handleTimeout, RoundStepPrevoteWait)
- **Trigger point**: When timeout fires
- **Trace event name**: `"HandleTimeoutPrevote"`
- **Fields**: `state` (step="PrevoteWait", PRE-state)

### 2.12 HandleTimeoutPrecommit
- **Spec action**: `HandleTimeoutPrecommit(i)`
- **Code location**: `consensus/state.go:1018-1022` (handleTimeout, RoundStepPrecommitWait)
- **Trigger point**: When timeout fires, before enterNewRound
- **Trace event name**: `"HandleTimeoutPrecommit"`
- **Fields**: `state` (step="PrecommitWait", PRE-state)

### 2.13 EnterCommit
- **Spec action**: `EnterCommit(i)`
- **Code location**: `consensus/state.go:1620-1673`
- **Trigger point**: After `cs.Step = RoundStepCommit` at line 1629
- **Trace event name**: `"EnterCommit"`
- **Fields**: `state` (step="Commit", committed value)

### 2.14 FinalizeCommit
- **Spec action**: `FinalizeCommit(i)`
- **Code location**: `consensus/state.go:1704-1827`
- **Trigger point**: After `updateToState` at line 1800 (height incremented)
- **Trace event name**: `"FinalizeCommit"`
- **Fields**: `state` (new height, round=0, step="NewHeight")
- **Notes**: 4 crash injection points within finalizeCommit (lines 1744, 1761, 1784, 1812).

### 2.15 RoundSkip
- **Spec actions**: `RoundSkipPrevote(i)`, `RoundSkipPrecommit(i)`
- **Code locations**: `consensus/state.go:2329-2331` (prevote), `2371-2373` (precommit)
- **Trigger point**: After `enterNewRound` called from addVote handler
- **Trace event name**: `"RoundSkip"`
- **Fields**: `state` (new round, step="NewRound")

### 2.16 Crash
- **Spec action**: `Crash(i)`
- **Code location**: Injected via `fail.Fail()` points in finalizeCommit (lines 1744, 1761, 1784, 1812) or external SIGKILL
- **Trigger point**: At crash injection point or process death detection
- **Trace event name**: `"Crash"`
- **Fields**: `nid` only

### 2.17 Recover
- **Spec action**: `Recover(i)`
- **Code location**: `consensus/replay.go:93-170` (catchupReplay)
- **Trigger point**: After WAL replay completes and consensus state is restored
- **Trace event name**: `"Recover"`
- **Fields**: `state` (recovered height, round=0, step="NewHeight")

### 2.18 AcceptCommitLightClient (Family 1)
- **Spec action**: `AcceptCommitLightClient(i, h)`
- **Code location**: `light/verifier.go:57` (VerifyAdjacent), `72-75` (VerifyNonAdjacent), `125-128` (Verify)
- **Trigger point**: After the commit at height h is accepted by the light client verifier
- **Trace event name**: `"AcceptCommitLightClient"`
- **Fields**: `state.height` = h
- **Notes**: All three code paths call `verifyCommitLightInternal` (state/validation.go), which never calls VerifyVoteExtension. Emit once per accepted height.

### 2.19 AcceptCommitBlockSync (Family 1)
- **Spec action**: `AcceptCommitBlockSync(i, h)`
- **Code location**: `blocksync/reactor.go:548-554` (handlePeerResponse, EnsureExtensions call)
- **Trigger point**: After EnsureExtensions presence check, before block is applied
- **Trace event name**: `"AcceptCommitBlockSync"`
- **Fields**: `state.height` = h
- **Notes**: `blocksync/reactor.go:531` has a TODO about missing extension verification. Only extension presence (not signatures) is checked via `EnsureExtensions`.

### 2.20 CheckDoubleSigningRisk (Family 2)
- **Spec action**: `CheckDoubleSigningRisk(i, h)`
- **Code location**: `consensus/state.go:2638-2661` (checkDoubleSigningRisk)
- **Trigger point**: Entry to checkDoubleSigningRisk (before any loop iteration)
- **Trace event name**: `"CheckDoubleSigningRisk"`
- **Fields**: `state.height` = h
- **Notes**: Emit regardless of whether the loop runs (the bug is that it doesn't run at h=1). Include a `"loopRan": <bool>` field in the event to distinguish the zero-iteration case.

### 2.21 SubmitLightClientEvidence (Family 3)
- **Spec action**: `SubmitLightClientEvidence(v, commonH, conflictingBlockHash)`
- **Code location**: `evidence/pool.go:AddEvidence` (pool.go:181-188)
- **Trigger point**: After evidence is validated and before pool.addToCache
- **Trace event name**: `"SubmitLightClientEvidence"`
- **Fields**: `evidence.commonHeight`, `evidence.conflictingBlockHash` (hex of ConflictingBlock.Hash().Bytes())
- **Notes**: The pool key is computed from the truncated hash: `types/evidence.go:326`. The harness should capture the FULL 32-byte hash, not the truncated key, so the collision can be detected during trace validation.

### 2.22 SetPeerRange (Family 4)
- **Spec action**: `SetPeerRange(v, p, h)`
- **Code location**: `blocksync/pool.go:SetPeerRange` (lines 391-413)
- **Trigger point**: After `pool.maxPeerHeight` is (conditionally) updated at line 411-413
- **Trace event name**: `"SetPeerRange"`
- **Fields**: `peer.id`, `peer.height`, `peer.base`
- **Notes**: Emit even when `pool.maxPeerHeight` is NOT updated (h < current max). The spec tracks this to model the non-monotone peer height updates that enable the MC5 scenario.

### 2.23 RemovePeer (Family 4)
- **Spec action**: `RemovePeer(v, p)`
- **Code location**: `blocksync/pool.go:removePeer` (lines 426-452)
- **Trigger point**: Before `delete(pool.peers, peerID)` at line 439
- **Trace event name**: `"RemovePeer"`
- **Fields**: `peer.id`, `peer.height` (captured from `peer.height` before deletion)
- **Notes**: The bug is at line 449-451: `if peer.height == pool.maxPeerHeight { updateMaxPeerHeight() }`. Capture `peer.height` (stored value) AND `pool.maxPeerHeight` to expose the mismatch case.

### 2.24 CheckCaughtUp (Family 4)
- **Spec action**: `CheckCaughtUp(v)`
- **Code location**: `blocksync/pool.go:IsCaughtUp()` called from `blocksync/reactor.go:poolRoutine`
- **Trigger point**: When IsCaughtUp returns TRUE and reactor transitions to consensus mode
- **Trace event name**: `"CheckCaughtUp"`
- **Fields**: `state` with `syncMode = "consensus"`

---

## Section 3: Special Considerations

### 3.1 Single-Writer Invariant
All trace events must be emitted from within the `receiveRoutine` goroutine (consensus/state.go:764-870). This is the only goroutine that writes `RoundState`. Do NOT instrument gossip goroutines (`gossipDataRoutine`, `gossipVotesRoutine`) — they only read snapshots and may see stale state.

### 3.2 Vote Extension Capture (Family 1)
- **`msg.ve`** is captured after the precommit message is generated. For outbound precommits (EnterPrecommit actions), capture `voteExt[i]` = `vote.Extension` (if non-nil) else `"NoExt"`.
- **`ext.verified`** is captured after `VerifyVoteExtension` returns (state.go:2329-2333). Record the bool result.
- **`ext.bypassed`** is set TRUE when the `!bytes.Equal(vote.ValidatorAddress, myAddr)` guard (state.go:2310) fires, skipping the ABCI call.
- For light client acceptance (AcceptCommitLightClient), no `ext` fields are set since verification never ran.

### 3.3 Concurrent Goroutines and Blocksync
Blocksync runs in its own goroutine (`poolRoutine`). Events from `SetPeerRange`, `RemovePeer`, and `CheckCaughtUp` are emitted from that goroutine. These events are in a different causal ordering from the consensus events emitted by `receiveRoutine`. Traces should be collected with monotonic timestamps to enable causal ordering reconstruction.

### 3.4 Evidence Pool Capture (Family 3)
`AddEvidence` is called from various goroutines. Emit events from within `pool.mtx` lock to ensure atomic capture. The `conflictingBlockHash` must be the full 32-byte hash (not the truncated key) so the trace spec can detect collisions.

### 3.5 Double-Sign Check Capture (Family 2)
The off-by-one bug at state.go:2647 means the loop runs 0 times at height=1. The harness can detect this by checking `doubleSignCheckHeight` (= `min(config.DoubleSignCheckHeight, height)`) before the loop and emitting a `"CheckDoubleSigningRisk"` event with `"loopRan": false` when `doubleSignCheckHeight <= 1`.

### 3.6 Bootstrap / Initial State
- Consensus starts at `height = state.LastBlockHeight + 1`
- Initial values: `round=0, step="NewHeight", lockedRound=-1, validRound=-1`
- For trace validation, `TraceInit` matches these values.

### 3.7 Serialization
- Block hashes: hex-encoded 32-byte strings (64 chars); `"nil"` for absent blocks
- Validator addresses: hex-encoded 20-byte strings (40 chars)
- `NilVote` for nil-block votes: serialize `msg.value = "NilVote"`
- Integers: plain JSON numbers; -1 for "not set" rounds (lockedRound, validRound)
- Boolean fields: JSON `true`/`false`
