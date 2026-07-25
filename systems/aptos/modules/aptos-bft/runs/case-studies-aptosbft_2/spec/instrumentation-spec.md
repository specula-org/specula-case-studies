# Instrumentation Spec — Aptos BFT (round 2)

Mapping between spec actions in `base.tla` / `Trace.tla` and the
implementation hook points where tracing should be inserted in
`aptos-core/consensus/`.

This document is consumed by the harness-generation phase.  Every spec
action that the trace spec recognizes must have an entry here.
Byzantine actions (`ByzEquivocateProposer`, `ByzEquivocateOrderVote`,
`ByzReuseRealCertificate`, `ByzForgeQCInOrderVoteMsg`,
`ByzCrossEpochReplay`, `ReceiveOrderVoteWeakEpoch`) are NOT
instrumented — they exist only in the MC adversary model.

## Section 1: Trace Event Schema

### Common envelope

```jsonc
{
  "tag":   "trace",
  "event": {
    "name":   "<spec action name>",
    "nid":    "<server id>",
    "epoch":  <int>,
    "round":  <int>,
    "state":  { /* per-action state snapshot, see Section 2 */ },
    "msg":    { /* present for message-receive events */
      "source": "<peer id>",
      "round":  <int>,
      "epoch":  <int>,
      "value":  "<block value or hash>"
    }
  }
}
```

### State fields (post-action snapshot)

| Trace field              | Spec variable                                  | Notes |
|--------------------------|------------------------------------------------|-------|
| `state.epoch`            | `volatileSafetyData[s].epoch`                  | Always captured |
| `state.lastVotedRound`   | `volatileSafetyData[s].lastVotedRound`         | Always captured |
| `state.preferredRound`   | `volatileSafetyData[s].preferredRound`         | Always captured |
| `state.oneChainRound`    | `volatileSafetyData[s].oneChainRound`          | Always captured |
| `state.highestTimeoutRound` | `volatileSafetyData[s].highestTimeoutRound` | Always captured |
| `state.highestQCRound`   | `highestQCRound[s]`                            | Captured for FormQC, ReceiveProposal |
| `state.highestOrderedRound` | `highestOrderedRound[s]`                    | Captured for FormOrderingCert |
| `state.committedRound`   | `committedRound[s]`                            | Captured for FormQC, PersistBlock |
| `state.currentRound`     | `currentRound[s]`                              | Captured for round-changing events |
| `state.proposalValue`    | `proposals[s][r]`                              | Captured for Propose, ProposeOpt, FormOrderingCert |

### Persisted state vs volatile

The trace event's `state.*` fields default to the **volatile** view
(what the in-memory `SafetyData` holds at the moment the action
completes).  The `CompletePersistVote` and `SignTimeout` events
ALSO emit a `state.persisted.*` sub-object reflecting
`persistedSafetyData[s]` after `set_safety_data` returns.

```jsonc
"state": {
  "epoch": 1,
  "lastVotedRound": 3,
  ...
  "persisted": {
     "epoch": 1,
     "lastVotedRound": 3,
     "highestTimeoutRound": 0
  }
}
```

The trace spec uses `ValidatePersistedState` for CompletePersistVote
and SignTimeout, and `ValidateSafetyState` for all other safety-data
mutators.

## Section 2: Action-to-Code Mapping

### Propose
- **Spec action**: `Propose(s, v)`
- **Code location**: `consensus/src/round_manager.rs:532-600`
  (`generate_and_send_proposal`)
- **Trigger point**: **after** the proposal has been signed and broadcast
- **Trace event name**: `"Propose"`
- **Fields**: envelope + `state.currentRound`, `state.proposalValue`
- **Notes**: matches the regular (BLS-signed) proposal path only.

### ProposeOpt
- **Spec action**: `ProposeOpt(s, v)`
- **Code location**: `consensus/src/round_manager.rs:820-913`
  (`process_optimistic_proposal`)
- **Trigger point**: **after** the OptProposalMsg is shipped
- **Trace event name**: `"ProposeOpt"`
- **Fields**: envelope + `state.currentRound`, `state.proposalValue`
- **Notes**: distinct event from `Propose` because Family 7 hinges on
  the missing BLS signature on `block_data`.

### ReceiveProposal
- **Spec action**: `ReceiveProposal(s, m)`
- **Code location**: `consensus/src/round_manager.rs:1127-1307`
  (`process_proposal`)
- **Trigger point**: **after** `ensure_round_and_sync_up` returns Ok
  and before the safety-rules signing call
- **Trace event name**: `"ReceiveProposal"`
- **Fields**: envelope + `msg.{source,round,epoch,value}` +
  `state.currentRound`

### SignVote (split point #1)
- **Spec action**: `SignVote(s)`
- **Code location**:
  `consensus/safety-rules/src/safety_rules_2chain.rs:88-89`
  (after `self.sign(&ledger_info)?` returns; before
  `set_safety_data` on line 92)
- **Trigger point**: **between** the `sign(...)` call and
  `set_safety_data`; this is the load-bearing instrumentation point
  for Family 1.  The event captures `state.lastVotedRound` AFTER the
  in-memory mutation at safety_rules.rs:225 (volatile) but BEFORE the
  persist.
- **Trace event name**: `"SignVote"`
- **Fields**: envelope + all volatile safety-state fields
- **Notes**: the harness must capture an instant where `last_voted_round`
  is bumped in memory but the disk write has not started.  If
  instrumentation cannot insert exactly here (e.g., the SafetyRules
  RPC backend is a separate process), a synthetic split via a
  fault-injection flag at safety_rules_2chain.rs:88 will work — the
  MC spec only requires *some* trace where SignVote precedes
  CompletePersistVote.

### CompletePersistVote (split point #2)
- **Spec action**: `CompletePersistVote(s)`
- **Code location**:
  `consensus/safety-rules/src/safety_rules_2chain.rs:92`
  (immediately after `self.persistent_storage.set_safety_data(safety_data)?`)
- **Trigger point**: **after** `set_safety_data` returns Ok
- **Trace event name**: `"CompletePersistVote"`
- **Fields**: envelope + `state.persisted.*`
- **Notes**: required for the Family 1 sign-then-persist gap.  Pair
  with SignVote (above).

### ReceiveVote
- **Spec action**: `ReceiveVote(s, m)`
- **Code location**: `consensus/src/round_manager.rs:1743-1793`
  (`process_vote`)
- **Trigger point**: **after** the vote has been added to
  `pending_votes`
- **Trace event name**: `"ReceiveVote"`
- **Fields**: envelope + `msg.{source,round,epoch,value}`

### FormQC
- **Spec action**: `FormQC(s, r)`
- **Code location**: `consensus/src/round_manager.rs:1802-1837`
  (`process_vote_reception_result`, `NewQuorumCertificate` branch)
- **Trigger point**: **after** the QC is inserted into the block store
- **Trace event name**: `"FormQC"`
- **Fields**: envelope + `state.highestQCRound`,
  `state.committedRound`, `state.currentRound`

### SignOrderVote
- **Spec action**: `SignOrderVote(s, r)`
- **Code location**:
  `consensus/safety-rules/src/safety_rules_2chain.rs:97-119`
  (`guarded_construct_and_sign_order_vote`)
- **Trigger point**: **after** the order vote has been signed AND
  `set_safety_data` (:117) has returned Ok
- **Trace event name**: `"SignOrderVote"`
- **Fields**: envelope + all volatile safety-state fields
- **Notes**: unlike SignVote, the order-vote path persists after
  signing AS A SINGLE STEP (`:117` is the only persist).  We treat
  this as atomic in the spec (single action) because the brief's
  Family 2 mechanism is the *missing guards* (no last_voted_round
  read or update), not a crash window.

### ReceiveOrderVote
- **Spec action**: `ReceiveOrderVote(s, m)`
- **Code location**: `consensus/src/round_manager.rs:1582-1660`
  (`process_order_vote_msg`)
- **Trigger point**: **after** the order vote has been inserted into
  `pending_order_votes`
- **Trace event name**: `"ReceiveOrderVote"`
- **Fields**: envelope + `msg.{source,round,epoch,value}`

### FormOrderingCert
- **Spec action**: `FormOrderingCert(s, r, v)`
- **Code location**: `consensus/src/round_manager.rs:1918-1944`
  (`process_order_vote_reception_result`, `NewLedgerInfoWithSignatures`)
- **Trigger point**: **after** the ordering cert is dispatched to
  the BufferManager
- **Trace event name**: `"FormOrderingCert"`
- **Fields**: envelope + `state.highestOrderedRound`,
  `state.proposalValue`

### SignTimeout
- **Spec action**: `SignTimeout(s)`
- **Code location**:
  `consensus/safety-rules/src/safety_rules_2chain.rs:47-49`
  (after `set_safety_data` at :47 AND `self.sign(&timeout.signing_format())?`
  at :49)
- **Trigger point**: **after** both persist and sign — these happen
  in the safety-fix order (persist BEFORE sign, the canonical fix from
  commit `f58e184471`).  The event therefore captures the post-persist
  state.
- **Trace event name**: `"SignTimeout"`
- **Fields**: envelope + `state.persisted.{lastVotedRound, highestTimeoutRound}`

### EchoTimeout
- **Spec action**: `EchoTimeout(s)`
- **Code location**: `consensus/src/round_manager.rs:1855-1857`
  (timeout echo branch in the timeout handler)
- **Trigger point**: **after** the echoed timeout has been broadcast
- **Trace event name**: `"EchoTimeout"`
- **Fields**: envelope + volatile safety-state
- **Notes**: required to exercise MC-7.  Echo timeouts re-enter
  `guarded_sign_timeout_with_qc` with the same round; the safety check
  `round >= last_voted_round` at :37-42 permits equality.

### ReceiveTimeout
- **Spec action**: `ReceiveTimeout(s, m)`
- **Code location**: `consensus/src/round_manager.rs:1876-1916`
  (`process_round_timeout_msg`)
- **Trigger point**: **after** the timeout has been inserted into
  pending timeouts
- **Trace event name**: `"ReceiveTimeout"`
- **Fields**: envelope + `msg.{source,round,epoch,value}`

### FormTC
- **Spec action**: `FormTC(s, r)`
- **Code location**: `consensus/src/round_manager.rs:1839-1841, 2026-2036`
  (`New2ChainTimeoutCertificate` branch)
- **Trigger point**: **after** TC is inserted into block store
- **Trace event name**: `"FormTC"`
- **Fields**: envelope + `state.currentRound`

### SignCommitVote
- **Spec action**: `SignCommitVote(s, r, e)`
- **Code location**: `consensus/safety-rules/src/safety_rules.rs:372-418`
  (`guarded_sign_commit_vote`)
- **Trigger point**: **after** the commit vote is signed and shipped
  to the BufferManager
- **Trace event name**: `"SignCommitVote"`
- **Fields**: envelope + `state.epoch` (the `new_ledger_info` epoch)
- **Notes**: the spec action takes `e` as a separate argument so the
  trace can drive Family 3 / MC-5 (epoch mismatch); on honest
  traces, `e == volatileSafetyData[s].epoch` always.

### ReceiveCommitVote
- **Spec action**: `ReceiveCommitVote(s, m)`
- **Code location**: `consensus/src/pipeline/buffer_manager.rs:736-800`
  (`process_commit_message`)
- **Trigger point**: **after** the commit vote has been added to the
  buffer item
- **Trace event name**: `"ReceiveCommitVote"`
- **Fields**: envelope + `msg.{source,round,epoch,value}`

### Pipeline events

| Spec action | Code location | Trigger point | Trace event |
|---|---|---|---|
| `ExecuteBlock(s, r)` | `consensus/src/pipeline/buffer_manager.rs` (execution-wait phase completion) | after the executed-result future resolves Ok | `"ExecuteBlock"` |
| `AggregateCommitVotes(s, r)` | `consensus/src/pipeline/buffer_item.rs:237-255` (`try_advance_to_aggregated`) | after the buffer item transitions to Aggregated | `"AggregateCommitVotes"` |
| `PersistBlock(s, r)` | `consensus/src/pipeline/persisting_phase.rs:65-79` | after `commit_blocks` persists the LedgerInfo | `"PersistBlock"` |
| `ResetPipeline(s)` | `consensus/src/pipeline/buffer_manager.rs:546-570` (`reset`) | after the channel reset completes | `"ResetPipeline"` |

### EpochChange
- **Spec action**: `EpochChange(s)`
- **Code location**: `consensus/safety-rules/src/safety_rules.rs:265-344`
  (`guarded_initialize`, `Ordering::Less` branch)
- **Trigger point**: **after** `set_safety_data(SafetyData::new(new_epoch, 0, 0, 0, None, 0))` at :296-303
- **Trace event name**: `"EpochChange"`
- **Fields**: envelope + `state.epoch`

### Recover (Family 1)
- **Spec action**: `Recover(s)`
- **Code location**: `consensus/src/recovery_manager.rs:120-170`
  (`RecoveryManager::start` success branch) — note this currently
  calls `process::exit(0)` at :154-157; the harness must observe
  the *next* process start as the recover boundary.
- **Trigger point**: at SafetyRules construction following a
  process restart (`new` + `initialize`)
- **Trace event name**: `"Recover"`
- **Fields**: envelope + `state.persisted.*`
- **Notes**: there is no in-process Recover event because of the
  `process::exit(0)` at recovery_manager.rs:154; the harness must
  treat the first event after process boot as a Recover boundary.
  See Section 3.

## Section 3: Special Considerations

### Recovery boundary (`process::exit(0)`)

`RecoveryManager::start` exits the entire process on successful
recovery (`recovery_manager.rs:154-157`).  The trace harness must
therefore:

1. emit a single "process boundary" record when the operator
   restarts the binary;
2. synthesize a Recover event at the new process's first
   SafetyRules::initialize call;
3. drop any in-flight messages from the prior epoch (the in-process
   queue is destroyed on exit).

### Sign-then-persist window (Family 1)

The instrumentation for `SignVote` (before persist) and
`CompletePersistVote` (after persist) requires *two* hook points
inside `guarded_construct_and_sign_vote_two_chain`.  If the
SafetyRules backend is `ProcessService`, the IPC boundary already
serves as a natural split — capture one event before the IPC reply
and one after the persist syscall.  For the `SerializerService`
backend, manual splits at safety_rules_2chain.rs:88 and :92 are
required.

### Order-vote vs regular-vote asymmetry (Family 2)

The trace harness must NOT collapse `SignVote` and `SignOrderVote`
into a single "Vote" event.  The brief's Family 2 mechanism depends on
both being distinct in the trace so the spec can validate that an
honest node did or did not check `last_voted_round` per path.

### `lastVote` field handling

`SafetyData::last_vote` is an `Option<Vote>` in the implementation.  In
the trace, the `state.lastVote` field carries either `null` or
`{round: N, value: "..."}`.  The spec normalises both forms via
`TraceValue`.

### Cross-epoch artifacts (Family 4)

Cross-epoch replay (MC-6, `ByzCrossEpochReplay`) is NOT instrumented:
honest validators never replay a message into a different epoch.  The
MC spec handles this entirely in the model.

### Self-vote handling

Both `SignVote` and `ReceiveVote` cover the local-self path
(`votesForBlock[s][r]` already contains `s` after SignVote).  The
trace spec includes a "skip self" disjunct in `ReceiveVoteIfLogged`
and `ReceiveOrderVoteIfLogged` to avoid double-counting.

### Optimistic-proposal (Family 7)

`OptProposalMsg` carries no signature on `block_data`; the harness
should capture the *sender* (sender of the OptProposalMsg) and the
*claimed_proposer* (the `block_data.proposer` field) as distinct in
the trace so that `process_proposal` can validate
`sender == claimed_proposer`.  If the two diverge in a trace, the
spec catches it via `Propose`'s `roundProposer[r] = Nil` precondition
failing (only ONE proposer per round is allowed in the spec).

### Bootstrap state

`TraceInit == Init` matches the standard initial state.  If the
implementation under test starts mid-epoch (e.g., from a snapshot),
the harness must emit a synthetic `Recover` event as the first
trace record carrying the persisted state.
