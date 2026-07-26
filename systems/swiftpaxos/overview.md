# SwiftPaxos

## Scope

Specula analyzed and tested SwiftPaxos's EPaxos, N2Paxos, and SwiftPaxos implementations, including fast and slow proposal paths, conflicting-command dependency ordering, quorum commits, delivery and execution, speculative execution, and leader-change recovery.

## Bugs

Specula found 8 new bugs:

- Crash-recovery metadata persistence writes `vbal` over the byte range used by `bal`, corrupting the stored ballot.
- `handlePrepareReply` contains a duplicate recovery subcase that makes its prepare-reply quorum calculation incorrect.
- Recovery conflict status is never propagated because every `TryPreAcceptReply` reports `NONE`.
- N2Paxos does not validate quorum membership for M2B messages, allowing a sender to spoof votes.
- A follower can commit a slot after receiving 2A and 2B messages before it has processed the local proposal payload required for delivery.
- The leader's delivery guard permits speculative execution before commit and chains delivery to the next slot.
- Command descriptors can remain in `START` while proposal handling is queued asynchronously, violating the implementation's command-state invariant.
- Recovery producers can enqueue old and new acknowledgements out of order, and the recovery path performs no conflict check before using them.
