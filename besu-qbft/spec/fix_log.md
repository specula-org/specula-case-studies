# Besu QBFT — Trace Validation Fix Log

Records all spec corrections discovered during trace validation.
Each fix was verified by re-running `run_trace_validation` against all three traces.

---

## Fix #1 — DiscardAndSendAll Helper (Conflicting `messages'` Assignments)

**Error Type**: Spec Modeling Issue

**Symptom**: TLC reported "The variable messages has two different values in this state" when
HandleRoundChange processed a round change message and triggered a re-proposal.  The action
both discarded the incoming message (`Discard(m)`) and broadcast new messages (`SendAll(...)`)
— two separate `messages'` assignments in the same conjunction.

**Evidence**: In the besu implementation, `QbftBlockHeightManager.java:handleRoundChangePayload`
processes the incoming round change, and if a quorum or f+1 threshold is met, immediately
broadcasts new messages.  The incoming message is consumed from the network as part of this
single atomic step.

**Spec Change** (`base.tla`):
- **Before**: Separate `Discard(m)` and `SendAll(...)` conjuncts that both assign `messages'`.
- **After**: Added `DiscardAndSendAll(m, newMsgs)` helper that atomically replaces `messages`
  in a single assignment:
  ```tla
  DiscardAndSendAll(m, newMsgs) ==
      messages' = FoldBag(
          LAMBDA msg, bag : bag (+) SetToBag({msg}),
          messages (-) SetToBag({m}),
          SetToBag(newMsgs))
  ```
  Applied to all actions that simultaneously consume one message and send new messages:
  `HandleProposal`, `HandlePrepare`, `HandleCommit`, `HandleRoundChange`.

**Verification**: All three traces pass after this fix.

---

## Fix #2 — Model Value Nil (Record vs String Fingerprint Error)

**Error Type**: Spec Modeling Issue

**Symptom**: TLC reported a fingerprint error comparing `proposedBlock[s] /= Nil` where
`proposedBlock` held a record and `Nil` was the string `"Nil"`.  TLC cannot safely compare
records with strings for fingerprinting purposes.

**Evidence**: The besu implementation uses `null` for unset block values.  The spec modeled
this as string `"Nil"`, but records (blocks with fields `.content`, `.hash`, `.round`,
`.proposer`) cannot be fingerprint-compared to strings.

**Spec Change**:
- **`Trace.cfg` / `MC.cfg`**: Changed `Nil = "Nil"` to `Nil = Nil` (model value).
  Model values can be compared with `=`/`/=` to any type without fingerprint errors.
- **`base.tla`**: Added `IsNil` helper and replaced all direct `proposedBlock = Nil` /
  `proposedBlock /= Nil` comparisons with `IsNil(proposedBlock)` / `~IsNil(proposedBlock)`.
  Also replaced similar comparisons on `latestPrepCert`, `prepCert`, `effectivePrepCert`,
  `bestPrepared`, and `roundSummary` values.
  ```tla
  IsNil(x) == x = Nil
  ```

**Verification**: All three traces pass after this fix.

---

## Fix #3 — Ordered Comparison Guards for Model Value Nil

**Error Type**: Spec Modeling Issue

**Symptom**: After switching Nil to a model value, TLC reported "The second argument of >
should be an integer, but instead it is: Nil" on expressions like `r > currentRound[s]` when
`currentRound[s]` was Nil.

**Root Cause**: Model values cannot be used with ordered operators (`>`, `>=`, `<`, `<=`).
TLC's `\/` disjunction does NOT reliably short-circuit — `\/ currentRound[s] = Nil
\/ r > currentRound[s]` can still evaluate both branches.

**Spec Change** (`base.tla`): Replaced all `\/`-guarded ordered comparisons with
`IF-THEN-ELSE` which guarantees only one branch is evaluated:

| Location | Before | After |
|----------|--------|-------|
| `HandleProposal` round check | `\/ currentRound[s] = Nil \/ r >= currentRound[s]` | `IF currentRound[s] = Nil THEN TRUE ELSE r >= currentRound[s]` |
| `HandleRoundChange` age check | `\/ currentRound[s] = Nil \/ targetRound >= currentRound[s]` | `IF currentRound[s] = Nil THEN TRUE ELSE targetRound >= currentRound[s]` |
| `HandleRoundChange` quorum Max | `Max(@, targetRound)` | `IF @ = Nil THEN targetRound ELSE Max(@, targetRound)` |
| `RoundExpiry` future count | `r /= Nil /\ r > curRound` | `IF r = Nil THEN FALSE ELSE r > curRound` |
| `RoundExpiry` future rounds | `rv /= Nil /\ rv > curRound` | `IF rv = Nil THEN FALSE ELSE rv > curRound` |

**Verification**: All three traces pass after this fix.

---

## Fix #4 — Silent Actions (State Space Explosion)

**Error Type**: Abstraction Gap

**Symptom**: Trace validation of the `round_change` trace (55 events) caused billions of
states from combinatorial explosion.  Silent actions (spec transitions that don't consume
a trace event) were allowing any server to silently process messages, creating massive
branching.

**Evidence**: In the besu implementation, message handling is sequential per node.  Between
two logged events on node `s1`, only `s1` processes intermediate messages — other nodes'
state doesn't change between `s1`'s logged events.

**Spec Change** (`Trace.tla`): Two restrictions on silent actions:
1. Restricted all silent actions to `logline.event.nid` (the next logged event's server only)
2. Removed same-type events from each silent action's guard set (prevents silent actions
   from competing with the logged action of the same type)

```tla
\* Example: SilentBlockTimerExpiry
\* Before: fired for any server, any next event
\* After:
SilentBlockTimerExpiry ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {"HandleProposal", "HandlePrepare"}  \* NOT BlockTimerExpiry
    /\ BlockTimerExpiry(logline.event.nid)                          \* Only next event's server
    /\ UNCHANGED l
```

**Impact**: basic trace: 317K states → 110 states; round_change: completed in 4m51s (3.99M states)

**Verification**: All three traces pass after this fix.

---

## Fix #5 — TraceSpec Fairness and Completion Checking

**Error Type**: Spec Modeling Issue

**Symptom**: `TraceMatched == <>(l > Len(TraceLog))` was trivially violated because TLC
could find stuttering counterexamples from the initial state.

**Spec Change** (`Trace.tla`):
- Added weak fairness: `TraceSpec == TraceInit /\ [][TraceNext]_<<l, vars>> /\ WF_<<l, vars>>(TraceNext)`
- Added `ASSUME TLCGet("config").worker = 1` (required for temporal properties with trace validation)
- Added `NotDone == l <= Len(TraceLog)` sentinel invariant as faster alternative to temporal checking
  (violation = trace fully consumed = success)

**Verification**: All three traces pass (NotDone correctly violated = full consumption).

---

## Fix #6 — JSON Null Values in Traces

**Error Type**: Abstraction Gap

**Symptom**: TLC's `ndJsonDeserialize` failed on `null` values in the `round_change.ndjson`
trace file (e.g., `"preparedBlock": null`).

**Evidence**: Besu's `RoundChangePayload` stores `Optional<PreparedRoundMetadata>` which
serializes as `null` when empty.

**Spec Change** (`traces/round_change.ndjson`): Replaced JSON `null` with string `"Nil"`
for `preparedBlock` fields in round change events.

**Verification**: round_change trace passes after this fix.

---

## Fix #7 — MC.tla/MC.cfg Configuration Fixes

**Error Type**: Spec Modeling Issue

**Symptom**: TLC config parser error at `Proposer(h, r) == CHOOSE s \in Server : TRUE` (invalid
config file syntax) and potential runtime crash from `currentRound[s] < MaxRoundLimit` when
`currentRound[s]` is Nil (model value).

**Spec Changes**:
1. **MC.tla**: Added `MCProposer(h, r)` operator with round-robin proposer matching besu
   implementation: `validators[(height + round) % n]`
2. **MC.tla**: Added Nil guard to `MCRoundExpiry`: `/\ currentRound[s] /= Nil` before the
   `currentRound[s] < MaxRoundLimit` comparison
3. **MC.cfg**: Replaced `Proposer(h, r) == CHOOSE ...` with `Proposer <- MCProposer`
4. **MC.cfg**: Removed `SYMMETRY Symmetry` (round-robin proposer breaks symmetry)

**Verification**: MC model checking passes (51.7M distinct states, all invariants + temporal properties).

---

## Summary of Trace Validation Results

| Trace | Events | States | Depth | Time | Invariants |
|-------|--------|--------|-------|------|-----------|
| basic | 32 | 110 | 33 | <1s | Agreement, PreparedBlockIntegrity |
| round_change | 55 | 3,994,337 | 65 | 4m51s | Agreement, PreparedBlockIntegrity |
| crash_recovery | 21 | 43 | 22 | <1s | Agreement, PreparedBlockIntegrity |
