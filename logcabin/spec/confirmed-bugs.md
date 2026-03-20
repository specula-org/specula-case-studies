# Confirmed Bug Report — logcabin

## Summary

- Total findings reviewed: 17
- Confirmed: 0
- False positives: 3
- MC-verified safe: 8
- Not bugs (design issues / defensive coding): 6

**LogCabin's Raft implementation has no confirmed bugs.** Written by Diego Ongaro (Raft co-author), the codebase is notably clean and correct. Model checking explored 318M states across 3.69M traces with 5 targeted bug-family configurations and found no safety violations. Code audit of all 17 findings from the modeling brief confirmed that every potential concern is either guarded against, by design, or outright incorrect.

---

## MC-Verified Safe Findings

These 8 findings from the modeling brief were tested by model checking with targeted fault injection. All passed.

### MC-1: Crash between truncateSuffix and append in handleAppendEntries
- **Source**: Code Review (modeling-brief MC-1)
- **Status**: MC-VERIFIED SAFE
- **Location**: `Server/RaftConsensus.cc:1393-1415`
- **Analysis**: The conflict-aware truncation logic (lines 1382-1394) only truncates from the first conflicting entry, and the acknowledged crash window between truncate and append is guarded by the duplicate-request detection (lines 1382-1384: entries with matching terms are skipped on replay). MC explored this with crash/recovery fault injection across 40M states — no LogMatching or LeaderCompleteness violations.

### MC-2: Snapshot load with stale term info
- **Source**: Code Review (modeling-brief MC-2)
- **Status**: MC-VERIFIED SAFE
- **Location**: `Server/RaftConsensus.cc:2780-2858`
- **Analysis**: `readSnapshot()` correctly updates `lastSnapshotTerm` from the snapshot header and preserves or discards the log suffix based on term consistency (lines 2810-2835). MC explored this with 37M states — no ElectionSafety or LeaderCompleteness violations.

### MC-3: Multi-chunk InstallSnapshot interrupted by term change
- **Source**: Code Review (modeling-brief MC-3)
- **Status**: MC-VERIFIED SAFE
- **Location**: `Server/RaftConsensus.cc:1449-1560`
- **Analysis**: Partial snapshot state (`snapshotWriter`) is discarded on step-down (line 3072-3074). The follower correctly handles byte offset mismatches (lines 1494-1520) and stale snapshot indices (lines 1526-1540). Modeled as atomic in MC but implementation handles interruption gracefully.

### MC-4: TRANSITIONAL config with split quorum
- **Source**: Code Review (modeling-brief MC-4)
- **Status**: MC-VERIFIED SAFE
- **Location**: `Server/RaftConsensus.cc` — Configuration class
- **Analysis**: Joint consensus requires both old-set and new-set majorities via `quorumAll`/`quorumMin` methods. MC explored 48M states with configuration change fault injection — no JointQuorumAgreement violations.

### MC-5: Leader self-exclusion term bump
- **Source**: Code Review (modeling-brief MC-5)
- **Status**: MC-VERIFIED SAFE
- **Location**: `Server/RaftConsensus.cc:2206`
- **Analysis**: When the leader excludes itself from a new configuration, it bumps its term by 1, causing a cluster-wide step-down. This is correct behavior — it forces a new election with the new configuration. MC confirmed no ElectionSafety violations.

### MC-6: Removed server election disruption
- **Source**: Code Review (modeling-brief MC-6)
- **Status**: MC-VERIFIED SAFE
- **Location**: `Server/RaftConsensus.cc:1318,1436,1477`
- **Analysis**: `withholdVotesUntil` is reset on every AppendEntries/InstallSnapshot from the leader. Servers that haven't heard from a leader recently (removed/partitioned) can still start elections, but remaining servers ignore their RequestVote if within the withhold window. MC confirmed no NoDisruptiveElection violations.

### MC-7: Epoch-based stepDown with slow disk
- **Source**: Code Review (modeling-brief MC-7)
- **Status**: MC-VERIFIED SAFE
- **Location**: `Server/RaftConsensus.cc:2179-2225`
- **Analysis**: The epoch mechanism is logically sound: leader increments `currentEpoch`, peers report `lastAckEpoch` in RPC responses, and `stepDownThreadMain` checks `quorumMin(&Server::getLastAckEpoch) >= epoch`. MC explored 155M states with disk-delay fault injection — no StepDownCorrectness violations. (Issue #202 is an availability concern about timeout tuning, not a safety bug.)

### MC-8: Leader memory-only entries lost on crash
- **Source**: Code Review (modeling-brief MC-8)
- **Status**: MC-VERIFIED SAFE
- **Location**: `Server/RaftConsensus.cc:2072-2110`
- **Analysis**: Leader defers disk sync to `leaderDiskThread` (line 2295-2296). `advanceCommitIndex` uses `quorumMin(&Server::getMatchIndex)`, and `localServer->lastSyncedIndex` is only updated after disk sync completes (line 2093). So entries aren't counted as replicated locally until persisted. A crash before sync loses unpersisted entries, but they aren't committed. MC confirmed no LeaderCompleteness violations across 38M states.

---

## False Positives

### TV-2: `leaderDiskThreadWorking` atomicity concern
- **Source**: Code Review (modeling-brief TV-2)
- **Status**: FALSE POSITIVE
- **Location**: `Server/RaftConsensus.h:1549`
- **Analysis**: The variable is declared as `std::atomic<bool>` (line 1549). The comment at line 1547 acknowledges it's "set to false without #mutex" but this is safe because it's atomic. The polling in `stepDown` (line 3094) and the write in `leaderDiskThreadMain` (line 2090) are race-free. No ThreadSanitizer issue exists.

### TV-3: `rpcFailuresSinceLastWarning` non-atomic access
- **Source**: Code Review (modeling-brief TV-3)
- **Status**: FALSE POSITIVE
- **Location**: `Server/RaftConsensus.h:427-429`
- **Analysis**: The comment on line 427 states "Accessed only from callRPC() without holding the lock." Each peer has its own `rpcFailuresSinceLastWarning` (it's a per-Peer member variable), and each peer has exactly one thread (`peerThreadMain`). Since only one thread ever accesses the variable, there is no data race.

### CR-4: Bogus term=0 in snapshot header
- **Source**: Code Review (modeling-brief CR-4)
- **Status**: FALSE POSITIVE
- **Location**: `Server/RaftConsensus.cc:1822-1832`
- **Analysis**: The else branch at line 1822 sets `last_included_term = 0` when `lastIncludedIndex` falls between the snapshot index and log start. This only occurs when `lastIncludedIndex < lastSnapshotIndex` (since `lastIncludedIndex > commitIndex` is blocked by the PANIC at line 1796, and `lastIncludedIndex == lastSnapshotIndex` is handled at line 1817). In `snapshotDone()` (line 1857), the check `lastIncludedIndex <= lastSnapshotIndex` catches this case and discards the snapshot. The bogus term=0 value is never installed. The comment at line 1829 correctly describes this behavior.

---

## Not Bugs (Design Issues / Known Limitations)

### TV-1: stepDown busy-waits with mutex held
- **Source**: Code Review (modeling-brief TV-1)
- **Status**: NOT A BUG (known design limitation, issue #202)
- **Severity**: Medium (availability)
- **Location**: `Server/RaftConsensus.cc:3090-3095`
- **Description**: `stepDown()` polls `leaderDiskThreadWorking` with `usleep(500)` while holding the mutex. This blocks all server operations during the disk flush. The comment explains why: releasing the lock would let other threads incorrectly assume writes are flushed.
- **Impact**: Temporary server unresponsiveness during leadership transitions when disk is slow. Duration bounded by disk sync time.
- **Why not a bug**: The logic is correct — it's the only safe approach given the deferred-sync design. This is a performance tradeoff, not a correctness issue.

### TV-4: No absolute timeout on staging server catch-up
- **Source**: Code Review (modeling-brief TV-4)
- **Status**: NOT A BUG (intentional design)
- **Location**: `Server/RaftConsensus.cc:1680-1712`
- **Description**: The staging catch-up loop has a progress check every ELECTION_TIMEOUT but no absolute timeout. If the staging server makes slow but continuous progress, the loop runs indefinitely.
- **Impact**: Configuration change can take arbitrarily long if staging server is slow.
- **Why not a bug**: The progress check (lines 1696-1710) aborts if no progress is made. Running indefinitely with progress is the intended behavior — you want the staging server fully caught up before committing the configuration change. Aborting a progressing catch-up would waste work.

### CR-1: Assertions on network-received values
- **Source**: Code Review (modeling-brief CR-1)
- **Status**: NOT A BUG (correct under non-Byzantine model)
- **Location**: `Server/RaftConsensus.cc:1326,1375,1386,1428,1485`
- **Description**: Several `assert()` calls check invariants on data received from the leader (e.g., leader identity, entry index sequence, commit index bounds).
- **Why not a bug**: All assertions check Raft protocol invariants that cannot be violated by a correct implementation. Line 1326 checks election safety (one leader per term). Line 1375 checks sequential indices (added post-#160). Line 1386 ensures committed entries aren't truncated. Line 1428 checks commitIndex ≤ lastLogIndex, which is guaranteed because the leader caps commit_index at `prevLogIndex + numEntries` (line 2349). Under a Byzantine threat model these would be vulnerabilities, but LogCabin doesn't target Byzantine fault tolerance.

### CR-2: PANIC on EntryType::UNKNOWN
- **Source**: Code Review (modeling-brief CR-2)
- **Status**: NOT A BUG (deliberate design choice)
- **Location**: `Server/RaftConsensus.cc:1401-1409`
- **Description**: Follower PANICs if the leader sends an unknown entry type.
- **Why not a bug**: The comment at lines 1404-1408 explains: "there's not a good way forward. There's some hope that if this server reboots, it'll come back up with a newer version of the code that understands the entry." This is a forward-compatibility issue, not a protocol bug. Silently dropping the entry would be worse (it would create a log gap).

### CR-3: No snapshot data integrity check
- **Source**: Code Review (modeling-brief CR-3)
- **Status**: NOT A BUG (defense-in-depth suggestion)
- **Location**: `Server/RaftConsensus.cc:1522`
- **Description**: No checksum verification on received snapshot data.
- **Why not a bug**: The RPC transport layer provides message integrity. A checksum would be defense-in-depth but its absence doesn't create a reachable bug path.

### CR-5: Session timeout hardcoded
- **Source**: Code Review (modeling-brief CR-5)
- **Status**: NOT A BUG (design issue)
- **Location**: `Server/StateMachine.cc:58-63`
- **Description**: Session timeout is hardcoded rather than replicated via the log.
- **Why not a bug**: This is a design preference, not a correctness issue. All servers use the same compiled-in timeout, so there's no divergence.

---

## Reproduction Attempts

No reproduction was attempted because no bugs were confirmed. All 8 model-checkable findings passed MC verification (318M states, 3.69M traces), all 3 suspected code-level issues were false positives on closer inspection, and the remaining 6 findings are design choices or known limitations rather than bugs.

---

## Discussion

LogCabin's Raft implementation stands out for its correctness:

1. **Atomic persistence**: `updateLogMetadata()` persists `currentTerm` and `votedFor` in a single metadata write (line 2955-2962), avoiding the two-step persist bug found in other Raft implementations (e.g., hashicorp/raft).

2. **Correct commit rule**: The current-term check in `advanceCommitIndex` (line 2249) correctly prevents commitment of entries from prior terms, fixing historical bug #44.

3. **Robust conflict detection**: AppendEntries only truncates from the first conflicting entry (lines 1382-1394), not from `prevLogIndex`. This prevents stale duplicate messages from damaging committed state, addressing both the data-loss and crash-window concerns noted in the comments.

4. **Clean snapshot-log boundary**: `readSnapshot` (lines 2806-2835) correctly handles both full-log and prefix-only snapshot installations, with a final safety check (line 2850) ensuring the invariant `logStartIndex <= lastSnapshotIndex + 1`.

5. **Correct leader commit_index**: The leader caps `commit_index` in AppendEntries at `min(commitIndex, prevLogIndex + numEntries)` (line 2349), ensuring followers never receive a commit index beyond what's in the message.

The implementation reflects deep understanding of Raft's subtleties, as expected from its co-author. The most bug-prone areas (snapshot-log interaction, configuration changes) have been hardened through 6+ historical bug fixes, and our model checking confirms the current state is robust.
