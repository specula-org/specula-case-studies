---- MODULE base ----
\*****************************************************************************
\* MongoDB MongoRaftReconfig — Logless Dynamic Reconfiguration
\*
\* Extended spec modeling force reconfig, multi-step election (drain mode),
\* heartbeat config propagation, arbiter quorum semantics, and newlyAdded
\* two-phase voter addition.
\*
\* Based on MongoReplReconfig.tla (TLAPS-proven spec) with extensions
\* targeting 5 bug families from the modeling brief.
\*
\* Key differences from existing spec:
\*  - Force reconfig (Family 1): configTerm=-1, bypasses all safety checks
\*  - Multi-step election (Family 2): WinElection -> DrainMode -> CompleteDrain
\*  - Heartbeat config (Family 3): missing lastCommittedInPrevConfig update
\*  - Arbiter quorum (Family 4): separate config vs data quorums
\*  - newlyAdded (Family 5): two-phase voter addition, effective voters
\*****************************************************************************

EXTENDS Integers, FiniteSets, Sequences, TLC

\* The set of server IDs.
CONSTANTS Server

\* Server states.
CONSTANTS Leader, Follower, Down

\* Family 4: Arbiter nodes — subset of Server that are arbiters.
\* Arbiters can vote and acknowledge configs but do NOT hold data.
\* repl_set_config.cpp:634-635 — arbiters counted in _totalVotingMembers
CONSTANTS Arbiter

\* Sentinel value for force reconfig config term.
\* repl_set_config.h:78 — OpTime::kUninitializedTerm = -1
UninitializedTerm == -1

(******************************************************************************)
(* Global variables                                                           *)
(******************************************************************************)

\* Set of all immediately committed entries.
\* Each element: [index |-> Nat, term |-> Nat, configVersion |-> Nat]
VARIABLE immediatelyCommitted

(******************************************************************************)
(* Per-server variables                                                       *)
(******************************************************************************)

\* The server's term number.
VARIABLE currentTerm

\* The server's state (Leader, Follower, or Down).
VARIABLE state

serverVars == <<currentTerm, state>>

\* A sequence of log entries. Each entry is a record [term |-> Nat].
VARIABLE log

\* A server's current config — a set of servers (SUBSET Server).
VARIABLE config

\* The config version of a node's current config.
VARIABLE configVersion

\* The term in which the current config was written.
\* UninitializedTerm (-1) for force-installed configs.
\* replication_coordinator_impl.cpp:3425 — force sets term to kUninitializedTerm
VARIABLE configTerm

configVars == <<config, configVersion, configTerm>>

\* Family 2: Whether node is in drain mode (post-election, pre-config-term-bump).
\* replication_coordinator_impl.cpp:1454 — ApplierDraining state
VARIABLE drainMode

\* Family 5: Whether node has newlyAdded flag set (non-voting until caught up).
\* member_config.h:177-179 — isVoter() returns false for newlyAdded
VARIABLE newlyAdded

\* Family 3: Index of last committed entry when config was last changed.
\* replication_coordinator_impl.cpp:3999 — updateLastCommittedInPrevConfig
\* Heartbeat path (line 1052-1055) does NOT update this.
VARIABLE lastCommittedInPrevConfig

extensionVars == <<drainMode, newlyAdded, lastCommittedInPrevConfig>>

vars == <<serverVars, log, immediatelyCommitted, configVars, extensionVars>>

-------------------------------------------------------------------------------------------

(******************************************************************************)
(* Generic helper operators                                                   *)
(******************************************************************************)

\* The set of all quorums (strict majority) of a given set.
Quorums(S) == {i \in SUBSET(S) : Cardinality(i) * 2 > Cardinality(S)}

Min(s) == CHOOSE x \in s : \A y \in s : x <= y
Max(s) == CHOOSE x \in s : \A y \in s : x >= y
Range(f) == {f[x] : x \in DOMAIN f}
Empty(s) == Len(s) = 0
AliveNodes(s) == {n \in s : state[n] # Down}

-------------------------------------------------------------------------------------------

(******************************************************************************)
(* Family 4/5: Quorum semantics                                              *)
(* repl_set_config.cpp:631-700                                               *)
(******************************************************************************)

\* Effective voters: members who count as voters in quorum calculations.
\* member_config.h:177-179 — isVoter() returns false if newlyAdded=true
EffectiveVoters(cfg) == {s \in cfg : ~newlyAdded[s]}

\* Data-bearing voters: effective voters that are NOT arbiters.
\* repl_set_config.cpp:638 — _writableVotingMembersCount = voters - arbiters
DataVoters(cfg) == EffectiveVoters(cfg) \ Arbiter

\* Config quorum: majority of ALL effective voters (including arbiters).
\* repl_set_config.cpp:685-686 — $majorityConfig pattern
ConfigQuorums(cfg) == Quorums(EffectiveVoters(cfg))

\* Data quorum: majority of data-bearing voters (excluding arbiters).
\* repl_set_config.cpp:648 — $majority pattern uses _writeMajority
DataQuorums(cfg) == Quorums(DataVoters(cfg))

-------------------------------------------------------------------------------------------

(******************************************************************************)
(* Family 1: ConfigVersionAndTerm comparison                                  *)
(* repl_set_config.h:82-99                                                   *)
(* When either term is UninitializedTerm (-1), only version is compared.     *)
(******************************************************************************)

\* Is config (v1,t1) strictly newer than config (v2,t2)?
\* repl_set_config.h:91-100 — operator< with term=-1 semantics
ConfigIsNewer(v1, t1, v2, t2) ==
    IF t1 = UninitializedTerm \/ t2 = UninitializedTerm
    \* repl_set_config.h:95-96 — version-only comparison
    THEN v1 > v2
    \* repl_set_config.h:98-99 — (term, version) lexicographic
    ELSE \/ t1 > t2
         \/ /\ t1 = t2
            /\ v1 > v2

\* Same config version and term (equality with term=-1 semantics).
\* repl_set_config.h:81-89 — operator== ignores terms when either is -1
HasSameConfig(i, j) ==
    IF configTerm[i] = UninitializedTerm \/ configTerm[j] = UninitializedTerm
    THEN configVersion[i] = configVersion[j]
    ELSE /\ configTerm[i] = configTerm[j]
         /\ configVersion[i] = configVersion[j]

-------------------------------------------------------------------------------------------

(******************************************************************************)
(* Log and entry helpers                                                      *)
(******************************************************************************)

\* The term of the last entry in a log, or 0 if empty.
LastTerm(xlog) == IF Len(xlog) = 0 THEN 0 ELSE xlog[Len(xlog)].term
GetTerm(xlog, index) == IF index = 0 \/ index > Len(xlog) THEN 0 ELSE xlog[index].term
LogTerm(i, index) == GetTerm(log[i], index)

\* Is it possible for log 'i' to roll back against log 'j'?
CanRollback(i, j) ==
    /\ Len(log[i]) > 0
    /\ LastTerm(log[i]) < LastTerm(log[j])
    /\ \/ Len(log[i]) > Len(log[j])
       \/ /\ Len(log[i]) <= Len(log[j])
          /\ LastTerm(log[i]) /= LogTerm(j, Len(log[i]))

\* Set of all log entries in a given log.
LogEntries(xlog) == {<<i, xlog[i].term>> : i \in DOMAIN xlog}

\* Is <<index, term>> in the given log.
EntryInLog(xlog, index, term) == <<index, term>> \in LogEntries(xlog)

\* Is 'xlog' a prefix of 'ylog'.
IsPrefix(xlog, ylog) ==
    /\ Len(xlog) <= Len(ylog)
    /\ xlog = SubSeq(ylog, 1, Len(xlog))

-------------------------------------------------------------------------------------------

(******************************************************************************)
(* Voting helpers                                                             *)
(******************************************************************************)

\* Can node 'voter' cast a vote for 'candidate' in term 'term'?
CanVoteFor(voter, candidate, term) ==
    LET logOk ==
        \/ LastTerm(log[candidate]) > LastTerm(log[voter])
        \/ /\ LastTerm(log[candidate]) = LastTerm(log[voter])
           /\ Len(log[candidate]) >= Len(log[voter]) IN
    \* Nodes can only vote once per term (ensured by term < check).
    /\ currentTerm[voter] < term
    \* Only vote for someone with the same config.
    \* Family 1: HasSameConfig uses term=-1 semantics.
    /\ HasSameConfig(candidate, voter)
    \* Family 5: newlyAdded nodes cannot vote.
    \* member_config.h:177-179 — isVoter() returns false for newlyAdded
    /\ ~newlyAdded[voter]
    /\ logOk

-------------------------------------------------------------------------------------------

(******************************************************************************)
(* Commitment and config safety                                               *)
(******************************************************************************)

\* Check whether entry at "index" on "primary" is committed (data quorum).
\* Uses DataQuorums: oplog commitment excludes arbiters.
\* repl_set_config.cpp:648 — $majority uses _writeMajority (excludes arbiters)
IsCommitted(index, primary) ==
    /\ LogTerm(primary, index) = currentTerm[primary]
    /\ \E quorum \in DataQuorums(config[primary]):
        \A s \in quorum:
            /\ Len(log[s]) >= index
            /\ log[s][index] = log[primary][index]
            /\ currentTerm[s] = currentTerm[primary]

\* Maximum committed index from the global ghost variable.
MaxCommittedIndex ==
    IF immediatelyCommitted = {} THEN 0
    ELSE Max({e.index : e \in immediatelyCommitted})

\* Per-node commit point: bounded by what the node has in its log.
\* In reality, _lastCommittedOpTime is a local value that can't exceed the node's log.
\* replication_coordinator_impl.cpp:3999 — updateLastCommittedInPrevConfig
NodeCommitIndex(i) == Min({MaxCommittedIndex, Len(log[i])})

\* Config quorum check: a quorum has the same config.
\* topology_coordinator.cpp:1425-1429 — makeConfigPredicate
ConfigQuorumCheck(self, s) ==
    /\ configVersion[self] = configVersion[s]
    /\ configTerm[self] = configTerm[s]

\* Term quorum check: primary has talked to a quorum in current term.
TermQuorumCheck(self, s) == currentTerm[self] >= currentTerm[s]

\* Oplog commitment using global ghost variable (for invariant checking).
OpCommittedInConfig(primary) ==
    /\ \/ immediatelyCommitted = {}
       \/ \E e \in immediatelyCommitted : IsCommitted(e.index, primary)
    /\ \A e \in immediatelyCommitted :
       e.term = currentTerm[primary] => IsCommitted(e.index, primary)

\* Family 3: Implementation-faithful oplog commitment using local state.
\* replication_coordinator_impl.cpp:3606-3623
\* Uses lastCommittedInPrevConfig instead of global knowledge.
OpCommittedInConfigLocal(primary) ==
    \/ lastCommittedInPrevConfig[primary] = 0
    \/ IsCommitted(lastCommittedInPrevConfig[primary], primary)

\* Is the config on node i currently "safe"?
\* replication_coordinator_impl.cpp: three preconditions in _doReplSetReconfig
ConfigIsSafe(i) ==
    \* Precondition 1: Config quorum check (replication_coordinator_impl.cpp:3594)
    /\ \E q \in ConfigQuorums(config[i]):
       \A s \in q : /\ TermQuorumCheck(i, s)
                    /\ ConfigQuorumCheck(i, s)
    \* Precondition 2+3: Oplog commitment (replication_coordinator_impl.cpp:3606-3623)
    \* Family 3: Uses local commit point tracking.
    /\ OpCommittedInConfigLocal(i)

-------------------------------------------------------------------------------------------

(******************************************************************************)
(*                           ACTIONS                                          *)
(******************************************************************************)

(******************************************************************************)
(* [ACTION] WinElection                                                       *)
(* Node i wins an election and enters drain mode.                             *)
(* Family 2: Split from BecomeLeader to model drain-mode window.             *)
(* Config term is NOT bumped here — that happens in CompleteDrain.           *)
(* replication_coordinator_impl.cpp: _voteForMyselfV1 + catchup phase       *)
(******************************************************************************)
WinElection(i) ==
    LET newTerm == currentTerm[i] + 1 IN
    \* Election quorum from effective voters (excludes newlyAdded, includes arbiters).
    \E voteQuorum \in Quorums(EffectiveVoters(config[i])):
        /\ i \in config[i]
        /\ i \in voteQuorum
        \* Only Followers can start elections (primaries don't re-elect).
        /\ state[i] = Follower
        /\ ~drainMode[i]
        \* Family 5: candidate must be an effective voter (not newlyAdded).
        /\ ~newlyAdded[i]
        \* All voters in quorum can vote for this candidate.
        /\ \A v \in voteQuorum : CanVoteFor(v, i, newTerm)
        \* Update terms of each voter.
        /\ currentTerm' = [s \in Server |->
            IF s \in voteQuorum THEN newTerm ELSE currentTerm[s]]
        /\ state' = [s \in Server |->
            IF s = i THEN Leader
            ELSE IF s \in voteQuorum THEN Follower
            ELSE state[s]]
        \* Family 2: Enter drain mode. ConfigTerm NOT bumped yet.
        \* replication_coordinator_impl.cpp:1454 — ApplierDraining
        \* Clear drainMode for voters that step down (they become Follower).
        /\ drainMode' = [s \in Server |->
            IF s = i THEN TRUE
            ELSE IF s \in voteQuorum THEN FALSE
            ELSE drainMode[s]]
        \* Config term NOT updated (contrast with existing spec's BecomeLeader).
        /\ UNCHANGED <<log, configVars, immediatelyCommitted, newlyAdded,
                        lastCommittedInPrevConfig>>

(******************************************************************************)
(* [ACTION] CompleteDrain                                                     *)
(* Node i completes drain mode and bumps config term via doOptimizedReconfig. *)
(* Family 2: replication_coordinator_impl.cpp:1469-1515                      *)
(* skipSafetyChecks=true — no ConfigIsSafe check needed.                     *)
(******************************************************************************)
CompleteDrain(i) ==
    /\ state[i] = Leader
    /\ drainMode[i] = TRUE
    \* replication_coordinator_impl.cpp:1470 — skip term bump for force configs
    /\ IF configTerm[i] # UninitializedTerm
       THEN \* Bump config term to current term (doOptimizedReconfig).
            \* replication_coordinator_impl.cpp:1489 — configTerm = primaryTerm
            \* Note: configVersion is NOT incremented during drain completion.
            \* The optimized reconfig only bumps the term, not the version.
            \* Evidence: trace data shows configVersion unchanged after CompleteDrain.
            configTerm' = [configTerm EXCEPT ![i] = currentTerm[i]]
       ELSE UNCHANGED configTerm
    /\ drainMode' = [drainMode EXCEPT ![i] = FALSE]
    \* Record commit point (normal reconfig path via doOptimizedReconfig).
    \* replication_coordinator_impl.cpp:3999 — updateLastCommittedInPrevConfig
    /\ lastCommittedInPrevConfig' = [lastCommittedInPrevConfig EXCEPT
        ![i] = NodeCommitIndex(i)]
    /\ UNCHANGED <<currentTerm, state, log, config, configVersion,
                    immediatelyCommitted, newlyAdded>>

(******************************************************************************)
(* [ACTION] Reconfig                                                          *)
(* Safe reconfig: leader, not in drain mode, ConfigIsSafe must hold.         *)
(* replication_coordinator_impl.cpp:3530-3882                                *)
(* (_doReplSetReconfig with force=false, skipSafetyChecks=false)             *)
(******************************************************************************)
Reconfig(i) ==
    \* replication_coordinator_impl.cpp:3563 — primary check (not force/skip)
    /\ state[i] = Leader
    \* replication_coordinator_impl.cpp:3563 — must be writable (not in drain)
    /\ drainMode[i] = FALSE
    \* replication_coordinator_impl.cpp:3593-3624 — ConfigIsSafe check
    /\ ConfigIsSafe(i)
    /\ \E newConfig \in SUBSET Server :
        \* repl_set_config_checks.cpp:573-578 — single node change only (non-force)
        /\ \/ \E n \in newConfig : newConfig \ {n} = config[i]  \* add 1
           \/ \E n \in config[i] : config[i] \ {n} = newConfig  \* remove 1
        \* Node must remain in its own config.
        /\ i \in newConfig
        \* Require a quorum of alive nodes in new config.
        /\ AliveNodes(newConfig) \in Quorums(newConfig)
        \* Install new config on this node.
        /\ config' = [config EXCEPT ![i] = newConfig]
        \* replication_coordinator_impl.cpp:3286 — configTerm = currentTerm
        /\ configTerm' = [configTerm EXCEPT ![i] = currentTerm[i]]
        \* replication_coordinator_impl.cpp:3289 — version incremented
        /\ configVersion' = [configVersion EXCEPT ![i] = configVersion[i] + 1]
        \* Family 5: Set newlyAdded for new voting members (not arbiters).
        \* replication_coordinator_impl.cpp:3465-3511 — newlyAdded injection
        /\ newlyAdded' = [s \in Server |->
            IF s \in newConfig /\ s \notin config[i] /\ s \notin Arbiter
            \* replication_coordinator_impl.cpp:3488-3494 — set newlyAdded=true
            THEN TRUE
            ELSE newlyAdded[s]]
        \* Family 3: Record commit point for previous config.
        \* replication_coordinator_impl.cpp:3999 — updateLastCommittedInPrevConfig
        /\ lastCommittedInPrevConfig' = [lastCommittedInPrevConfig EXCEPT
            ![i] = NodeCommitIndex(i)]
    /\ UNCHANGED <<serverVars, log, immediatelyCommitted, drainMode>>

(******************************************************************************)
(* [ACTION] ForceReconfig                                                     *)
(* Force reconfig: bypasses ALL safety checks, sets configTerm=-1.           *)
(* Family 1: replication_coordinator_impl.cpp:3530-3882                      *)
(* (_doReplSetReconfig with force=true)                                      *)
(******************************************************************************)
ForceReconfig(i) ==
    \* replication_coordinator_impl.cpp:3563 — primary check SKIPPED for force
    /\ state[i] # Down
    /\ \E newConfig \in SUBSET Server :
        /\ newConfig # {}
        \* repl_set_config_checks.cpp:573-578 — single-node-change SKIPPED for force
        \* Force allows arbitrary membership changes.
        \* replication_coordinator_impl.cpp:3780-3824 — self must be in new config
        /\ i \in newConfig
        \* Install new config.
        /\ config' = [config EXCEPT ![i] = newConfig]
        \* replication_coordinator_impl.cpp:3425 — configTerm = kUninitializedTerm
        /\ configTerm' = [configTerm EXCEPT ![i] = UninitializedTerm]
        \* replication_coordinator_impl.cpp:3453-3460 — large version bump
        /\ configVersion' = [configVersion EXCEPT ![i] = configVersion[i] + 10000]
        \* replication_coordinator_impl.cpp:3923 — step down if not electable
        \* _shouldStepDownOnReconfig (line 667-672): step down if member not electable
        /\ IF state[i] = Leader /\ i \in Arbiter
           THEN \* Arbiter can't be primary — step down
                /\ state' = [state EXCEPT ![i] = Follower]
                /\ drainMode' = [drainMode EXCEPT ![i] = FALSE]
           ELSE UNCHANGED <<state, drainMode>>
        \* Family 5: force reconfig skips newlyAdded injection.
        \* replication_coordinator_impl.cpp:3481 — skipped for force
        /\ UNCHANGED <<currentTerm, log, immediatelyCommitted, newlyAdded,
                        lastCommittedInPrevConfig>>

(******************************************************************************)
(* [ACTION] SendConfig                                                        *)
(* Config propagation: sender's config replaces receiver's if newer.         *)
(* Models heartbeat-based config propagation to secondaries.                 *)
(* Family 1: Uses ConfigVersionAndTerm with term=-1 semantics.               *)
(* Family 3: Does NOT update lastCommittedInPrevConfig on receiver.          *)
(* replication_coordinator_impl_heartbeat.cpp:949-1060 (_heartbeatReconfigFinish) *)
(******************************************************************************)
SendConfig(sender, receiver) ==
    \* Family 1: Config comparison with term=-1 semantics.
    \* repl_set_config.h:91-100
    /\ ConfigIsNewer(configVersion[sender], configTerm[sender],
                     configVersion[receiver], configTerm[receiver])
    \* Family 2: Reject heartbeat reconfig during drain mode (except force configs).
    \* replication_coordinator_impl_heartbeat.cpp:708-716
    /\ IF drainMode[receiver]
       THEN configTerm[sender] = UninitializedTerm  \* Only force configs allowed
       ELSE TRUE
    \* replication_coordinator_impl_heartbeat.cpp:719-723 — reject during election
    \* (modeled implicitly: elections are atomic in WinElection)
    \* Install sender's config on receiver.
    /\ config' = [config EXCEPT ![receiver] = config[sender]]
    /\ configVersion' = [configVersion EXCEPT ![receiver] = configVersion[sender]]
    /\ configTerm' = [configTerm EXCEPT ![receiver] = configTerm[sender]]
    \* Update terms between nodes.
    /\ currentTerm' = [currentTerm EXCEPT
        ![sender] = Max({currentTerm[sender], currentTerm[receiver]}),
        ![receiver] = Max({currentTerm[sender], currentTerm[receiver]})]
    /\ state' = [state EXCEPT
        ![receiver] = IF currentTerm[receiver] < currentTerm[sender]
                       THEN Follower ELSE state[receiver],
        ![sender] = IF currentTerm[sender] < currentTerm[receiver]
                     THEN Follower ELSE state[sender]]
    \* Step down from drain mode if term updated.
    /\ drainMode' = [drainMode EXCEPT
        ![sender] = IF currentTerm[sender] < currentTerm[receiver]
                     THEN FALSE ELSE drainMode[sender],
        ![receiver] = IF currentTerm[receiver] < currentTerm[sender]
                       THEN FALSE ELSE drainMode[receiver]]
    \* Family 3: Heartbeat path does NOT update lastCommittedInPrevConfig.
    \* replication_coordinator_impl_heartbeat.cpp:1052-1055
    /\ UNCHANGED <<log, immediatelyCommitted, newlyAdded, lastCommittedInPrevConfig>>

(******************************************************************************)
(* [ACTION] ClientRequest                                                     *)
(* A leader handles a new client write.                                       *)
(* replication_coordinator_impl.cpp — write path                             *)
(******************************************************************************)
ClientRequest(i) ==
    /\ state[i] = Leader
    \* Cannot accept writes during drain mode.
    /\ drainMode[i] = FALSE
    /\ log' = [log EXCEPT ![i] = Append(@, [term |-> currentTerm[i]])]
    /\ UNCHANGED <<serverVars, immediatelyCommitted, configVars, extensionVars>>

(******************************************************************************)
(* [ACTION] CommitEntry                                                       *)
(* A leader commits its newest log entry using data quorum.                  *)
(* Family 4: Uses DataQuorums (excludes arbiters) for oplog commitment.      *)
(******************************************************************************)
CommitEntry(i) ==
    /\ ~Empty(log[i])
    /\ state[i] = Leader
    /\ ~drainMode[i]
    /\ IsCommitted(Len(log[i]), i)
    /\ immediatelyCommitted' = immediatelyCommitted \cup
        {[index         |-> Len(log[i]),
          term          |-> currentTerm[i],
          configVersion |-> configVersion[i]]}
    /\ UNCHANGED <<serverVars, log, configVars, extensionVars>>

(******************************************************************************)
(* [ACTION] GetEntry                                                          *)
(* Node i gets a new log entry from node j (replication).                    *)
(******************************************************************************)
GetEntry(i, j) ==
    /\ j \in config[i]
    /\ state[i] = Follower
    /\ Len(log[j]) > Len(log[i])
    /\ LET logOk == IF Empty(log[i]) THEN TRUE
                     ELSE LogTerm(j, Len(log[i])) = LastTerm(log[i]) IN
       /\ logOk
       /\ LET newEntryIndex == Len(log[i]) + 1
              newEntry      == log[j][newEntryIndex]
              newLog        == Append(log[i], newEntry) IN
              log' = [log EXCEPT ![i] = newLog]
    \* Update terms.
    /\ currentTerm' = [currentTerm EXCEPT
        ![i] = Max({currentTerm[i], currentTerm[j]}),
        ![j] = Max({currentTerm[i], currentTerm[j]})]
    /\ state' = [state EXCEPT
        ![j] = IF currentTerm[j] < currentTerm[i] THEN Follower ELSE state[j],
        ![i] = IF currentTerm[i] < currentTerm[j] THEN Follower ELSE state[i]]
    /\ drainMode' = [drainMode EXCEPT
        ![i] = IF currentTerm[i] < currentTerm[j] THEN FALSE ELSE drainMode[i],
        ![j] = IF currentTerm[j] < currentTerm[i] THEN FALSE ELSE drainMode[j]]
    /\ UNCHANGED <<immediatelyCommitted, configVars, newlyAdded, lastCommittedInPrevConfig>>

(******************************************************************************)
(* [ACTION] RollbackEntries                                                   *)
(* Node i rolls back against the log of node j.                              *)
(******************************************************************************)
RollbackEntries(i, j) ==
    /\ CanRollback(i, j)
    /\ j \in config[i]
    /\ log' = [log EXCEPT ![i] = SubSeq(log[i], 1, Len(log[i]) - 1)]
    /\ UNCHANGED <<serverVars, immediatelyCommitted, configVars, extensionVars>>

(******************************************************************************)
(* [ACTION] UpdateTermsOnNodes                                                *)
(* Exchange terms between two nodes (heartbeat term exchange).               *)
(******************************************************************************)
UpdateTermsOnNodes(i, j) ==
    /\ currentTerm' = [currentTerm EXCEPT
        ![i] = Max({currentTerm[i], currentTerm[j]}),
        ![j] = Max({currentTerm[i], currentTerm[j]})]
    /\ state' = [state EXCEPT
        ![j] = IF currentTerm[j] < currentTerm[i] THEN Follower ELSE state[j],
        ![i] = IF currentTerm[i] < currentTerm[j] THEN Follower ELSE state[i]]
    /\ drainMode' = [drainMode EXCEPT
        ![i] = IF currentTerm[i] < currentTerm[j] THEN FALSE ELSE drainMode[i],
        ![j] = IF currentTerm[j] < currentTerm[i] THEN FALSE ELSE drainMode[j]]
    /\ UNCHANGED <<log, immediatelyCommitted, configVars, newlyAdded,
                    lastCommittedInPrevConfig>>

(******************************************************************************)
(* [ACTION] ShutDown                                                          *)
(* Shut down a node. Used for partition and liveness checking.               *)
(******************************************************************************)
ShutDown(i) ==
    /\ state[i] # Down
    /\ state' = [state EXCEPT ![i] = Down]
    /\ drainMode' = [drainMode EXCEPT ![i] = FALSE]
    /\ UNCHANGED <<currentTerm, immediatelyCommitted, log, configVars,
                    newlyAdded, lastCommittedInPrevConfig>>

(******************************************************************************)
(* [ACTION] RemoveNewlyAdded                                                  *)
(* Family 5: Primary auto-removes newlyAdded flag for a caught-up member.    *)
(* replication_coordinator_impl.cpp:4110-4206                                *)
(* (_reconfigToRemoveNewlyAddedField)                                        *)
(* This is a safe reconfig — requires ConfigIsSafe.                          *)
(******************************************************************************)
RemoveNewlyAdded(i, j) ==
    /\ state[i] = Leader
    /\ ~drainMode[i]
    /\ j \in config[i]
    \* replication_coordinator_impl.cpp:4153-4157 — member still has newlyAdded
    /\ newlyAdded[j] = TRUE
    \* replication_coordinator_impl_heartbeat.cpp:416-417 — member must be
    \* SECONDARY/RECOVERING (caught up). Proxy: member's log is at least as long
    \* as the leader's and member is alive (Follower, not Down).
    /\ state[j] = Follower
    /\ Len(log[j]) >= Len(log[i])
    \* replication_coordinator_impl.cpp:4188 — doReplSetReconfig(force=false)
    \* Full safety checks apply.
    /\ ConfigIsSafe(i)
    \* replication_coordinator_impl.cpp:4141 — staleness check (modeled by
    \* ConfigIsSafe requiring config hasn't changed)
    /\ newlyAdded' = [newlyAdded EXCEPT ![j] = FALSE]
    \* replication_coordinator_impl.cpp:4151 — version incremented
    /\ configVersion' = [configVersion EXCEPT ![i] = configVersion[i] + 1]
    \* Normal reconfig path: update lastCommittedInPrevConfig.
    /\ lastCommittedInPrevConfig' = [lastCommittedInPrevConfig EXCEPT
        ![i] = NodeCommitIndex(i)]
    /\ UNCHANGED <<serverVars, log, config, configTerm, immediatelyCommitted, drainMode>>

-------------------------------------------------------------------------------------------

(******************************************************************************)
(* Spec definition                                                            *)
(******************************************************************************)

Init ==
    /\ currentTerm = [i \in Server |-> 0]
    /\ state       = [i \in Server |-> Follower]
    /\ log         = [i \in Server |-> << >>]
    \* Initially, all nodes start with the same config (any non-empty subset).
    /\ \E initConfig \in (SUBSET Server) :
        /\ initConfig # {}
        /\ config = [i \in Server |-> initConfig]
    /\ configVersion = [i \in Server |-> 0]
    /\ configTerm    = [i \in Server |-> 0]
    /\ immediatelyCommitted = {}
    \* Extension variables.
    /\ drainMode = [i \in Server |-> FALSE]
    /\ newlyAdded = [i \in Server |-> FALSE]
    /\ lastCommittedInPrevConfig = [i \in Server |-> 0]

\* Action wrappers with existential quantification.
WinElectionAction       == \E s \in AliveNodes(Server) : WinElection(s)
CompleteDrainAction     == \E s \in AliveNodes(Server) : CompleteDrain(s)
ClientRequestAction     == \E s \in AliveNodes(Server) : ClientRequest(s)
GetEntryAction          == \E s, t \in AliveNodes(Server) : GetEntry(s, t)
RollbackEntriesAction   == \E s, t \in AliveNodes(Server) : RollbackEntries(s, t)
ReconfigAction          == \E s \in AliveNodes(Server) : Reconfig(s)
ForceReconfigAction     == \E s \in AliveNodes(Server) : ForceReconfig(s)
SendConfigAction        == \E s, t \in AliveNodes(Server) : SendConfig(s, t)
CommitEntryAction       == \E s \in AliveNodes(Server) : CommitEntry(s)
ShutDownAction          == \E s \in AliveNodes(Server) : ShutDown(s)
UpdateTermsAction       == \E s, t \in AliveNodes(Server) : UpdateTermsOnNodes(s, t)
RemoveNewlyAddedAction  == \E s, t \in AliveNodes(Server) : RemoveNewlyAdded(s, t)

Next ==
    \/ WinElectionAction
    \/ CompleteDrainAction
    \/ ClientRequestAction
    \/ GetEntryAction
    \/ RollbackEntriesAction
    \/ ReconfigAction
    \/ ForceReconfigAction
    \/ SendConfigAction
    \/ CommitEntryAction
    \/ ShutDownAction
    \/ UpdateTermsAction
    \/ RemoveNewlyAddedAction

Liveness ==
    /\ WF_vars(WinElectionAction)
    /\ WF_vars(CompleteDrainAction)
    /\ WF_vars(SendConfigAction)
    /\ WF_vars(UpdateTermsAction)
    /\ WF_vars(GetEntryAction)
    /\ WF_vars(RollbackEntriesAction)
    /\ WF_vars(CommitEntryAction)

Spec == Init /\ [][Next]_vars /\ Liveness

-------------------------------------------------------------------------------------------

(******************************************************************************)
(* Correctness Properties                                                     *)
(******************************************************************************)

\* Are there two primaries in the current state?
TwoPrimaries == \E s, t \in Server : s # t /\ state[s] = Leader /\ state[t] = Leader

TwoPrimariesInSameTerm ==
    \E i, j \in Server :
        /\ i # j
        /\ currentTerm[i] = currentTerm[j]
        /\ state[i] = Leader
        /\ state[j] = Leader

\* --- Standard invariants ---

\* There should be at most one leader per term.
ElectionSafety == ~TwoPrimariesInSameTerm

\* Only uncommitted entries are allowed to be deleted from logs.
RollbackCommitted == \E s \in Server :
    \E e \in immediatelyCommitted :
        /\ EntryInLog(log[s], e.index, e.term)
        /\ Len(log'[s]) < e.index

NeverRollbackCommitted == [][~RollbackCommitted]_vars

\* --- Extension invariants (Bug Family targets) ---

\* The set of all currently installed configs.
InstalledConfigs == Range(config)

\* Do all quorums of set x and set y share at least one overlapping node?
QuorumsOverlap(x, y) == \A qx \in Quorums(x), qy \in Quorums(y) : qx \cap qy # {}

\* Is a given config "active" i.e. can it form a quorum?
ActiveConfig(cfg) == \E Q \in Quorums(cfg) : \A s \in Q : config[s] = cfg

\* The set of all active configs.
ActiveConfigs == {c \in InstalledConfigs : ActiveConfig(c)}

\* Family 1: Active configs have overlapping quorums.
\* Expected to be VIOLATED by force reconfig (SERVER-47852, SERVER-54746).
ActiveConfigsOverlap == \A x, y \in ActiveConfigs : QuorumsOverlap(x, y)

\* Family 1: Force reconfig quorum overlap.
\* After force reconfigs, do effective voter quorums still overlap?
ForceReconfigQuorumOverlap ==
    \A x, y \in InstalledConfigs :
        QuorumsOverlap(EffectiveVoters(x), EffectiveVoters(y))

\* Family 2: Drain mode reconfig safety.
\* A node in drain mode should not coexist with another active leader
\* that could create a conflicting committed entry.
DrainModeReconfigSafety ==
    \A i \in Server :
        drainMode[i] = TRUE =>
            \* No other leader in the same term.
            ~\E j \in Server : j # i /\ state[j] = Leader /\ currentTerm[j] = currentTerm[i]

\* Family 3: Config propagation safety.
\* If a leader's local ConfigIsSafe passes, global OpCommittedInConfig should too.
\* Violated when lastCommittedInPrevConfig is stale (heartbeat config path).
ConfigPropagationSafety ==
    \A i \in Server :
        /\ state[i] = Leader
        /\ ~drainMode[i]
        /\ ConfigIsSafe(i)
        => OpCommittedInConfig(i)

\* Family 4: Arbiter quorum overlap.
\* Every config quorum must overlap with some data quorum.
\* Violated when arbiter-heavy configs allow config commitment without data nodes.
ArbiterQuorumOverlap ==
    \A cfg \in InstalledConfigs :
        DataVoters(cfg) # {} =>
            \A cq \in ConfigQuorums(cfg) :
                \E dq \in DataQuorums(cfg) : cq \cap dq # {}

\* Family 5: newlyAdded safety.
\* A newlyAdded node never counts toward data quorum (structural).
NewlyAddedSafety ==
    \A i \in Server :
        newlyAdded[i] => i \notin DataVoters(config[i])

\* Family 1+5: Force reconfig skips newlyAdded — voter counts immediately.
\* Check: can a force-added voter participate in quorum before being caught up?
ForceNewlyAddedBypass ==
    \* After force reconfig, any newly added node is immediately a voter
    \* (newlyAdded not set). This is safe ONLY if the node's log is sufficient.
    \A i \in Server :
        /\ state[i] = Leader
        /\ ~drainMode[i]
        => \A j \in config[i] :
            \* If j was added via force (no newlyAdded), ensure quorum overlap holds
            TRUE  \* Structural — detected by ForceReconfigQuorumOverlap

\* --- Structural invariants ---

\* Config term is either UninitializedTerm or non-negative.
ConfigTermValid ==
    \A i \in Server :
        configTerm[i] = UninitializedTerm \/ configTerm[i] >= 0

\* Leaders are members of their own config.
LeaderInOwnConfig ==
    \A i \in Server :
        state[i] = Leader => i \in config[i]

\* Drain mode only for leaders.
DrainModeOnlyForLeaders ==
    \A i \in Server :
        drainMode[i] = TRUE => state[i] = Leader

\* newlyAdded nodes are in some config.
NewlyAddedInConfig ==
    \A i \in Server :
        newlyAdded[i] = TRUE => \E j \in Server : i \in config[j]

\* Config version is non-negative.
ConfigVersionNonNeg ==
    \A i \in Server : configVersion[i] >= 0

=============================================================================
