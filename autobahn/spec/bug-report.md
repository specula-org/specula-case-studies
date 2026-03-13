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
**MC confirmed**: MC_hunt_da23.cfg, simulation, 1s, 26-state counterexample (AgreementSafety violated)

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
**MC confirmed**: MC_hunt_da23.cfg, simulation, 1s, 26-state counterexample (AgreementSafety violated)

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
**MC confirmed**: MC_hunt_da5v2.cfg, simulation, 1s, 28-state counterexample (ViewChangeSafety violated)

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

## Bug DA-27: HashMap Iteration Causes Non-Deterministic Commit Order (HIGH)

**Severity**: HIGH — Replicas derive different total orders
**Family**: 6 (Commit Ordering Determinism)
**Found by**: MC_hunt_ordering.cfg, BFS, <1s, 9-state counterexample
**Author confirmed**: Known bug — "proposals should be a BTreeMap instead of a HashMap"

### Summary

When a slot is committed, the Committer processes proposal lanes by iterating
over `HashMap<PublicKey, Proposal>`. HashMap iteration order is non-deterministic
(depends on internal hash state). Different replicas process the same proposal
lanes in different order, producing different total orders for committed headers.

This violates the fundamental SMR (State Machine Replication) requirement that
all replicas execute operations in the same total order.

### Root Cause

```rust
// committer.rs:132-133 (process_commit_message)
ConsensusMessage::Commit { slot: _, view: _, qc: _, proposals } => {
    for (pk, proposal) in proposals {  // HashMap — non-deterministic!
        // ... fetch headers for this lane and send to tx_output
    }
}
```

The `proposals` field is `HashMap<PublicKey, Proposal>` (messages.rs:101,107,113).
Each entry represents one validator's "lane" — a chain of headers to deliver.
The iteration order determines which validator's headers are committed first.

### Counterexample Trace (9 steps)

```
1.  Init
2.  s1 enters slot 1 (view=1)
3.  s3 (leader) sends Prepare(v1)
4.  s1 votes Prepare
5.  s2 votes Prepare
6.  s4 votes Prepare → 4/4 = fast quorum
7.  s1 sends FastCommit(v1)
8.  s1 receives Commit → commitOrder = <<s1, s2, s3, s4>>
9.  s2 receives Commit → commitOrder = <<s1, s2, s4, s3>>
    *** ExecutionOrderAgreement VIOLATED ***
```

No Byzantine behavior required. The bug occurs in a completely honest execution.

### Related: Latent Bug in proposal_digest()

The `proposal_digest()` function (messages.rs:210-231) also iterates over
`HashMap<PublicKey, Proposal>`. If Bug DA-1 is fixed by uncommenting
`proposal_digest()` calls WITHOUT also changing HashMap to BTreeMap,
different replicas will compute different digests for the same proposal set,
breaking QC verification.

### Affected Code

| File | Lines | Issue |
|------|-------|-------|
| `committer.rs` | 132-133 | Iterates HashMap for commit execution order |
| `messages.rs` | 96-115 | ConsensusMessage proposals field is HashMap |
| `messages.rs` | 210-231 | proposal_digest() iterates HashMap for hashing |

### Fix

Replace `HashMap<PublicKey, Proposal>` with `BTreeMap<PublicKey, Proposal>`
in the `ConsensusMessage` enum (messages.rs:101,107,113). BTreeMap iterates
in key order (deterministic), ensuring all replicas derive the same total order.

---

## Bug DA-7: handle_tc() Is a Near-No-Op (MEDIUM)

**Severity**: MEDIUM — Liveness violation, non-leader nodes stuck after view change
**Family**: 2 (View Change Safety)
**Found by**: Code analysis (core.rs:1916-1922)

### Summary

`handle_tc()` does not verify the TC, does not update the node's view, and does
not start a new timer. It only calls `generate_prepare_from_tc()`, which is
leader-only. Non-leader nodes that receive a TC do nothing — they remain in the
old view and cannot participate in the new view's consensus.

### Root Cause

```rust
// core.rs:1916-1922
fn handle_tc(&mut self, tc: TC) {
    // No TC verification (relies on DA-3's broken TC::verify())
    // No view update: self.views.insert(slot, new_view)
    // No timer restart for new view
    self.generate_prepare_from_tc(tc);  // Only useful for leader
}
```

A correct implementation should: (1) verify the TC, (2) update the node's view
to `tc.view + 1`, (3) restart the consensus timer for the new view.

### Affected Code

- `core.rs:1916-1922` — handle_tc(): missing TC verification, view update, and timer start

---

## Bug DA-8: No Committed-Slot Check on Prepare Voting (MEDIUM)

**Severity**: MEDIUM — Defense-in-depth violation
**Location**: `core.rs:1108-1166` (`is_valid` for Prepare), `core.rs:1452-1517` (`process_prepare_message`)

### Summary

`is_valid()` for Prepare does not check whether the slot has already been
committed. An honest node that has committed value v1 for slot s will still
accept and vote for new Prepare messages targeting slot s. The final validity
check (line 1211) only verifies duplicate voting and view, not commit status:

```rust
!self.last_voted_consensus.contains(&(*slot, *view)) && ticket_valid && self.views.get(slot).unwrap() == view
// Missing: && !self.committed_slots.contains_key(slot)
```

### Impact

In any correct BFT implementation, a node should skip voting on already-committed
slots. While this does not independently cause a safety violation (with DA-3
fixed, TC verification prevents conflicting proposals), it is unnecessary work
and violates the principle that committed state is final.

---

## Bug DA-9: Header Digest Excludes Consensus Messages (HIGH)

**Severity**: HIGH — Enables dissemination-layer equivocation
**Family**: 1 (Proposal Binding & Equivocation)
**Found by**: Code analysis (messages.rs:570-593)

### Summary

`Header::digest()` does not include the `consensus_messages` field in the hash.
A Byzantine proposer can create two headers with identical digests but different
embedded consensus messages, enabling equivocation at the DAG dissemination layer.

### Root Cause

```rust
// messages.rs:570-593 (Header::digest)
fn digest(&self) -> Digest {
    let mut hasher = Sha512::new();
    hasher.update(&self.author);
    hasher.update(self.height.to_le_bytes());
    for (x, y) in &self.payload {
        hasher.update(x);
        hasher.update(y.to_le_bytes());
    }
    hasher.update(&self.parent_cert.header_digest);

    //TODO: Sign Consensus Messages too.
    //     // for (dig, _) in &self.consensus_messages {
    //     //     hasher.update(dig);
    //     // }

    Digest(hasher.finalize().as_slice()[..32].try_into().unwrap())
}
```

The `consensus_messages` field (`HashMap<Digest, ConsensusMessage>`, line 432)
carries Prepare/Confirm/Commit messages embedded in the header. Since these are
excluded from the digest, the header signature does not cover consensus content.

### Attack

1. Byzantine proposer creates Header H with `consensus_messages = {Prepare(v1)}`
2. Peers vote on H based on its digest (which only covers author, height, payload, parent)
3. Byzantine creates H' with same (author, height, payload, parent) but `consensus_messages = {Prepare(v2)}`
4. H and H' have the **same digest and same valid signature**
5. Byzantine sends H to some peers, H' to others — equivocation at the dissemination layer

### Affected Code

- `messages.rs:570-593` — Header::digest(): consensus_messages excluded from hash
- `messages.rs:432` — Header struct: `consensus_messages: HashMap<Digest, ConsensusMessage>`

### Fix

Uncomment the consensus_messages hashing loop in `Header::digest()` so the
header digest (and thus signature) binds to the embedded consensus content.

---

## Bug DA-11: panic! Crashes Node on QC ID Mismatch (HIGH)

**Severity**: HIGH — Remote node crash (DoS)
**Family**: 3 (Message Acceptance Guards)
**Found by**: Code analysis (messages.rs:159)

### Summary

In `verify_commit()`, the slow-path QC ID check uses `panic!("ids don't match")`
instead of `return false`. A Byzantine node can craft a Commit message with a
mismatched QC ID, causing any honest node that receives it to crash.

### Root Cause

```rust
// messages.rs:134-164 (verify_commit)
if qc.votes.len() == committee.size() {  // Fast path (3f+1)
    if prepare_id != qc.id {
        return false;                     // Correct: returns false
    }
} else {                                  // Slow path (2f+1)
    if confirm_id != qc.id {
        panic!("ids don't match");        // BUG: crashes the node!
        return false;                     // Dead code
    }
}
```

The fast path (line 138) correctly returns `false` on ID mismatch. The slow path
(line 159) panics instead, crashing the entire node process.

### Attack

A Byzantine node sends a Commit message with a valid-looking but mismatched QC
(slow-path size, wrong ID). Every honest node that processes this message will
panic and crash. This is a remote denial-of-service attack requiring only a
single Byzantine node.

### Affected Code

- `messages.rs:159` — `panic!("ids don't match")` instead of `return false`

### Fix

Replace `panic!("ids don't match")` with `return false` to match the fast-path
behavior.

---

## Bug DA-20: Commit Not Stored for Retry on Missing Proposals (HIGH)

**Severity**: HIGH — Liveness violation, possible permanent stall
**Family**: 5 (Message Delivery & Retry)
**Found by**: Code analysis (core.rs:1581-1607)

### Summary

When `process_commit_message()` receives a Commit but the referenced proposal
headers have not yet been synced locally, the message is not persisted. It relies
on an asynchronous loopback mechanism to retry, but if the loopback fails (channel
full, node restart, etc.), the Commit is permanently lost.

### Impact

A node that loses a Commit message will never learn that the slot was committed.
It cannot advance to subsequent slots that depend on this commitment (slot s+K
requires slot s committed). If multiple nodes lose the same Commit, the protocol
can permanently stall.

### Affected Code

- `core.rs:1581-1607` — process_commit_message: no persistent storage before async retry

### Fix

Persist the Commit message to durable storage before attempting async proposal
fetching, so it can be retried after any transient failure.

---

## Bug DA-22: tokio::select! Priority Bias Starves Timers (HIGH)

**Severity**: HIGH — Liveness violation under adversarial conditions
**Family**: 5 (Message Delivery & Retry)
**Found by**: Code analysis (core.rs:2067-2172)

### Summary

The main event loop uses `tokio::select!` with network messages as the first
branch and timers as the last. When multiple branches are ready simultaneously,
`tokio::select!` preferentially matches earlier branches. Under high message load
(e.g., a Byzantine leader flooding garbage), the timer branch is starved and
view change timeouts never fire.

### Root Cause

```rust
// core.rs:2067-2172
tokio::select! {
    msg = self.rx_network.recv() => { ... },    // Priority 1: network
    msg = self.rx_proposer.recv() => { ... },   // Priority 2: proposer
    msg = self.rx_loopback.recv() => { ... },   // Priority 3: loopback
    timer = self.timer_futures.next() => { ... } // Priority 4: timers (starved!)
}
```

### Impact

A Byzantine leader can prevent honest nodes from ever triggering a view change
by flooding them with messages. The nodes cannot escape the Byzantine leader's
view, violating liveness. This is exploitable without any cryptographic forgery —
just network-level message flooding.

### Fix

Use `tokio::select!` with `biased;` removed or use a fair scheduling strategy
(e.g., process timers in a separate task, or alternate priority each iteration).

---

## Bug DA-17: clean_slot_periods() Deletes Future Slot State (MEDIUM)

**Severity**: MEDIUM — Liveness violation when K > 1
**Family**: 4 (Garbage Collection)
**Found by**: Code analysis (core.rs:1674-1690)

### Summary

`clean_slot_periods()` uses a retain predicate with `&&` instead of `||`, causing
it to delete consensus state for ALL future slots (s > committed slot), not just
completed slots in the same period. When K > 1 (concurrent slots), committing one
slot destroys in-progress state for other active slots.

### Root Cause

```rust
// core.rs:1681-1686
self.consensus_instances.retain(|(s, _), _| s % k != slot_period && s <= &slot);
self.consensus_cancel_handlers.retain(|s, _| s % k != slot_period && s <= &slot);
self.qc_makers.retain(|(s, _), _| s % k != slot_period && s <= &slot);
```

The retain predicate keeps entries where BOTH conditions hold:
1. `s % k != slot_period` (different period)
2. `s <= slot` (not in the future)

This means entries with `s > slot` are ALWAYS deleted regardless of period.
With K=3, committing slot 5 deletes consensus instances for slots 6, 7, 8, etc.

### Fix

Change `&&` to `||` so only same-period past entries are deleted:
```rust
self.consensus_instances.retain(|(s, _), _| s % k != slot_period || s > &slot);
```

This keeps entries that are either in a different period OR in the future.

### Affected Code

- `core.rs:1681` — consensus_instances retain
- `core.rs:1682` — consensus_cancel_handlers retain
- `core.rs:1686` — qc_makers retain

---

## Bug DA-23: enough_coverage() Panics on Missing Key (MEDIUM)

**Severity**: MEDIUM — Conditional remote node crash (DoS)
**Family**: 3 (Message Acceptance Guards)
**Found by**: Code analysis (core.rs:1561-1578)

### Summary

`enough_coverage()` calls `prepare_proposals.get(&pk).unwrap()` without checking
if the key exists. If a Byzantine leader constructs a Prepare message with an
incomplete proposals map (missing some validators' keys), any honest node that
is the leader of the next slot will panic when evaluating coverage.

### Root Cause

```rust
// core.rs:1572-1575
let new_tips: HashMap<&PublicKey, &Proposal> = current_proposals
    .iter()
    .filter(|(pk, proposal)| proposal.height > prepare_proposals.get(&pk).unwrap().height)
    //                                                                      ^^^^^^^^^ panic!
    .collect();
```

`current_proposals` contains all validators' keys (local state). If
`prepare_proposals` (from received Prepare message) is missing a key,
`unwrap()` panics.

### Affected Code

- `core.rs:1574` — `prepare_proposals.get(&pk).unwrap()` without None check

### Fix

Replace `.unwrap()` with `.unwrap_or(&default)` or skip missing keys, or
validate that `prepare_proposals` contains all required keys before calling
`enough_coverage()`.

---

## ~~DA-28~~: Missing Vote Lock Check (RETRACTED — Not an Independent Bug)

**Status**: RETRACTED after code audit (Phase 1 of bug confirmation)

### What MC Found

MC_noDA1 (DA-1 fixed spec variant) found AgreementSafety violation via a
21-state counterexample: Byzantine sends Prepare(v2, view=2) without TC,
honest servers vote for v2 (no lock check), conflicting commits occur.

### Why It's Not a Real Bug

Code audit revealed our spec's `ByzantinePrepare` was **unfaithful to the code**:

1. **`is_valid` enforces TC for view > 1** (`core.rs:1200`):
   `ticket_valid = ticket_valid && *view == 1` — Prepare without TC is
   rejected for any view > 1. Our spec did not model this constraint.

2. **With a fake TC?** DA-3 (TC::verify always passes) would allow a fake TC,
   making the attack possible. But this is just DA-3's consequence, not a new bug.

3. **If DA-3 is fixed**: Byzantine needs a real TC (2f+1 valid timeout sigs).
   Real TC's `get_winning_proposals()` returns the locked value (v1). Lines
   1172-1176 of `is_valid` enforce proposals match winning_proposals. Byzantine
   leader **cannot propose v2** — forced to propose v1.

**Conclusion**: The missing lock check in `ReceivePrepare` is a defense-in-depth
weakness, but the lock is effectively enforced via TC verification +
`get_winning_proposals()` + proposals matching check. Once DA-3 is fixed, this
code path has no independent safety impact. The MC violation was a spec fidelity
false positive.

---

## Model Checking Results Summary

| Config | Invariant | Result | Time | States |
|--------|-----------|--------|------|--------|
| MC_hunt_equivocation | AgreementSafety | **VIOLATED** | 27s | 856K gen, 112K distinct |
| MC_hunt_viewchange v1 | ViewChangeSafety | Invariant too strong (Case A) | 7min | 10.5M gen |
| MC_hunt_viewchange v2 | AgreementSafety | **VIOLATED** | 10min | 19.5M gen, 4.8M distinct |
| MC_hunt_guards | AgreementSafety | No violation (51M states) | 17min | 51M gen, 9.8M distinct |
| MC.cfg (standard) | All invariants | No violation (timeout) | 10min | 17M gen, 3.3M distinct |
| MC_hunt_ordering | ExecutionOrderAgreement | **VIOLATED** | <1s | 1K gen, 361 distinct |
| MC_hunt_nolock (DA-1 fixed) | AgreementSafety | **VIOLATED** | <2min | 146M gen, 2.1M distinct |
| MC_hunt_da23 (DA-1 fixed) | AgreementSafety | **VIOLATED** | 1s | 424K gen (simulation) |
| MC_hunt_da5v2 (DA-1 fixed) | ViewChangeSafety | **VIOLATED** | 1s | 22K gen (simulation) |

The first two AgreementSafety violations are caused by Bug DA-1.
The MC_hunt_nolock violation was RETRACTED after code audit: the spec's
ByzantinePrepare did not model the TC requirement for view > 1 (core.rs:1200).
The attack only works if DA-3 is also present (fake TC passes verification).

### DA-2+DA-3 Attack Trace (26 steps, MC_hunt_da23.cfg)

With DA-1 fixed, Byzantine exploits DA-2/DA-3 (forgeable timeouts + broken TC verification)
plus Byzantine vote injection to break AgreementSafety:

```
View 1:
  s1(Byz) injects ByzantineVotePrepare(v2) → prepareVotesFor[v2] = {s1}
  s3(honest leader) proposes v2 via SendPrepare
  s3, s4 vote Prepare(v2) → prepareVotesFor[v2] = {s1,s3,s4}
  s1(Byz) sends ByzantinePrepare(v2) to provide message for s2
  s2 votes Prepare(v2) → fast quorum (4/4)
  s4 sends FastCommit(v2) → CommitMsg(v2, view=1)
  s2 receives CommitMsg(v2) → committed[s2] = v2

View change:
  s2, s4 timeout from view 1; s3 timeouts from view 2
  s1(Byz) injects ByzantineVotePrepare(v1, view 2) × 2

View 2:
  s4(honest leader) proposes v1
  s1(Byz) injects ByzantineVotePrepare(v1, view 2)
  s2, s3, s4 vote Prepare(v1) → fast quorum (4/4)
  s4 sends FastCommit(v1) → CommitMsg(v1, view=2)
  s4 receives CommitMsg(v2, view=1) → committed[s4] = v2
  s2 receives CommitMsg(v1, view=2) → committed[s2] = v1 (overwrites v2! DA-14)

Final: s2=v1, s4=v2 → AgreementSafety VIOLATED
```

### DA-5 Attack Trace (28 steps, MC_hunt_da5v2.cfg)

With DA-1 fixed, Byzantine exploits DA-2/DA-3 + DA-8 (no committed-slot check)
plus buggy winning view selection to break ViewChangeSafety:

```
View 2:
  s4(honest leader) proposes v1
  s1(Byz) injects ByzantineVotePrepare(v1) × 2
  s2, s3, s4 vote Prepare(v1) → fast quorum (4/4)
  FastCommit(v1) → s2, s3, s4 commit v1

View 3:
  s1(Byz) proposes v2 via ByzantinePrepare
  s1(Byz) injects ByzantineVoteConfirm(v2, view 3)
  s2, s3, s4 vote Prepare(v2) DESPITE already committed (DA-8)
  s3 sends Confirm(v2) → s2, s4 vote Confirm(v2)
  confirmVotesFor[view 3][v2] = {s1, s2, s4} = quorum → ConfirmQC(v2, view 3)

Final: committed=v1, ConfirmQC(v2, view 3) exists, v1 ∉ proposed[view 3]
  → ViewChangeSafety VIOLATED
```

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
