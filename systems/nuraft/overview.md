# NuRaft

## Scope

Specula analyzed and tested NuRaft's consensus core, including pre-vote and priority elections, log replication and precommit and commit ordering, quorum calculation, membership changes, snapshots, response handling, and recovery.

## Bugs

Specula found 3 new bugs:

- A same-term join request clears `voted_for` before attempting to update the term, erasing the server's existing vote.
- PreVote requests are granted without checking log freshness, allowing a stale node to trigger unnecessary elections.
- **Open:** `set_priority()` bypasses the one-configuration-change-at-a-time guard, allowing overlapping uncommitted configuration changes.
