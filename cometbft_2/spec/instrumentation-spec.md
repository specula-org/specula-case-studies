# Instrumentation Spec: CometBFT — Round 2 (BFT Extensions)

Maps TLA+ spec actions to source code locations for trace generation.

This is the round-2 instrumentation spec; it extends the round-1 events
(round/timeout/crash/VE) with the Byzantine action set (equivocation,
amnesia, VE-reuse, lunatic, evidence-lifecycle races, locking transitions).

## Section 1: Trace Event Schema

### Event Envelope

```json
{
  "tag": "trace",
  "timestamp": "<ISO8601>",
  "event": {
    "name": "<action_name>",
    "nid": "<server_id>",
    "state": {
      "height": <int>,
      "round": <int>,
      "step": "<StepName>",
      "lockedRound": <int>,
      "lockedValue": "<value_or_nil>",
      "validRound": <int>,
      "validValue": "<value_or_nil>",
      "validatorClock": <int>
    },
    "msg": {
      "source": "<sender_id>",
      "dest": "<receiver_id>",
      "type": "<msg_type>",
      "value": "<value_or_nil>",
      "round": <int>,
      "polRound": <int>,
      "ve": "<vote_extension_value>"
    },
    "byzVote": {
      "vtype": "<vote_type>",
      "height": <int>,
      "round": <int>,
      "oldRound": <int>,
      "newRound": <int>,
      "value": "<value_or_nil>",
      "ve": "<vote_extension_value>"
    },
    "k": <int>
  }
}
```

### State Fields

| Implementation field | TLA+ variable | Access method |
|----------------------|---------------|---------------|
| `cs.Height` | `height[s]` | `RoundState.Height` |
| `cs.Round` | `round[s]` | `RoundState.Round` |
| `cs.Step` | `step[s]` | `RoundState.Step.String()` |
| `cs.LockedRound` | `lockedRound[s]` | `RoundState.LockedRound` |
| `cs.LockedBlock.Hash()` | `lockedValue[s]` | hex string or `"nil"` |
| `cs.ValidRound` | `validRound[s]` | `RoundState.ValidRound` |
| `cs.ValidBlock.Hash()` | `validValue[s]` | hex string or `"nil"` |
| `evpool.State().LastBlockTime` (monotonic counter) | `validatorClock[s]` | unix timestamp truncated to ticks |

### Message Fields

| Implementation field | TLA+ field | Notes |
|---------------------|------------|-------|
| `vote.ValidatorAddress` / `proposal.signer` | `msg.source` | hex address |
| Receiver | `msg.dest` | recipient node ID |
| `vote.BlockID.Hash` | `msg.value` | hex or `"nil"` |
| `vote.Round` / `proposal.Round` | `msg.round` | |
| `proposal.POLRound` | `msg.polRound` | |
| `vote.Extension` (base64) or sentinel | `msg.ve` | `"NoVE"` for nil precommits, `"ValidVE"` / `"InvalidVE"` after VE-verification result |
| `LightClientAttackEv` / `DuplicateVoteEv` / `InvalidEv` | `msg.evtype` | for evidence-gossip messages |

### Byzantine-vote Fields

| Field | Meaning |
|-------|---------|
| `byzVote.vtype` | `"prevote"` or `"precommit"` |
| `byzVote.height` / `byzVote.round` | the (h, r) of the signed vote |
| `byzVote.oldRound` / `byzVote.newRound` | for `ByzReplaySelfVE` |
| `byzVote.value` | the BlockID this signed vote covers |
| `byzVote.ve` | vote extension byte sentinel |

`k` is the truncation length for `WALTailTruncate` events.

## Section 2: Action-to-Code Mapping

### Honest consensus events (round-1 carryover)

#### 1. EnterNewRound
- **Spec action**: `EnterNewRound(i, r)`
- **Code location**: `consensus/state.go:1066-1131`
- **Trigger point**: after `cs.Step = RoundStepNewRound` (line 1114)
- **Trace event name**: `"EnterNewRound"`
- **Fields**: state snapshot

#### 2. EnterPropose
- **Spec action**: `EnterPropose(i)`
- **Code location**: `consensus/state.go:1157-1214`
- **Trigger point**: after step transition; if proposer, after broadcast
- **Trace event name**: `"EnterPropose"`
- **Fields**: state snapshot

#### 3. ReceiveProposal
- **Spec action**: `ReceiveProposal(i, m)`
- **Code location**: `consensus/state.go:1920-1967` (`defaultSetProposal`)
- **Trigger point**: after `cs.Proposal = proposal` at line 1957
- **Trace event name**: `"ReceiveProposal"`
- **Fields**: state snapshot + msg (source, value, round, polRound)

#### 4. EnterPrevote
- **Spec action**: `EnterPrevote(i)`
- **Code location**: `consensus/state.go:1334-1420` (enterPrevote + defaultDoPrevote)
- **Trigger point**: after `signAddVote` returns
- **Trace event name**: `"EnterPrevote"`
- **Fields**: state snapshot + msg (source = self, value = vote value)

#### 5. ReceivePrevote
- **Spec action**: `ReceivePrevote(i, m)`
- **Code location**: `consensus/state.go:2269-2346`
- **Trigger point**: after `cs.Votes.AddVote` (around line 2246)
- **Trace event name**: `"ReceivePrevote"`
- **Fields**: state snapshot (capturing lock/unlock changes) + msg

#### 6. EnterPrevoteWait
- **Spec action**: `EnterPrevoteWait(i)`
- **Code location**: `consensus/state.go:1423-1440`
- **Trigger point**: after step set at line 1445
- **Trace event name**: `"EnterPrevoteWait"`
- **Fields**: state snapshot

#### 7. EnterPrecommit (5 paths)
- **Spec actions**: `EnterPrecommitNoPolka`, `…NilPolka`, `…RelockPolka`, `…NewLockPolka`, `…UnknownPolka`
- **Code location**: `consensus/state.go:1459-1603`
- **Trigger point**: after step transition and precommit broadcast
- **Trace event name**: `"EnterPrecommit"` (all 5 paths use same name; trace spec disambiguates by post-state)
- **Fields**: state snapshot (post-state lock fields disambiguate path) + msg (value, ve)

#### 8. ReceivePrecommit
- **Spec action**: `ReceivePrecommit(i, m)`
- **Code location**: `consensus/state.go:2348-2374`
- **Trigger point**: after vote added
- **Trace event name**: `"ReceivePrecommit"`
- **Fields**: state snapshot + msg (with ve sentinel reflecting VerifyVoteExtension result)
- **Notes**: VE verification at `state.go:2193-2222`; proposer skips self-verify (#5204).

#### 9. EnterPrecommitWait / HandleTimeout{Propose, Prevote, Precommit}
- **Spec actions**: `EnterPrecommitWait`, `HandleTimeoutPropose`, `HandleTimeoutPrevote`, `HandleTimeoutPrecommit`
- **Code locations**: `state.go:1584-1610`, `state.go:1003-1022`
- **Trace event names**: `"EnterPrecommitWait"`, `"HandleTimeoutPropose"`, `"HandleTimeoutPrevote"`, `"HandleTimeoutPrecommit"`
- **Fields**: state snapshot

#### 10. EnterCommit / FinalizeCommit
- **Spec actions**: `EnterCommit(i)`, `FinalizeCommit(i)`
- **Code locations**: `state.go:1620-1673`, `state.go:1704-1827`
- **Trigger points**: after `cs.Step = StepCommit` (1629) / after `updateToState` (1800)
- **Trace event names**: `"EnterCommit"`, `"FinalizeCommit"`
- **Fields**: state snapshot + decision value

#### 11. RoundSkip (prevote / precommit driven)
- **Spec actions**: `RoundSkipPrevote(i)`, `RoundSkipPrecommit(i)`
- **Code locations**: `state.go:2329-2331`, `state.go:2371-2373`
- **Trace event name**: `"RoundSkip"`
- **Fields**: state snapshot (new round)

#### 12. Crash / Recover
- **Spec actions**: `Crash(i)`, `Recover(i)`
- **Code locations**: implicit (process kill / restart); fail.Fail() points at
  `state.go:858`, `1744`, `1761`, `1784`, `1804`, `1812`; replay at `replay.go:94-166`
- **Trace event names**: `"Crash"`, `"Recover"`

### Round-2 Byzantine and BFT-extension events

#### 13. ByzEquivocate
- **Spec action**: `ByzEquivocate(s, h, r)`
- **Code location**: harness-injected (BFT category 2.1). Conceptually fires
  inside a Byzantine wrapper around `consensus/state.go:2422-2470 signVote`,
  bypassing the privval `CheckHRS` step-equality clause; reaches the message
  bus via `gossipVotesRoutine`.
- **Trigger point**: after two conflicting precommit messages have been
  posted to the broadcast queue
- **Trace event name**: `"ByzEquivocate"`
- **Fields**: state snapshot + `byzVote` (vtype="precommit", height, round,
  value=first BlockID — pair the second event's value separately if both are
  to be observed)
- **Notes**: Detection sink: `vote_set.go:218-238 NewConflictingVoteError`;
  reporter path: `state.go:2132-2149 tryAddVote` ➜ `evidence/pool.go:181-188 ReportConflictingVotes`.

#### 14. ByzSelectiveDisseminate
- **Spec action**: `ByzSelectiveDisseminate(s, h, r)`
- **Code location**: harness-injected variant of `consensus/reactor.go gossipVotesRoutine`
  that delivers `voteA` only to a partition and `voteB` only to the complement;
  exercises evidence-loss vector at the `evidence/reactor.go:1611 VoteSetBits` reconciliation.
- **Trigger point**: after the partitioned broadcast completes
- **Trace event name**: `"ByzSelectiveDisseminate"`
- **Fields**: `byzVote` (height, round); message envelope captures partition
  via the per-message `dest` set in the message bag.

#### 15. ByzAmnesia
- **Spec action**: `ByzAmnesia(s, h, r2)`
- **Code location**: harness-injected wrapper around `privval/file.go:340-355 SignVote`
  that bypasses the `sameHRS` BlockID check (only HRS monotonicity is enforced
  at `privval/file.go:100-131 CheckHRS`).
- **Trigger point**: after the privval state has been overwritten with the
  new (height, round, step, blockID) and the precommit broadcast posted
- **Trace event name**: `"ByzAmnesia"`
- **Fields**: state snapshot + `byzVote` (height, round=r2, value=new BlockID)
- **Notes**: Composes with `Crash` and `WALTailTruncate` to model the honest-but-amnesiac variant. Pair with prior `signedVotes` entry for r1.

#### 16. WALTailTruncate
- **Spec action**: `WALTailTruncate(s, k)`
- **Code location**: `consensus/state.go:2675-2708 repairWalFile`
- **Trigger point**: after `repairWalFile` truncates at the first decode
  error, write the last-good prefix length (`k` = number of records lost)
- **Trace event name**: `"WALTailTruncate"`
- **Fields**: state snapshot, `k` (records dropped)

#### 17. ByzAttachSameVEToBoth
- **Spec action**: `ByzAttachSameVEToBoth(s, h, r)`
- **Code location**: harness-injected (BFT 2.5 + 2.1). The attack uses
  `types/canonical.go:71-78 CanonicalizeVoteExtension`'s lack of BlockID
  binding: same VE-sig bytes work for both conflicting BlockIDs.
- **Trigger point**: after both precommit messages (different BlockIDs,
  same VE bytes) have been broadcast
- **Trace event name**: `"ByzAttachSameVEToBoth"`
- **Fields**: `byzVote` (height, round); two message envelopes follow

#### 18. ByzLateAddPrecommitWithBadVE
- **Spec action**: `ByzLateAddPrecommitWithBadVE(s, h, r)`
- **Code location**: harness-injected late-add into `consensus/state.go:2193-2222 addVote`
  LastCommit path, with `state/execution.go:609-665 BuildExtendedCommitInfo`
  consuming the precommit without re-verifying its VE.
- **Trigger point**: after the precommit has been appended to LastCommit at
  height h+1 (receiver has advanced past h)
- **Trace event name**: `"ByzLateAddPrecommitWithBadVE"`
- **Fields**: `byzVote` (height=h, round=r); message envelope with `ve = "InvalidVE"` and `lateAdd = true`

#### 19. ByzReplaySelfVE
- **Spec action**: `ByzReplaySelfVE(s, h, oldR, newR)`
- **Code location**: harness-injected wrapper that re-signs a vote envelope
  while reusing the previously-signed VE bytes (different round).
- **Trigger point**: after the new vote (with reused VE) is broadcast
- **Trace event name**: `"ByzReplaySelfVE"`
- **Fields**: `byzVote` (height, oldRound, newRound, value, ve)

#### 20. ByzLunaticForkHeader
- **Spec action**: `ByzLunaticForkHeader(h)`
- **Code location**: harness-injected lunatic header (BFT 2.2 + 2.7).
  The forged header has a `LastBlockID` that does not match the canonical
  chain's `chainHistory[h-1]`. Sent over the light-client gossip channel.
- **Trigger point**: after the Byzantine ≥1/3 of `nextValidators(h-1)` have
  signed the forged header
- **Trace event name**: `"ByzLunaticForkHeader"`
- **Fields**: state snapshot (height = h); HeaderMsg envelope (lastBlockID, value)

#### 21. LightClientVerify
- **Spec action**: `LightClientVerify(c, m)`
- **Code location**: `light/verifier.go:92-131 VerifyAdjacent`
- **Trigger point**: after `lightClientTrusted[c]` is updated with the
  newly-verified header (just before returning to caller)
- **Trace event name**: `"LightClientVerify"`
- **Fields**: state snapshot (lightClientTrusted height, value, validatorsHash)
- **Notes**: The bug — `VerifyAdjacent` does NOT check LastBlockID against
  the trusted header (#2252). The trace records the verifier accepting a
  lunatic-forked header.

#### 22. ByzInjectInvalidEvidence
- **Spec action**: `ByzInjectInvalidEvidence(s)`
- **Code location**: harness-injected at `evidence/reactor.go broadcastEvidenceRoutine`
  with an Evidence record whose signatures/conflict are fabricated.
- **Trace event name**: `"ByzInjectInvalidEvidence"`
- **Fields**: msg envelope (source, dest, evtype="InvalidEv")

#### 23. ByzFloodEvidence
- **Spec action**: `ByzFloodEvidence(s)`
- **Code location**: harness-injected — many valid `DuplicateVoteEvidence`
  records produced from past Byzantine equivocations.
- **Trace event name**: `"ByzFloodEvidence"`
- **Fields**: msg envelope (evtype="DuplicateVoteEv", height)
- **Notes**: Reveals pool's unbounded growth at `evidence/pool.go:297-316 addPendingEvidence`.

#### 24. EvidenceExpiryRace
- **Spec action**: `EvidenceExpiryRace(s1, s2, ev)`
- **Code location**: `evidence/reactor.go:185-206` (sender, height-only filter)
  vs `evidence/verify.go:309-317 IsEvidenceExpired` (receiver, height-AND-time).
- **Trigger point**: when sender broadcasts evidence its filter approves but
  the receiver rejects.
- **Trace event name**: `"EvidenceExpiryRace"`
- **Fields**: state snapshot + msg envelope (source=s1, dest=s2, evtype, height)

#### 25. CrashDuringConsensusBuffer
- **Spec action**: `CrashDuringConsensusBuffer(s)`
- **Code location**: crash injected between `evidence/pool.go:181-188 ReportConflictingVotes`
  and the next `pool.Update` (line 538), which would have flushed the buffer.
- **Trace event name**: `"CrashDuringConsensusBuffer"`
- **Fields**: state snapshot (post-crash: in-memory buffer cleared)

#### 26. ProposerExcludeEvidence
- **Spec action**: `ProposerExcludeEvidence(s, ev)`
- **Code location**: Byzantine proposer at `state/execution.go:114-181 CreateProposalBlock`
  fails to include `pendingEvidence` items in the block.
- **Trace event name**: `"ProposerExcludeEvidence"`
- **Fields**: state snapshot; the excluded evidence record is the most-recently
  added pending evidence at this server (verifiable from prior trace events)

#### 27. AdvanceClock
- **Spec action**: `AdvanceClock(s)`
- **Code location**: derived from `evpool.State().LastBlockTime` ticks; no
  explicit code action, but the harness emits this event each time a
  validator's reference time advances by 1 unit.
- **Trace event name**: `"AdvanceClock"`
- **Fields**: state snapshot (validatorClock)

#### 28. CommitEvidence
- **Spec action**: `CommitEvidence(i, ev)`
- **Code location**: `state/execution.go FinalizeBlock` — Misbehavior items
  applied; evidence record marked committed in `evidence/pool.go`.
- **Trace event name**: `"CommitEvidence"`
- **Fields**: state snapshot + the evidence record (offender, height, round)

#### 29. DetectEquivocation
- **Spec action**: `DetectEquivocation(i)`
- **Code location**: `consensus/state.go:2132-2149 tryAddVote` catches `*ErrVoteConflictingVotes`
- **Trace event name**: `"DetectEquivocation"`
- **Fields**: state snapshot + the conflict pair (signer, height, round, two
  block IDs)

#### 30. ProcessConsensusBuffer
- **Spec action**: `ProcessConsensusBuffer(i)`
- **Code location**: `evidence/pool.go:461-538 processConsensusBuffer`
- **Trigger point**: each iteration of the inner buffer-flush loop
- **Trace event name**: `"ProcessConsensusBuffer"`
- **Fields**: state snapshot; emit `dropped = true` when an entry was
  dropped for `height > LastBlockHeight` (pool.go:502-509)

#### 31. ByzProposeAlternating
- **Spec action**: `ByzProposeAlternating(s, blockChoice)`
- **Code location**: harness-injected variant of `defaultDecideProposal`
  (`state.go:1221-1271`) that bypasses `validValue` reuse.
- **Trigger point**: after the proposal message is broadcast
- **Trace event name**: `"ByzProposeAlternating"`
- **Fields**: state snapshot + msg envelope (value = chosen block)

#### 32. ByzPolkaForUnknownBlock
- **Spec action**: `ByzPolkaForUnknownBlock(blockX)`
- **Code location**: harness emits prevotes from a Byzantine subset for a
  BlockID the target validator does not have; reaches `state.go:1559-1577 EnterPrecommitUnknownPolka`.
- **Trace event name**: `"ByzPolkaForUnknownBlock"`
- **Fields**: msg envelope (value = blockX)

#### 33. ByzPOLRoundGtRound
- **Spec action**: `ByzPOLRoundGtRound(s)`
- **Code location**: Byzantine variant of `defaultDecideProposal` that sets
  `Proposal.POLRound >= Proposal.Round`. The check at `types/proposal.go:50-70 ValidateBasic`
  only enforces `POLRound >= -1`, allowing the bad value through.
- **Trace event name**: `"ByzPOLRoundGtRound"`
- **Fields**: state snapshot + msg envelope (polRound, round)

## Section 3: Special Considerations

### 3.1 Vote-extension capture

- `ExtendVote` (state.go:2413-2423) called inside `signVote` for non-nil precommit;
  this is where the harness records the VE bytes that get attached.
- `VerifyVoteExtension` (state.go:2196-2244 receive path) records the verification
  outcome — the harness emits `ve = "ValidVE"` or `"InvalidVE"` based on the
  ABCI response.
- For Family 3 (VE-reuse / cross-vote), the harness must capture the VE bytes
  and the (H, R, ChainID) tuple they were signed over — these are recorded
  in the `byzVote` substructure of the trace event.

### 3.2 Signed-votes shadow state

- `signedVotes[s]` in the spec models EVERY vote validator `s` has ever signed,
  including conflicting ones a Byzantine produces.
- For the harness to populate this correctly, instrument `privval/file.go:340-355 SignVote`
  to emit a sibling event each time a fresh signature is produced (`saveSigned`).
- Byzantine-controlled validators may produce signatures via a separate path
  (the BFT harness's adversary controller); these MUST also emit a corresponding
  trace event so `signedVotes` stays accurate.

### 3.3 Privval state / amnesia

- `pvLastSign` mirrors `FilePVLastSignState`. Instrument `privval/file.go:412-421 saveSigned`
  to emit the new state on every successful sign.
- For amnesia replays from `consensus/state.go:858 fail.Fail()` (the window
  between WAL write and `handleMsg`), the harness emits a `Crash` event
  IMMEDIATELY after the fail.Fail() injection point and a `Recover` event
  when the process is restarted.

### 3.4 Evidence pipeline

- `consensusBuffer[s]` is purely in-memory (`evidence/pool.go:49,538`); emit a
  `DetectEquivocation` event each time `ReportConflictingVotes` (pool.go:181-188)
  is called, and a `ProcessConsensusBuffer` event for each entry of the next
  `pool.Update` call.
- `pendingEvidence[s]` is on-disk-backed; emit on each `addPendingEvidence`
  (pool.go:297-316).
- `committedEvidence` is global; emit on `state/execution.go FinalizeBlock`
  when the application's Misbehavior slot is updated.

### 3.5 Light-client trace

- Light clients run in their own process (`light/client.go`). Instrument
  `light/verifier.go:92-131 VerifyAdjacent` to emit `LightClientVerify` AFTER
  the trusted-header update.
- `forkBranches` is the set of "alternative" header chains a Byzantine has
  signed. Emit `ByzLunaticForkHeader` from the harness's adversary controller
  *before* the header reaches the light-client gossip channel.

### 3.6 Bootstrap / initial state

- Consensus starts at `height = state.LastBlockHeight + 1`, round = 0, step = NewHeight.
- `lockedRound = -1`, `validRound = -1`, all vote maps empty.
- `pvLastSign` initially zeroed (height=0, round=0, step=newHeight, blockID=Nil).
- Light clients start with `lightClientTrusted = { height=0, value=Nil, validatorsHash="genesis" }`.
- Initial `validatorClock = 0` (advances on each block commit or `pool.Update`).

### 3.7 Serialization quirks

- BlockID hashes hex-encoded; nil maps to `"nil"` or `""`.
- Vote extensions base64-encoded; `"NoVE"` for nil precommits.
- Server IDs: use validator address hex string.
- `byzVote.value` and `msg.value` must use the same encoding as `state.lockedValue`
  for cross-check via `ValidatePostState`/`ValidatePostStateWeak`.
- `validatorClock` is an integer tick counter (not wall-clock time) to align
  with the spec's finite domain (0 .. MaxHeight+1).

### 3.8 Granularity alignment

Each spec action maps to exactly one trace event type — the trace spec
disambiguates the 5 EnterPrecommit paths by post-state lock fields.

For Byzantine actions, each trace event is emitted by the harness adversary
controller (not the consensus code), but at points that correspond to
specific implementation hook sites (e.g., a Byzantine signVote bypass emits
`"ByzEquivocate"` after BOTH conflicting signatures have been produced and
broadcast — not after the first).
