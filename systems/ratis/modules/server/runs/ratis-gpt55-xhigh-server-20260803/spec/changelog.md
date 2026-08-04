## Round 1 - Trace Validation

## Round 1 - Model Checking
- [fix-spec] MCRaftLogBase_appendEntry_CacheAndQueue: fixed the MC wrapper to pass `kind` and `p` through to `RaftLogBase_appendEntry_CacheAndQueue`, matching the base action used by trace validation.
- [fix-spec] CrashAndRecover: cleared in-flight async flush state on recovery after `FlushIndexWithinPublishedWrites` found a pre-crash flush completion firing after restart; real Ratis rebuilds `ServerState`/`SegmentedRaftLogWorker` from durable storage, so old callback state does not survive crash recovery.

## Round 2 - Trace Validation

## Round 2 - Model Checking
- [pass] MC.cfg: 30-minute BFS budget reached with no invariant violation or TLC error; last progress line reported level 11, 670,908,177 generated states, 153,350,221 distinct states, and 145,647,048 queued states.

## Bug Hunting
- [bug] MC_hunt_scenario1.cfg / CommittedImpliesDurableFlush: async flush failure can still advance `flushIndex`, allowing `LeaderStateImpl` commit advancement while the log entry is not durable (`spec/output/MC_hunt_scenario1_bfs.out`, 9-state trace). Implementation anchor: `SegmentedRaftLogWorker.asyncFlushOutStream` calls `updateFlushedIndexIncreasingly(lastWrittenIndex)` even when `e != null`.
- [fix-spec] MC_hunt_scenario2.cfg / LeaderCompleteness: rejected the 32-state trace as Case B after it executed `LeaderStateImpl_commitOldNewConf` on `s3` while `role[s3] = Listener`; tightened leader-only configuration/catch-up actions, restored `formatEmptyStorage` to `BootstrapConf` instead of full `Server`, and made `CrashAndRecover` replay durable config-log state when `confLogIndex` is covered by `diskLog`.
- [fix-spec] MC_hunt_scenario2.cfg / LeaderCompleteness: rejected the 26-state simulation trace as Case B after it executed `RaftLogBase_appendMetadata` on `s3` while `role[s3] = Follower`; added the missing leader guard because production `appendMetadata` is reached from `LeaderStateImpl.logMetadata`.
- [fix-spec] MC_hunt_scenario2.cfg / RecoveredCommitCovered: rejected the 36-state simulation trace as Case B after `RaftServerImpl_appendEntriesAsync_Success` updated `metadataCommitIndex` for a follower-replicated metadata entry that was only volatile; production follower append does not update `lastMetadataEntry` in `SegmentedRaftLog.appendEntryImpl`, and durable metadata is loaded during `RaftLogBase.open`.
- [fix-spec] Crash/recovery metadata: refined the previous metadata fix so successful flush of a metadata entry advances the recoverable `metadataCommitIndex`; this preserves the `crash_recover.ndjson` behavior where `s2` recovers `commitIndex=1` only after entry 2 was flushed.
- [fix-spec] MC_hunt_scenario2.cfg / RecoveredCommitCovered: rejected the 26-state simulation trace as Case B after `RaftStorageImpl_formatEmptyStorage` formatted a live leader with existing durable log state; production formatting is reached only for FORMAT startup or NOT_FORMATTED current-empty storage, so the action now requires empty local storage/log-worker state.
- [fix-spec] MC_hunt_scenario2.cfg / ElectionSafety: rejected the 27-state simulation trace as Case B after a candidate counted a stale lower-term `RequestVoteReply` in a later election term; production `LeaderElection.waitForResults` is bound to one `electionTerm` and `shouldRun(electionTerm)` stops when the server term changes, so accepted vote replies now must match `currentTerm[c]`.
- [fix-spec] MC_hunt_scenario3.cfg / SnapshotInstallExclusion: rejected the 9-state trace as Case B after `appendReplyPending` retained a successful heartbeat reply that was produced before snapshot notification started; production rejects only new AppendEntries while `inProgressInstallSnapshotIndex` is set, so snapshot notification now clears this spec bookkeeping flag.
- [fix-spec] MC_hunt_scenario3.cfg / SnapshotInstallExclusion: rejected the follow-up 9-state trace as Case B because it used the source-unsupported `AcceptDuringSnapshotFault` transition; production `RaftServerImpl.checkInconsistentAppendEntries` returns INCONSISTENCY while snapshot installation is in progress, so that synthetic fault path was removed from `Next`/`MCNext`.
- [fix-inv] MC_hunt_scenario4.cfg / ReadIndexRequiresCurrentLeader: rejected the 11-state trace as Case A because `leaderStateGeneration` counts leader-state creations, not Raft terms; production may advance election term multiple times before a single `changeToLeader`, so the invariant now requires an active leader generation rather than equality with `currentTerm`.
- [bug] MC_hunt_scenario4.cfg / NoOldLeaderLeaseRead: `LogAppenderDefault` updates a follower's lease timestamp before handling a `NOT_LEADER`/higher-term AppendEntries reply, so a concurrent read can extend the leader lease and use the lease fast path before the reply forces stepdown or rejection handling (`spec/output/MC_hunt_scenario4_bfs_round10.out`, 11-state trace).
- [fix-spec] MC_hunt_scenario5.cfg / DurableConfigMatchesRecoveredRole: rejected the 7-state trace as Case B after a recovered follower executed `RaftLogBase_appendEntry_CacheAndQueue` directly for a config entry; production local client/config appends are leader-local, while follower replication is modeled by AppendEntries success, so the local append action now requires `role[s] = Leader`.
- [fix-inv] MC_hunt_scenario5.cfg / DurableConfigMatchesRecoveredRole: rejected the 3-state trace as Case A after a recovered listener accepted a new config AppendEntries and updated in-memory config/role before the entry was durable; production `appendEntries` calls `state.updateConfiguration(entries)` before appending the entries, so the invariant now checks only states still aligned with durable recovery evidence.
- [fix-spec] MC_hunt_scenario5.cfg / JointConfigMajorityOverlap: rejected the 10-state trace as Case B because it used the source-unsupported `LeaderStateImpl_commitConfigWithoutOldMajorityFault` transition; production `LeaderStateImpl.getMajorityMin` combines old and new configuration majorities and `RaftConfigurationImpl.hasMajority` requires both, so that synthetic fault path was removed from `Next`/`MCNext`.

## Round 3 - Trace Validation
- [pass] Trace.cfg: all four existing traces passed after the scenario2 Case B spec fix (`crash_recover.ndjson`, `normal_append.ndjson`, `read_index.ndjson`, `reconfiguration.ndjson`).

## Round 3 - Model Checking
- [pass] MC.cfg: 30-minute BFS budget reached with no invariant violation or TLC error; last progress line reported level 11, 838,389,749 generated states, 183,554,573 distinct states, and 173,910,923 queued states.

## Round 4 - Trace Validation
- [pass] Trace.cfg: all four existing traces passed after the `RaftLogBase_appendMetadata` leader-guard fix.

## Round 4 - Model Checking
- [pass] MC.cfg: 30-minute BFS budget reached with no invariant violation or TLC error; last progress line reported level 11, 804,591,687 generated states, 177,445,389 distinct states, and 168,138,358 queued states.

## Round 5 - Trace Validation
- [pass] Trace.cfg: all four existing traces passed after the durable metadata flush refinement.

## Round 5 - Model Checking
- [pass] MC.cfg: 30-minute BFS budget reached with no invariant violation or TLC error; last progress line reported level 11, 847,819,190 generated states, 186,006,517 distinct states, and 176,235,222 queued states.

## Round 6 - Trace Validation
- [pass] Trace.cfg: all four existing traces passed after the empty-storage formatting guard.

## Round 6 - Model Checking
- [pass] MC.cfg: 30-minute BFS budget reached with no invariant violation or TLC error; last progress line reported level 10, 837,912,589 generated states, 183,240,842 distinct states, and 173,447,387 queued states.

## Round 7 - Trace Validation
- [pass] Trace.cfg: all four existing traces passed after the stale vote-reply term guard.

## Round 7 - Model Checking
- [pass] MC.cfg: 30-minute BFS budget reached with no invariant violation or TLC error; last progress line reported level 10, 854,530,999 generated states, 185,376,466 distinct states, and 175,457,064 queued states.

## Round 8 - Trace Validation
- [pass] Trace.cfg: all four existing traces passed after the snapshot-install append-reply bookkeeping fix.

## Round 8 - Model Checking
- [pass] MC.cfg: 30-minute BFS budget reached with no invariant violation or TLC error; last progress line reported level 10, 841,060,547 generated states, 183,021,692 distinct states, and 173,299,576 queued states.

## Round 9 - Trace Validation
- [pass] Trace.cfg: all four existing traces passed after removing the source-unsupported snapshot fault transition from `Next`/`MCNext`.

## Round 9 - Model Checking
- [pass] MC.cfg: 30-minute BFS budget reached with no invariant violation or TLC error; last progress line reported level 10, 834,307,828 generated states, 181,289,226 distinct states, and 171,630,111 queued states.

## Round 10 - Trace Validation
- [pass] Trace.cfg: all four existing traces passed after the `ReadIndexRequiresCurrentLeader` invariant refinement.

## Round 10 - Model Checking
- [pass] MC.cfg: 30-minute BFS budget reached with no invariant violation or TLC error; last progress line reported level 11, 853,818,777 generated states, 184,093,639 distinct states, and 174,250,502 queued states.

## Round 11 - Trace Validation
- [pass] Trace.cfg: all four existing traces passed after adding the leader guard to `RaftLogBase_appendEntry_CacheAndQueue`.

## Round 11 - Model Checking
- [pass] MC.cfg: 30-minute BFS budget reached with no invariant violation or TLC error; last progress line reported level 11, 846,569,744 generated states, 163,833,305 distinct states, and 150,293,848 queued states.

## Round 12 - Trace Validation
- [pass] Trace.cfg: all four existing traces passed after the `DurableConfigMatchesRecoveredRole` invariant refinement.

## Round 12 - Model Checking
- [pass] MC.cfg: 30-minute BFS budget reached with no invariant violation or TLC error; last progress line reported level 10, 854,210,308 generated states, 164,172,199 distinct states, and 150,492,933 queued states.

## Round 13 - Trace Validation
- [pass] Trace.cfg: all four existing traces passed after removing the source-unsupported config majority fault transition from `Next`/`MCNext`.

## Round 13 - Model Checking
- [pass] MC.cfg: 30-minute BFS budget reached with no invariant violation or TLC error; last progress line reported level 10, 851,827,289 generated states, 163,328,962 distinct states, and 149,630,711 queued states.

## Round 14 - Trace Validation
- [pass] Trace.cfg: all four existing traces passed after tightening `ServerState_initElection_ELECTION`.

## Round 14 - Model Checking
- [pass] MC.cfg: 30-minute BFS budget reached with no invariant violation or TLC error; last progress line reported level 11, 854,361,810 generated states, 154,965,889 distinct states, and 140,875,998 queued states.

## Round 14 - Bug Hunting
- [fix-spec] MC_hunt_scenario5.cfg / LeaderCompleteness: rejected the simulation trace as Case B after a listener outside the current voting configuration became candidate/leader; production follower election checks do not transition listener follower loops to candidate, and `LeaderElection` aborts when the local server is not in the election configuration, so `ServerState_initElection_ELECTION` now requires `voterRole[s] # Listener` and `s \in currentConf[s]`.
- [fix-spec] MC_hunt_scenario5.cfg / LeaderCompleteness: rejected the follow-up simulation trace as Case B after `ServerState_updateConfiguration_BeforeAppendDurable` mutated configuration without a real AppendEntries context; production calls `state.updateConfiguration(entries)` only after recognizing the AppendEntries leader, setting `leaderId`, and passing snapshot-in-progress inconsistency checks, so the action now requires follower role, a recognized recorded leader, and no snapshot install in progress.

## Round 15 - Trace Validation
- [pass] Trace.cfg: all four existing traces passed after the `ServerState_updateConfiguration_BeforeAppendDurable` AppendEntries-context guard.
- [pass] VAV: `base.tla` reported no missing or duplicate variable assignments across 92 operators and 56 variables.

## Round 15 - Model Checking
- [pass] MC.cfg: 30-minute BFS budget reached with no invariant violation or TLC error; last progress line reported level 12, 761,908,987 generated states, 143,518,721 distinct states, and 127,703,110 queued states.

## Round 15 - Bug Hunting
- [pass] MC_hunt_scenario5.cfg: stable BFS retry using `MSBDiskFPSet`, ParallelGC, `-Xmx24G`, and 4 workers reached the 30-minute budget with no violation; last progress line reported level 13, 104,666,351 generated states, 26,155,056 distinct states, and 21,329,747 queued states.
- [pass] MC_hunt_scenario5.cfg: 30-minute simulation reached 227,264,462 states checked and 18,500,526 traces generated with no invariant violation or TLC error.
- [env-limited] MC_hunt_scenario5.cfg: two earlier OffHeapDiskFPSet BFS attempts aborted with JVM SIGBUS and no TLC violation before the stable MSBDiskFPSet retry completed; treated as environment noise, not a spec or Ratis finding.

## Result
Converged for Phase 3 validation and bug hunting. Final model-checking artifacts report two source-backed candidate findings and no reproduced violations for scenarios 2, 3, or 5 after Case A/B spec fixes.
