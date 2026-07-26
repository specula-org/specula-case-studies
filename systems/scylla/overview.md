# ScyllaDB

## Scope

Specula analyzed and tested ScyllaDB's Raft library, including pre-vote and elections, log replication and commit advancement, joint-consensus membership changes, read barriers, leadership transfer, snapshots, and persistence.

## Bugs

Specula found 1 new bug:

- Read-quorum broadcasting can omit voters demoted only in the current half of a joint configuration, stalling read barriers and reducing fault tolerance; this was fixed in PR #29226.
