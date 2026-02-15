## 2026-02-15 - Relax leader-known precondition in accepted dependency invariant

**Trace:** `N/A (base model check: /tmp/StrictPaxosImpl.basecheck.cfg)`
**Error Type:** Inconsistency Error

**Issue:**
`InvAcceptedDepMatchesLeaderWhenNormal` was violated during base model checking.

**Root Cause:**
The invariant required dependency agreement with the leader whenever the leader was `NORMAL`, even if the leader had not yet learned the command id. In the model, a replica can be in `ACCEPT` for an id before the leader knows that id.

**Fix:**
Strengthened the antecedent guard to require `id \in knownCmds[l]` before enforcing leader-side acceptance and dependency equality.

**Files Modified:**
- `spec/StrictPaxosImpl.tla`: updated `InvAcceptedDepMatchesLeaderWhenNormal` to gate on leader knowledge of `id`.

## 2026-02-15 - Make Ack ballot invariant robust to in-flight messages

**Trace:** `N/A (base model check: /tmp/basecheck_tiny_InvAckUsesCurrentBallot.cfg)`
**Error Type:** Inconsistency Error

**Issue:**
`InvAckUsesCurrentBallot` was violated during base model checking.

**Root Cause:**
The invariant compared each in-flight Ack message ballot to the sender's current ballot via equality. After send, sender ballot can advance, so state-time equality is too strong for queued messages.

**Fix:**
Replaced strict equality checks on in-flight Ack ballots with monotonicity (`m.b <= ballot[m.from]`) and kept a separate normal-mode consistency check (`status[r] = "NORMAL" => cballot[r] = ballot[r]`).

**Files Modified:**
- `spec/StrictPaxosImpl.tla`: revised `InvAckUsesCurrentBallot` to a send-time-safe state formulation.
