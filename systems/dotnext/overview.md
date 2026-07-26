# dotNext

## Scope

Specula analyzed and tested dotNext's Raft module, including elections and PreVote, leader leases, heartbeat and replication rounds, sideband membership changes, asynchronous transitions, parallel follower replication, and persistent term/vote state.

## Bugs

Specula found 5 new bugs:

- `AppendEntriesAsync` and `InstallSnapshotAsync` do not reject non-members, allowing an outside node's request to reach log and commit-index processing.
- `IsUpToDateAsync` uses a conjunction instead of Raft's lexicographic comparison, rejecting candidates with a newer last log term but a shorter log.
- **Fixed:** The `MemberAdded` event's remove accessor updates the `MemberRemoved` handler list, leaking one subscription and corrupting the other; see PR #280.
- **Fixed:** `VoteAsync` refreshes the election timer before determining whether a vote is granted, so rejected vote requests can delay elections; see PR #281.
- **Fixed:** An exception-throwing `LeaderChanged` subscriber can fail both leader entry and its unguarded standby fallback inside `async void`; see commit `e93f35a`.
