# RethinkDB

## Scope

Specula analyzed and tested RethinkDB's per-table Raft implementation, including elections and virtual heartbeats, log replication, term transitions, joint-consensus membership changes, snapshots, and recovery.

## Bugs

Specula found 1 new bug:

- **Fixed:** A debug invariant repeats the same predicate on both sides of an `or`, making the intended readiness check tautological (PR #7193).

Specula also found 1 previously known bug:

- **Open:** Re-enrolling a server with the same Raft member ID after clearing its inactive state can erase its vote history and permit it to vote twice in one term.
