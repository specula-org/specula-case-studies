# Confirmed Bug Report — goraft

## Summary

- Total findings reviewed: 10 (3 MC-confirmed bugs, 4 code-review families, 3 code-review-only items)
- Confirmed: 5 (3 reproduced, 2 code-audit only)
- False positives: 1
- Inconclusive: 1
- Out of scope: 3 (defensive coding / style)

---

## Bug 1: Non-Persistent currentTerm/votedFor Enables Double-Voting After Crash

- **Source**: MC (25-state counterexample, ElectionSafety violated) + Code Review (Family 1)
- **Status**: REPRODUCED
- **Severity**: Critical
- **Location**: `server.go:118,120` (field declarations); `server.go:1407-1434` (`writeConf()`)

### Description

Raft requires `currentTerm` and `votedFor` on stable storage before responding to any RPC (Figure 2). goraft stores these as plain struct fields in memory (`server.go:118,120`). The `writeConf()` function (`server.go:1407-1434`) only persists `commitIndex` and peer configuration — it never saves term or vote state. On restart, `Init()` (`server.go:511`) recovers `currentTerm` from the last log entry's term, and `votedFor` resets to `""`.

### Trigger Scenario

1. Server s1 joins a 3-server cluster and votes for candidateA at term 2
2. s1 crashes (process kill / power failure)
3. s1 restarts — `currentTerm` reverts to last log entry's term (0), `votedFor` is `""`
4. s1 votes for candidateB at term 2 (double-vote)
5. Both candidateA and candidateB achieve quorum → two leaders at term 2

### Reproduction

Test: `TestBug1_NonPersistentVotedFor_DoubleVoteAfterCrash` in `bug_repro_test.go`

```
After join: term=0, state=leader, logIndex=2
Before crash: term=2, votedFor="candidateA"
After crash: term=0, votedFor=""
BUG CONFIRMED: Server voted for candidateA at term 2 before crash,
  then voted for candidateB at term 2 after crash.
  votedFor was not persisted — Election Safety violated.
```

Additional test `TestBug1_NonPersistentCurrentTerm_TermRegression` confirms `currentTerm` regresses from 5 to 0 after crash.

### Recommendation

Persist `currentTerm` and `votedFor` to stable storage in `writeConf()` (or a separate durable write) before responding to any RPC that modifies them. Affected code paths: `updateCurrentTerm()`, `processRequestVoteRequest()`, `candidateLoop()`, `processSnapshotRecoveryRequest()`.

---

## Bug 2: Incorrect Log Comparison Rejects Valid Candidates

- **Source**: MC (46-state counterexample, LeaderCompleteness violated) + Code Review (Family 2)
- **Status**: REPRODUCED
- **Severity**: Critical
- **Location**: `server.go:1087`

### Description

The RequestVote log up-to-date check uses `||` (OR) instead of the correct lexicographic comparison from Raft Section 5.4.1:

```go
// goraft (WRONG):
if lastIndex > req.LastLogIndex || lastTerm > req.LastLogTerm {
    // reject
}

// Correct Raft:
if lastTerm > req.LastLogTerm || (lastTerm == req.LastLogTerm && lastIndex > req.LastLogIndex) {
    // reject
}
```

The `||` comparison is strictly more restrictive — it rejects candidates whose log has a higher term but fewer entries. In Raft, a log with a higher last-entry term is always more up-to-date regardless of length. This can prevent valid elections, and in specific configurations leads to electing a leader whose log is missing committed entries (LeaderCompleteness violation).

### Trigger Scenario

Server has log `[1@T1, 2@T1, 3@T1]` (lastIndex=3, lastTerm=1). Candidate requests vote with `lastLogIndex=1, lastLogTerm=2`. The candidate's log has a higher last-entry term (2 > 1), so it is more up-to-date per Raft. But goraft rejects it because `3 > 1` (lastIndex > req.LastLogIndex).

### Reproduction

Test: `TestBug2_WrongLogComparison_RejectsHigherTermCandidate` in `bug_repro_test.go`

```
BUG CONFIRMED: Vote denied for candidate with lastLogTerm=2, lastLogIndex=1
  Server's log: lastLogTerm=1, lastLogIndex=3
  Correct Raft: candidate's log is more up-to-date (higher term)
  goraft's || comparison rejects it because server has more entries
  server.go:1087: 'if lastIndex > req.LastLogIndex || lastTerm > req.LastLogTerm'
```

Additional test `TestBug2_CorrectVsIncorrect_Comparison` shows the specific (index, term) pairs where goraft and correct Raft disagree.

### Recommendation

Replace the comparison at `server.go:1087` with the correct lexicographic check:
```go
if lastTerm > req.LastLogTerm || (lastTerm == req.LastLogTerm && lastIndex > req.LastLogIndex) {
```

---

## Bug 3: Leader Commits Previous-Term Entries Without Term Check

- **Source**: MC (68-state counterexample, CommitTermSafety violated) + Code Review (Family 3)
- **Status**: REPRODUCED
- **Severity**: Critical
- **Location**: `server.go:1008-1030` (`processAppendEntriesResponse`)

### Description

The commit advancement in `processAppendEntriesResponse` computes the median `matchIndex` among peers and sets `commitIndex` to that value without verifying that the entry at the commit index is from the current term. Raft Section 5.4.2 (Figure 8) requires: "a leader does not commit entries from previous terms by counting replicas — only entries from the leader's current term are committed by counting replicas."

The `syncedPeer` mechanism (`server.go:1004-1006`) is a partial mitigation: it gates commit advancement on at least one peer having replicated a current-term entry. But this doesn't ensure the commit target index itself has a current-term entry — the median can land on an older-term entry.

### Trigger Scenario

1. Leader s1 at term 1 appends entries `[1@T1]` and replicates to peers
2. s2 becomes leader at term 2
3. s2 sends AppendEntries to peers, peers respond successfully
4. After a quorum of `syncedPeer` is achieved, `processAppendEntriesResponse` computes median matchIndex = 1
5. Entry at index 1 has term 1 (not term 2), but s2 commits it anyway
6. This violates Figure 8: the entry from term 1 could be overwritten by a future leader

### Reproduction

Test: `TestBug3_CommitWithoutTermCheck` in `bug_repro_test.go`

```
Leader at term 2 committed entry at index 1 with term 1
BUG CONFIRMED: Leader at term 2 committed entry at index 1 from term 1
  Raft Section 5.4.2: leader must only commit entries from its current term.
  server.go:1022: commitIndex is set to median matchIndex without term check.
```

Additional test `TestBug3_MissingTermCheckInCode` confirms with a larger log: leader at term 2 commits index 2 which has term 1.

### Recommendation

Add a term check before advancing commitIndex:
```go
if commitIndex > committedIndex {
    entry := s.log.getEntry(commitIndex)
    if entry != nil && entry.Term() == s.currentTerm {
        s.log.sync()
        s.log.setCommitIndex(commitIndex)
    }
}
```

---

## Bug 4: Snapshot Recovery Overwrites Term Without Clearing votedFor

- **Source**: Code Review (Family 4)
- **Status**: CONFIRMED (code audit)
- **Severity**: Medium
- **Location**: `server.go:1289-1313` (`processSnapshotRecoveryRequest`); `server.go:1267-1281` (`processSnapshotRequest`)

### Description

Two issues in the snapshot handling:

1. `processSnapshotRequest` (`server.go:1267-1281`) has no term validation. The `SnapshotRequest` struct (`snapshot.go:43-47`) lacks a `Term` field entirely. Any node can trigger `setState(Snapshotting)` on a follower regardless of term.

2. `processSnapshotRecoveryRequest` (`server.go:1302`) overwrites `currentTerm` with `req.LastTerm` but does NOT clear `votedFor`. This leaves the server in an inconsistent state: `votedFor` may reference a candidate from a different term than `currentTerm`.

### Why Not Reproduced

MC explored 382M states without finding a violation. The snapshot flow is only triggered when the leader's log doesn't have the entries the follower needs (log compacted), and in practice the leader's snapshot term is >= the follower's current term. The inconsistency is real but difficult to exploit through normal protocol flows.

### Recommendation

1. Add a `Term` field to `SnapshotRequest` and validate `req.Term >= s.currentTerm` in `processSnapshotRequest`
2. Clear `votedFor` in `processSnapshotRecoveryRequest` after updating `currentTerm`

---

## Bug 5: Log Compaction Writes Wrong File Positions

- **Source**: Code Review (Family 6, TV-1)
- **Status**: CONFIRMED (code audit)
- **Severity**: Medium
- **Location**: `log.go:601-603`

### Description

In `compact()`, the code seeks on the **old** file handle (`l.file`) to get position values, but writes entries to the **new** file:

```go
for _, entry := range entries {
    position, _ := l.file.Seek(0, os.SEEK_CUR)  // OLD file position
    entry.Position = position
    if _, err = entry.Encode(file); err != nil {  // writes to NEW file
```

After compaction, all entries have incorrect `Position` values (they reference positions in the old file, not the new one). This could cause corruption when entries are later read by position (e.g., during truncation).

### Why Not Reproduced

This is a file I/O implementation bug, not a protocol logic bug. It would require a specific sequence of compact → truncate → read-by-position to manifest as observable data corruption. It does not affect in-memory protocol correctness and is outside the scope of TLA+ model checking.

### Recommendation

Change `l.file.Seek(0, os.SEEK_CUR)` to `file.Seek(0, os.SEEK_CUR)` at `log.go:602` to seek on the new file handle.

---

## FALSE POSITIVE: Stale-Term Heartbeat (Family 5)

- **Source**: Code Review (Family 5) + MC (208M states, no violation)
- **Status**: FALSE POSITIVE
- **Severity**: N/A (for protocol safety)

### Description

Per-peer heartbeat goroutines read `currentTerm` without locks (`peer.go:173`), potentially sending AppendEntries with a stale term after the leader has stepped down.

### Why False Positive

Followers correctly reject AppendEntries with stale terms via the term check at `server.go:942-944`:
```go
if req.Term < s.currentTerm {
    return newAppendEntriesResponse(s.currentTerm, false, ...), false
}
```

MC confirmed this with 208M states: no safety violation from stale-term heartbeats. The data race is real (detectable by Go race detector) but the protocol-level impact is benign — followers always reject stale-term messages.

---

## Out of Scope

The following code-review findings were excluded as they are defensive coding / error handling issues, not protocol logic bugs:

| ID | Description | Category |
|----|-------------|----------|
| CR-1 | `processSnapshotRecoveryRequest` panics on recovery error (`server.go:1291-1293`) | Error handling |
| CR-2 | `writeConf` ignores `os.Rename` error (`server.go:1433`) | Error handling |
| CR-3 | `readConf` silently accepts missing file (`server.go:1444-1446`) | Intentional for first boot |

---

## Reproduction Test File

All reproduction tests are in `artifact/raft/bug_repro_test.go`. Run with:
```bash
cd case-studies/goraft/artifact/raft
go test -v -run 'TestBug1|TestBug2|TestBug3' -timeout 60s -vet=off
```

All 6 tests pass, confirming all 3 critical bugs:
- `TestBug1_NonPersistentVotedFor_DoubleVoteAfterCrash` — PASS (bug manifested)
- `TestBug1_NonPersistentCurrentTerm_TermRegression` — PASS (bug manifested)
- `TestBug2_WrongLogComparison_RejectsHigherTermCandidate` — PASS (bug manifested)
- `TestBug2_CorrectVsIncorrect_Comparison` — PASS (comparison divergence shown)
- `TestBug3_CommitWithoutTermCheck` — PASS (bug manifested)
- `TestBug3_MissingTermCheckInCode` — PASS (bug manifested)
