# Autobahn

## Scope

Specula analyzed and tested Autobahn's DAG-BFT consensus module, including lane and car dissemination, proof-of-availability formation, Prepare/Confirm/Commit slow and fast paths, timeout-certificate view changes, and pipelined slots.

## Bugs

Specula found 21 new bugs:

- Prepare-vote deduplication is keyed by both slot and view, allowing an honest node to vote for different values across views of the same slot.
- Commit processing lacks view-monotonicity and already-committed guards, so a stale lower-view commit can overwrite a newer commitment.
- `clean_slot_periods()` uses an incorrect conjunction in its retention predicate and deletes in-progress state for future slots.
- A commit waiting on missing proposals is not persisted before asynchronous proposal retrieval, so a failed loopback or restart can lose it permanently and stall the protocol.
- `enough_coverage()` unwraps attacker-controlled missing proposal-map entries, allowing an incomplete Byzantine Prepare to panic the node.
- Timeout-certificate handling neither verifies the certificate nor updates the view or restarts the timer, leaving non-leader nodes stuck after a view change.
- Commit order depends on nondeterministic `HashMap` iteration, so replicas can derive different total orders for the same committed proposals.
- `Header::digest()` omits embedded consensus messages, allowing different consensus payloads to share the same header digest.
- Prepare validation does not verify that the sender is the designated leader, allowing any Byzantine server to submit a Prepare.
- Slow-path commit verification panics on a proposal/QC identifier mismatch instead of rejecting the malformed message.
- Quorum-certificate signatures do not bind to the proposal value, allowing a valid ConfirmQC to be reused for a different value.
- `TC::verify()` always succeeds because timeout-certificate equality is hard-coded to true and the genesis check bypasses quorum and signature validation.
- `Timeout::digest()` hashes none of the timeout fields, making signatures replayable across slots and views.
- Network traffic has priority over timer handling in `tokio::select!`, so sustained adversarial messages can starve view-change timeouts.
- View-change proposal selection records the timeout view instead of the winning QC's view, which can select the wrong locked value.
- Prepare validation advances the local slot view before completing validation, allowing one invalid high-view Prepare to block legitimate lower-view voting.
- Embedded parent certificates are accepted without the standalone signature, uniqueness, and quorum checks, allowing forged certificates into the DAG.
- Prepare validation unwraps a missing timeout-certificate winner-map entry, so a Byzantine proposal key can crash the core task.
- Proposal retrieval unwraps a genesis-header lookup before committee validation, so an outsider proposal key can crash the recipient.
- Slot cleanup leaves several per-slot commitment, view, QC, proposal, and vote maps unpruned, causing unbounded memory growth.
- Prepare validation unwraps a missing QC ticket for slots without a local predecessor commit, allowing an authenticated malformed request to crash the core task.
