# goraft

## Scope

Specula analyzed and tested goraft's Raft core, including elections, log replication, concurrent peer heartbeats, membership commands, snapshot installation and recovery, and persistence across server, log, and peer state.

## Bugs

Specula found 5 new bugs:

- Log compaction seeks on the old file while encoding into the new file, so recorded entry positions refer to the wrong file offsets.
- **Open:** The leader commits the median replicated index without checking that the entry is from its current term, violating Raft's previous-term commitment rule; see PR #1.
- `currentTerm` and `votedFor` are not persisted, so a crash can reset the vote record and let a node vote twice in one term.
- Snapshot recovery overwrites `currentTerm` without clearing `votedFor`, leaving inconsistent voting state.
- `RequestVote` uses a disjunctive comparison of the local index and term instead of Raft's lexicographic rule, rejecting a candidate with a newer last log term and shorter log.
