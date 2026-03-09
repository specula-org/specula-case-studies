# Autobahn BFT Bug Report

Bugs found via TLA+ model checking of the Autobahn BFT consensus protocol
(SOSP 2024, neilgiri/autobahn-artifact).

Spec: `case-studies/autobahn/spec/base.tla`
Artifact: `case-studies/autobahn/artifact/autobahn-artifact/`

---

## Bug DA-1: QC Does Not Bind to Proposal Value (CRITICAL)

**Severity**: CRITICAL — Agreement safety violation
**Family**: 1 (Proposal Binding & Equivocation)
**Found by**: MC_hunt_equivocation.cfg, BFS, 27s, 14-state counterexample

### Summary

The PrepareQC, ConfirmQC, and CommitQC do not cryptographically bind to the
proposal value. A Byzantine validator can reuse a valid QC to forge a Commit
message for an arbitrary value, causing two honest nodes to commit different
values for the same slot.

### Root Cause

In `messages.rs`, the `proposal_digest()` function is never called in the
vote hash computation. Three FIXME comments document this:

```rust
// messages.rs:128 (verify_commit)
//hasher.update(proposal_digest(consensus_message)); FIXME: ADD THIS AND DEBUG
hasher.update((0 as u8).to_le_bytes());

// messages.rs:194 (verify_confirm)
//hasher.update(proposal_digest(consensus_message)); FIXME: ADD THIS AND DEBUG
hasher.update((0 as u8).to_le_bytes());

// messages.rs:246 (ConsensusMessage::digest for Prepare)
//hasher.update(proposal_digest(self)); FIXME: ADD THIS AND DEBUG
```

The vote hash only includes `[slot, view, 0]`, not the actual proposal contents.
This means a QC for (slot=1, view=1) is valid for ANY proposal value.

### Attack Trace (14 steps)

```
1.  Init
2.  Honest leader s3 proposes v1 for (slot=1, view=1)
3.  s2 votes Prepare (prepareVotes = {s2})
4.  s3 votes Prepare (prepareVotes = {s2,s3})
5.  s4 votes Prepare (prepareVotes = {s2,s3,s4}) — quorum!
6.  Honest server sends Confirm(v1) based on PrepareQC
7.  s2 votes Confirm (confirmVotes = {s2})
8.  s4 votes Confirm (confirmVotes = {s2,s4})
9.  s3 votes Confirm (confirmVotes = {s2,s3,s4}) — ConfirmQC!
10. Honest server sends Commit(v1) based on ConfirmQC
11. s3 receives Commit(v1) and commits v1
12. Byzantine s1 sends ByzantinePrepare(v2) for same (slot=1, view=1)
13. Byzantine s1 creates Commit(v2) reusing the SAME ConfirmQC
14. s2 receives Commit(v2) and commits v2
    *** AgreementSafety VIOLATED: s3=v1, s2=v2 ***
```

### Affected Code

| File | Lines | Issue |
|------|-------|-------|
| `messages.rs` | 128 | verify_commit: proposal_digest commented out |
| `messages.rs` | 194 | verify_confirm: proposal_digest commented out |
| `messages.rs` | 246 | ConsensusMessage::digest: proposal_digest commented out |
| `core.rs` | 1231 | is_valid for Commit: only calls verify_commit (no value check) |
| `core.rs` | 1581-1607 | process_commit_message: stores proposals without validation |

### Fix

Uncomment the `proposal_digest()` calls in all three locations and ensure the
vote hash includes the proposal content. This binds the QC to the specific
value, preventing a Byzantine node from reusing a QC for a different value.

---

## Bug DA-2: Timeout Digest Hashes Nothing (CRITICAL)

**Severity**: CRITICAL — Enables forged timeout certificates
**Family**: 2 (View Change Safety)
**Found by**: Code analysis (messages.rs:1349-1358)

### Summary

`Timeout::digest()` creates a hash but does not include any meaningful fields.
The resulting digest is always the same regardless of slot, view, or evidence.
Combined with Bug DA-3 (TC verification always passes), this allows forged
Timeout Certificates.

### Root Cause

```rust
// messages.rs:1349-1359
impl Hash for Timeout {
    fn digest(&self) -> Digest {
        let mut hasher = Sha512::new();
        /*hasher.update(self.view.to_le_bytes());
        if let Some(qc_view) = self.vote_high_qc {
            hasher.update(qc_view.to_le_bytes());
        }*/

        Digest(hasher.finalize().as_slice()[..32].try_into().unwrap())
    }
}
```

All content (slot, view, high_qc, high_prop) is commented out. All Timeout
messages produce the **identical digest**. Timeouts are replayable across any
slot, view, or context.

### Affected Code

- `messages.rs:1349-1358` — Timeout::digest(): hash of empty data

---

## Bug DA-3: TC Verification Always Returns Ok (CRITICAL)

**Severity**: CRITICAL — Enables forged timeout certificates
**Family**: 2 (View Change Safety)
**Found by**: Code analysis (messages.rs:1405-1411, 1518-1546)

### Summary

`TC::verify()` always returns `Ok(())` regardless of input. The `PartialEq`
implementation for TC always returns `true`, causing `TC::genesis() == *self`
to short-circuit verification for ANY TC, even forged ones.

### Root Cause

```rust
// messages.rs:1405-1411
impl PartialEq for TC {
    fn eq(&self, other: &Self) -> bool {
        //self.hash == other.hash && self.view == other.view
        //*self.winning_proposal == *other.winning_proposal
        true    // <-- Always true!
    }
}

// messages.rs:1518-1521 (in TC::verify)
if Self::genesis(committee) == *self {
    return Ok(());    // <-- Always taken due to PartialEq
}
// ... quorum/signature checks are dead code
```

Any TC passes verification without checking quorum or signatures. A single
malicious node can create a fake TC to force a view change.

### Related: QC::PartialEq Always Returns false (Bug DA-13)

```rust
// messages.rs:1287-1292
impl PartialEq for QC {
    fn eq(&self, other: &Self) -> bool {
        false   // <-- Always false (opposite of TC!)
    }
}
```

QC genesis check is dead code (never matches). This asymmetry between
QC (always false) and TC (always true) means QC verification runs properly
but TC verification is completely bypassed.

### Affected Code

- `messages.rs:1405-1411` — TC PartialEq always true
- `messages.rs:1518-1521` — TC::verify() short-circuits on genesis check
- `messages.rs:1287-1292` — QC PartialEq always false (related)

---

## Bug DA-4: No Leader Check on Prepare Messages (CRITICAL)

**Severity**: CRITICAL — Any server can act as proposer
**Family**: 3 (Message Acceptance Guards)
**Found by**: Code analysis (core.rs:1108-1166)

### Summary

When processing a Prepare message, the code does NOT verify that the sender
is the legitimate leader for the (slot, view). Any server — including a
Byzantine one — can send a Prepare that honest nodes will accept and vote on.

### Affected Code

- `core.rs:1108-1166` — is_valid for Prepare: no `Leader(slot, view) == sender` check

---

## Bug DA-5: View Change Selects Wrong Winning View (CRITICAL)

**Severity**: CRITICAL — May select wrong value after view change
**Family**: 2 (View Change Safety)
**Found by**: Code analysis (messages.rs:1436-1499)

### Summary

In `get_winning_proposals()`, the `winning_view` is set to `timeout.view`
(the view the server timed out FROM) instead of the highQC's actual view.
This could cause the new leader to select the wrong "locked" value after
a view change.

### Root Cause

```rust
// messages.rs:1436-1499 (TC::get_winning_proposals)
for timeout in &self.timeouts {
    match &timeout.high_qc {
        Some(qc) => {
            match qc {
                ConsensusMessage::Confirm {
                    slot: _, view: other_view, qc: _, proposals,
                } => {
                    if other_view > &winning_view {
                        winning_view = timeout.view;  // BUG: should be *other_view
                        winning_proposals = proposals.clone();
                    }
                }
```

The comparison uses `other_view` (the QC's actual view) correctly, but the
assignment uses `timeout.view` (the current failed round's view). This
decouples the winning_view from the actual QC evidence.

### Affected Code

- `messages.rs:1455` — `winning_view = timeout.view` instead of `*other_view`

---

## Bug DA-6: No Duplicate Guard for Confirm Votes (CRITICAL)

**Severity**: CRITICAL — Honest server can double-vote Confirm
**Family**: 3 (Message Acceptance Guards)
**Found by**: Code analysis (core.rs:1468-1496 vs 1448)

### Summary

The Prepare handler has a duplicate voting guard via `last_voted_consensus`
(core.rs:1448). However, the Confirm handler has NO such guard. An honest
server receiving two Confirm messages for the same (slot, view) with different
values (possible due to Bug DA-1) will vote for both.

### Affected Code

- `core.rs:1448` — Prepare has `last_voted_consensus` guard
- `core.rs:1468-1496` — Confirm handler: NO duplicate guard

---

## Bug DA-14: No Commit Idempotency Check (CRITICAL)

**Severity**: CRITICAL — Can overwrite committed value
**Family**: 3 (Message Acceptance Guards)
**Found by**: Code analysis (core.rs:1581-1607)

### Summary

`process_commit_message` does not check whether a slot is already committed.
If two Commit messages arrive for the same slot with different values (possible
due to Bug DA-1), the second overwrites the first.

### Affected Code

- `core.rs:1581-1607` — process_commit_message: no `committed_slots.contains(slot)` check

---

## Model Checking Results Summary

| Config | Invariant | Result | Time | States |
|--------|-----------|--------|------|--------|
| MC_hunt_equivocation | AgreementSafety | **VIOLATED** | 27s | 856K gen, 112K distinct |
| MC_hunt_viewchange v1 | ViewChangeSafety | Invariant too strong (Case A) | 7min | 10.5M gen |
| MC_hunt_viewchange v2 | AgreementSafety | **VIOLATED** | 10min | 19.5M gen, 4.8M distinct |
| MC_hunt_guards | AgreementSafety | No violation (51M states) | 17min | 51M gen, 9.8M distinct |
| MC.cfg (standard) | All invariants | No violation (timeout) | 10min | 17M gen, 3.3M distinct |

Both AgreementSafety violations are caused by Bug DA-1 (QC not binding to value).
The guards config did not independently find AgreementSafety violations because
the guard bugs (DA-4, DA-6, DA-18) are "defense in depth" issues that amplify
the equivocation attack but don't independently break safety.

---

## Spec Modifications During Bug Hunting

### ViewChangeSafety Invariant (Case A Fix)

The original invariant referenced `messages` (which can be lost via LoseMessage):
```tla
\E m \in messages : m.mtype = ConfirmMsg /\ ...
```

Fixed to use `proposed` (persistent):
```tla
committed[s][sl] \in proposed[sl][v]
```

This ensures the invariant isn't falsified by message loss events.
