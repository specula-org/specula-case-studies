# RethinkDB

## Scope

Specula analyzed and tested RethinkDB's per-table Raft implementation, including elections and virtual heartbeats, log replication, term transitions, joint-consensus membership changes, snapshots, and recovery.

## Bugs

Specula found 1 new bug:

- A debug invariant repeats the same predicate on both sides of an `or`, making the intended readiness check tautological; this was fixed in PR #7193.

The bug tracker also records 1 known bug examined by Specula:

- Re-enrolling a server with the same Raft member ID after clearing its inactive state can erase its vote history and permit it to vote twice in one term.
