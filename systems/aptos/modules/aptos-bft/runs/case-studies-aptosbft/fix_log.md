# Aptos BFT Trace Validation Fix Log

## Summary

Validated 1 implementation trace against the TLA+ spec (`base.tla` + `Trace.tla`). The trace covers 4 rounds of consensus with 3 servers (s1, s2, s3) running the Jolteon / 2-chain HotStuff protocol.

**Trace validated:**
- `trace.ndjson` — 4 rounds of happy-path consensus (Propose, ReceiveProposal, CastVote, ReceiveVote, FormQC per round, 64 events total)

**Final result:** Trace passes — all 64 events consumed, all 5 safety invariants hold, TraceMatched temporal property satisfied.

---

### Fix #1 — VoteSafety invariant violation: missing leader election (Case B)

**File:** `base.tla` (Propose action)
**Type:** Spec modeling issue — missing abstraction for leader election

**Root Cause:** The `Propose` action allowed any server to propose in any round, with no constraint preventing multiple proposers per round. In the implementation, `ProposerElection` ensures at most one leader per round. Without this, TLC found an 8-state counterexample where two servers proposed different values for the same round, both formed quorum, violating VoteSafety.

**Counterexample (8 states):**
1. Init
2. s1 proposes v1 for round 1
3. s2 proposes v2 for round 1 (different value, same round!)
4-8. Both proposals get votes and form QC → VoteSafety violated

**Fix:** Added `roundProposer` ghost variable to model leader election:

```tla
VARIABLE roundProposer  \* [Round -> Server \cup {Nil}]
blockVars == <<proposals, roundProposer>>

\* In Init:
/\ roundProposer = [r \in 1..MaxRound |-> Nil]

\* In Propose(s, v):
/\ roundProposer[currentRound[s]] = Nil   \* Guard: no one proposed yet
/\ roundProposer' = [roundProposer EXCEPT ![currentRound[s]] = s]  \* Record leader

\* In ReceiveProposal and all other actions:
/\ UNCHANGED roundProposer
```

---

### Fix #2 — SignCommitVote: msgs in UNCHANGED contradicts Broadcast

**File:** `base.tla:629` (SignCommitVote action)
**Type:** Inconsistency error — double assignment of `msgs`

**Root Cause:** `SignCommitVote` calls `Broadcast(...)` which sets `msgs'`, but `msgs` was also listed in the `UNCHANGED` clause. TLC caught this as a variable assignment conflict.

**Before:**
```tla
/\ UNCHANGED <<safetyVars, persistVars, roundVars, certVars,
                votesForBlock, orderVotesForBlock, timeoutVotes,
                syncInProgress, epochChangeNotified,
                commitVars, blockVars, msgs>>
```

**After:**
```tla
/\ UNCHANGED <<safetyVars, persistVars, roundVars, certVars,
                votesForBlock, orderVotesForBlock, timeoutVotes,
                syncInProgress, epochChangeNotified,
                commitVars, blockVars>>
```

---

### Fix #3 — Broadcast sends 1 copy instead of N copies

**File:** `base.tla` (Broadcast operator)
**Type:** Inconsistency error — broadcast semantics wrong

**Root Cause:** `Broadcast` used `SetToBag({Msg(...)})` which creates a bag with 1 copy of the message. With 3 servers, each `ReceiveProposal`/`ReceiveVote` calls `Discard(m)` which decrements the count by 1. After the first receiver, the message count drops to 0, preventing other servers from receiving it.

**Before:**
```tla
Broadcast(type, src, round, epoch, value) ==
    msgs' = msgs (+) SetToBag({Msg(type, src, round, epoch, value)})
```

**After:**
```tla
Broadcast(type, src, round, epoch, value) ==
    LET m == Msg(type, src, round, epoch, value)
    IN msgs' = msgs (+) (m :> Cardinality(Server))
```

---

### Fix #4 — Server IDs: model values vs strings in Trace.cfg

**File:** `Trace.cfg`
**Type:** Config error — type mismatch between JSON trace and TLC constants

**Root Cause:** The trace file contains server IDs as JSON strings (`"s1"`, `"s2"`, `"s3"`), but `Trace.cfg` originally used TLC model values (`{s1, s2, s3}`). TLC model values are atoms that don't match JSON strings, causing `ASSUME TraceServer \subseteq Server` to fail.

**Before:**
```
Server = {s1, s2, s3}
Values = {v1, v2}
Nil = Nil
```

**After:**
```
Server = {"s1", "s2", "s3"}
Values = {"v1", "v2"}
Nil = "Nil"
```

---

### Fix #5 — SilentDropMessage consuming needed messages

**File:** `Trace.tla` (SilentDropMessage removed from TraceNext)
**Type:** Abstraction gap — aggressive silent action consumes messages prematurely

**Root Cause:** `SilentDropMessage` could fire at any trace position and consume any message from `msgs`. This non-deterministically removed proposal and vote messages before `ReceiveProposalIfLogged` or `ReceiveVoteIfLogged` could consume them, causing deadlocks at early trace positions.

With the broadcast fix (#3) sending N copies per message, every message is explicitly consumed by its intended receiver. No message dropping is needed.

**Fix:** Removed `SilentDropMessage` from `TraceNext` disjunction:
```tla
\* NOTE: SilentDropMessage removed — with proper broadcast (N copies),
\* all messages are explicitly consumed by receive events.
```

---

### Fix #6 — ReceiveVoteIfLogged blocks after QC formed

**File:** `Trace.tla` (ReceiveVoteIfLogged)
**Type:** Abstraction gap — spec blocks on redundant votes

**Root Cause:** The base spec's `ReceiveVote` action has guard `~HasQuorum(votesForBlock[s][m.mround])`, which means once a QC forms (quorum reached), no more votes can be received for that round. But the implementation continues to receive votes after QC formation — they're simply ignored.

With Quorum=2 and 3 servers, the first external vote forms the QC (self-vote + 1 = quorum). The second external vote can't be processed by the base spec's ReceiveVote.

**Fix:** Added QC-already-formed skip branch:
```tla
ReceiveVoteIfLogged ==
    \E i \in Server :
        /\ IsNodeEvent("ReceiveVote", i)
        /\ "msg" \in DOMAIN logline.event
        /\ \/ \* Self-vote: already recorded
              ...
           \/ \* QC already formed: vote is redundant, skip
              /\ HasQuorum(votesForBlock[i][logline.event.msg.round])
              /\ UNCHANGED allVars
              /\ StepTrace
           \/ \* Normal: receive from network
              ...
```

---

### Fix #7 — SilentFormQC preempts FormQCIfLogged

**File:** `Trace.tla` (SilentFormQC trigger set)
**Type:** Abstraction gap — silent action races with explicit event handler

**Root Cause:** `SilentFormQC` had `"FormQC"` in its trigger set (`logline.event.name \in {"CastOrderVote", "FormOrderingCert", "FormQC"}`). When the next trace event is `FormQC`, `SilentFormQC` could fire first (forming the QC silently), then `FormQCIfLogged` would try to fire for the same QC but produce no state change (stuttering step).

**Fix:** Removed `"FormQC"` from SilentFormQC triggers — let `FormQCIfLogged` handle it explicitly:
```tla
SilentFormQC ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name \in {"CastOrderVote", "FormOrderingCert"}  \* "FormQC" removed
    ...
```

---

### Fix #8 — ValidateCertState: highestOrderedRound mismatch for FormQC events

**File:** `Trace.tla` (FormQCIfLogged + new ValidateQCState operator)
**Type:** Abstraction gap — ordering pipeline not traced

**Root Cause:** The trace has no order vote events (CastOrderVote, ReceiveOrderVote, FormOrderingCert). In the implementation, the ordering pipeline runs synchronously after QC formation, updating `highestOrderedRound`. In the spec, ordering is modeled as separate actions that don't fire during trace validation.

`ValidateCertState` checked both `highestQCRound` and `highestOrderedRound`, but `FormQC` doesn't change `highestOrderedRound` (it's in UNCHANGED). So the trace's `highestOrderedRound=1` after FormQC round 2 didn't match the spec's `highestOrderedRound=0`.

**Fix:** Split validation — use QC-only check for FormQC events:
```tla
ValidateQCState(i) ==
    /\ highestQCRound'[i] = logline.event.state.highestQCRound

ValidateCertState(i) ==
    /\ highestQCRound'[i] = logline.event.state.highestQCRound
    /\ highestOrderedRound'[i] = logline.event.state.highestOrderedRound

\* FormQCIfLogged uses ValidateQCState (not ValidateCertState)
```

---

### Fix #9 — TraceSpec missing weak fairness (trivial temporal counterexamples)

**File:** `Trace.tla` (TraceSpec)
**Type:** Spec completeness — temporal property checking requires fairness

**Root Cause:** Without `WF`, TLC finds stuttering counterexamples where the system can stutter forever at any state (including l < Len(TraceLog)), trivially violating `TraceMatched == <>[](l > Len(TraceLog))`. TLC's warning: "Temporal properties are being verified without a fairness constraint."

**Before:**
```tla
TraceSpec == TraceInit /\ [][TraceNext]_<<allVars, traceVars>>
```

**After:**
```tla
TraceSpec == TraceInit /\ [][TraceNext]_<<allVars, traceVars>>
             /\ WF_<<allVars, traceVars>>(TraceNext)
```

---

## Harness Fixes (Rust test code)

### Harness Fix A — Missing NetworkPlayground.start()

**File:** `harness/src/tla_trace_scenario.rs`
**Type:** Test infrastructure — message routing not started

**Root Cause:** The test created nodes via `NodeSetup::create_nodes()` but didn't spawn `playground.start()`, so network messages were never routed. The test timed out after 60s.

**Fix:** Added `runtime.spawn(playground.start())` after creating nodes.

---

### Harness Fix B — Optimistic proposal handling

**File:** `harness/src/tla_trace_scenario.rs`
**Type:** Test infrastructure — missing protocol variant

**Root Cause:** Starting from round 2, Aptos uses optimistic proposals (`ProposalMsgType::Optimistic`). The harness only handled normal proposals, panicking on optimistic ones.

**Fix:** Added two-step optimistic proposal processing:
```rust
ProposalMsgType::Optimistic(opt_proposal_msg) => {
    round_manager.process_opt_proposal_msg(opt_proposal_msg).await?;
    let opt_block = processed_opt_proposal_rx.next().await?;
    round_manager.process_opt_proposal(opt_block).await?;
}
```

---
