# Modeling Targets: etcd-raft

## Prioritized List

### Target 1: Config Change Safety with Joint Consensus (HIGHEST PRIORITY)
**Why**: Issue #372 describes a concrete scenario where EnterJoint() allows removing 2 nodes simultaneously, creating a configuration where old and new quorums don't overlap. This can lead to committed entries being lost. The etcd implementation applies config changes at commit time (not append time like the paper), making quorum overlap critical.

**What to model**:
- Joint consensus: Voters[0] (incoming) and Voters[1] (outgoing)
- Config change proposal with pendingConfIndex guard
- Config change application at commit time (applyConfChange)
- Quorum calculation with JointConfig.CommittedIndex (min of both majorities)
- Multiple node additions/removals in a single EnterJoint

**Key code**: raft.go:1301-1339 (proposal), raft.go:1947-2031 (application), confchange/confchange.go:51-78 (EnterJoint), quorum/joint.go:49-56 (CommittedIndex)

**Bug we're hunting**: Can committed entries be lost when joint consensus transitions involve non-overlapping quorums?

### Target 2: Election Safety with PreVote and CheckQuorum
**Why**: PreVote (B4) has had past bugs. The interaction between PreVote, CheckQuorum, and the `lead` field in canVote (raft.go:1206-1210) is complex. The `inLease` check (raft.go:1095-1096) adds another dimension.

**What to model**:
- PreVote phase (StatePreCandidate)
- canVote logic with all 3 conditions (vote==from, vote==Nil&&lead==Nil, preVote&&term>currentTerm)
- CheckQuorum leader step-down
- inLease guard (prevents vote if recently heard from leader)
- campaignTransfer bypassing PreVote

**Key code**: raft.go:1085-1263 (Step term handling + vote), raft.go:917-931 (becomePreCandidate), raft.go:1025-1073 (campaign)

**Bug we're hunting**: Can two leaders exist in the same term? Can a PreVote interaction with CheckQuorum cause elections to stall or violate safety?

### Target 3: Log Consistency under Leader Changes
**Why**: The handleAppendEntries logic (raft.go:1786-1828), combined with the findConflict mechanism and the two-phase commit (maybeCommit via trk.Committed), is the core of log safety. The commit advancement (raft.go:778-781) only advances for entries in the current term — a key Raft safety property.

**What to model**:
- AppendEntries with conflict detection and log truncation
- Commit index advancement (only current term entries)
- Leader election completeness (new leader has all committed entries)
- Log matching invariant

**Key code**: raft.go:616-660 (maybeSendAppend), raft.go:778-781 (maybeCommit), raft.go:1786-1828 (handleAppendEntries), log.go:107-129 (maybeAppend)

**Bug we're hunting**: Can log matching invariant be violated? Can committed entries be lost during leader transitions?

### Target 4: pendingConfIndex Guard Effectiveness
**Why**: The guard (raft.go:1318: `alreadyPending = pendingConfIndex > raftLog.applied`) uses `applied` not `committed`. Since applied can lag behind committed, there's a window where a second config change could be proposed while the first is committed but not yet applied. Issue #354 shows the silent failure mode.

**What to model**:
- pendingConfIndex set on proposal, cleared on application
- Gap between committed and applied
- Interaction with leader changes (pendingConfIndex set to lastIndex on becoming leader)

**Key code**: raft.go:1317-1339, raft.go:958 (becomeLeader sets pendingConfIndex)

**Bug we're hunting**: Can two config changes be committed before the first is applied? Does the conservative guard in becomeLeader (setting pendingConfIndex = lastIndex) cause availability issues?

## Scope Decision

For the TLA+ spec, I will focus on **Targets 1-3** together in a single specification, as they share the core state variables (term, log, config, votes). Target 4 naturally falls out of modeling Target 1's config change logic.

Key abstractions:
- **Abstract away**: Storage persistence details, flow control (Inflights), message batching, snapshot contents, ReadIndex, leader transfer
- **Model faithfully**: Joint consensus config changes, PreVote, CheckQuorum, canVote logic, commit advancement, log append/conflict, election
