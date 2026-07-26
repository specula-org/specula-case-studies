# Dragonboat

## Scope

Specula analyzed and tested Dragonboat's multi-group Raft core, including elections and PreVote, replication and heartbeats, quorum checking, leadership transfer, configuration changes, persistence ordering, and non-voting and witness roles.

## Bugs

Specula found 1 new bug:

- `saveSnapshot` returns `nil` instead of its persistence error, causing the caller to treat an unsuccessful batch as saved and risking lost Raft log entries after a crash; PR #409 remains open.
