# Additional Potential Issues in Autobahn BFT

Following our earlier exchange regarding the QC proposal binding issue and the view change winning-view selection issue, we continued studying the Autobahn codebase and identified several additional observations that we wanted to share. We describe them below in detail so that you can evaluate whether they are relevant to your implementation.

All line references are to the `autobahn-artifact` repository as published.

---

## Issue 1: Non-Deterministic Commit Ordering Due to HashMap Iteration

### Summary

We noticed that in the commit path, proposal lanes are iterated using a `HashMap<PublicKey, Proposal>`. Since Rust's `HashMap` does not guarantee iteration order, different replicas may process the same set of proposals in different orders, potentially producing different total orderings for committed headers.

### Observation

In `committer.rs`, lines 132–133, when a slot is committed, the code iterates over the proposals map:

```rust
// committer.rs:132-133
ConsensusMessage::Commit { slot: _, view: _, qc: _, proposals } => {
    for (pk, proposal) in proposals {  // HashMap — iteration order is non-deterministic
        let stop_height = *state.last_executed_heights.get(pk).unwrap();
        if proposal.height <= stop_height {
            continue;
        }
        // ... fetch headers for this lane and send to tx_output
    }
}
```

The `proposals` field is defined as `HashMap<PublicKey, Proposal>` in the `ConsensusMessage` enum (`messages.rs`, lines 101, 107, 113). Each entry represents one validator's "lane" — a chain of headers to deliver. The iteration order determines which validator's headers appear first in the output.

Since `HashMap` iteration order depends on internal hash state and can differ across process instances, two replicas receiving the same `Commit` message may iterate the proposals in different orders and produce different output sequences.

### Possible Scenario

With 4 validators (s1, s2, s3, s4) in a single slot:

1. Honest leader proposes with proposals from all 4 validators
2. Validators reach consensus and commit the slot
3. Replica A iterates proposals in order: s1, s2, s3, s4
4. Replica B iterates proposals in order: s1, s2, s4, s3
5. The two replicas deliver headers in different total orders

No Byzantine behavior is required. This arises in a fully honest execution.

### Related: `proposal_digest()` Also Iterates a HashMap

The function `proposal_digest()` (`messages.rs`, lines 210–231) similarly iterates over a `HashMap<PublicKey, Proposal>` when computing the digest:

```rust
// messages.rs:214
for (_, proposal) in proposals {
    hasher.update(proposal.header_digest.0);
}
```

If in the future the `proposal_digest()` calls are uncommented (to fix the QC binding issue from our first report), the non-deterministic iteration would cause different replicas to compute different digests for the same proposal set, breaking QC verification.

### Possible Fix

Replacing `HashMap<PublicKey, Proposal>` with `BTreeMap<PublicKey, Proposal>` in the `ConsensusMessage` enum (`messages.rs`, lines 101, 107, 113) would ensure deterministic iteration order across all replicas.

---

## Issue 2: Timeout Digest Does Not Include Any Fields

### Summary

We noticed that `Timeout::digest()` creates a SHA-512 hash but does not feed any of the timeout's fields (slot, view, high_qc, high_prop) into the hasher. As a result, all Timeout messages appear to produce the same digest regardless of their content. If our reading is correct, this would mean that timeout signatures do not bind to the timeout's actual slot, view, or QC evidence, and a signed timeout could be replayed across different slots and views.

### Observation

In `messages.rs`, lines 1349–1358, the `Hash` implementation for `Timeout`:

```rust
// messages.rs:1349-1358
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

All meaningful fields are commented out. The hasher receives no input, so `Sha512::new().finalize()` always produces the same hash. This digest is used for signature creation in `Timeout::new_from_key()` (line 1384):

```rust
// messages.rs:1384
let signature = Signature::new(&timeout.digest(), &secret);
```

Since the digest is constant, a valid timeout signature from any (slot, view) context can be attached to a timeout message with a completely different (slot, view).

### Consequence

A timeout signed for (slot=1, view=2) would have the same digest — and therefore the same valid signature — as a timeout for (slot=5, view=10). If an attacker collects one valid signed timeout from a given validator, that signature could be reused to construct timeout messages for arbitrary slots and views under that validator's identity.

### Possible Fix

Uncommenting the hashed fields, and additionally including `self.slot` and potentially `self.high_prop` in the digest computation, would bind each timeout signature to its intended context.

---

## Issue 3: TC Verification Always Returns Ok

### Summary

We noticed that `TC::verify()` appears to always return `Ok(())` due to a `PartialEq` implementation that unconditionally returns `true`. The genesis check `Self::genesis(committee) == *self` at the top of `verify()` short-circuits to `Ok(())` for every TC, bypassing all quorum and signature checks.

### Observation

In `messages.rs`, lines 1405–1411, the `PartialEq` implementation for `TC`:

```rust
// messages.rs:1405-1411
impl PartialEq for TC {
    fn eq(&self, other: &Self) -> bool {
        //self.hash == other.hash && self.view == other.view
        //*self.winning_proposal == *other.winning_proposal
        true    // Always returns true
    }
}
```

This causes every `TC` to be "equal" to every other `TC`. In `TC::verify()` (lines 1518–1546):

```rust
// messages.rs:1518-1522
pub fn verify(&self, committee: &Committee) -> ConsensusResult<()> {
    //genesis TC always valid
    if Self::genesis(committee) == *self {
        return Ok(());      // <-- Always taken, since PartialEq always returns true
    }

    // Ensure the QC has a quorum.
    let mut weight = 0;
    // ... quorum and signature checks (never reached)
}
```

Since `Self::genesis(committee) == *self` is always true (because `PartialEq::eq` always returns `true`), the function returns `Ok(())` immediately. The quorum threshold check (line 1535) and the per-timeout signature verification loop (lines 1541–1544) are effectively dead code.

### Consequence

A single node could construct a TC with arbitrary (or empty) timeout lists, and it would pass verification. Combined with Issue 2 (constant timeout digest), this would allow a Byzantine node to fabricate a complete view change without collecting any genuine timeout votes from other validators.

This is used in the `is_valid` check for Prepare messages with a TC (`core.rs`, lines 1182–1187):

```rust
// core.rs:1187
ticket_valid = tc.verify(&self.committee).is_ok();
```

Since `tc.verify()` always succeeds, any TC attached to a Prepare message is accepted as valid.

### Related: QC PartialEq Always Returns False

Interestingly, the `QC` type has the opposite behavior (`messages.rs`, lines 1287–1292):

```rust
// messages.rs:1287-1292
impl PartialEq for QC {
    fn eq(&self, other: &Self) -> bool {
        false   // Always returns false
        //self.hash == other.hash && self.view == other.view
    }
}
```

This means the QC genesis check in `QC::verify()` never short-circuits, so QC verification does run the full quorum and signature checks. The asymmetry — QC (always false) vs TC (always true) — means QC verification works correctly while TC verification is entirely bypassed.

### Possible Fix

Restoring the commented-out comparison logic in `TC::PartialEq` (comparing hash and view fields) would allow the genesis check to function correctly, letting non-genesis TCs proceed to the quorum and signature verification code that is already implemented.

---

## Issue 4: `panic!()` in `verify_commit()` Slow Path Enables Remote Node Crash

### Summary

We noticed an asymmetry in `verify_commit()`: when the QC ID does not match, the fast path (3f+1 Prepare votes) correctly returns `false`, but the slow path (2f+1 Confirm votes) calls `panic!()` instead, which would crash the node process. If our reading is correct, a Byzantine node could craft a Commit message that triggers this panic on any honest node that receives it.

### Observation

In `messages.rs`, lines 134–163, the `verify_commit()` function handles two cases:

```rust
// messages.rs:134-163
if qc.votes.len() == committee.size() {  // Fast path (3f+1 Prepare votes)
    if prepare_id != qc.id {
        return false;                     // Correct: returns false on mismatch
    }
    qc.verify(committee).is_ok()

} else {                                  // Slow path (2f+1 Confirm votes)
    // ...
    let confirm_id = Digest(hasher.finalize().as_slice()[..32].try_into().unwrap());

    if confirm_id != qc.id {
        panic!("ids don't match");        // Crashes the node!
        return false;                     // Dead code — never reached
    }
    qc.verify(committee).is_ok()
}
```

The fast path (line 137–138) returns `false` on ID mismatch, allowing the caller to reject the message gracefully. The slow path (line 158–159) panics instead, terminating the entire process.

### Consequence

A Byzantine node could construct a Commit message with a QC that has fewer than `committee.size()` votes (taking the slow path) and a deliberately mismatched QC ID. When an honest node processes this Commit via `is_valid()` (`core.rs`, line 1249: `verify_commit(consensus_message, &self.committee)`), the panic would crash the node.

Since `verify_commit` is called before any authentication check on the Commit message itself, a single malformed message from any network participant could crash honest nodes.

### Possible Fix

Replacing `panic!("ids don't match")` with `return false` to match the fast-path behavior would allow the caller to reject the message without crashing.

---

## Issue 5: Header Digest Does Not Cover Consensus Messages

### Summary

We noticed that `Header::digest()` does not include the `consensus_messages` field in the hash computation. Since the header's signature covers only the digest, two headers with the same (author, height, payload, parent) but different embedded consensus messages would produce the same digest and the same valid signature.

### Observation

In `messages.rs`, lines 570–593, the `Hash` implementation for `Header`:

```rust
// messages.rs:570-593
impl Hash for Header {
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
}
```

The `consensus_messages` field (`HashMap<Digest, ConsensusMessage>`, line 432) carries Prepare, Confirm, and Commit messages embedded in the DAG header. The code for including these in the digest is commented out with a `TODO` annotation.

### Consequence

A Byzantine proposer could create two headers with identical (author, height, payload, parent) but different `consensus_messages` — for example, one carrying `Prepare(v1)` and another carrying `Prepare(v2)`. Both headers would have the same digest, and therefore the same valid signature. The proposer could then send different versions to different peers, equivocating at the dissemination layer while passing all signature checks.

### Possible Fix

Uncommenting the `consensus_messages` hashing loop would bind the header digest (and thus its signature) to the embedded consensus content.

---

## Issue 6: No Leader Verification for Prepare Messages

### Summary

We noticed that when an honest node receives a Prepare message, `is_valid()` does not appear to check whether the sender is the legitimate leader for that (slot, view). If our reading is correct, any node — including a Byzantine one — could send a Prepare message for any slot and view, and honest nodes would accept it and vote.

### Observation

In `core.rs`, lines 1170–1229, `is_valid()` for a Prepare message performs the following checks:

1. **TC validity** (lines 1182–1194): if a TC is provided, verify it and check that proposals match the TC's winning proposals
2. **QC ticket validity** (lines 1196–1217): if no TC (view 1), check the slot-bounding QC ticket
3. **View constraint** (line 1218): `ticket_valid = ticket_valid && *view == 1` — for the no-TC case, only view 1 is accepted
4. **Duplicate vote prevention** (line 1229): `!self.last_voted_consensus.contains(&(*slot, *view))`
5. **View match** (line 1229): `self.views.get(slot).unwrap() == view`

Notably absent is a check like `leader(slot, view) == sender`. The function validates the message content (TC, ticket, view) but not whether the sender is authorized to propose for that (slot, view).

### Consequence

In view 1 (no TC required), any node could act as proposer by simply sending a Prepare message with valid proposals. Honest nodes would vote on it without checking if the sender is the designated leader. In views > 1, a node would need to provide a valid TC, which under normal circumstances limits this to nodes that actually collected enough timeouts — but combined with Issue 3 (TC verification bypass), any Byzantine node could construct a valid-looking TC and propose in any view.

### Possible Fix

Adding a leader check before accepting the Prepare — verifying that the message sender matches `leader(slot, view)` — would ensure only the designated leader's proposals are voted on.

---

## Issue 7: No Duplicate Vote Guard for Confirm Messages

### Summary

We noticed that the Prepare handler has a duplicate voting guard via `last_voted_consensus`, but the Confirm handler does not appear to have an equivalent check. If our reading is correct, an honest node receiving two Confirm messages for the same (slot, view) — potentially with different proposal values — would vote for both.

### Observation

For **Prepare** messages, `is_valid()` includes a duplicate check (`core.rs`, line 1229):

```rust
// core.rs:1227-1229
// Ensure that we haven't already voted in this slot, view, that the ticket is
// valid, and we are in the same view
!self.last_voted_consensus.contains(&(*slot, *view)) && ticket_valid && self.views.get(slot).unwrap() == view
```

And after voting, the (slot, view) pair is recorded (`core.rs`, line 1512):

```rust
// core.rs:1511-1512
// Ensure that we don't vote for another prepare in this slot, view
self.last_voted_consensus.insert((*slot, *view));
```

For **Confirm** messages, `is_valid()` (`core.rs`, lines 1231–1246) performs only a view check and QC verification:

```rust
// core.rs:1231-1242
ConsensusMessage::Confirm { slot, view, qc, proposals: _ } => {
    let curr_view = self.views.get(slot).unwrap_or(&0);
    if curr_view <= view {
        if verify_confirm(consensus_message, &self.committee) {
            self.views.insert(*slot, *view);
            return true;
        }
    }
    return false;
}
```

There is no `last_voted_consensus.contains` check, and `process_confirm_message()` (`core.rs`, lines 1541–1576) does not record the (slot, view) pair in any duplicate-prevention set.

### Consequence

If a node receives a second Confirm for the same (slot, view) — whether a legitimate retransmission or a conflicting one — it would sign and emit a second Confirm vote. Under normal circumstances this may be harmless, but in the presence of other issues (e.g., Issue 1 from our first report, where the QC does not bind to the proposal value), an attacker could potentially collect Confirm votes for two different values in the same (slot, view).

### Possible Fix

Adding a `last_voted_consensus`-style check (or a separate set) in `is_valid()` for Confirm messages, and recording the (slot, view) pair after voting, would prevent duplicate Confirm votes.

---

## Issue 8: No Commit Idempotency Check

### Summary

We noticed that `process_commit_message()` does not check whether a slot has already been committed before processing a Commit message. If our reading is correct, a second Commit for the same slot — potentially with a different value — would overwrite the previously committed value.

### Observation

In `core.rs`, lines 1599–1625, when a Commit message is received:

```rust
// core.rs:1622-1625
let sl = *slot;
self.last_committed_slot = max(sl, self.last_committed_slot);
self.committed_slots.insert(sl, CommitQC::new(*slot, *view, qc.clone(), proposals.clone()).await);
```

The code directly inserts into `committed_slots` without first checking whether `committed_slots.contains_key(&sl)`. If a Commit for slot `sl` was already processed, the new entry overwrites the old one.

The `is_valid()` check for Commit messages (`core.rs`, line 1248–1249) only calls `verify_commit()`, which validates the QC but does not check whether the slot is already committed:

```rust
// core.rs:1248-1249
ConsensusMessage::Commit { slot, view, qc, proposals } => {
    verify_commit(consensus_message, &self.committee)
```

### Consequence

Under normal operation, a slot should only be committed once. However, if two Commit messages arrive for the same slot with different values — which could happen in the presence of Issue 1 from our first report (QC not binding to proposal value) — the second commit silently overwrites the first. There is no logging, no error, and no detection of the conflicting commit.

### Possible Fix

Adding a check like `if self.committed_slots.contains_key(&sl) { return Ok(()); }` before the insert would ensure that the first committed value for a slot is final.

---

## Issue 9: `clean_slot_periods()` May Delete Future Slot State When K > 1

### Summary

We noticed that the retain predicates in `clean_slot_periods()` use `&&` (logical AND) to combine two conditions, which appears to cause entries for future slots to be unconditionally deleted. If our reading is correct, when K > 1 (multiple concurrent slots), committing one slot would destroy in-progress consensus state for other active slots.

### Observation

In `core.rs`, lines 1693–1708, after committing a slot, garbage collection runs:

```rust
// core.rs:1693-1705
async fn clean_slot_periods(&mut self, slot: Slot) -> DagResult<()> {
    let slot_period = slot % self.k;
    let k = self.k;

    self.consensus_instances.retain(|(s, _), _| s % k != slot_period && s <= &slot);
    self.consensus_cancel_handlers.retain(|s, _| s % k != slot_period && s <= &slot);
    self.qc_makers.retain(|(s, _), _| s % k != slot_period && s <= &slot);

    Ok(())
}
```

The retain predicate keeps entries where **both** conditions hold:
1. `s % k != slot_period` — the entry is in a different period
2. `s <= &slot` — the entry is not in the future

For entries with `s > slot` (future slots), condition (2) is `false`, so the entry is always removed regardless of its period. This means committing slot 5 with K=3 would delete consensus instances for slots 6, 7, 8, and so on.

### Example

With K=3 and committing slot 3 (`slot_period = 0`):

| Entry slot | `s % 3 != 0` | `s <= 3` | Retained? | Expected? |
|-----------|-------------|---------|-----------|-----------|
| slot 1    | false       | true    | No        | No (same period, past) |
| slot 2    | true        | true    | Yes       | Yes (different period) |
| slot 3    | false       | true    | No        | No (same period, current) |
| slot 4    | true        | false   | **No**    | **Yes (active, different period)** |
| slot 5    | true        | false   | **No**    | **Yes (active, different period)** |
| slot 6    | false       | false   | No        | No (same period, future) |

Slots 4 and 5 are in different periods and should be retained (they may have active consensus in progress), but they are deleted because `s <= &slot` is false.

### Consequence

When K > 1, committing a slot garbage-collects all future consensus state, including QC makers and cancel handlers for slots that are actively running consensus. This could cause honest nodes to lose track of votes and fail to reach quorum on in-progress slots.

Note: when K = 1, `clean_slot_periods()` is equivalent to `clean_slot()` (which only removes entries matching the exact slot), so this issue does not manifest in single-slot configurations.

### Possible Fix

Changing `&&` to `||` in the retain predicates would keep entries that are either in a different period **or** in the future:

```rust
self.consensus_instances.retain(|(s, _), _| s % k != slot_period || s > &slot);
```

---

## Issue 10: `enough_coverage()` Panics on Incomplete Proposal Maps

### Summary

We noticed that `enough_coverage()` calls `.unwrap()` on a `HashMap::get()` without checking for `None`. If a received Prepare message has an incomplete proposals map (missing some validators' keys), this would panic and crash the node.

### Observation

In `core.rs`, lines 1579–1596:

```rust
// core.rs:1579-1596
fn enough_coverage(
    &mut self,
    prepare_proposals: &HashMap<PublicKey, Proposal>,
) -> bool {
    let current_proposals = match self.use_optimistic_tips {
        true => &self.current_proposal_tips,
        false => &self.current_certified_tips,
    };

    let new_tips: HashMap<&PublicKey, &Proposal> = current_proposals
        .iter()
        .filter(|(pk, proposal)| proposal.height > prepare_proposals.get(&pk).unwrap().height)
        //                                                                       ^^^^^^^^^ panics if pk not found
        .collect();

    new_tips.len() as u32 >= self.committee.quorum_threshold()
}
```

The function iterates over `current_proposals` (which contains entries for all validators in the committee) and looks up each key in `prepare_proposals` (from the received message). If `prepare_proposals` does not contain an entry for a given `pk`, `.unwrap()` panics.

### Consequence

A Byzantine leader could construct a Prepare message with a proposals map that is missing one or more validators' keys. When the next slot's leader evaluates `enough_coverage()` on this message (`core.rs`, line 1110), the unwrap would crash the node.

This crash occurs after the Prepare has already passed `is_valid()`, since `is_valid()` does not check that the proposals map contains all expected keys.

### Possible Fix

Replacing `.unwrap()` with a fallback (e.g., `.unwrap_or(&default)` or skipping missing keys) or validating completeness of the proposals map in `is_valid()` would prevent the crash.

---

## Issue 11: No Committed-Slot Check When Voting on Prepare

### Summary

We noticed that `is_valid()` for Prepare messages does not check whether the slot has already been committed. If our reading is correct, an honest node that has committed a value for slot `s` would still accept and vote for new Prepare messages targeting slot `s` in a higher view.

### Observation

In `core.rs`, line 1229, the validity check for Prepare includes:

```rust
!self.last_voted_consensus.contains(&(*slot, *view)) && ticket_valid && self.views.get(slot).unwrap() == view
```

This checks for duplicate voting and view consistency, but does not check `self.committed_slots.contains_key(slot)`. A committed slot's consensus is final — there is no reason to accept further proposals for it.

### Consequence

In isolation, this is primarily a defense-in-depth concern: unnecessary consensus messages waste resources but do not independently cause a safety violation (assuming the TC verification and winning-proposals checks are working correctly). However, if a Byzantine node can trigger voting on already-committed slots, it could accumulate QCs for conflicting values in later views, which combined with other issues could be leveraged to violate agreement safety.

### Possible Fix

Adding `!self.committed_slots.contains_key(slot)` to the validity check would prevent voting on already-committed slots.

---

## Issue 12: `handle_tc()` Does Not Update View or Verify TC for Non-Leader Nodes

### Summary

We noticed that when a node receives a TC (Timeout Certificate) broadcast from another node, `handle_tc()` only calls `generate_prepare_from_tc()` — which is relevant only for the next view's leader. Non-leader nodes that receive the TC do not appear to update their local view or start a new timer. This contrasts with the TC assembly path, where the node that collects enough timeout votes does update its view and start a timer.

### Observation

In `core.rs`, lines 2027–2033, the `handle_tc()` function:

```rust
// core.rs:2027-2033
async fn handle_tc(&mut self, tc: &TC) -> DagResult<()> {
    debug!("Processing TC {:?}", tc);
    self.generate_prepare_from_tc(tc).await?;
    Ok(())
}
```

Compare this with the TC assembly code (in the timeout processing path), lines 1914–1927:

```rust
// core.rs:1914-1927
// Try to advance the view
self.views.insert(timeout.slot, timeout.view + 1);

// Start the new view timer
let timer = Timer::new(tc.slot, tc.view + 1, self.timeout_delay);
self.timer_futures.push(Box::pin(timer));
self.timers.insert((tc.slot, tc.view + 1));

// Broadcast the TC.
```

The node that assembles the TC (by collecting 2f+1 timeout votes locally) correctly advances its view and starts a timer. But when other nodes receive the broadcast TC via `handle_tc()`, neither action occurs.

### Consequence

After a view change, only the node that assembled the TC (and the new leader, via `generate_prepare_from_tc`) would be in the new view. All other honest nodes would remain in the old view. When the new leader sends a Prepare for the new view, those nodes would reject it (since their local view does not match), potentially stalling consensus.

Additionally, `handle_tc()` does not call `tc.verify()`. While TC verification is currently bypassed due to Issue 3, once that is fixed, the lack of verification here would mean `handle_tc()` accepts any TC without checking quorum or signatures.

### Possible Fix

`handle_tc()` should: (1) verify the TC, (2) update the node's view to `tc.view + 1`, and (3) start a new timer for the new view, matching the behavior of the TC assembly path.

---

## Issue 13: Commit Message Not Persisted Before Async Proposal Fetch

### Summary

We noticed that in `process_commit_message()`, when the referenced proposals are not yet available locally, the Commit message is not stored persistently. The code relies on an asynchronous loopback mechanism to eventually reprocess it, but if this mechanism fails (e.g., channel full, node restart), the Commit could be permanently lost.

### Observation

In `core.rs`, lines 1654–1663:

```rust
// core.rs:1654-1663
// Only send to committer if proposals and all ancestors are stored locally,
// otherwise sync will be triggered, and this commit message will be reprocessed
if !self.synchronizer.get_proposals(&commit_message, &header).await.unwrap().is_empty() {
    debug!("sending to committer");
    self.tx_committer
        .send(commit_message)
        .await
        .expect("Failed to send headers");
}
```

If the proposals are not locally available, `get_proposals` triggers an asynchronous sync and the Commit message is expected to be redelivered via the `rx_header_waiter_instances` loopback channel (`core.rs`, line 2266). However, the original Commit message is not saved to any persistent storage — it exists only in the current call's stack frame.

### Consequence

If the loopback fails to redeliver the Commit (channel capacity exceeded, node crashes during sync, or the sync itself fails), the node would never learn that the slot was committed. Since slot s+K requires slot s to be committed (the slot-bounding ticket mechanism), a lost Commit could stall all future slots in the same period.

We acknowledge that this may be acceptable for a research prototype, but wanted to flag it as a potential concern for production deployments.

### Possible Fix

Persisting the Commit message to durable storage before initiating the async proposal fetch would allow it to be retried after any transient failure.

---

## Issue 14: View Change Timer May Be Delayed Under Heavy Message Load

### Summary

We noticed that the main event loop uses `tokio::select!` with the timer branch as one of several competing branches. Under sustained high message load — particularly from a flooding adversary — the timer branch may be selected less frequently, potentially delaying view change timeouts.

### Observation

In `core.rs`, line 2212, the event loop uses `tokio::select!` with multiple branches:

```rust
// core.rs:2212-2281
let result = tokio::select! {
    Some(message) = self.rx_primaries.recv() => { ... },           // Network messages
    Some(header) = self.rx_proposer.recv() => { ... },             // Own proposals
    Some(header) = self.rx_header_waiter.recv() => { ... },        // Header waiter loopback
    Some((...)) = self.rx_header_waiter_instances.recv() => { ... }, // Instance loopback
    Some(digest) = self.rx_request_header_sync.recv() => { ... },  // Sync requests
    Some((slot, view)) = self.timer_futures.next() => { ... },     // Timers
    Some(vote) = self.car_timer_futures.next() => { ... },         // Car timers
};
```

While `tokio::select!` (without the `biased;` modifier) selects randomly among ready branches, under sustained flooding the network channel (`rx_primaries`) would be ready on nearly every iteration. With 7 branches, each branch has roughly equal probability of being selected, but a continuously-full network channel means the event loop would mostly be processing network messages, with timers only being checked on approximately 1-in-7 iterations.

### Consequence

If a Byzantine leader floods honest nodes with messages (which do not need to be valid — they just need to enter the channel), the effective timeout duration could be extended by a factor proportional to the message processing rate. This would delay view changes, allowing the Byzantine leader to maintain control of the view for longer than the configured timeout period.

We note that this is a common challenge in event-loop-based BFT implementations and may be acceptable given the protocol's threat model. We wanted to flag it for completeness.

### Possible Fix

Processing timers in a separate task or checking timer expiry outside the `select!` macro (e.g., at the top of each loop iteration) would ensure timers are handled promptly regardless of network load.
