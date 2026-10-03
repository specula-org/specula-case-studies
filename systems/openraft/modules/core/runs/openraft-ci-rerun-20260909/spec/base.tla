---------------------------- MODULE base ----------------------------
(*
 * Reference model for databendlabs/openraft 0.10.0, incrementally updated
 * from d5da3a0f168c532fa348edda44427649b422139e to
 * 15f927e1358d41ffc1297516f781029dbf8ca86a.
 *
 * Category A: distributed / message-passing.
 *
 * The model is scenario-driven:
 *   S1 - startup recovery and read admission;
 *   S2 - accepted/submitted/durable/flushed I/O boundaries;
 *   S3 - effective/committed membership and two-call API ownership;
 *   S4 - snapshot metadata, worker completion, and durable purge;
 *   S5 - independent replication, heartbeat, and ReadIndex paths.
 *
 * Snapshot contents are abstracted to metadata and a canonical committed
 * prefix.  Storage is assumed to obey OpenRaft's ordered-write and immediate
 * reader-visibility contract; violating stores are outside this model.
 *)

EXTENDS Integers, Naturals, Sequences, FiniteSets, TLC

CONSTANTS
    NodeCount, MaxIndex, MaxTerm, MaxClock, RequestCount,
    Payload, PersistCommitted,
    StandardMode, AdvancedMode, LeaderMode,
    Nil, NoRequest, NoMembership, NoopValue,
    Follower, Candidate, Leader, Down,
    Running, RecoverLoad, RecoverSnapshot, RecoverReplay, RecoverReady,
    NormalEntry, BlankEntry, MembershipEntry,
    AppendRequest, AppendResponse, HeartbeatRequest, HeartbeatResponse,
    ReadIndexRequest, ReadIndexResponse,
    VoteResponseKind, AppendResponseKind, HeartbeatResponseKind,
    ReadIndexResponseKind, ClientResponseKind,
    ReadIndexPolicy, LeaseReadPolicy,
    ReadIdle, ReadWaitQuorum, ReadWaitApply, ReadDone,
    RequestIdle, RequestStarted, RequestJointSubmitted,
    RequestJointCommitted, RequestUniformSubmitted, RequestDone,
    BuildIdle, BuildQueued, BuildRunning

Server == 1..NodeCount
Index == 1..MaxIndex
Term == 0..MaxTerm
Request == 1..RequestCount
VoteRankRange == 0..(2 * ((MaxTerm * (NodeCount + 1)) + NodeCount) + 1)

VARIABLES
    online, role, recoveryStage, recoveryReady,
    vote, persistentVote, acceptedIO, submittedIO, durableIO, flushedIO,
    engineLog, persistentLog,
    clusterCommitted, localCommitted, persistedCommitted,
    applySubmitted, smApplied, appliedLog,
    pendingLocalIO, pendingResponses, ackHistory, ioWatch, ioForwarded,
    committedLog, clientCompleted,
    committedMembership, effectiveMembership, membershipLog,
    changeRequests, requestPhase,
    candidateGranted, establishedVotes, voteSupport, voteMembership,
    leaderHistory, matchIndex, replicationSession,
    network, heartbeatEvent, clock, clockAck, leaseUntil,
    readBarrier, readEpoch, lastReadObserved, lastReadRequired,
    staleSessionEffect,
    buildPhase, buildTarget, buildMembership,
    snapshotMetaLast, snapshotMetaMembership,
    snapshotAccepted, snapshotSubmitted, snapshotFlushed,
    snapshotLast, snapshotMembership, installPending, installDone,
    purgeUpto, purgeCommand, durablePurged

Max2(a, b) == IF a >= b THEN a ELSE b
Min2(a, b) == IF a <= b THEN a ELSE b
MaxElem(S) == CHOOSE x \in S : \A y \in S : x >= y

Vote(t, n, committed) == [term |-> t, leader |-> n, committed |-> committed]
VoteRank(v) ==
    2 * ((v.term * (NodeCount + 1)) + v.leader)
      + IF v.committed THEN 1 ELSE 0
VoteGE(a, b) == VoteRank(a) >= VoteRank(b)
CommittedVote(v) == Vote(v.term, v.leader, TRUE)

IO(voteRank, logIndex) == [vote |-> voteRank, log |-> logIndex]
SetIOVote(io, voteRank) == [io EXCEPT !.vote = voteRank]
SetIOLog(io, logIndex) == [io EXCEPT !.log = logIndex]

InitialMembership ==
    [log |-> 0, old |-> Server, new |-> Server,
     joint |-> FALSE, request |-> NoRequest]

Membership(logIndex, oldVoters, newVoters, isJoint, requestId) ==
    [log |-> logIndex, old |-> oldVoters, new |-> newVoters,
     joint |-> isJoint, request |-> requestId]

VoterConfigs(m) == IF m.joint THEN {m.old, m.new} ELSE {m.new}
AllVoters(m) == m.old \cup m.new
IsQuorum(granted, m) ==
    \A voters \in VoterConfigs(m) :
        2 * Cardinality(granted \cap voters) > Cardinality(voters)

(* membership/membership.rs:271-307 -- find_coherent() retains the current
 * final config as one side of a joint transition, or flattens when the goal
 * is already one side of the joint membership. *)
NextCoherent(m, goal, requestId, logIndex) ==
    IF m.joint
    THEN IF goal = m.old \/ goal = m.new
         THEN Membership(logIndex, goal, goal, FALSE, requestId)
         ELSE Membership(logIndex, m.new, goal, TRUE, requestId)
    ELSE IF m.new = goal
         THEN Membership(logIndex, goal, goal, FALSE, requestId)
         ELSE Membership(logIndex, m.new, goal, TRUE, requestId)

SessionFrom(v, membershipIndex) ==
    [term |-> v.term, leader |-> v.leader,
     membershipIndex |-> membershipIndex]
CurrentSession(s) == SessionFrom(vote[s], effectiveMembership[s].log)
VoteFromSession(session) == Vote(session.term, session.leader, TRUE)

Entry(t, leaderNode, idx, kind, value, membership, requestId) ==
    [term |-> t, leader |-> leaderNode, index |-> idx,
     kind |-> kind, value |-> value,
     membership |-> membership, request |-> requestId]

BlankLog == [i \in Index |-> Nil]

Message(src, dst, kind, idx, entry, session, sentAt, committed, readId) ==
    [src |-> src, dst |-> dst, kind |-> kind, idx |-> idx,
     entry |-> entry, session |-> session, sentAt |-> sentAt,
     committed |-> committed, readId |-> readId]

Response(node, peer, kind, requiredVote, requiredLog, session, readId) ==
    [node |-> node, peer |-> peer, kind |-> kind,
     requiredVote |-> requiredVote, requiredLog |-> requiredLog,
     session |-> session, readId |-> readId]

Ack(kind, node, requiredVote, requiredLog) ==
    [kind |-> kind, node |-> node,
     requiredVote |-> requiredVote, requiredLog |-> requiredLog]

ReadState(phase, policy, required, floor, session, membership, acks, readId) ==
    [phase |-> phase, policy |-> policy, required |-> required,
     floor |-> floor, session |-> session, membership |-> membership,
     acks |-> acks, readId |-> readId]

IdleRead(s) ==
    ReadState(ReadIdle, ReadIndexPolicy, 0, 0,
              SessionFrom(Vote(0, s, FALSE), 0), InitialMembership, {}, 0)

RequestState(status, owner, goal, retain, logIndex) ==
    [status |-> status, owner |-> owner, goal |-> goal,
     retain |-> retain, log |-> logIndex]

IdleRequest == RequestState(RequestIdle, 1, Server, FALSE, 0)

nodeVars ==
    <<online, role, recoveryStage, recoveryReady, vote, persistentVote,
      acceptedIO, submittedIO, durableIO, flushedIO,
      engineLog, persistentLog, clusterCommitted, localCommitted,
      persistedCommitted, applySubmitted, smApplied, appliedLog>>

ioBridgeVars == <<ioWatch, ioForwarded>>
ioVars == <<pendingLocalIO, pendingResponses, ackHistory, ioWatch, ioForwarded>>
membershipVars ==
    <<committedMembership, effectiveMembership, membershipLog,
      changeRequests, requestPhase>>
electionVars ==
    <<candidateGranted, establishedVotes, voteSupport, voteMembership,
      leaderHistory>>
replicationVars == <<matchIndex, replicationSession, network>>
readVars ==
    <<heartbeatEvent, clock, clockAck, leaseUntil, readBarrier, readEpoch,
      lastReadObserved, lastReadRequired, staleSessionEffect>>
snapshotVars ==
    <<buildPhase, buildTarget, buildMembership,
      snapshotMetaLast, snapshotMetaMembership,
      snapshotAccepted, snapshotSubmitted, snapshotFlushed,
      snapshotLast, snapshotMembership, installPending, installDone,
      purgeUpto, purgeCommand, durablePurged>>
historyVars == <<committedLog, clientCompleted>>

vars ==
    <<nodeVars, ioVars, membershipVars, electionVars,
      replicationVars, readVars, snapshotVars, historyVars>>

MembershipIndices(logFn, upto) ==
    {i \in Index :
        /\ i <= upto
        /\ logFn[i] /= Nil
        /\ logFn[i].kind = MembershipEntry}

LatestMembership(logFn, upto, fallback) ==
    LET inds == MembershipIndices(logFn, upto)
    IN IF inds = {} THEN fallback
       ELSE logFn[MaxElem(inds)].membership

PurgePrefix(logFn, upto) ==
    [i \in Index |-> IF i <= upto THEN Nil ELSE logFn[i]]

TruncateSuffix(logFn, since) ==
    [i \in Index |-> IF i >= since THEN Nil ELSE logFn[i]]

CopyPrefix(oldFn, sourceFn, upto) ==
    [i \in Index |-> IF i <= upto THEN sourceFn[i] ELSE oldFn[i]]

EntryBacked(s, idx, entry) ==
    \/ engineLog[s][idx] = entry
    \/ /\ snapshotLast[s] >= idx
       /\ committedLog[idx] = entry

HasCommittedPrefix(s) ==
    \A i \in Index :
        committedLog[i] /= Nil => EntryBacked(s, i, committedLog[i])

NextElectionVote(s) ==
    IF LeaderMode = AdvancedMode /\ s > vote[s].leader
    THEN Vote(vote[s].term, s, FALSE)
    ELSE Vote(vote[s].term + 1, s, FALSE)

LastAcceptedEntry(s) ==
    IF acceptedIO[s].log = 0 THEN Nil ELSE engineLog[s][acceptedIO[s].log]

CandidateAtLeastAsUpToDate(candidate, receiver) ==
    LET ci == acceptedIO[candidate].log
        ri == acceptedIO[receiver].log
    IN \/ ci > ri
       \/ /\ ci = ri
          /\ ci = 0
       \/ /\ ci = ri
          /\ ci > 0
          /\ VoteRank(Vote(engineLog[candidate][ci].term,
                            engineLog[candidate][ci].leader, TRUE))
             >= VoteRank(Vote(engineLog[receiver][ri].term,
                              engineLog[receiver][ri].leader, TRUE))

UpdateCommittedPrefix(oldCommitted, sourceLog, upto) ==
    [i \in Index |->
        IF i <= upto /\ sourceLog[i] /= Nil
        THEN sourceLog[i]
        ELSE oldCommitted[i]]

(* -------------------------------------------------------------------------
 * Initialization
 * storage/helper.rs:87-223 constructs synchronized IO state after storage
 * and state-machine recovery; the abstract baseline starts fully running.
 * ------------------------------------------------------------------------- *)
Init ==
    /\ online = [s \in Server |-> TRUE]
    /\ role = [s \in Server |-> Follower]
    /\ recoveryStage = [s \in Server |-> Running]
    /\ recoveryReady = [s \in Server |-> TRUE]
    /\ vote = [s \in Server |-> Vote(0, s, FALSE)]
    /\ persistentVote = vote
    /\ acceptedIO = [s \in Server |-> IO(VoteRank(vote[s]), 0)]
    /\ submittedIO = acceptedIO
    /\ durableIO = acceptedIO
    /\ flushedIO = acceptedIO
    /\ engineLog = [s \in Server |-> BlankLog]
    /\ persistentLog = engineLog
    /\ clusterCommitted = [s \in Server |-> 0]
    /\ localCommitted = [s \in Server |-> 0]
    /\ persistedCommitted = [s \in Server |-> 0]
    /\ applySubmitted = [s \in Server |-> 0]
    /\ smApplied = [s \in Server |-> 0]
    /\ appliedLog = [s \in Server |-> BlankLog]
    /\ pendingLocalIO = [s \in Server |-> {}]
    /\ pendingResponses = {}
    /\ ackHistory = {}
    /\ ioWatch = acceptedIO
    /\ ioForwarded = acceptedIO
    /\ committedLog = BlankLog
    /\ clientCompleted = 0
    /\ committedMembership = [s \in Server |-> InitialMembership]
    /\ effectiveMembership = committedMembership
    /\ membershipLog = [s \in Server |-> [i \in Index |-> NoMembership]]
    /\ changeRequests = [r \in Request |-> IdleRequest]
    /\ requestPhase = [r \in Request |-> RequestIdle]
    /\ candidateGranted = [s \in Server |-> {}]
    /\ establishedVotes = {}
    /\ voteSupport = [r \in VoteRankRange |-> {}]
    /\ voteMembership = [r \in VoteRankRange |-> InitialMembership]
    /\ leaderHistory = [t \in Term |-> {}]
    /\ matchIndex = [s \in Server |-> [t \in Server |-> 0]]
    /\ replicationSession = [s \in Server |-> SessionFrom(vote[s], 0)]
    /\ network = {}
    /\ heartbeatEvent = [s \in Server |-> [t \in Server |-> Nil]]
    /\ clock = 0
    /\ clockAck = [s \in Server |-> {}]
    /\ leaseUntil = [s \in Server |-> 0]
    /\ readBarrier = [s \in Server |-> IdleRead(s)]
    /\ readEpoch = [s \in Server |-> 0]
    /\ lastReadObserved = [s \in Server |-> 0]
    /\ lastReadRequired = [s \in Server |-> 0]
    /\ staleSessionEffect = FALSE
    /\ buildPhase = [s \in Server |-> BuildIdle]
    /\ buildTarget = [s \in Server |-> 0]
    /\ buildMembership = [s \in Server |-> InitialMembership]
    /\ snapshotMetaLast = [s \in Server |-> 0]
    /\ snapshotMetaMembership = [s \in Server |-> InitialMembership]
    /\ snapshotAccepted = [s \in Server |-> 0]
    /\ snapshotSubmitted = [s \in Server |-> 0]
    /\ snapshotFlushed = [s \in Server |-> 0]
    /\ snapshotLast = [s \in Server |-> 0]
    /\ snapshotMembership = [s \in Server |-> InitialMembership]
    /\ installPending = [s \in Server |-> Nil]
    /\ installDone = [s \in Server |-> FALSE]
    /\ purgeUpto = [s \in Server |-> 0]
    /\ purgeCommand = [s \in Server |-> 0]
    /\ durablePurged = [s \in Server |-> 0]

(* -------------------------------------------------------------------------
 * Election and ordered votes (S1, S2, S5)
 * ------------------------------------------------------------------------- *)

(* core/raft_core.rs:1633-1685 -- timeout/elector checks precede Engine::elect.
 * engine/engine_impl.rs:214-230 -- elect creates a greater vote and records
 * the candidate's last log id. *)
HandleElectionTimeout(s) ==
    LET nv == NextElectionVote(s)
    IN /\ online[s]
       /\ recoveryReady[s]
       /\ role[s] /= Leader
       /\ s \in AllVoters(effectiveMembership[s])
       /\ nv.term \in Term
       /\ VoteRank(nv) > VoteRank(vote[s])
       /\ role' = [role EXCEPT ![s] = Candidate]
       /\ vote' = [vote EXCEPT ![s] = nv]
       /\ acceptedIO' = [acceptedIO EXCEPT ![s] = SetIOVote(@, VoteRank(nv))]
       /\ candidateGranted' = [candidateGranted EXCEPT ![s] = {}]
       /\ pendingResponses' = pendingResponses \cup
            {Response(s, s, VoteResponseKind, VoteRank(nv),
                      acceptedIO[s].log,
                      SessionFrom(nv, effectiveMembership[s].log), 0)}
       /\ UNCHANGED <<online, recoveryStage, recoveryReady, persistentVote,
                       submittedIO, durableIO, flushedIO, engineLog,
                       persistentLog, clusterCommitted, localCommitted,
                       persistedCommitted, applySubmitted, smApplied,
                       appliedLog, pendingLocalIO, ackHistory, ioBridgeVars,
                       historyVars, membershipVars, establishedVotes, voteSupport,
                       voteMembership, leaderHistory, matchIndex,
                       replicationSession, network, readVars, snapshotVars>>

(* engine/engine_impl.rs:286-336 -- reject an unexpired committed lease,
 * compare candidate last-log before update_vote, then enqueue a response that
 * will wait for IOFlushed in raft_core.rs:1271-1282. *)
EngineHandleVoteRequest(receiver, candidate) ==
    LET cv == vote[candidate]
    IN /\ receiver /= candidate
       /\ online[receiver] /\ online[candidate]
       /\ role[candidate] = Candidate
       /\ recoveryReady[receiver]
       /\ clock >= leaseUntil[receiver]
       /\ CandidateAtLeastAsUpToDate(candidate, receiver)
       /\ VoteGE(cv, vote[receiver])
       /\ vote' = [vote EXCEPT ![receiver] = cv]
       /\ acceptedIO' =
            [acceptedIO EXCEPT ![receiver] = SetIOVote(@, VoteRank(cv))]
       /\ role' = [role EXCEPT ![receiver] = Follower]
       /\ pendingResponses' = pendingResponses \cup
            {Response(receiver, candidate, VoteResponseKind, VoteRank(cv),
                      acceptedIO[receiver].log,
                      SessionFrom(cv, effectiveMembership[receiver].log), 0)}
       /\ UNCHANGED <<online, recoveryStage, recoveryReady, persistentVote,
                       submittedIO, durableIO, flushedIO, engineLog,
                       persistentLog, clusterCommitted, localCommitted,
                       persistedCommitted, applySubmitted, smApplied,
                       appliedLog, pendingLocalIO, ackHistory, ioBridgeVars,
                       historyVars, membershipVars, candidateGranted, establishedVotes,
                       voteSupport, voteMembership, leaderHistory, matchIndex,
                       replicationSession, network, readVars, snapshotVars>>

(* core/raft_core.rs:1864-1887 -- SaveVote marks submitted, awaits durable
 * save_vote, then queues LocalIO and (for a pending vote) a response. *)
RaftCoreRunCommandSaveVote(s) ==
    /\ online[s]
    /\ submittedIO[s].vote < acceptedIO[s].vote
    /\ persistentVote' = [persistentVote EXCEPT ![s] = vote[s]]
    /\ submittedIO' =
         [submittedIO EXCEPT ![s] = SetIOVote(@, acceptedIO[s].vote)]
    /\ durableIO' =
         [durableIO EXCEPT ![s] = SetIOVote(@, acceptedIO[s].vote)]
    /\ pendingLocalIO' = pendingLocalIO @@
         (s :> (pendingLocalIO[s] \cup
                 {IO(acceptedIO[s].vote, durableIO[s].log)}))
    /\ UNCHANGED <<online, role, recoveryStage, recoveryReady, vote,
                    acceptedIO, flushedIO, engineLog, persistentLog,
                    clusterCommitted, localCommitted, persistedCommitted,
                    applySubmitted, smApplied, appliedLog, pendingResponses,
                    ackHistory, ioBridgeVars, historyVars, membershipVars, electionVars,
                    replicationVars, readVars, snapshotVars>>

(* core/raft_core.rs:1540-1558 -- LocalIO advances the flushed cursor; out of
 * order completions are tolerated by try_flush. *)
RaftCoreHandleLocalIO(s, io) ==
    /\ io \in pendingLocalIO[s]
    /\ flushedIO' = [flushedIO EXCEPT ![s] =
         IO(Max2(@.vote, io.vote), Max2(@.log, io.log))]
    /\ pendingLocalIO' =
         [pendingLocalIO EXCEPT ![s] = @ \ {io}]
    /\ UNCHANGED <<online, role, recoveryStage, recoveryReady, vote,
                    persistentVote, acceptedIO, submittedIO, durableIO,
                    engineLog, persistentLog, clusterCommitted,
                    localCommitted, persistedCommitted, applySubmitted,
                    smApplied, appliedLog, pendingResponses, ackHistory,
                    ioBridgeVars, historyVars, membershipVars, electionVars,
                    replicationVars, readVars, snapshotVars>>

(* engine/command.rs:314-335 and raft_core.rs:970-993 -- only an IOFlushed
 * condition can release a granted vote response. *)
RaftCoreReleaseVoteResponse(p) ==
    /\ p \in pendingResponses
    /\ p.kind = VoteResponseKind
    /\ flushedIO[p.node].vote >= p.requiredVote
    /\ flushedIO[p.node].log >= p.requiredLog
    /\ online[p.peer]
    /\ role[p.peer] = Candidate
    /\ VoteRank(vote[p.peer]) = p.requiredVote
    /\ pendingResponses' = pendingResponses \ {p}
    /\ candidateGranted' =
         [candidateGranted EXCEPT ![p.peer] = @ \cup {p.node}]
    /\ ackHistory' = ackHistory \cup
         {Ack(VoteResponseKind, p.node, p.requiredVote, p.requiredLog)}
    /\ UNCHANGED <<nodeVars, pendingLocalIO, ioBridgeVars, historyVars,
                    membershipVars, establishedVotes, voteSupport, voteMembership,
                    leaderHistory, matchIndex, replicationSession, network,
                    readVars, snapshotVars>>

(* engine/engine_impl.rs:339-363 -- only a response for the current candidate
 * vote counts; quorum establishment calls establish_leader.  vote_handler/
 * mod.rs:162-218 immediately creates Leader state, resets IO progress for the
 * committed vote, rebuilds streams, and appends the leader no-op. *)
EngineHandleVoteResponse(s) ==
    LET support == candidateGranted[s]
        cv == vote[s]
        committed == CommittedVote(cv)
        vr == VoteRank(committed)
        idx == acceptedIO[s].log + 1
        noop == Entry(committed.term, committed.leader, idx,
                      BlankEntry, NoopValue, NoMembership, NoRequest)
    IN /\ online[s]
       /\ role[s] = Candidate
       /\ IsQuorum(support, effectiveMembership[s])
       /\ acceptedIO[s].log < MaxIndex
       /\ HasCommittedPrefix(s)
       /\ LeaderMode /= StandardMode
          \/ leaderHistory[cv.term] \subseteq {s}
       /\ vote' = [vote EXCEPT ![s] = committed]
       /\ role' = [role EXCEPT ![s] = Leader]
       /\ acceptedIO' = [acceptedIO EXCEPT ![s] =
            IO(vr, idx)]
       /\ engineLog' = [engineLog EXCEPT ![s][idx] = noop]
       /\ replicationSession' =
            [replicationSession EXCEPT ![s] =
                SessionFrom(committed, effectiveMembership[s].log)]
       /\ matchIndex' = [matchIndex EXCEPT ![s][s] = idx]
       /\ establishedVotes' = establishedVotes \cup {vr}
       /\ voteSupport' = [voteSupport EXCEPT ![vr] = support]
       /\ voteMembership' =
            [voteMembership EXCEPT ![vr] = effectiveMembership[s]]
       /\ leaderHistory' =
            [leaderHistory EXCEPT ![cv.term] = @ \cup {s}]
       /\ clockAck' = [clockAck EXCEPT ![s] = {s}]
       /\ leaseUntil' = [leaseUntil EXCEPT ![s] = 0]
       /\ UNCHANGED <<online, recoveryStage, recoveryReady, persistentVote,
                       submittedIO, durableIO, flushedIO, persistentLog,
                       clusterCommitted, localCommitted, persistedCommitted,
                       applySubmitted, smApplied, appliedLog, pendingLocalIO,
                       pendingResponses, ackHistory, ioBridgeVars, historyVars,
                       membershipVars, candidateGranted, network,
                       heartbeatEvent, clock, readBarrier, readEpoch,
                       lastReadObserved, lastReadRequired,
                       staleSessionEffect, snapshotVars>>

(* -------------------------------------------------------------------------
 * Log I/O, replication, commit, and apply (S2, S3, S5)
 * ------------------------------------------------------------------------- *)

(* leader_handler/mod.rs:43-95 -- assign the next log id, update the engine's
 * accepted IO cursor, queue AppendEntries, then initiate replication. *)
LeaderHandlerLeaderAppendEntries(s, value) ==
    LET idx == acceptedIO[s].log + 1
        e == Entry(vote[s].term, s, idx, NormalEntry,
                   value, NoMembership, NoRequest)
    IN /\ online[s] /\ role[s] = Leader
       /\ value \in Payload
       /\ acceptedIO[s].log < MaxIndex
       /\ engineLog' = [engineLog EXCEPT ![s][idx] = e]
       /\ acceptedIO' = [acceptedIO EXCEPT ![s] = SetIOLog(@, idx)]
       /\ matchIndex' = [matchIndex EXCEPT ![s][s] = idx]
       /\ pendingResponses' = pendingResponses \cup
            {Response(s, s, ClientResponseKind, VoteRank(vote[s]), idx,
                      CurrentSession(s), 0)}
       /\ UNCHANGED <<online, role, recoveryStage, recoveryReady, vote,
                       persistentVote, submittedIO, durableIO, flushedIO,
                       persistentLog, clusterCommitted, localCommitted,
                       persistedCommitted, applySubmitted, smApplied,
                       appliedLog, pendingLocalIO, ackHistory, ioBridgeVars,
                       historyVars, membershipVars, electionVars, replicationSession,
                       network, readVars, snapshotVars>>

(* core/raft_core.rs:1837-1863 -- submit is recorded before append() because
 * the storage callback may run before append returns.  Ordered writes require
 * the vote component to have been submitted first. *)
RaftCoreRunCommandAppendEntries(s) ==
    LET idx == submittedIO[s].log + 1
        entryVote == VoteRank(Vote(engineLog[s][idx].term,
                                   engineLog[s][idx].leader, TRUE))
    IN /\ online[s]
       /\ submittedIO[s].log < acceptedIO[s].log
       /\ submittedIO[s].vote >= entryVote
       /\ submittedIO' =
            [submittedIO EXCEPT ![s] = SetIOLog(@, idx)]
       /\ UNCHANGED <<online, role, recoveryStage, recoveryReady, vote,
                       persistentVote, acceptedIO, durableIO, flushedIO,
                       engineLog, persistentLog, clusterCommitted,
                       localCommitted, persistedCommitted, applySubmitted,
                       smApplied, appliedLog, ioVars, historyVars,
                       membershipVars, electionVars, replicationVars,
                       readVars, snapshotVars>>

(* raft_log_storage.rs:26-31,88-103 and storage/callback.rs:80-116 --
 * ordered append completion durably exposes the entry, then the synchronous
 * callback updates the watch slot.  raft/mod.rs:315-359 later forwards the
 * latest watch value as LocalIO; intermediate successes may be coalesced. *)
LogStoreCompleteAppend(s) ==
    LET idx == durableIO[s].log + 1
        newDurable == IO(durableIO[s].vote, idx)
    IN /\ online[s]
       /\ durableIO[s].log < submittedIO[s].log
       /\ persistentLog' =
            [persistentLog EXCEPT ![s][idx] = engineLog[s][idx]]
       /\ durableIO' = [durableIO EXCEPT ![s] = newDurable]
       /\ ioWatch' = [ioWatch EXCEPT ![s] = newDurable]
       /\ UNCHANGED <<online, role, recoveryStage, recoveryReady, vote,
                       persistentVote, acceptedIO, submittedIO, flushedIO,
                       engineLog, clusterCommitted, localCommitted,
                       persistedCommitted, applySubmitted, smApplied,
                       appliedLog, pendingLocalIO, pendingResponses, ackHistory,
                       ioForwarded, historyVars,
                       membershipVars, electionVars, replicationVars,
                       readVars, snapshotVars>>

(* raft/mod.rs:315-359 -- io_completion_forwarder observes the watch receiver
 * and sends a LocalIO notification for the latest unseen successful IOId. *)
IOCompletionForwarder(s) ==
    /\ online[s]
    /\ ioWatch[s] /= ioForwarded[s]
    /\ pendingLocalIO' =
         [pendingLocalIO EXCEPT ![s] = @ \cup {ioWatch[s]}]
    /\ ioForwarded' = [ioForwarded EXCEPT ![s] = ioWatch[s]]
    /\ UNCHANGED <<nodeVars, pendingResponses, ackHistory, historyVars,
                    membershipVars, electionVars, replicationVars, readVars,
                    snapshotVars, ioWatch>>

(* replication_handler/mod.rs:303-340 and raft_core.rs:1931-1934 -- a stream
 * sends the next entry only after the local append is submitted/readable. *)
ReplicationHandlerSendReplicate(s, target) ==
    LET idx == matchIndex[s][target] + 1
        msg == Message(s, target, AppendRequest, idx,
                       engineLog[s][idx], CurrentSession(s), clock,
                       localCommitted[s], 0)
    IN /\ online[s] /\ online[target]
       /\ role[s] = Leader
       /\ target /= s
       /\ target \in AllVoters(effectiveMembership[s])
       /\ idx <= submittedIO[s].log
       /\ engineLog[s][idx] /= Nil
       /\ msg \notin network
       /\ network' = network \cup {msg}
       /\ UNCHANGED <<nodeVars, ioVars, historyVars, membershipVars,
                       electionVars, matchIndex, replicationSession,
                       readVars, snapshotVars>>

(* engine_impl.rs:401-458 and following_handler/mod.rs:145-212 -- update_vote
 * first, truncate a conflicting suffix, append the received entry, and make a
 * membership entry effective immediately.  raft_core.rs:1286-1296 then
 * records the leader's commit frontier. *)
EngineHandleAppendEntries(target, msg) ==
    LET incomingVote == VoteFromSession(msg.session)
        idx == msg.idx
        oldLog == IF engineLog[target][idx] = Nil
                  \/ engineLog[target][idx] = msg.entry
                  THEN engineLog[target]
                  ELSE TruncateSuffix(engineLog[target], idx)
        newLog == [oldLog EXCEPT ![idx] = msg.entry]
        newAccepted == Max2(acceptedIO[target].log, idx)
        newLocal == Min2(msg.committed, newAccepted)
        newEffective == IF msg.entry.kind = MembershipEntry
                        THEN msg.entry.membership
                        ELSE effectiveMembership[target]
        newCommitted == LatestMembership(newLog, newLocal,
                                         committedMembership[target])
        response == Response(target, msg.src, AppendResponseKind,
                             VoteRank(incomingVote), idx, msg.session, 0)
    IN /\ msg \in network
       /\ msg.kind = AppendRequest /\ msg.dst = target
       /\ msg.entry /= Nil
       /\ online[target] /\ recoveryReady[target]
       /\ VoteGE(incomingVote, vote[target])
       /\ idx \in Index
       /\ IF idx = 1 THEN TRUE
          ELSE engineLog[target][idx - 1] = engineLog[msg.src][idx - 1]
       /\ vote' = [vote EXCEPT ![target] = incomingVote]
       /\ role' = [role EXCEPT ![target] = Follower]
       /\ acceptedIO' = [acceptedIO EXCEPT ![target] =
            IO(VoteRank(incomingVote), newAccepted)]
       /\ engineLog' = [engineLog EXCEPT ![target] = newLog]
       /\ clusterCommitted' =
            [clusterCommitted EXCEPT ![target] =
                Max2(@, Min2(msg.committed, newAccepted))]
       /\ localCommitted' =
            [localCommitted EXCEPT ![target] = Max2(@, newLocal)]
       /\ effectiveMembership' =
            [effectiveMembership EXCEPT ![target] = newEffective]
       /\ committedMembership' =
            [committedMembership EXCEPT ![target] = newCommitted]
       /\ membershipLog' = IF msg.entry.kind = MembershipEntry
            THEN [membershipLog EXCEPT ![target][idx] = msg.entry.membership]
            ELSE membershipLog
       /\ replicationSession' =
            [replicationSession EXCEPT ![target] =
                SessionFrom(incomingVote, newEffective.log)]
       /\ pendingResponses' = pendingResponses \cup {response}
       /\ network' = network \ {msg}
       /\ UNCHANGED <<online, recoveryStage, recoveryReady, persistentVote,
                       submittedIO, durableIO, flushedIO, persistentLog,
                       persistedCommitted, applySubmitted, smApplied,
                       appliedLog, pendingLocalIO, ackHistory, ioBridgeVars,
                       historyVars, changeRequests, requestPhase, electionVars,
                       matchIndex, heartbeatEvent, clock, clockAck,
                       leaseUntil, readBarrier, readEpoch, lastReadObserved,
                       lastReadRequired, staleSessionEffect, snapshotVars>>

(* engine/command.rs:314-335 and raft_core.rs:970-993 -- successful append,
 * heartbeat and ReadIndex RPC replies share the IOFlushed release rule. *)
RaftCoreReleaseRPCResponse(p) ==
    LET responseKind ==
          CASE p.kind = AppendResponseKind -> AppendResponse
            [] p.kind = HeartbeatResponseKind -> HeartbeatResponse
            [] OTHER -> ReadIndexResponse
        msg == Message(p.node, p.peer, responseKind, p.requiredLog, Nil,
                       p.session, clock, localCommitted[p.node], p.readId)
    IN /\ p \in pendingResponses
       /\ p.kind \in {AppendResponseKind, HeartbeatResponseKind,
                       ReadIndexResponseKind}
       /\ flushedIO[p.node].vote >= p.requiredVote
       /\ flushedIO[p.node].log >= p.requiredLog
       /\ pendingResponses' = pendingResponses \ {p}
       /\ ackHistory' = ackHistory \cup
            {Ack(p.kind, p.node, p.requiredVote, p.requiredLog)}
       /\ network' = network \cup {msg}
       /\ UNCHANGED <<nodeVars, pendingLocalIO, ioBridgeVars, historyVars,
                       membershipVars, electionVars, matchIndex, replicationSession,
                       readVars, snapshotVars>>

(* raft_core.rs:1561-1570 and replication_handler/mod.rs:150-201 -- ignore a
 * response whose leader-vote or membership-log session is stale; otherwise
 * update matching and commit only a current-leader entry granted by quorum. *)
ReplicationHandlerUpdateProgress(s, msg) ==
    LET newMatch == [matchIndex[s] EXCEPT ![msg.src] = Max2(@, msg.idx)]
        granted == {n \in Server : newMatch[n] >= msg.idx}
        canCommit ==
            /\ msg.session = CurrentSession(s)
            /\ engineLog[s][msg.idx] /= Nil
            /\ engineLog[s][msg.idx].term = vote[s].term
            /\ IsQuorum(granted, effectiveMembership[s])
        newCommit == IF canCommit THEN Max2(localCommitted[s], msg.idx)
                     ELSE localCommitted[s]
        newMembership == LatestMembership(engineLog[s], newCommit,
                                          committedMembership[s])
        req == IF canCommit /\ engineLog[s][msg.idx].kind = MembershipEntry
               THEN engineLog[s][msg.idx].request ELSE NoRequest
    IN /\ msg \in network
       /\ msg.kind = AppendResponse /\ msg.dst = s
       /\ online[s] /\ role[s] = Leader
       /\ network' = network \ {msg}
       /\ matchIndex' = IF msg.session = CurrentSession(s)
            THEN [matchIndex EXCEPT ![s] = newMatch]
            ELSE matchIndex
       /\ clusterCommitted' = IF canCommit
            THEN [clusterCommitted EXCEPT ![s] = newCommit]
            ELSE clusterCommitted
       /\ localCommitted' = IF canCommit
            THEN [localCommitted EXCEPT ![s] = newCommit]
            ELSE localCommitted
       /\ committedLog' = IF canCommit
            THEN UpdateCommittedPrefix(committedLog, engineLog[s], newCommit)
            ELSE committedLog
       /\ committedMembership' = IF canCommit
            THEN [committedMembership EXCEPT ![s] = newMembership]
            ELSE committedMembership
       /\ requestPhase' = IF req \in Request
            THEN [requestPhase EXCEPT ![req] =
                    IF newMembership.joint
                    THEN RequestJointCommitted ELSE RequestDone]
            ELSE requestPhase
       /\ changeRequests' = IF req \in Request
            THEN [changeRequests EXCEPT ![req] =
                    [@ EXCEPT !.status = requestPhase'[req],
                              !.log = newMembership.log]]
            ELSE changeRequests
       /\ UNCHANGED <<online, role, recoveryStage, recoveryReady, vote,
                       persistentVote, acceptedIO, submittedIO, durableIO,
                       flushedIO, engineLog, persistentLog,
                       persistedCommitted, applySubmitted, smApplied,
                       appliedLog, ioVars, clientCompleted,
                       effectiveMembership, membershipLog, electionVars,
                       replicationSession, readVars, snapshotVars>>

(* engine_impl.rs:670-705 and raft_core.rs:1928-1937 -- mark apply submitted,
 * save committed first, then dispatch the next apply range.  The source caps
 * the applicable range at min(log_progress.submitted, apply_progress.accepted).
 * save_committed is explicitly optional in storage/v2/raft_log_storage.rs. *)
RaftCoreRunCommandSaveCommittedAndApply(s) ==
    LET idx == smApplied[s] + 1
        applyLimit == Min2(localCommitted[s], submittedIO[s].log)
    IN /\ online[s]
       /\ applySubmitted[s] = smApplied[s]
       /\ idx <= applyLimit
       /\ engineLog[s][idx] /= Nil
       /\ applySubmitted' = [applySubmitted EXCEPT ![s] = idx]
       /\ persistedCommitted' = IF PersistCommitted
            THEN [persistedCommitted EXCEPT ![s] = Max2(@, idx)]
            ELSE persistedCommitted
       /\ UNCHANGED <<online, role, recoveryStage, recoveryReady, vote,
                       persistentVote, acceptedIO, submittedIO, durableIO,
                       flushedIO, engineLog, persistentLog,
                       clusterCommitted, localCommitted, smApplied,
                       appliedLog, ioVars, historyVars, membershipVars,
                       electionVars, replicationVars, readVars, snapshotVars>>

(* core/sm/worker.rs:177-233 and raft_core.rs:1624-1626 -- apply the submitted
 * entry, then consume the worker notification and advance applied progress. *)
SMWorkerApply(s) ==
    LET idx == applySubmitted[s]
        e == engineLog[s][idx]
        req == IF e.kind = MembershipEntry THEN e.request ELSE NoRequest
        nextPhase == IF e.kind = MembershipEntry
                     THEN IF e.membership.joint
                          THEN RequestJointCommitted ELSE RequestDone
                     ELSE RequestIdle
    IN /\ online[s]
       /\ idx = smApplied[s] + 1
       /\ e /= Nil
       /\ smApplied' = [smApplied EXCEPT ![s] = idx]
       /\ appliedLog' = [appliedLog EXCEPT ![s][idx] = e]
       /\ requestPhase' = IF req \in Request
            THEN [requestPhase EXCEPT ![req] = nextPhase]
            ELSE requestPhase
       /\ changeRequests' = IF req \in Request
            THEN [changeRequests EXCEPT ![req] =
                    [@ EXCEPT !.status = nextPhase, !.log = idx]]
            ELSE changeRequests
       /\ UNCHANGED <<online, role, recoveryStage, recoveryReady, vote,
                       persistentVote, acceptedIO, submittedIO, durableIO,
                       flushedIO, engineLog, persistentLog,
                       clusterCommitted, localCommitted,
                       persistedCommitted, applySubmitted, ioVars,
                       historyVars, committedMembership,
                       effectiveMembership, membershipLog, electionVars,
                       replicationVars, readVars, snapshotVars>>

(* raft_core.rs:823-835 and sm/worker.rs:197-220 -- the application responder
 * is attached to the entry and can complete only after that entry is applied. *)
ApplyResponderComplete(p) ==
    /\ p \in pendingResponses
    /\ p.kind = ClientResponseKind
    /\ smApplied[p.node] >= p.requiredLog
    /\ pendingResponses' = pendingResponses \ {p}
    /\ clientCompleted' = Max2(clientCompleted, p.requiredLog)
    /\ UNCHANGED <<nodeVars, pendingLocalIO, ackHistory, ioBridgeVars,
                    committedLog, membershipVars, electionVars, replicationVars,
                    readVars, snapshotVars>>

(* -------------------------------------------------------------------------
 * Two-stage membership API and session rebuild (S3)
 * ------------------------------------------------------------------------- *)

(* raft/api/management.rs:61-88 -- each caller retains its own change, retain
 * flag and responder while awaiting the first (possibly joint) entry. *)
ManagementApiStartMembership(requestId, s, goal, retain) ==
    /\ requestId \in Request
    /\ requestPhase[requestId] = RequestIdle
    /\ online[s] /\ role[s] = Leader
    /\ goal \subseteq Server /\ goal /= {}
    /\ changeRequests' = [changeRequests EXCEPT ![requestId] =
         RequestState(RequestStarted, s, goal, retain, 0)]
    /\ requestPhase' =
         [requestPhase EXCEPT ![requestId] = RequestStarted]
    /\ UNCHANGED <<nodeVars, ioVars, historyVars, committedMembership,
                    effectiveMembership, membershipLog, electionVars,
                    replicationVars, readVars, snapshotVars>>

(* membership_state/change_handler.rs:31-58, membership.rs:292-330,
 * raft_core.rs:465-482 and leader_handler/mod.rs:53-95 -- require the latest
 * effective membership to be committed, compute one coherent step, append it,
 * make it effective immediately, and rebuild the replication session. *)
CoreChangeMembership(requestId) ==
    LET req == changeRequests[requestId]
        s == req.owner
        idx == acceptedIO[s].log + 1
        m == NextCoherent(effectiveMembership[s], req.goal,
                          requestId, idx)
        e == Entry(vote[s].term, s, idx, MembershipEntry,
                   NoopValue, m, requestId)
        nextPhase == IF m.joint
                     THEN RequestJointSubmitted ELSE RequestUniformSubmitted
    IN /\ requestId \in Request
       /\ requestPhase[requestId] = RequestStarted
       /\ online[s] /\ role[s] = Leader
       /\ effectiveMembership[s].log = committedMembership[s].log
       /\ acceptedIO[s].log < MaxIndex
       /\ engineLog' = [engineLog EXCEPT ![s][idx] = e]
       /\ acceptedIO' = [acceptedIO EXCEPT ![s] = SetIOLog(@, idx)]
       /\ effectiveMembership' =
            [effectiveMembership EXCEPT ![s] = m]
       /\ membershipLog' = [membershipLog EXCEPT ![s][idx] = m]
       /\ requestPhase' =
            [requestPhase EXCEPT ![requestId] = nextPhase]
       /\ changeRequests' = [changeRequests EXCEPT ![requestId] =
            [@ EXCEPT !.status = nextPhase, !.log = idx]]
       /\ replicationSession' =
            [replicationSession EXCEPT ![s] = SessionFrom(vote[s], idx)]
       /\ matchIndex' = [matchIndex EXCEPT ![s][s] = idx]
       /\ clockAck' = [clockAck EXCEPT ![s] = {s}]
       /\ leaseUntil' = [leaseUntil EXCEPT ![s] = 0]
       /\ UNCHANGED <<online, role, recoveryStage, recoveryReady, vote,
                       persistentVote, submittedIO, durableIO, flushedIO,
                       persistentLog, clusterCommitted, localCommitted,
                       persistedCommitted, applySubmitted, smApplied,
                       appliedLog, ioVars, historyVars, committedMembership,
                       candidateGranted, establishedVotes, voteSupport,
                       voteMembership, leaderHistory, network,
                       heartbeatEvent, clock, readBarrier, readEpoch,
                       lastReadObserved, lastReadRequired,
                       staleSessionEffect, snapshotVars>>

(* raft/api/management.rs:98-124 -- after the first call returns a joint
 * config, the API releases control and later submits AddVoterIds(empty) with
 * the original caller's retain flag.  Membership::compute_target_membership
 * uses the then-current final config (membership.rs:333-345), not a stored
 * transaction object; this is the cross-request window from S3. *)
ManagementApiFlattenJoint(requestId) ==
    LET req == changeRequests[requestId]
        s == req.owner
        idx == acceptedIO[s].log + 1
        goalNow == effectiveMembership[s].new
        m == NextCoherent(effectiveMembership[s], goalNow,
                          requestId, idx)
        e == Entry(vote[s].term, s, idx, MembershipEntry,
                   NoopValue, m, requestId)
    IN /\ requestId \in Request
       /\ requestPhase[requestId] = RequestJointCommitted
       /\ online[s] /\ role[s] = Leader
       /\ effectiveMembership[s].log = committedMembership[s].log
       /\ acceptedIO[s].log < MaxIndex
       /\ engineLog' = [engineLog EXCEPT ![s][idx] = e]
       /\ acceptedIO' = [acceptedIO EXCEPT ![s] = SetIOLog(@, idx)]
       /\ effectiveMembership' =
            [effectiveMembership EXCEPT ![s] = m]
       /\ membershipLog' = [membershipLog EXCEPT ![s][idx] = m]
       /\ requestPhase' =
            [requestPhase EXCEPT ![requestId] = RequestUniformSubmitted]
       /\ changeRequests' = [changeRequests EXCEPT ![requestId] =
            [@ EXCEPT !.status = RequestUniformSubmitted, !.log = idx]]
       /\ replicationSession' =
            [replicationSession EXCEPT ![s] = SessionFrom(vote[s], idx)]
       /\ matchIndex' = [matchIndex EXCEPT ![s][s] = idx]
       /\ clockAck' = [clockAck EXCEPT ![s] = {s}]
       /\ leaseUntil' = [leaseUntil EXCEPT ![s] = 0]
       /\ UNCHANGED <<online, role, recoveryStage, recoveryReady, vote,
                       persistentVote, submittedIO, durableIO, flushedIO,
                       persistentLog, clusterCommitted, localCommitted,
                       persistedCommitted, applySubmitted, smApplied,
                       appliedLog, ioVars, historyVars, committedMembership,
                       candidateGranted, establishedVotes, voteSupport,
                       voteMembership, leaderHistory, network,
                       heartbeatEvent, clock, readBarrier, readEpoch,
                       lastReadObserved, lastReadRequired,
                       staleSessionEffect, snapshotVars>>

(* -------------------------------------------------------------------------
 * Snapshot install/build/purge lifecycle (S4)
 * ------------------------------------------------------------------------- *)

(* snapshot_handler/mod.rs:28-43 -- only one build may be queued/running. *)
SnapshotHandlerTriggerSnapshot(s) ==
    /\ online[s] /\ recoveryReady[s]
    /\ buildPhase[s] = BuildIdle
    /\ buildPhase' = [buildPhase EXCEPT ![s] = BuildQueued]
    /\ UNCHANGED <<nodeVars, ioVars, historyVars, membershipVars,
                    electionVars, replicationVars, readVars, buildTarget,
                    buildMembership, snapshotMetaLast,
                    snapshotMetaMembership, snapshotAccepted,
                    snapshotSubmitted, snapshotFlushed, snapshotLast,
                    snapshotMembership, installPending, installDone,
                    purgeUpto, purgeCommand, durablePurged>>

(* core/sm/worker.rs:236-269 -- the worker obtains a consistent builder view;
 * subsequent apply/install steps may interleave with the spawned build. *)
SMWorkerBuildSnapshotStart(s) ==
    /\ online[s]
    /\ buildPhase[s] = BuildQueued
    /\ buildPhase' = [buildPhase EXCEPT ![s] = BuildRunning]
    /\ buildTarget' = [buildTarget EXCEPT ![s] = smApplied[s]]
    /\ buildMembership' =
         [buildMembership EXCEPT ![s] = committedMembership[s]]
    /\ snapshotAccepted' =
         [snapshotAccepted EXCEPT ![s] = Max2(@, smApplied[s])]
    /\ snapshotSubmitted' =
         [snapshotSubmitted EXCEPT ![s] = Max2(@, smApplied[s])]
    /\ UNCHANGED <<nodeVars, ioVars, historyVars, membershipVars,
                    electionVars, replicationVars, readVars,
                    snapshotMetaLast, snapshotMetaMembership,
                    snapshotFlushed, snapshotLast, snapshotMembership,
                    installPending, installDone, purgeUpto, purgeCommand,
                    durablePurged>>

(* engine_impl.rs:524-565 -- completion may be older than a concurrently
 * installed snapshot; try_update_all prevents cursor regression, then the
 * engine updates metadata and schedules purge. *)
EngineOnBuildingSnapshotDone(s) ==
    LET target == buildTarget[s]
        newer == target > snapshotMetaLast[s]
    IN /\ online[s]
       /\ buildPhase[s] = BuildRunning
       /\ snapshotLast' =
            [snapshotLast EXCEPT ![s] = Max2(@, target)]
       /\ snapshotMembership' = IF target >= snapshotLast[s]
            THEN [snapshotMembership EXCEPT ![s] = buildMembership[s]]
            ELSE snapshotMembership
       /\ snapshotFlushed' =
            [snapshotFlushed EXCEPT ![s] = Max2(@, target)]
       /\ snapshotAccepted' =
            [snapshotAccepted EXCEPT ![s] = Max2(@, target)]
       /\ snapshotSubmitted' =
            [snapshotSubmitted EXCEPT ![s] = Max2(@, target)]
       /\ snapshotMetaLast' = IF newer
            THEN [snapshotMetaLast EXCEPT ![s] = target]
            ELSE snapshotMetaLast
       /\ snapshotMetaMembership' = IF newer
            THEN [snapshotMetaMembership EXCEPT ![s] = buildMembership[s]]
            ELSE snapshotMetaMembership
       /\ buildPhase' = [buildPhase EXCEPT ![s] = BuildIdle]
       /\ UNCHANGED <<nodeVars, ioVars, historyVars, membershipVars,
                       electionVars, replicationVars, readVars, buildTarget,
                       buildMembership, installPending, installDone,
                       purgeUpto, purgeCommand, durablePurged>>

(* log_handler/mod.rs:51-68 -- policy calculation only advances the expected
 * purge target, and only to a prefix covered by engine snapshot metadata. *)
LogHandlerSchedulePolicyBasedPurge(s) ==
    /\ online[s]
    /\ snapshotMetaLast[s] > purgeUpto[s]
    /\ purgeUpto' = [purgeUpto EXCEPT ![s] = snapshotMetaLast[s]]
    /\ UNCHANGED <<nodeVars, ioVars, historyVars, membershipVars,
                    electionVars, replicationVars, readVars, buildPhase,
                    buildTarget, buildMembership, snapshotMetaLast,
                    snapshotMetaMembership, snapshotAccepted,
                    snapshotSubmitted, snapshotFlushed, snapshotLast,
                    snapshotMembership, installPending, installDone,
                    purgeCommand, durablePurged>>

(* log_handler/mod.rs:29-49 -- engine log metadata is purged immediately and
 * a durable PurgeLog command is queued.  raft_core.rs:1889-1892 persists it
 * later, after the snapshot condition in command.rs:256. *)
LogHandlerPurgeLog(s) ==
    /\ online[s]
    /\ purgeUpto[s] > purgeCommand[s]
    /\ snapshotFlushed[s] >= purgeUpto[s]
    /\ engineLog' =
         [engineLog EXCEPT ![s] = PurgePrefix(@, purgeUpto[s])]
    /\ purgeCommand' = [purgeCommand EXCEPT ![s] = purgeUpto[s]]
    /\ UNCHANGED <<online, role, recoveryStage, recoveryReady, vote,
                    persistentVote, acceptedIO, submittedIO, durableIO,
                    flushedIO, persistentLog, clusterCommitted,
                    localCommitted, persistedCommitted, applySubmitted,
                    smApplied, appliedLog, ioVars, historyVars,
                    membershipVars, electionVars, replicationVars,
                    readVars, buildPhase, buildTarget, buildMembership,
                    snapshotMetaLast, snapshotMetaMembership,
                    snapshotAccepted, snapshotSubmitted, snapshotFlushed,
                    snapshotLast, snapshotMembership, installPending,
                    installDone, purgeUpto, durablePurged>>

(* core/raft_core.rs:1889-1892 -- the storage purge completion is the durable
 * frontier, distinct from the earlier in-memory log-id purge. *)
RaftCoreRunCommandPurgeLog(s) ==
    /\ online[s]
    /\ durablePurged[s] < purgeCommand[s]
    /\ snapshotLast[s] >= purgeCommand[s]
    /\ persistentLog' =
         [persistentLog EXCEPT ![s] = PurgePrefix(@, purgeCommand[s])]
    /\ durablePurged' = [durablePurged EXCEPT ![s] = purgeCommand[s]]
    /\ UNCHANGED <<online, role, recoveryStage, recoveryReady, vote,
                    persistentVote, acceptedIO, submittedIO, durableIO,
                    flushedIO, engineLog, clusterCommitted, localCommitted,
                    persistedCommitted, applySubmitted, smApplied,
                    appliedLog, ioVars, historyVars, membershipVars,
                    electionVars, replicationVars, readVars, buildPhase,
                    buildTarget, buildMembership, snapshotMetaLast,
                    snapshotMetaMembership, snapshotAccepted,
                    snapshotSubmitted, snapshotFlushed, snapshotLast,
                    snapshotMembership, installPending, installDone,
                    purgeUpto, purgeCommand>>

(* replication/mod.rs:82-105 -- snapshot transmission is metadata-only in
 * this model; chunk buffers/codecs are intentionally excluded by brief 3.2. *)
ReplicationCoreSendSnapshot(s, target) ==
    LET msg == Message(s, target, AppendRequest, snapshotLast[s], Nil,
                       CurrentSession(s), clock, localCommitted[s], 0)
    IN /\ online[s] /\ online[target]
       /\ role[s] = Leader /\ target /= s
       /\ snapshotLast[s] > 0
       /\ installPending[target] = Nil
       /\ msg \notin network
       /\ network' = network \cup {msg}
       /\ UNCHANGED <<nodeVars, ioVars, historyVars, membershipVars,
                       electionVars, matchIndex, replicationSession,
                       readVars, snapshotVars>>

(* following_handler/mod.rs:249-302 -- accept only a newer snapshot, update
 * engine snapshot/effective membership first, accept log/apply/snapshot IO,
 * queue worker install, and immediately queue the covered purge. *)
FollowingHandlerInstallFullSnapshot(target, msg) ==
    LET last == msg.idx
        incomingMembership == snapshotMembership[msg.src]
        incomingVote == VoteFromSession(msg.session)
    IN /\ msg \in network
       /\ msg.kind = AppendRequest /\ msg.entry = Nil
       /\ msg.dst = target /\ online[target]
       /\ last > localCommitted[target]
       /\ last > snapshotMetaLast[target]
       /\ vote' = [vote EXCEPT ![target] = incomingVote]
       /\ role' = [role EXCEPT ![target] = Follower]
       /\ acceptedIO' = [acceptedIO EXCEPT ![target] =
            IO(VoteRank(incomingVote), Max2(@.log, last))]
       /\ localCommitted' =
            [localCommitted EXCEPT ![target] = Max2(@, last)]
       /\ clusterCommitted' =
            [clusterCommitted EXCEPT ![target] = Max2(@, last)]
       /\ effectiveMembership' =
            [effectiveMembership EXCEPT ![target] = incomingMembership]
       /\ committedMembership' =
            [committedMembership EXCEPT ![target] = incomingMembership]
       /\ snapshotMetaLast' = [snapshotMetaLast EXCEPT ![target] = last]
       /\ snapshotMetaMembership' =
            [snapshotMetaMembership EXCEPT ![target] = incomingMembership]
       /\ snapshotAccepted' =
            [snapshotAccepted EXCEPT ![target] = Max2(@, last)]
       /\ installPending' = [installPending EXCEPT ![target] = msg]
       /\ installDone' = [installDone EXCEPT ![target] = FALSE]
       /\ purgeUpto' = [purgeUpto EXCEPT ![target] = Max2(@, last)]
       /\ engineLog' =
            [engineLog EXCEPT ![target] = PurgePrefix(@, last)]
       /\ purgeCommand' =
            [purgeCommand EXCEPT ![target] = Max2(@, last)]
       /\ replicationSession' =
            [replicationSession EXCEPT ![target] =
                SessionFrom(incomingVote, incomingMembership.log)]
       /\ network' = network \ {msg}
       /\ UNCHANGED <<online, recoveryStage, recoveryReady, persistentVote,
                       submittedIO, durableIO, flushedIO, persistentLog,
                       persistedCommitted, applySubmitted, smApplied,
                       appliedLog, ioVars, historyVars, membershipLog,
                       changeRequests, requestPhase, electionVars,
                       matchIndex, readVars, buildPhase, buildTarget,
                       buildMembership, snapshotSubmitted, snapshotFlushed,
                       snapshotLast, snapshotMembership, durablePurged>>

(* raft_core.rs:1954-1973 and sm/worker.rs:124-139 -- forwarding the install
 * first advances submitted progress; worker completion durably installs the
 * snapshot and reports a notification, but core flushed cursors still lag. *)
SMWorkerInstallSnapshot(target) ==
    LET msg == installPending[target]
        last == msg.idx
    IN /\ online[target]
       /\ msg /= Nil /\ ~installDone[target]
       /\ submittedIO' = [submittedIO EXCEPT ![target] =
            IO(Max2(@.vote, VoteRank(VoteFromSession(msg.session))),
               Max2(@.log, last))]
       /\ durableIO' = [durableIO EXCEPT ![target] =
            IO(Max2(@.vote, VoteRank(VoteFromSession(msg.session))),
               Max2(@.log, last))]
       /\ applySubmitted' =
            [applySubmitted EXCEPT ![target] = Max2(@, last)]
       /\ snapshotSubmitted' =
            [snapshotSubmitted EXCEPT ![target] = Max2(@, last)]
       /\ snapshotLast' = [snapshotLast EXCEPT ![target] = Max2(@, last)]
       /\ snapshotMembership' =
            [snapshotMembership EXCEPT ![target] =
                snapshotMetaMembership[target]]
       /\ smApplied' = [smApplied EXCEPT ![target] = Max2(@, last)]
       /\ appliedLog' = [appliedLog EXCEPT ![target] =
            CopyPrefix(@, committedLog, last)]
       /\ installDone' = [installDone EXCEPT ![target] = TRUE]
       /\ UNCHANGED <<online, role, recoveryStage, recoveryReady, vote,
                       persistentVote, acceptedIO, flushedIO, engineLog,
                       persistentLog, clusterCommitted, localCommitted,
                       persistedCommitted, ioVars, historyVars,
                       membershipVars, electionVars, replicationVars,
                       readVars, buildPhase, buildTarget, buildMembership,
                       snapshotMetaLast, snapshotMetaMembership,
                       snapshotAccepted, snapshotFlushed, installPending,
                       purgeUpto, purgeCommand, durablePurged>>

(* raft_core.rs:1591-1622 -- the core notification independently advances
 * log, apply and snapshot flushed cursors; only then can snapshot response and
 * purge conditions be satisfied. *)
RaftCoreHandleInstallSnapshotNotification(target) ==
    LET msg == installPending[target]
        last == msg.idx
        io == IO(VoteRank(VoteFromSession(msg.session)), last)
    IN /\ online[target]
       /\ msg /= Nil /\ installDone[target]
       /\ flushedIO' = [flushedIO EXCEPT ![target] =
            IO(Max2(@.vote, io.vote), Max2(@.log, io.log))]
       /\ snapshotFlushed' =
            [snapshotFlushed EXCEPT ![target] = Max2(@, last)]
       /\ installPending' = [installPending EXCEPT ![target] = Nil]
       /\ installDone' = [installDone EXCEPT ![target] = FALSE]
       /\ UNCHANGED <<online, role, recoveryStage, recoveryReady, vote,
                       persistentVote, acceptedIO, submittedIO, durableIO,
                       engineLog, persistentLog, clusterCommitted,
                       localCommitted, persistedCommitted, applySubmitted,
                       smApplied, appliedLog, ioVars, historyVars,
                       membershipVars, electionVars, replicationVars,
                       readVars, buildPhase, buildTarget, buildMembership,
                       snapshotMetaLast, snapshotMetaMembership,
                       snapshotAccepted, snapshotSubmitted, snapshotLast,
                       snapshotMembership, purgeUpto, purgeCommand,
                       durablePurged>>

(* -------------------------------------------------------------------------
 * Independent heartbeat and read paths (S1, S5)
 * ------------------------------------------------------------------------- *)

(* leader_handler/mod.rs:98-104 and raft_core.rs:1765-1803 -- capture the
 * current (committed vote, effective membership log) session and publish one
 * heartbeat event per peer. *)
LeaderHandlerSendHeartbeat(s) ==
    /\ online[s] /\ role[s] = Leader
    /\ heartbeatEvent' = [heartbeatEvent EXCEPT ![s] =
         [t \in Server |->
            IF t /= s /\ t \in AllVoters(effectiveMembership[s])
            THEN [session |-> CurrentSession(s), sentAt |-> clock,
                  committed |-> localCommitted[s]]
            ELSE @ [t]]]
    /\ UNCHANGED <<nodeVars, ioVars, historyVars, membershipVars,
                    electionVars, replicationVars, clock, clockAck,
                    leaseUntil, readBarrier, readEpoch, lastReadObserved,
                    lastReadRequired, staleSessionEffect, snapshotVars>>

(* core/heartbeat/worker.rs:72-107 -- each worker independently consumes its
 * watch value and sends an empty AppendEntries using the recorded session. *)
HeartbeatWorkerDoRun(s, target) ==
    LET ev == heartbeatEvent[s][target]
        msg == Message(s, target, HeartbeatRequest, 0, Nil,
                       ev.session, ev.sentAt, ev.committed, 0)
    IN /\ ev /= Nil /\ online[s] /\ online[target]
       /\ msg \notin network
       /\ network' = network \cup {msg}
       /\ heartbeatEvent' = [heartbeatEvent EXCEPT ![s][target] = Nil]
       /\ UNCHANGED <<nodeVars, ioVars, historyVars, membershipVars,
                       electionVars, matchIndex, replicationSession, clock,
                       clockAck, leaseUntil, readBarrier, readEpoch,
                       lastReadObserved, lastReadRequired,
                       staleSessionEffect, snapshotVars>>

(* engine_impl.rs:405-458 and heartbeat/worker.rs:94-156 -- heartbeat is an
 * empty AppendEntries: accept its vote/commit, then delay success until the
 * same IOFlushed condition as other protocol replies. *)
EngineHandleHeartbeatRequest(target, msg) ==
    LET incomingVote == VoteFromSession(msg.session)
        newLocal == Min2(msg.committed, acceptedIO[target].log)
        p == Response(target, msg.src, HeartbeatResponseKind,
                      VoteRank(incomingVote), acceptedIO[target].log,
                      msg.session, 0)
    IN /\ msg \in network
       /\ msg.kind = HeartbeatRequest /\ msg.dst = target
       /\ online[target] /\ recoveryReady[target]
       /\ VoteGE(incomingVote, vote[target])
       /\ vote' = [vote EXCEPT ![target] = incomingVote]
       /\ role' = [role EXCEPT ![target] = Follower]
       /\ acceptedIO' = [acceptedIO EXCEPT ![target] =
            SetIOVote(@, VoteRank(incomingVote))]
       /\ clusterCommitted' = [clusterCommitted EXCEPT ![target] =
            Max2(@, newLocal)]
       /\ localCommitted' = [localCommitted EXCEPT ![target] =
            Max2(@, newLocal)]
       /\ pendingResponses' = pendingResponses \cup {p}
       /\ network' = network \ {msg}
       /\ UNCHANGED <<online, recoveryStage, recoveryReady, persistentVote,
                       submittedIO, durableIO, flushedIO, engineLog,
                       persistentLog, persistedCommitted, applySubmitted,
                       smApplied, appliedLog, pendingLocalIO, ackHistory,
                       ioBridgeVars, historyVars, membershipVars, electionVars, matchIndex,
                       replicationSession, readVars, snapshotVars>>

(* raft_core.rs:1573-1588 and replication_handler/mod.rs:115-148 -- only the
 * current session updates clock progress; a quorum extends the lease from the
 * heartbeat's conservative send time. *)
RaftCoreHandleHeartbeatProgress(s, msg) ==
    LET matches == msg.session = CurrentSession(s)
        newAcks == clockAck[s] \cup {msg.src}
        granted == IsQuorum(newAcks, effectiveMembership[s])
    IN /\ msg \in network
       /\ msg.kind = HeartbeatResponse /\ msg.dst = s
       /\ network' = network \ {msg}
       /\ clockAck' = IF matches
            THEN [clockAck EXCEPT ![s] = newAcks]
            ELSE clockAck
       /\ leaseUntil' = IF matches /\ granted
            THEN [leaseUntil EXCEPT ![s] = Max2(@, msg.sentAt + 1)]
            ELSE leaseUntil
       /\ UNCHANGED <<nodeVars, ioVars, historyVars, membershipVars,
                       electionVars, matchIndex, replicationSession,
                       heartbeatEvent, clock, readBarrier, readEpoch,
                       lastReadObserved, lastReadRequired,
                       staleSessionEffect, snapshotVars>>

(* raft_core.rs:267-317 -- capture max(no-op, local committed) and applied;
 * LeaseRead returns only under an unexpired quorum lease, while ReadIndex
 * starts with the leader's own grant and a snapshot of effective membership. *)
RaftCoreHandleEnsureLinearizableRead(s, policy) ==
    LET nextId == readEpoch[s] + 1
        required == Max2(localCommitted[s],
                         IF role[s] = Leader THEN 1 ELSE 0)
        own == {s}
        immediate == IsQuorum(own, effectiveMembership[s])
        phase == IF policy = LeaseReadPolicy
                 THEN ReadWaitApply
                 ELSE IF immediate THEN ReadWaitApply ELSE ReadWaitQuorum
    IN /\ online[s] /\ role[s] = Leader /\ recoveryReady[s]
       /\ readBarrier[s].phase \in {ReadIdle, ReadDone}
       /\ nextId <= MaxIndex
       /\ policy \in {ReadIndexPolicy, LeaseReadPolicy}
       /\ policy = ReadIndexPolicy \/ clock < leaseUntil[s]
       /\ readEpoch' = [readEpoch EXCEPT ![s] = nextId]
       /\ readBarrier' = [readBarrier EXCEPT ![s] =
            ReadState(phase, policy, required, clientCompleted,
                      CurrentSession(s), effectiveMembership[s], own, nextId)]
       /\ UNCHANGED <<nodeVars, ioVars, historyVars, membershipVars,
                       electionVars, replicationVars, heartbeatEvent, clock,
                       clockAck, leaseUntil, lastReadObserved,
                       lastReadRequired, staleSessionEffect, snapshotVars>>

(* raft_core.rs:319-377 -- ReadIndex spawns one empty AppendEntries task per
 * voter using the vote/membership snapshot captured at request creation. *)
RaftCoreSendReadIndexRequest(s, target) ==
    LET r == readBarrier[s]
        msg == Message(s, target, ReadIndexRequest, 0, Nil,
                       r.session, clock, localCommitted[s], r.readId)
    IN /\ online[s] /\ online[target]
       /\ r.phase = ReadWaitQuorum /\ r.policy = ReadIndexPolicy
       /\ target \in AllVoters(r.membership) /\ target /= s
       /\ target \notin r.acks
       /\ msg \notin network
       /\ network' = network \cup {msg}
       /\ UNCHANGED <<nodeVars, ioVars, historyVars, membershipVars,
                       electionVars, matchIndex, replicationSession,
                       readVars, snapshotVars>>

(* raft_core.rs:335-370 through engine_impl.rs:405-438 -- the remote call is
 * an empty AppendEntries and its response is still gated by IOFlushed. *)
EngineHandleReadIndexRequest(target, msg) ==
    LET incomingVote == VoteFromSession(msg.session)
        newLocal == Min2(msg.committed, acceptedIO[target].log)
        p == Response(target, msg.src, ReadIndexResponseKind,
                      VoteRank(incomingVote), acceptedIO[target].log,
                      msg.session, msg.readId)
    IN /\ msg \in network
       /\ msg.kind = ReadIndexRequest /\ msg.dst = target
       /\ online[target] /\ recoveryReady[target]
       /\ VoteGE(incomingVote, vote[target])
       /\ vote' = [vote EXCEPT ![target] = incomingVote]
       /\ role' = [role EXCEPT ![target] = Follower]
       /\ acceptedIO' = [acceptedIO EXCEPT ![target] =
            SetIOVote(@, VoteRank(incomingVote))]
       /\ clusterCommitted' = [clusterCommitted EXCEPT ![target] =
            Max2(@, newLocal)]
       /\ localCommitted' = [localCommitted EXCEPT ![target] =
            Max2(@, newLocal)]
       /\ pendingResponses' = pendingResponses \cup {p}
       /\ network' = network \ {msg}
       /\ UNCHANGED <<online, recoveryStage, recoveryReady, persistentVote,
                       submittedIO, durableIO, flushedIO, engineLog,
                       persistentLog, persistedCommitted, applySubmitted,
                       smApplied, appliedLog, pendingLocalIO, ackHistory,
                       ioBridgeVars, historyVars, membershipVars, electionVars, matchIndex,
                       replicationSession, readVars, snapshotVars>>

(* raft_core.rs:379-427 -- the spawned ReadIndex task counts successful
 * responses against its captured membership and does not re-enter the core to
 * re-check the current replication session.  staleSessionEffect is a ghost
 * witness for the S5 SessionFence property. *)
RaftCoreHandleReadIndexResponse(s, msg) ==
    LET r == readBarrier[s]
        newAcks == r.acks \cup {msg.src}
        granted == IsQuorum(newAcks, r.membership)
        newPhase == IF granted THEN ReadWaitApply ELSE ReadWaitQuorum
    IN /\ msg \in network
       /\ msg.kind = ReadIndexResponse /\ msg.dst = s
       /\ r.phase = ReadWaitQuorum
       /\ msg.readId = r.readId /\ msg.session = r.session
       /\ network' = network \ {msg}
       /\ readBarrier' = [readBarrier EXCEPT ![s] =
            [@ EXCEPT !.acks = newAcks, !.phase = newPhase]]
       /\ staleSessionEffect' =
            (staleSessionEffect \/ (granted /\ msg.session /= CurrentSession(s)))
       /\ UNCHANGED <<nodeVars, ioVars, historyVars, membershipVars,
                       electionVars, matchIndex, replicationSession,
                       heartbeatEvent, clock, clockAck, leaseUntil, readEpoch,
                       lastReadObserved, lastReadRequired, snapshotVars>>

(* linearizer.rs:99-135 and linearize_state.rs:67-77 -- success requires that
 * the same node's applied cursor reaches the captured read-log-id. *)
LinearizerTryAwaitReady(s) ==
    LET r == readBarrier[s]
    IN /\ r.phase = ReadWaitApply
       /\ smApplied[s] >= r.required
       /\ readBarrier' = [readBarrier EXCEPT ![s] =
            [@ EXCEPT !.phase = ReadDone]]
       /\ lastReadObserved' =
            [lastReadObserved EXCEPT ![s] = smApplied[s]]
       /\ lastReadRequired' =
            [lastReadRequired EXCEPT ![s] = r.floor]
       /\ UNCHANGED <<nodeVars, ioVars, historyVars, membershipVars,
                       electionVars, replicationVars, heartbeatEvent, clock,
                       clockAck, leaseUntil, readEpoch, staleSessionEffect,
                       snapshotVars>>

(* async timeout/clock progression used by election and lease expiry. *)
AdvanceClock ==
    /\ clock < MaxClock
    /\ clock' = clock + 1
    /\ UNCHANGED <<nodeVars, ioVars, historyVars, membershipVars,
                    electionVars, replicationVars, heartbeatEvent, clockAck,
                    leaseUntil, readBarrier, readEpoch, lastReadObserved,
                    lastReadRequired, staleSessionEffect, snapshotVars>>

(* Network loss/reorder is permitted for RPC messages; set semantics makes
 * receive order nondeterministic.  This is S5's concrete network adversary. *)
LoseMessage(msg) ==
    /\ msg \in network
    /\ network' = network \ {msg}
    /\ UNCHANGED <<nodeVars, ioVars, historyVars, membershipVars,
                    electionVars, matchIndex, replicationSession,
                    readVars, snapshotVars>>

(* -------------------------------------------------------------------------
 * Crash and ordered recovery (S1, S2, S4)
 * ------------------------------------------------------------------------- *)

(* External process failure.  Volatile state is discarded at RestartLoadState
 * rather than here, allowing the crash event itself to be logged precisely. *)
Crash(s) ==
    /\ online[s]
    /\ online' = [online EXCEPT ![s] = FALSE]
    /\ role' = [role EXCEPT ![s] = Down]
    /\ recoveryStage' = [recoveryStage EXCEPT ![s] = RecoverLoad]
    /\ recoveryReady' = [recoveryReady EXCEPT ![s] = FALSE]
    /\ readBarrier' = [readBarrier EXCEPT ![s] = IdleRead(s)]
    /\ clockAck' = [clockAck EXCEPT ![s] = {}]
    /\ leaseUntil' = [leaseUntil EXCEPT ![s] = 0]
    /\ UNCHANGED <<vote, persistentVote, acceptedIO, submittedIO,
                    durableIO, flushedIO, engineLog, persistentLog,
                    clusterCommitted, localCommitted, persistedCommitted,
                    applySubmitted, smApplied, appliedLog, ioVars,
                    historyVars, membershipVars, electionVars, matchIndex,
                    replicationSession, network, heartbeatEvent, clock,
                    readEpoch, lastReadObserved, lastReadRequired,
                    staleSessionEffect, snapshotVars>>

(* storage/helper.rs:87-118,150-223 -- load durable vote/log/committed and
 * synchronize IO cursors.  A transient state machine starts empty; snapshot
 * restore and replay remain separate awaited steps. *)
RestartLoadState(s) ==
    LET restoredCommit == IF PersistCommitted
                           THEN persistedCommitted[s]
                           ELSE snapshotLast[s]
    IN /\ ~online[s]
       /\ recoveryStage[s] = RecoverLoad
       /\ online' = [online EXCEPT ![s] = TRUE]
       /\ vote' = [vote EXCEPT ![s] = persistentVote[s]]
       /\ role' = [role EXCEPT ![s] = Follower]
       /\ engineLog' = [engineLog EXCEPT ![s] = persistentLog[s]]
       /\ acceptedIO' = [acceptedIO EXCEPT ![s] = durableIO[s]]
       /\ submittedIO' = [submittedIO EXCEPT ![s] = durableIO[s]]
       /\ flushedIO' = [flushedIO EXCEPT ![s] = durableIO[s]]
       /\ clusterCommitted' =
            [clusterCommitted EXCEPT ![s] = restoredCommit]
       /\ localCommitted' =
            [localCommitted EXCEPT ![s] = restoredCommit]
       /\ applySubmitted' = [applySubmitted EXCEPT ![s] = 0]
       /\ smApplied' = [smApplied EXCEPT ![s] = 0]
       /\ appliedLog' = [appliedLog EXCEPT ![s] = BlankLog]
       /\ recoveryStage' =
            [recoveryStage EXCEPT ![s] = RecoverSnapshot]
       /\ candidateGranted' = [candidateGranted EXCEPT ![s] = {}]
       /\ replicationSession' = [replicationSession EXCEPT ![s] =
            SessionFrom(persistentVote[s], effectiveMembership[s].log)]
       /\ pendingLocalIO' = [pendingLocalIO EXCEPT ![s] = {}]
       /\ pendingResponses' =
            {p \in pendingResponses : p.node /= s /\ p.peer /= s}
       /\ ioWatch' = [ioWatch EXCEPT ![s] = durableIO[s]]
       /\ ioForwarded' = [ioForwarded EXCEPT ![s] = durableIO[s]]
       /\ UNCHANGED <<recoveryReady, persistentVote, durableIO,
                       persistentLog, persistedCommitted, ackHistory,
                       historyVars, membershipVars, establishedVotes,
                       voteSupport, voteMembership, leaderHistory,
                       matchIndex, network, heartbeatEvent, clock, clockAck,
                       leaseUntil, readBarrier, readEpoch, lastReadObserved,
                       lastReadRequired, staleSessionEffect, snapshotVars>>

(* storage/helper.rs:225-255 -- install a persistent snapshot only when it is
 * newer than the state machine's applied cursor. *)
StorageHelperRestoreFromSnapshot(s) ==
    /\ online[s]
    /\ recoveryStage[s] = RecoverSnapshot
    /\ smApplied' = [smApplied EXCEPT ![s] = snapshotLast[s]]
    /\ applySubmitted' = [applySubmitted EXCEPT ![s] = snapshotLast[s]]
    /\ appliedLog' = [appliedLog EXCEPT ![s] =
         CopyPrefix(@, committedLog, snapshotLast[s])]
    /\ committedMembership' =
         [committedMembership EXCEPT ![s] = snapshotMembership[s]]
    /\ effectiveMembership' =
         [effectiveMembership EXCEPT ![s] = snapshotMembership[s]]
    /\ recoveryStage' = [recoveryStage EXCEPT ![s] = RecoverReplay]
    /\ UNCHANGED <<online, role, recoveryReady, vote, persistentVote,
                    acceptedIO, submittedIO, durableIO, flushedIO,
                    engineLog, persistentLog, clusterCommitted,
                    localCommitted, persistedCommitted, ioVars,
                    historyVars, membershipLog, changeRequests,
                    requestPhase, electionVars, replicationVars, readVars,
                    snapshotVars>>

(* storage/helper.rs:123-148,258-275 -- replay committed entries in ordered
 * chunks; one entry per model step exposes a crash point between chunks. *)
StorageHelperReapplyCommitted(s) ==
    LET idx == smApplied[s] + 1
        e == engineLog[s][idx]
    IN /\ online[s]
       /\ recoveryStage[s] = RecoverReplay
       /\ PersistCommitted
       /\ idx <= localCommitted[s]
       /\ idx > durablePurged[s]
       /\ e /= Nil
       /\ smApplied' = [smApplied EXCEPT ![s] = idx]
       /\ applySubmitted' = [applySubmitted EXCEPT ![s] = idx]
       /\ appliedLog' = [appliedLog EXCEPT ![s][idx] = e]
       /\ UNCHANGED <<online, role, recoveryStage, recoveryReady, vote,
                       persistentVote, acceptedIO, submittedIO, durableIO,
                       flushedIO, engineLog, persistentLog,
                       clusterCommitted, localCommitted,
                       persistedCommitted, ioVars, historyVars,
                       membershipVars, electionVars, replicationVars,
                       readVars, snapshotVars>>

(* storage/helper.rs:123-150 -- recovery is ready only after snapshot restore
 * and every required persisted-commit replay step is complete. *)
StorageHelperFinishRecovery(s) ==
    /\ online[s]
    /\ recoveryStage[s] = RecoverReplay
    /\ (~PersistCommitted \/ smApplied[s] >= localCommitted[s])
    /\ recoveryStage' = [recoveryStage EXCEPT ![s] = RecoverReady]
    /\ recoveryReady' = [recoveryReady EXCEPT ![s] = TRUE]
    /\ UNCHANGED <<online, role, vote, persistentVote, acceptedIO,
                    submittedIO, durableIO, flushedIO, engineLog,
                    persistentLog, clusterCommitted, localCommitted,
                    persistedCommitted, applySubmitted, smApplied,
                    appliedLog, ioVars, historyVars, membershipVars,
                    electionVars, replicationVars, readVars, snapshotVars>>

(* engine_impl.rs:145-159 and vote_handler/mod.rs:162-218 -- a persisted
 * committed self-vote restores Leader immediately after helper recovery and
 * recreates its replication session. *)
EngineStartupRestoreLeader(s) ==
    LET pv == persistentVote[s]
        vr == VoteRank(pv)
    IN /\ online[s] /\ recoveryReady[s]
       /\ recoveryStage[s] = RecoverReady
       /\ pv.committed /\ pv.leader = s
       /\ vr \in establishedVotes
       /\ role' = [role EXCEPT ![s] = Leader]
       /\ recoveryStage' = [recoveryStage EXCEPT ![s] = Running]
       /\ replicationSession' = [replicationSession EXCEPT ![s] =
            SessionFrom(pv, effectiveMembership[s].log)]
       /\ matchIndex' =
            [matchIndex EXCEPT ![s][s] = acceptedIO[s].log]
       /\ leaderHistory' =
            [leaderHistory EXCEPT ![pv.term] = @ \cup {s}]
       /\ clockAck' = [clockAck EXCEPT ![s] = {s}]
       /\ leaseUntil' = [leaseUntil EXCEPT ![s] = 0]
       /\ UNCHANGED <<online, recoveryReady, vote, persistentVote,
                       acceptedIO, submittedIO, durableIO, flushedIO,
                       engineLog, persistentLog, clusterCommitted,
                       localCommitted, persistedCommitted, applySubmitted,
                       smApplied, appliedLog, ioVars, historyVars,
                       membershipVars, candidateGranted, establishedVotes,
                       voteSupport, voteMembership, network, heartbeatEvent,
                       clock, readBarrier, readEpoch, lastReadObserved,
                       lastReadRequired, staleSessionEffect, snapshotVars>>

(* engine_impl.rs:162-174 -- otherwise startup selects follower or learner;
 * learner is abstracted to Follower because both reject leader-only actions. *)
EngineStartupFollowing(s) ==
    /\ online[s] /\ recoveryReady[s]
    /\ recoveryStage[s] = RecoverReady
    /\ ~(persistentVote[s].committed /\ persistentVote[s].leader = s)
    /\ role' = [role EXCEPT ![s] = Follower]
    /\ recoveryStage' = [recoveryStage EXCEPT ![s] = Running]
    /\ UNCHANGED <<online, recoveryReady, vote, persistentVote,
                    acceptedIO, submittedIO, durableIO, flushedIO,
                    engineLog, persistentLog, clusterCommitted,
                    localCommitted, persistedCommitted, applySubmitted,
                    smApplied, appliedLog, ioVars, historyVars,
                    membershipVars, electionVars, replicationVars, readVars,
                    snapshotVars>>

(* -------------------------------------------------------------------------
 * Next-state relation
 * ------------------------------------------------------------------------- *)

NodeStep(s) ==
    \/ HandleElectionTimeout(s)
    \/ \E c \in Server \ {s} : EngineHandleVoteRequest(s, c)
    \/ RaftCoreRunCommandSaveVote(s)
    \/ \E io \in pendingLocalIO[s] : RaftCoreHandleLocalIO(s, io)
    \/ EngineHandleVoteResponse(s)
    \/ \E value \in Payload : LeaderHandlerLeaderAppendEntries(s, value)
    \/ RaftCoreRunCommandAppendEntries(s)
    \/ LogStoreCompleteAppend(s)
    \/ IOCompletionForwarder(s)
    \/ \E target \in Server \ {s} : ReplicationHandlerSendReplicate(s, target)
    \/ \E msg \in network : EngineHandleAppendEntries(s, msg)
    \/ \E msg \in network : ReplicationHandlerUpdateProgress(s, msg)
    \/ RaftCoreRunCommandSaveCommittedAndApply(s)
    \/ SMWorkerApply(s)
    \/ SnapshotHandlerTriggerSnapshot(s)
    \/ SMWorkerBuildSnapshotStart(s)
    \/ EngineOnBuildingSnapshotDone(s)
    \/ LogHandlerSchedulePolicyBasedPurge(s)
    \/ LogHandlerPurgeLog(s)
    \/ RaftCoreRunCommandPurgeLog(s)
    \/ \E target \in Server \ {s} : ReplicationCoreSendSnapshot(s, target)
    \/ \E msg \in network : FollowingHandlerInstallFullSnapshot(s, msg)
    \/ SMWorkerInstallSnapshot(s)
    \/ RaftCoreHandleInstallSnapshotNotification(s)
    \/ LeaderHandlerSendHeartbeat(s)
    \/ \E target \in Server \ {s} : HeartbeatWorkerDoRun(s, target)
    \/ \E msg \in network : EngineHandleHeartbeatRequest(s, msg)
    \/ \E msg \in network : RaftCoreHandleHeartbeatProgress(s, msg)
    \/ \E policy \in {ReadIndexPolicy, LeaseReadPolicy} :
           RaftCoreHandleEnsureLinearizableRead(s, policy)
    \/ \E target \in Server \ {s} : RaftCoreSendReadIndexRequest(s, target)
    \/ \E msg \in network : EngineHandleReadIndexRequest(s, msg)
    \/ \E msg \in network : RaftCoreHandleReadIndexResponse(s, msg)
    \/ LinearizerTryAwaitReady(s)
    \/ Crash(s)
    \/ RestartLoadState(s)
    \/ StorageHelperRestoreFromSnapshot(s)
    \/ StorageHelperReapplyCommitted(s)
    \/ StorageHelperFinishRecovery(s)
    \/ EngineStartupRestoreLeader(s)
    \/ EngineStartupFollowing(s)

GlobalStep ==
    \/ \E p \in pendingResponses : RaftCoreReleaseVoteResponse(p)
    \/ \E p \in pendingResponses : RaftCoreReleaseRPCResponse(p)
    \/ \E p \in pendingResponses : ApplyResponderComplete(p)
    \/ \E r \in Request, s \in Server, goal \in SUBSET Server,
          retain \in BOOLEAN :
           ManagementApiStartMembership(r, s, goal, retain)
    \/ \E r \in Request : CoreChangeMembership(r)
    \/ \E r \in Request : ManagementApiFlattenJoint(r)
    \/ \E msg \in network : LoseMessage(msg)
    \/ AdvanceClock

Next == (\E s \in Server : NodeStep(s)) \/ GlobalStep

Spec == Init /\ [][Next]_vars

(* -------------------------------------------------------------------------
 * Invariants from brief section 5
 * ------------------------------------------------------------------------- *)

VoteType == [term : Term, leader : Server, committed : BOOLEAN]
IOType == [vote : VoteRankRange, log : 0..MaxIndex]
MembershipType ==
    [log : 0..MaxIndex, old : SUBSET Server, new : SUBSET Server,
     joint : BOOLEAN, request : Request \cup {NoRequest}]
SessionType == [term : Term, leader : Server, membershipIndex : 0..MaxIndex]
EntryType ==
    [term : Term, leader : Server, index : Index,
     kind : {NormalEntry, BlankEntry, MembershipEntry},
     value : Payload \cup {NoopValue},
     membership : MembershipType \cup {NoMembership},
     request : Request \cup {NoRequest}]
MessageType ==
    [src : Server, dst : Server,
     kind : {AppendRequest, AppendResponse, HeartbeatRequest,
             HeartbeatResponse, ReadIndexRequest, ReadIndexResponse},
     idx : 0..MaxIndex, entry : EntryType \cup {Nil},
     session : SessionType, sentAt : 0..MaxClock,
     committed : 0..MaxIndex, readId : 0..MaxIndex]
ResponseType ==
    [node : Server, peer : Server,
     kind : {VoteResponseKind, AppendResponseKind,
             HeartbeatResponseKind, ReadIndexResponseKind,
             ClientResponseKind},
     requiredVote : VoteRankRange, requiredLog : 0..MaxIndex,
     session : SessionType, readId : 0..MaxIndex]
AckType ==
    [kind : {VoteResponseKind, AppendResponseKind,
             HeartbeatResponseKind, ReadIndexResponseKind,
             ClientResponseKind},
     node : Server, requiredVote : VoteRankRange,
     requiredLog : 0..MaxIndex]
HeartbeatEventType ==
    [session : SessionType, sentAt : 0..MaxClock,
     committed : 0..MaxIndex]
RequestStateType ==
    [status : {RequestIdle, RequestStarted, RequestJointSubmitted,
               RequestJointCommitted, RequestUniformSubmitted, RequestDone},
     owner : Server, goal : SUBSET Server, retain : BOOLEAN,
     log : 0..MaxIndex]
ReadStateType ==
    [phase : {ReadIdle, ReadWaitQuorum, ReadWaitApply, ReadDone},
     policy : {ReadIndexPolicy, LeaseReadPolicy}, required : 0..MaxIndex,
     floor : 0..MaxIndex, session : SessionType,
     membership : MembershipType, acks : SUBSET Server,
     readId : 0..MaxIndex]

TypeOK ==
    /\ online \in [Server -> BOOLEAN]
    /\ role \in [Server -> {Follower, Candidate, Leader, Down}]
    /\ recoveryStage \in
         [Server -> {Running, RecoverLoad, RecoverSnapshot,
                     RecoverReplay, RecoverReady}]
    /\ recoveryReady \in [Server -> BOOLEAN]
    /\ vote \in [Server -> VoteType]
    /\ persistentVote \in [Server -> VoteType]
    /\ acceptedIO \in [Server -> IOType]
    /\ submittedIO \in [Server -> IOType]
    /\ durableIO \in [Server -> IOType]
    /\ flushedIO \in [Server -> IOType]
    /\ engineLog \in [Server -> [Index -> EntryType \cup {Nil}]]
    /\ persistentLog \in [Server -> [Index -> EntryType \cup {Nil}]]
    /\ clusterCommitted \in [Server -> 0..MaxIndex]
    /\ localCommitted \in [Server -> 0..MaxIndex]
    /\ persistedCommitted \in [Server -> 0..MaxIndex]
    /\ applySubmitted \in [Server -> 0..MaxIndex]
    /\ smApplied \in [Server -> 0..MaxIndex]
    /\ appliedLog \in [Server -> [Index -> EntryType \cup {Nil}]]
    /\ pendingLocalIO \in [Server -> SUBSET IOType]
    /\ pendingResponses \subseteq ResponseType
    /\ ackHistory \subseteq AckType
    /\ ioWatch \in [Server -> IOType]
    /\ ioForwarded \in [Server -> IOType]
    /\ committedLog \in [Index -> EntryType \cup {Nil}]
    /\ clientCompleted \in 0..MaxIndex
    /\ committedMembership \in [Server -> MembershipType]
    /\ effectiveMembership \in [Server -> MembershipType]
    /\ membershipLog \in
         [Server -> [Index -> MembershipType \cup {NoMembership}]]
    /\ changeRequests \in [Request -> RequestStateType]
    /\ requestPhase \in
         [Request -> {RequestIdle, RequestStarted, RequestJointSubmitted,
                      RequestJointCommitted, RequestUniformSubmitted,
                      RequestDone}]
    /\ candidateGranted \in [Server -> SUBSET Server]
    /\ establishedVotes \subseteq VoteRankRange
    /\ voteSupport \in [VoteRankRange -> SUBSET Server]
    /\ voteMembership \in [VoteRankRange -> MembershipType]
    /\ leaderHistory \in [Term -> SUBSET Server]
    /\ matchIndex \in [Server -> [Server -> 0..MaxIndex]]
    /\ replicationSession \in [Server -> SessionType]
    /\ network \subseteq MessageType
    /\ heartbeatEvent \in
         [Server -> [Server -> HeartbeatEventType \cup {Nil}]]
    /\ clock \in 0..MaxClock
    /\ clockAck \in [Server -> SUBSET Server]
    /\ leaseUntil \in [Server -> 0..(MaxClock + 1)]
    /\ readBarrier \in [Server -> ReadStateType]
    /\ readEpoch \in [Server -> 0..MaxIndex]
    /\ lastReadObserved \in [Server -> 0..MaxIndex]
    /\ lastReadRequired \in [Server -> 0..MaxIndex]
    /\ staleSessionEffect \in BOOLEAN
    /\ buildPhase \in [Server -> {BuildIdle, BuildQueued, BuildRunning}]
    /\ buildTarget \in [Server -> 0..MaxIndex]
    /\ buildMembership \in [Server -> MembershipType]
    /\ snapshotMetaLast \in [Server -> 0..MaxIndex]
    /\ snapshotMetaMembership \in [Server -> MembershipType]
    /\ snapshotAccepted \in [Server -> 0..MaxIndex]
    /\ snapshotSubmitted \in [Server -> 0..MaxIndex]
    /\ snapshotFlushed \in [Server -> 0..MaxIndex]
    /\ snapshotLast \in [Server -> 0..MaxIndex]
    /\ snapshotMembership \in [Server -> MembershipType]
    /\ installPending \in [Server -> MessageType \cup {Nil}]
    /\ installDone \in [Server -> BOOLEAN]
    /\ purgeUpto \in [Server -> 0..MaxIndex]
    /\ purgeCommand \in [Server -> 0..MaxIndex]
    /\ durablePurged \in [Server -> 0..MaxIndex]

(* Standard mode retains textbook per-term uniqueness.  Advanced ordered
 * LeaderId mode intentionally allows successive leaders in one term. *)
StandardElectionSafety ==
    LeaderMode /= StandardMode
    \/ \A t \in Term : Cardinality(leaderHistory[t]) <= 1

(* Persistent/accepted votes never move backward, and every live leader vote
 * was established by a quorum of the membership captured at establishment. *)
OrderedVoteSafety ==
    /\ \A s \in Server :
         /\ VoteRank(persistentVote[s]) <= VoteRank(vote[s])
         /\ role[s] = Leader => VoteRank(vote[s]) \in establishedVotes
    /\ \A vr \in establishedVotes :
         IsQuorum(voteSupport[vr], voteMembership[vr])

(* Equal log IDs imply equal retained prefixes.  Purged prefixes are compared
 * through committed/snapshot safety instead of inventing log bytes. *)
LogMatching ==
    \A s, t \in Server, i \in Index :
      /\ engineLog[s][i] /= Nil
      /\ engineLog[t][i] /= Nil
      /\ engineLog[s][i].term = engineLog[t][i].term
      /\ engineLog[s][i].leader = engineLog[t][i].leader
      => \A j \in 1..i :
           /\ engineLog[s][j] /= Nil
           /\ engineLog[t][j] /= Nil
           => engineLog[s][j] = engineLog[t][j]

LeaderCompleteness ==
    \A s \in Server : role[s] = Leader => HasCommittedPrefix(s)

StateMachineSafety ==
    \A s, t \in Server, i \in Index :
      /\ appliedLog[s][i] /= Nil
      /\ appliedLog[t][i] /= Nil
      => appliedLog[s][i] = appliedLog[t][i]

DurableBeforeAck ==
    \A a \in ackHistory :
      /\ durableIO[a.node].vote >= a.requiredVote
      /\ durableIO[a.node].log >= a.requiredLog

(* The brief's cross-subsystem frontier, plus each subsystem's internal
 * accepted/submitted/flushed order.  localCommitted tracks apply_progress
 * accepted and may advance to acceptedIO before the append command is
 * submitted; SaveCommittedAndApply is capped by submittedIO. *)
CursorOrder ==
    \A s \in Server :
      /\ durablePurged[s] <= snapshotFlushed[s]
      /\ snapshotFlushed[s] <= smApplied[s]
      /\ smApplied[s] <= applySubmitted[s]
      /\ applySubmitted[s] <= localCommitted[s]
      /\ applySubmitted[s] <= submittedIO[s].log
      /\ localCommitted[s] <= acceptedIO[s].log
      /\ submittedIO[s].log <= acceptedIO[s].log
      /\ flushedIO[s].log <= submittedIO[s].log
      /\ durableIO[s].log <= submittedIO[s].log
      /\ snapshotFlushed[s] <= snapshotSubmitted[s]
      /\ snapshotSubmitted[s] <= snapshotAccepted[s]

RecoveryReadSafety ==
    \A s \in Server : lastReadObserved[s] >= lastReadRequired[s]

MembershipEqual(a, b) ==
    /\ a.log = b.log /\ a.old = b.old /\ a.new = b.new
    /\ a.joint = b.joint /\ a.request = b.request

MembershipAgreement ==
    /\ \A s, t \in Server :
         committedMembership[s].log = committedMembership[t].log
         => MembershipEqual(committedMembership[s], committedMembership[t])
    /\ \A s \in Server :
         /\ committedMembership[s].old /= {}
         /\ committedMembership[s].new /= {}
         /\ ~committedMembership[s].joint
            => committedMembership[s].old = committedMembership[s].new
    /\ \A s \in Server :
         committedMembership[s].request \in Request
         => committedMembership[s].new =
              changeRequests[committedMembership[s].request].goal

EffectiveMembershipBacked ==
    \A s \in Server :
      effectiveMembership[s].log = 0
      \/ /\ effectiveMembership[s].log \in Index
         /\ \/ membershipLog[s][effectiveMembership[s].log] =
                  effectiveMembership[s]
            \/ /\ snapshotMetaLast[s] >= effectiveMembership[s].log
               /\ snapshotMetaMembership[s] = effectiveMembership[s]

SessionFence == ~staleSessionEffect

SnapshotPurgeSafety ==
    \A s \in Server :
      /\ durablePurged[s] <= snapshotLast[s]
      /\ committedMembership[s].log <= durablePurged[s]
         => snapshotMembership[s].log >= committedMembership[s].log

NoPhantomCommitted ==
    \A i \in Index :
      committedLog[i] /= Nil => committedLog[i].index = i

ProgressStructure ==
    \A s \in Server :
      /\ flushedIO[s].vote <= durableIO[s].vote
      /\ durableIO[s].vote <= submittedIO[s].vote
      /\ submittedIO[s].vote <= acceptedIO[s].vote
      /\ flushedIO[s].log <= durableIO[s].log
      /\ ioForwarded[s].vote <= ioWatch[s].vote
      /\ ioForwarded[s].log <= ioWatch[s].log
      /\ ioWatch[s].vote <= durableIO[s].vote
      /\ ioWatch[s].log <= durableIO[s].log
      /\ recoveryReady[s] <=> recoveryStage[s] \in {Running, RecoverReady}

=================================================================
