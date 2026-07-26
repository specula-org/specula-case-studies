# SOFAJRaft

## Scope

Specula analyzed and tested SOFAJRaft's consensus core, including pre-vote and elections, pipelined replication and commit, joint-consensus membership changes, ReadIndex and lease reads, learners, leadership transfer, snapshots, and crash recovery.

## Bugs

Specula found 10 new bugs:

- `BallotBox.describe()` validates its optimistic `StampedLock` stamp before reading the protected variables, so the reported snapshot can be inconsistent.
- `checkConsistency()` formats a `LogId` object with an integer conversion and can throw `IllegalFormatConversionException`.
- **Fixed:** `electSelf()` sends RequestVote RPCs before persisting the new term and vote, leaving a crash window in which the vote is lost (PR #1245).
- **Fixed:** An exception from `StateMachine.onApply()` can bypass `setLastApplied()` and make the node retry the same entries indefinitely (PR #1246).
- `handlePreVoteRequest` releases and reacquires the node lock without checking whether the term changed during the gap.
- Loss of the local Raft metadata file is treated like first boot and silently resets the term to zero, allowing the node to forget prior votes.
- **Fixed:** Vote handling persists the new term and candidate in separate operations, so a crash between them can permit a second vote in the same term (Issue #1241).
- The install-snapshot response handler omits the higher-term check used by other response handlers, allowing a stale leader to remain in office.
- `passByStatus` returns true when the state-machine caller is already in error and no completion callback is present.
- Log-suffix truncation deletes two column families in separate operations, so a crash between them can leave the stores inconsistent.
