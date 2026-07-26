# eliben/raft

## Scope

Specula analyzed and tested eliben/raft's Raft core, including elections, heartbeats, log replication and conflict resolution, commit delivery, persistent term/vote/log state, and interleavings among timers, peer RPCs, and the state-machine lock.

## Bugs

Specula found 4 new bugs:

- `startElection` changes `currentTerm` and `votedFor` without persisting them, so a crash can let the node vote again in the same term; PR #26 fixed it.
- `persistToStorage` writes the term, vote, and log separately, creating partial-persistence crash states that can permit double voting.
- Vote-reply handlers compare against a captured election term instead of the current term, allowing stale replies to be counted in a later election; PR #27 fixed it.
- `becomeFollower` clears `votedFor` even on same-term transitions, erasing the vote record and permitting a second vote in that term; PR #27 fixed it.
