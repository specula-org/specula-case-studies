# CometBFT Trace Validation Fix Log

## Summary

Validated 4 implementation traces against the TLA+ spec (`base.tla` + `Trace.tla`). All fixes applied to base spec or trace spec to close gaps between spec and implementation.

**Traces validated:**
- `trace.ndjson` — basic consensus (1 height, all agree on v1)
- `timeout_propose_mapped.ndjson` — propose timeout (s1 times out, prevotes nil)
- `lock_and_relock_mapped.ndjson` — lock at round 0, relock at round 1
- `two_heights_mapped.ndjson` — two full height cycles (v1 at h1, v2 at h2)

**Final result:** All 4 traces pass (1504 states, 462 distinct, 0 left on queue each).

---

### Fix #1 — ReceiveProposal guard: proposal vs proposalBlock

**File:** `base.tla:277`
**Type:** Inconsistency Error (spec models the wrong variable)

**Root Cause:** `ReceiveProposal` guard checked `proposal[i] = Nil` but proposal is the full proposal record (set by EnterPropose for the proposer). For non-proposers who receive a proposal from the network, `proposalBlock[i]` is the correct guard — it tracks whether a block has been set for this round.

**Before:**
```tla
/\ proposal[i] = Nil
```

**After:**
```tla
/\ proposalBlock[i] = Nil
```

---

### Fix #2 — ReceivePrecommit missing UNCHANGED voteExtension

**File:** `base.tla` (ReceivePrecommit action)
**Type:** Inconsistency Error (missing variable assignment)

**Root Cause:** The `ReceivePrecommit` action's THEN branch (when precommit has VE and it's from another server) modified `veVerified` but didn't declare `UNCHANGED voteExtension`. TLC requires all state variables to be assigned.

**Before:**
```tla
THEN /\ veVerified' = [veVerified EXCEPT ...]
```

**After:**
```tla
THEN /\ veVerified' = [veVerified EXCEPT ...]
     /\ UNCHANGED voteExtension
```

---

### Fix #3 — Self-vote nil check in ReceivePrevoteIfLogged

**File:** `Trace.tla` (ReceivePrevoteIfLogged)
**Type:** Abstraction Gap (trace vs spec abstraction mismatch)

**Root Cause:** The self-vote detection used `prevotes[i][round[i]][i] /= Nil`, but Nil serves double duty: it means both "not voted yet" and "voted nil". In the timeout scenario, s1 prevoted nil, so `prevotes[i][round[i]][i] = Nil` was TRUE, causing the self-vote branch to not fire.

**Before:**
```tla
/\ prevotes[i][round[i]][i] /= Nil
```

**After:**
```tla
/\ step[i] = StepPrevote
```

---

### Fix #4 — SilentOtherEnterNewRound step guard too restrictive

**File:** `Trace.tla` (SilentOtherEnterNewRound)
**Type:** Abstraction Gap (trace spec too restrictive)

**Root Cause:** Only allowed entry from `{StepNewHeight, StepCommit}`, but `base.tla`'s `EnterNewRound` also allows entry when `r > round[i]` (round advancement from any step). Non-observed servers at StepPrecommit couldn't advance rounds.

**Before:**
```tla
/\ step[i] \in {StepNewHeight, StepCommit}
```

**After:**
```tla
/\ \/ step[i] \in {StepNewHeight, StepCommit}
   \/ round[ObservedNode] > round[i]
```

---

### Fix #5 — Remove SilentReceiveProposal

**File:** `Trace.tla` (SilentReceiveProposal removed from TraceNext)
**Type:** Abstraction Gap (incorrect silent action)

**Root Cause:** `SilentReceiveProposal` delivered proposals to ALL servers including the observed node. In the timeout scenario, this incorrectly gave s1 a proposal it had timed out on, causing s1 to prevote v1 instead of nil.

**Fix:** Removed `SilentReceiveProposal` entirely. The observed node's proposal reception is always explicit via `ReceiveProposalIfLogged`. Non-observed servers get proposals via `SilentOtherReceiveProposal`.

---

### Fix #6 — SilentOtherEnterPrevote event guard too narrow

**File:** `Trace.tla` (SilentOtherEnterPrevote)
**Type:** Abstraction Gap (trace spec too restrictive)

**Root Cause:** Event guard only included `{"ReceivePrevote", "EnterPrevoteWait", "EnterPrecommit"}`. Non-observed servers couldn't enter prevote before precommit/commit events, leaving them stuck at StepPropose when the trace expected their precommit messages.

**Before:**
```tla
/\ logline.event.name \in {"ReceivePrevote", "EnterPrevoteWait", "EnterPrecommit"}
```

**After:**
```tla
/\ logline.event.name \in {"ReceivePrevote", "EnterPrevoteWait", "EnterPrecommit",
                            "ReceivePrecommit", "EnterPrecommitWait", "EnterCommit"}
```

---

### Fix #7 — Nondeterministic proposal value via ChooseValue override

**Files:** `base.tla` (ChooseValue operator), `Trace.tla` (TraceChooseValue), `Trace.cfg`
**Type:** Abstraction Gap (spec's deterministic CHOOSE picks wrong value)

**Root Cause:** `CHOOSE val \in Values : TRUE` in `EnterPropose` is deterministic in TLA+ — it always returns the same value. When non-observed server s2 proposes at height 2, CHOOSE always picks v1, but the trace expects v2.

Initially fixed with `\E v \in Values` (nondeterministic), but this caused BFS state explosion with dead-end branches leading to deadlock on correct branches.

**Final fix:** Introduced overridable `ChooseValue(i)` operator:

**base.tla:**
```tla
ChooseValue(i) == CHOOSE val \in Values : TRUE

EnterPropose(i) ==
    ...
    LET v == IF validValue[i] /= Nil THEN validValue[i]
             ELSE ChooseValue(i)
```

**Trace.tla:**
```tla
TraceChooseValue(i) ==
    LET tv == TraceProposalValue(height[i], round[i])
    IN IF tv /= Nil THEN tv ELSE CHOOSE val \in Values : TRUE
```

**Trace.cfg:**
```
ChooseValue <- TraceChooseValue
```

---

### Fix #8 — FinalizeCommit not clearing vote maps

**File:** `base.tla` (FinalizeCommit)
**Type:** Inconsistency Error (real spec bug)

**Root Cause:** `FinalizeCommit` had `UNCHANGED <<voteVars, ...>>`, meaning `prevotes` and `precommits` were NOT reset when advancing height. Since votes are indexed by round (not height), votes from height 1 round 0 persisted into height 2 round 0. The `ReceivePrevote` guard `prevotes[i][m.round][m.source] = Nil` failed because stale votes from the previous height were still present.

The real implementation clears vote sets when entering a new height (state.go newStep/updateToState resets the vote set).

**Before:**
```tla
/\ UNCHANGED <<voteVars, messages, veVars, walEntries, crashed,
               evidenceVars, proposerVars, decisionVars>>
```

**After:**
```tla
/\ prevotes' = [prevotes EXCEPT ![i] = [r \in 0..MaxRound |-> EmptyVoteMap]]
/\ precommits' = [precommits EXCEPT ![i] = [r \in 0..MaxRound |-> EmptyVoteMap]]
/\ UNCHANGED <<messages, veVars, walEntries, crashed,
               evidenceVars, proposerVars, decisionVars>>
```

---
