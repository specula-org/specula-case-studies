# Potential Issue: Quorum Certificate Does Not Bind to Proposal Value

## Summary

We noticed that the Quorum Certificate (QC) does not appear to cryptographically bind to the proposal value. The vote digest computation includes `[slot, view, type_marker]` but not the proposal content. If our understanding is correct, this would allow a valid QC for one proposal to be reused with a different proposal, which could potentially lead to an agreement safety violation.

## Observation

In `primary/src/messages.rs`, the function `proposal_digest()` (lines 210–231) computes a hash over all proposal header digests. However, it does not seem to be called anywhere. In three locations, the call is commented out with a FIXME annotation:

**`verify_commit()` — line 128:**
```rust
let mut hasher = Sha512::new();
hasher.update(slot.to_le_bytes());
hasher.update(view.to_le_bytes());
//hasher.update(proposal_digest(consensus_message)); FIXME: ADD THIS AND DEBUG
hasher.update((0 as u8).to_le_bytes());
let prepare_id = Digest(hasher.finalize().as_slice()[..32].try_into().unwrap());
```

**`verify_confirm()` — line 194:**
```rust
//hasher.update(proposal_digest(consensus_message)); FIXME: ADD THIS AND DEBUG
```

**`ConsensusMessage::digest()` (Prepare variant) — line 246:**
```rust
//hasher.update(proposal_digest(self)); FIXME: ADD THIS AND DEBUG
```

Because `proposal_digest` is not included, the QC's `id` field appears to be computed as `SHA-512(slot || view || type_marker)`, which would be the same regardless of what proposals the message contains.

## Possible Attack Scenario

If our reading of the code is correct, the following scenario may be possible with 4 validators (3f+1 where f=1): three honest (s2, s3, s4) and one Byzantine (s1).

1. The honest leader s3 proposes value **v1** for (slot=1, view=1)
2. Honest validators s2, s3, s4 vote Prepare — forming a **PrepareQC**
3. Honest validators send Confirm(v1) with the PrepareQC
4. Honest validators s2, s3, s4 vote Confirm — forming a **ConfirmQC**
5. An honest validator constructs **Commit(v1)** with the ConfirmQC and sends it
6. s3 receives Commit(v1) and commits v1
7. Byzantine s1 constructs a **Commit(v2)** — same (slot=1, view=1), same ConfirmQC, but with different proposals containing **v2**
8. Commit(v2) passes `verify_commit()` because the QC id does not depend on proposals
9. s2 receives Commit(v2) and commits v2

This would result in s3 committing v1 and s2 committing v2 for the same slot.

## TLA+ Model Checking

We built a TLA+ specification modeling the Autobahn consensus protocol and checked agreement safety using TLC in BFS mode. TLC reported a violation with a 14-state counterexample that matches the scenario described above.

- **Configuration**: 4 servers (1 Byzantine), 2 values, 1 slot, 1 view
- **Counterexample length**: 14 states
- **Time to find**: 27 seconds

## Reproduction Test

We wrote a unit test that demonstrates the behavior without any network setup:

1. Create two distinct proposal sets (v1 and v2) with different header digests
2. Compute the ConfirmQC id as `SHA-512(slot || view || prepare_id || 1)` — without proposal content
3. Have 3 validators sign the ConfirmQC id (slow-path quorum)
4. Construct `Commit(v1)` and `Commit(v2)` with the **same QC** but **different proposals**
5. Both pass `verify_commit()`

```
$ cargo test -p primary test_da1 -- --nocapture

running 1 test
DA-1 CONFIRMED: verify_commit accepts two Commits with different
              proposals but the same QC for (slot=1, view=1)
test messages::messages_tests::test_da1_qc_does_not_bind_to_proposals ... ok
```

