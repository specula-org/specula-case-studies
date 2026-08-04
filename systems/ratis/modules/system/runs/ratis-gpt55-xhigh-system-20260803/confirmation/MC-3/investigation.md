# MC-3 Investigation

## Step 1: Code audit

Affected path:

- `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java:642`: `changeToFollowerAndPersistMetadata` calls `changeToFollower`, then calls `state.persistMetadata()` only when `metadataUpdated` is true.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/RaftServerImpl.java:598-631`: `changeToFollower` mutates volatile state before persistence. In the follower/no-force path it still calls `state.updateCurrentTerm(newTerm)`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/ServerState.java:213-220`: `updateCurrentTerm` raises `currentTerm`, clears `votedFor`, clears `leaderId`, and returns true when `newTerm > current`.
- `ratis-server/src/main/java/org/apache/ratis/server/impl/ServerState.java:246-253`: `persistMetadata` builds metadata from volatile `currentTerm`/`votedFor` and delegates to the raft log.
- `ratis-server/src/main/java/org/apache/ratis/server/raftlog/segmented/SegmentedRaftLog.java:497-503`: persistent logs store/load metadata through `storage.getMetadataFile()`.
- `ratis-server/src/main/java/org/apache/ratis/server/storage/RaftStorageMetadataFileImpl.java:75-84`: metadata is atomically written to `raft-meta`; an `IOException` prevents the new metadata object from being returned and cached.
- `ratis-server/src/main/java/org/apache/ratis/server/storage/RaftStorageImpl.java:105-118`: startup deletes incomplete `raft-meta.tmp` and reads durable `raft-meta`.

AppendEntries reachability:

- `RaftServerImpl.appendEntries` is a server-to-server RPC entry point. It checks lifecycle, group, and entry shape, then calls `appendEntriesAsync`.
- `RaftServerImpl.java:1669-1685` handles AppendEntries under the server lock: it reads `currentTerm`, calls `state.recognizeLeader`, calls `changeToFollowerAndPersistMetadata(leaderTerm, true, Op.APPEND_ENTRIES)`, then sets `leaderId`.
- `ServerState.java:337-350` recognizes a same-term leader as long as the term is not lower and there is no different known leader for the same term.
- If the first higher-term AppendEntries reaches `changeToFollowerAndPersistMetadata` and `state.persistMetadata()` fails, the caller gets an `IOException` but volatile `currentTerm` has already been raised.
- A later AppendEntries from the same leader and same term reaches `recognizeLeader`; because `peerTerm == currentTerm` and `leaderId` is still null, it is recognized. `updateCurrentTerm(peerTerm)` returns false, so `metadataUpdated` is false and the code skips a metadata retry.

Crash/restart consequence:

- `ServerState.initialize` loads `currentTerm` only from `log.get().loadMetadata()` at `ServerState.java:139-141`.
- Therefore, after accepting a same-term leader while `raft-meta` still contains the old term, a crash/restart restores the older term.
- After restart, `requestVote` can grant a vote in that same term to another candidate: `VoteContext.java:72-88` treats a restarted `currentTerm` lower than `candidateTerm` as `SKIP_CHECK_LEADER`, and `RaftServerImpl.java:1530-1539` changes term, optionally grants vote, and persists metadata.

Concrete trigger scenario:

1. Follower `s2` starts with durable term 0.
2. A legitimate AppendEntries heartbeat from peer `s1` at term 1 reaches `s2`.
3. The real metadata write to `raft-meta.tmp`/`raft-meta` fails with `IOException`, after `s2.currentTerm` has already become 1.
4. The storage fault clears.
5. `s1` retries a same-term AppendEntries heartbeat. `s2` recognizes `s1` and returns `AppendResult.SUCCESS`, but `raft-meta` remains term 0 because same-term `updateCurrentTerm` does not request persistence.
6. `s2` crashes and restarts from disk, restoring current term 0.
7. Candidate `s3` sends `RequestVote(term=1)` and `s2` grants it, despite having previously accepted `s1` as leader in term 1.

Safeguards checked:

- The `IOException` path in `appendEntriesAsync` returns exceptionally and does not set `leaderId`, but it also does not roll back volatile `currentTerm`.
- The second same-term AppendEntries does not retry persistence because `metadataUpdated` is false.
- Startup recovery deletes `raft-meta.tmp`, but it cannot reconstruct the lost term from volatile memory.

## Step 2: Developer-knowledge search

Code comments:

- `RaftStorageMetadataFileImpl.java:69-74` documents the developer intent that term/votedFor metadata is atomically written and fsynced, and that an `IOException` means the file cannot be written.
- `RaftStorageImpl.java:105-110` documents the recovery intent for `raft-meta.tmp`: an uncommitted metadata change is discarded on startup.
- No nearby TODO/FIXME/comment states that accepting a leader term without durable term metadata is intentional or tolerated.

Blame/history:

- `git blame` shows `RaftServerImpl.changeToFollowerAndPersistMetadata` has long-standing persistence-after-volatile-update behavior, with recent refactoring around `7f10888a41` and older persistence call ancestry from 2016.
- `git blame` shows `ServerState.updateCurrentTerm` and `recognizeLeader` are independent paths; no blame message near these lines describes a deliberate metadata-retry skip.
- `git log --all --since=2026-07-01` over `RaftServerImpl.java`, `ServerState.java`, and metadata storage paths found only unrelated `RATIS-2559` changes, not a fix for this mechanism.
- `git diff HEAD..origin/release-3.3.0` over the affected files showed no changes.

Issue/PR search:

- Ran GitHub issue/PR searches in `apache/ratis` for `raft-meta term persistMetadata`, `metadata persist failure currentTerm`, `changeToFollowerAndPersistMetadata`, `recognizeLeader persisted term`, `RaftStorageMetadata`, `raft-meta`, `persistMetadata`, and `votedFor term`.
- These searches returned no existing issue or PR reporting this exact same mechanism at the same site.

## Step 3: Known-status / precedent

Known-status evidence found no same-site upstream issue, PR, CVE, advisory, or recent merged/closed PR for this mechanism. Novelty evidence supports `NEW`.
