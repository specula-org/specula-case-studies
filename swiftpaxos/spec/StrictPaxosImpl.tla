---- MODULE StrictPaxosImpl ----
EXTENDS TLC, Sequences, SequencesExt, Naturals, FiniteSets, Bags

CONSTANTS Nodes, Clients, Keys, MaxCmdSeq, MaxBallot, MaxSeqnum, MaxChecksum, OptExec, FixedMajority

ASSUME /\ Nodes /= {}
       /\ Clients /= {}
       /\ Keys /= {}
       /\ Nodes = 1..Cardinality(Nodes)
       /\ Clients = 1..Cardinality(Clients)
       /\ MaxCmdSeq \in Nat \ {0}
       /\ MaxBallot \in Nat \ {0}
       /\ MaxSeqnum \in Nat
       /\ MaxChecksum \in Nat
       /\ OptExec \in BOOLEAN
       /\ FixedMajority \in BOOLEAN

CmdIds == { [client |-> c, seq |-> s] : c \in Clients, s \in 1..MaxCmdSeq }
Ops == {"GET", "PUT", "SCAN", "NONE"}
Statuses == {"NORMAL", "RECOVERING"}
Phases == {"START", "PRE_ACCEPT", "ACCEPT", "COMMIT"}
CmdPayloads == [op : Ops, key : Keys]
NoCmd == [op |-> "NONE", key |-> CHOOSE k \in Keys : TRUE]

MajorityThreshold == (Cardinality(Nodes) \div 2) + 1
FastThreshold ==
  IF FixedMajority
  THEN MajorityThreshold
  ELSE (3 * Cardinality(Nodes) + 3) \div 4

LeaderOf(b) == ((b % Cardinality(Nodes)) + 1)

Conflict(ca, cb) ==
  /\ ca.key = cb.key
  /\ ~(ca.op = "GET" /\ cb.op = "GET")

HashOf(c, d) == ((c.client * 257 + c.seq * 17 + Cardinality(d)) % (MaxChecksum + 1))

VARIABLES
  status, ballot, cballot, globalLeader,
  seqnum,
  knownCmds, hasPropose, cmdData, cmdDep, cmdPhase, slowPath,
  fastVotes, slowVotes, leaderAckSeen,
  committed, delivered, executing, executed,
  proposeNet,
  fastAckToReplica,
  fastAckToClient,
  lightSlowAckToReplica,
  lightSlowAckToClient,
  replyNet,
  acceptNet,
  recoverQueue,
  newLeaderNet,
  newLeaderAckNNet,
  syncNet,
  recoveryBallot,
  ackCollected,
  selectedCBallot,
  selectedCmds,
  selectedPhases,
  selectedDeps,
  selectedData,
  clientBallot,
  clientFastVotes,
  clientSlowVotes,
  clientDelivered

vars == <<
  status, ballot, cballot, globalLeader,
  seqnum,
  knownCmds, hasPropose, cmdData, cmdDep, cmdPhase, slowPath,
  fastVotes, slowVotes, leaderAckSeen,
  committed, delivered, executing, executed,
  proposeNet,
  fastAckToReplica,
  fastAckToClient,
  lightSlowAckToReplica,
  lightSlowAckToClient,
  replyNet,
  acceptNet,
  recoverQueue,
  newLeaderNet,
  newLeaderAckNNet,
  syncNet,
  recoveryBallot,
  ackCollected,
  selectedCBallot,
  selectedCmds,
  selectedPhases,
  selectedDeps,
  selectedData,
  clientBallot,
  clientFastVotes,
  clientSlowVotes,
  clientDelivered
>>

TypeOK ==
  /\ status \in [Nodes -> Statuses]
  /\ ballot \in [Nodes -> 0..MaxBallot]
  /\ cballot \in [Nodes -> 0..MaxBallot]
  /\ globalLeader \in Nodes
  /\ seqnum \in [Nodes -> 0..MaxSeqnum]
  /\ knownCmds \in [Nodes -> SUBSET CmdIds]
  /\ hasPropose \in [Nodes -> [CmdIds -> BOOLEAN]]
  /\ cmdData \in [Nodes -> [CmdIds -> CmdPayloads]]
  /\ cmdDep \in [Nodes -> [CmdIds -> SUBSET CmdIds]]
  /\ cmdPhase \in [Nodes -> [CmdIds -> Phases]]
  /\ slowPath \in [Nodes -> [CmdIds -> BOOLEAN]]
  /\ fastVotes \in [CmdIds -> SUBSET Nodes]
  /\ slowVotes \in [CmdIds -> SUBSET Nodes]
  /\ leaderAckSeen \in [CmdIds -> BOOLEAN]
  /\ committed \in [Nodes -> SUBSET CmdIds]
  /\ delivered \in [Nodes -> SUBSET CmdIds]
  /\ executing \in [Nodes -> SUBSET CmdIds]
  /\ executed \in [Nodes -> Seq(CmdIds)]
  /\ proposeNet \subseteq { [to |-> r, from |-> c, cmd |-> id, payload |-> p] :
                              r \in Nodes, c \in Clients, id \in CmdIds, p \in CmdPayloads }
  /\ fastAckToReplica \subseteq { [to |-> t, from |-> s, b |-> bl, cmd |-> id, dep |-> d, checksum |-> h, seq |-> sq] :
                                     t \in Nodes, s \in Nodes, bl \in 0..MaxBallot,
                                     id \in CmdIds, d \in SUBSET CmdIds,
                                     h \in 0..MaxChecksum, sq \in 0..MaxSeqnum }
  /\ fastAckToClient \subseteq { [to |-> c, from |-> s, b |-> bl, cmd |-> id, checksum |-> h] :
                                    c \in Clients, s \in Nodes, bl \in 0..MaxBallot,
                                    id \in CmdIds, h \in 0..MaxChecksum }
  /\ lightSlowAckToReplica \subseteq { [to |-> t, from |-> s, b |-> bl, cmd |-> id] :
                                         t \in Nodes, s \in Nodes, bl \in 0..MaxBallot, id \in CmdIds }
  /\ lightSlowAckToClient \subseteq { [to |-> c, from |-> s, b |-> bl, cmd |-> id] :
                                        c \in Clients, s \in Nodes, bl \in 0..MaxBallot, id \in CmdIds }
  /\ replyNet \subseteq { [to |-> c, from |-> s, b |-> bl, cmd |-> id, checksum |-> h] :
                            c \in Clients, s \in Nodes, bl \in 0..MaxBallot,
                            id \in CmdIds, h \in 0..MaxChecksum }
  /\ acceptNet \subseteq { [to |-> c, from |-> s, b |-> bl, cmd |-> id] :
                             c \in Clients, s \in Nodes, bl \in 0..MaxBallot, id \in CmdIds }
  /\ recoverQueue \subseteq { [requester |-> r, b |-> bl] : r \in Nodes, bl \in 0..MaxBallot }
  /\ newLeaderNet \subseteq { [to |-> t, from |-> s, b |-> bl] :
                                t \in Nodes, s \in Nodes, bl \in 0..MaxBallot }
  /\ newLeaderAckNNet \subseteq { [to |-> t, from |-> s, b |-> bl, cb |-> cbl,
                                     cmds |-> cs, phases |-> ph, deps |-> dp, data |-> dt] :
                                     t \in Nodes, s \in Nodes, bl \in 0..MaxBallot, cbl \in 0..MaxBallot,
                                     cs \in SUBSET CmdIds,
                                     ph \in [CmdIds -> Phases],
                                     dp \in [CmdIds -> SUBSET CmdIds],
                                     dt \in [CmdIds -> CmdPayloads] }
  /\ syncNet \subseteq { [to |-> t, from |-> s, b |-> bl, cmds |-> cs, phases |-> ph, deps |-> dp, data |-> dt] :
                           t \in Nodes, s \in Nodes, bl \in 0..MaxBallot,
                           cs \in SUBSET CmdIds,
                           ph \in [CmdIds -> Phases],
                           dp \in [CmdIds -> SUBSET CmdIds],
                           dt \in [CmdIds -> CmdPayloads] }
  /\ recoveryBallot \in 0..MaxBallot
  /\ ackCollected \subseteq Nodes
  /\ selectedCBallot \in 0..MaxBallot
  /\ selectedCmds \subseteq CmdIds
  /\ selectedPhases \in [CmdIds -> Phases]
  /\ selectedDeps \in [CmdIds -> SUBSET CmdIds]
  /\ selectedData \in [CmdIds -> CmdPayloads]
  /\ clientBallot \in [Clients -> 0..MaxBallot]
  /\ clientFastVotes \in [CmdIds -> SUBSET Nodes]
  /\ clientSlowVotes \in [CmdIds -> SUBSET Nodes]
  /\ clientDelivered \subseteq CmdIds

DepsFor(r, c, payload) ==
  { d \in knownCmds[r] : d # c /\ Conflict(payload, cmdData[r][d]) }

CanCommit(c) ==
  /\ Cardinality(fastVotes[c]) >= FastThreshold
     \/ (leaderAckSeen[c] /\ Cardinality(slowVotes[c]) >= MajorityThreshold)

CanExecute(r, c) ==
  /\ c \in committed[r]
     \/ /\ OptExec
        /\ r = globalLeader
        /\ cmdPhase[r][c] \in {"PRE_ACCEPT", "ACCEPT", "COMMIT"}
  /\ c \in knownCmds[r]
  /\ c \notin delivered[r]
  /\ c \notin executing[r]
  /\ cmdDep[r][c] \subseteq delivered[r]

Init ==
  /\ status = [r \in Nodes |-> "NORMAL"]
  /\ ballot = [r \in Nodes |-> 0]
  /\ cballot = [r \in Nodes |-> 0]
  /\ globalLeader = LeaderOf(0)
  /\ seqnum = [r \in Nodes |-> 0]
  /\ knownCmds = [r \in Nodes |-> {}]
  /\ hasPropose = [r \in Nodes |-> [c \in CmdIds |-> FALSE]]
  /\ cmdData = [r \in Nodes |-> [c \in CmdIds |-> NoCmd]]
  /\ cmdDep = [r \in Nodes |-> [c \in CmdIds |-> {}]]
  /\ cmdPhase = [r \in Nodes |-> [c \in CmdIds |-> "START"]]
  /\ slowPath = [r \in Nodes |-> [c \in CmdIds |-> FALSE]]
  /\ fastVotes = [c \in CmdIds |-> {}]
  /\ slowVotes = [c \in CmdIds |-> {}]
  /\ leaderAckSeen = [c \in CmdIds |-> FALSE]
  /\ committed = [r \in Nodes |-> {}]
  /\ delivered = [r \in Nodes |-> {}]
  /\ executing = [r \in Nodes |-> {}]
  /\ executed = [r \in Nodes |-> <<>>]
  /\ proposeNet = {}
  /\ fastAckToReplica = {}
  /\ fastAckToClient = {}
  /\ lightSlowAckToReplica = {}
  /\ lightSlowAckToClient = {}
  /\ replyNet = {}
  /\ acceptNet = {}
  /\ recoverQueue = {}
  /\ newLeaderNet = {}
  /\ newLeaderAckNNet = {}
  /\ syncNet = {}
  /\ recoveryBallot = 0
  /\ ackCollected = {}
  /\ selectedCBallot = 0
  /\ selectedCmds = {}
  /\ selectedPhases = [c \in CmdIds |-> "START"]
  /\ selectedDeps = [c \in CmdIds |-> {}]
  /\ selectedData = [c \in CmdIds |-> NoCmd]
  /\ clientBallot = [c \in Clients |-> 0]
  /\ clientFastVotes = [c \in CmdIds |-> {}]
  /\ clientSlowVotes = [c \in CmdIds |-> {}]
  /\ clientDelivered = {}

ClientSubmit(c, r, id, op, k) ==
  /\ c \in Clients
  /\ r \in Nodes
  /\ id \in CmdIds
  /\ id.client = c
  /\ op \in {"GET", "PUT", "SCAN"}
  /\ k \in Keys
  /\ [to |-> r, from |-> c, cmd |-> id, payload |-> [op |-> op, key |-> k]] \notin proposeNet
  /\ proposeNet' = proposeNet \cup { [to |-> r, from |-> c, cmd |-> id, payload |-> [op |-> op, key |-> k]] }
  /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum,
                 knownCmds, hasPropose, cmdData, cmdDep, cmdPhase, slowPath,
                 fastVotes, slowVotes, leaderAckSeen, committed, delivered,
                 executing, executed, fastAckToReplica, fastAckToClient,
                 lightSlowAckToReplica, lightSlowAckToClient, replyNet,
                 acceptNet, recoverQueue, newLeaderNet, newLeaderAckNNet,
                 syncNet, recoveryBallot, ackCollected, selectedCBallot,
                 selectedCmds, selectedPhases, selectedDeps, selectedData,
                 clientBallot, clientFastVotes, clientSlowVotes, clientDelivered >>

ReplicaRecvProposeExact(r, c, id, payload) ==
  /\ r \in Nodes
  /\ c \in Clients
  /\ id \in CmdIds
  /\ payload \in [op : {"GET", "PUT", "SCAN"}, key : Keys]
  /\ status[r] = "NORMAL"
  /\ LET m == [to |-> r, from |-> c, cmd |-> id, payload |-> payload]
     IN /\ m \in proposeNet
        /\ proposeNet' = proposeNet \ {m}
        /\ \/ /\ ~hasPropose[r][id]
              /\ knownCmds' = [knownCmds EXCEPT ![r] = @ \cup {id}]
              /\ hasPropose' = [hasPropose EXCEPT ![r][id] = TRUE]
              /\ cmdData' = [cmdData EXCEPT ![r][id] = payload]
              /\ cmdDep' = [cmdDep EXCEPT ![r][id] = DepsFor(r, id, payload)]
              /\ cmdPhase' = [cmdPhase EXCEPT ![r][id] = "START"]
              /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum, slowPath,
                             fastVotes, slowVotes, leaderAckSeen, committed, delivered,
                             executing, executed, fastAckToReplica, fastAckToClient,
                             lightSlowAckToReplica, lightSlowAckToClient, replyNet,
                             acceptNet, recoverQueue, newLeaderNet, newLeaderAckNNet,
                             syncNet, recoveryBallot, ackCollected, selectedCBallot,
                             selectedCmds, selectedPhases, selectedDeps, selectedData,
                             clientBallot, clientFastVotes, clientSlowVotes, clientDelivered >>
           \/ /\ hasPropose[r][id]
              /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum,
                             knownCmds, hasPropose, cmdData, cmdDep, cmdPhase, slowPath,
                             fastVotes, slowVotes, leaderAckSeen, committed, delivered,
                             executing, executed, fastAckToReplica, fastAckToClient,
                             lightSlowAckToReplica, lightSlowAckToClient, replyNet,
                             acceptNet, recoverQueue, newLeaderNet, newLeaderAckNNet,
                             syncNet, recoveryBallot, ackCollected, selectedCBallot,
                             selectedCmds, selectedPhases, selectedDeps, selectedData,
                             clientBallot, clientFastVotes, clientSlowVotes, clientDelivered >>

ReplicaRecvPropose(r) ==
  /\ r \in Nodes
  /\ \E c \in Clients, id \in CmdIds, payload \in [op : {"GET", "PUT", "SCAN"}, key : Keys] :
      ReplicaRecvProposeExact(r, c, id, payload)

ReplicaPropagate(r, id) ==
  /\ r \in Nodes
  /\ id \in CmdIds
  /\ status[r] = "NORMAL"
  /\ hasPropose[r][id]
  /\ cmdPhase[r][id] = "START"
  /\ cmdPhase' = [cmdPhase EXCEPT ![r][id] = "PRE_ACCEPT"]
  /\ fastAckToReplica' = fastAckToReplica \cup
       { [to |-> t, from |-> r, b |-> ballot[r], cmd |-> id,
          dep |-> cmdDep[r][id], checksum |-> HashOf(id, cmdDep[r][id]), seq |-> 0] : t \in Nodes }
  /\ fastAckToClient' =
       IF OptExec /\ r # globalLeader
       THEN fastAckToClient \cup
              { [to |-> id.client, from |-> r, b |-> ballot[r], cmd |-> id,
                 checksum |-> HashOf(id, cmdDep[r][id])] }
       ELSE fastAckToClient
  /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum,
                 knownCmds, hasPropose, cmdData, cmdDep, slowPath,
                 fastVotes, slowVotes, leaderAckSeen, committed, delivered,
                 executing, executed, proposeNet,
                 lightSlowAckToReplica, lightSlowAckToClient, replyNet,
                 acceptNet, recoverQueue, newLeaderNet, newLeaderAckNNet,
                 syncNet, recoveryBallot, ackCollected, selectedCBallot,
                 selectedCmds, selectedPhases, selectedDeps, selectedData,
                 clientBallot, clientFastVotes, clientSlowVotes, clientDelivered >>

ReplicaLeaderFastAckAssignSeq(id) ==
  /\ id \in CmdIds
  /\ hasPropose[globalLeader][id]
  /\ status[globalLeader] = "NORMAL"
  /\ cmdPhase[globalLeader][id] \in {"PRE_ACCEPT", "ACCEPT"}
  /\ seqnum[globalLeader] < MaxSeqnum
  /\ seqnum' = [seqnum EXCEPT ![globalLeader] = @ + 1]
  /\ cmdPhase' = [cmdPhase EXCEPT ![globalLeader][id] = "ACCEPT"]
  /\ fastVotes' = [fastVotes EXCEPT ![id] = @ \cup {globalLeader}]
  /\ leaderAckSeen' = [leaderAckSeen EXCEPT ![id] = TRUE]
  /\ clientFastVotes' = [clientFastVotes EXCEPT ![id] = @ \cup {globalLeader}]
  /\ fastAckToReplica' = fastAckToReplica \cup
       { [to |-> t, from |-> globalLeader, b |-> ballot[globalLeader], cmd |-> id,
          dep |-> cmdDep[globalLeader][id], checksum |-> HashOf(id, cmdDep[globalLeader][id]),
          seq |-> seqnum[globalLeader]] : t \in Nodes }
  /\ fastAckToClient' =
       IF OptExec
       THEN fastAckToClient \cup
              { [to |-> id.client, from |-> globalLeader, b |-> ballot[globalLeader], cmd |-> id,
                 checksum |-> HashOf(id, cmdDep[globalLeader][id])] }
       ELSE fastAckToClient
  /\ UNCHANGED << status, ballot, cballot, globalLeader,
                 knownCmds, hasPropose, cmdData, cmdDep, slowPath,
                 slowVotes, committed, delivered, executing, executed,
                 proposeNet, lightSlowAckToReplica,
                 lightSlowAckToClient, replyNet, acceptNet, recoverQueue,
                 newLeaderNet, newLeaderAckNNet, syncNet, recoveryBallot,
                 ackCollected, selectedCBallot, selectedCmds, selectedPhases,
                 selectedDeps, selectedData, clientBallot,
                 clientSlowVotes, clientDelivered >>

ReplicaRecvFastAckAgree(r) ==
  /\ r \in Nodes
  /\ status[r] = "NORMAL"
  /\ \E m \in fastAckToReplica :
      /\ m.to = r
      /\ m.b = ballot[r]
      /\ m.cmd \in knownCmds[r]
      /\ m.dep = cmdDep[globalLeader][m.cmd]
      /\ fastAckToReplica' = fastAckToReplica \ {m}
      /\ cmdPhase' = [cmdPhase EXCEPT ![r][m.cmd] = "ACCEPT"]
      /\ fastVotes' = [fastVotes EXCEPT ![m.cmd] = @ \cup {m.from}]
      /\ leaderAckSeen' = [leaderAckSeen EXCEPT ![m.cmd] = IF m.from = globalLeader THEN TRUE ELSE @]
      /\ clientFastVotes' = [clientFastVotes EXCEPT ![m.cmd] = @ \cup {m.from}]
      /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum,
                     knownCmds, hasPropose, cmdData, cmdDep, slowPath,
                     slowVotes, committed, delivered, executing, executed,
                     proposeNet, fastAckToClient, lightSlowAckToReplica,
                     lightSlowAckToClient, replyNet, acceptNet, recoverQueue,
                     newLeaderNet, newLeaderAckNNet, syncNet, recoveryBallot,
                     ackCollected, selectedCBallot, selectedCmds, selectedPhases,
                     selectedDeps, selectedData, clientBallot,
                     clientSlowVotes, clientDelivered >>

ReplicaRecvFastAckSelf(r) ==
  /\ r \in Nodes
  /\ status[r] = "NORMAL"
  /\ \E m \in fastAckToReplica :
      /\ m.to = r
      /\ m.from = r
      /\ m.b = ballot[r]
      /\ m.cmd \in knownCmds[r]
      /\ m.dep = cmdDep[globalLeader][m.cmd]
      /\ fastAckToReplica' = fastAckToReplica \ {m}
      /\ cmdPhase' = [cmdPhase EXCEPT ![r][m.cmd] = "ACCEPT"]
      /\ fastVotes' = [fastVotes EXCEPT ![m.cmd] = @ \cup {m.from}]
      /\ leaderAckSeen' = [leaderAckSeen EXCEPT ![m.cmd] = IF m.from = globalLeader THEN TRUE ELSE @]
      /\ clientFastVotes' = [clientFastVotes EXCEPT ![m.cmd] = @ \cup {m.from}]
      /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum,
                     knownCmds, hasPropose, cmdData, cmdDep, slowPath,
                     slowVotes, committed, delivered, executing, executed,
                     proposeNet, fastAckToClient, lightSlowAckToReplica,
                     lightSlowAckToClient, replyNet, acceptNet, recoverQueue,
                     newLeaderNet, newLeaderAckNNet, syncNet, recoveryBallot,
                     ackCollected, selectedCBallot, selectedCmds, selectedPhases,
                     selectedDeps, selectedData, clientBallot,
                     clientSlowVotes, clientDelivered >>

ReplicaRecvFastAckConflict(r) ==
  /\ r \in Nodes
  /\ r # globalLeader
  /\ status[r] = "NORMAL"
  /\ \E m \in fastAckToReplica :
      /\ m.to = r
      /\ m.b = ballot[r]
      /\ m.cmd \in knownCmds[r]
      /\ m.dep # cmdDep[globalLeader][m.cmd]
      /\ fastAckToReplica' = fastAckToReplica \ {m}
      /\ cmdDep' = [cmdDep EXCEPT ![r][m.cmd] = cmdDep[globalLeader][m.cmd]]
      /\ cmdPhase' = [cmdPhase EXCEPT ![r][m.cmd] = "ACCEPT"]
      /\ slowPath' = [slowPath EXCEPT ![r][m.cmd] = TRUE]
      /\ slowVotes' = [slowVotes EXCEPT ![m.cmd] = @ \cup {r}]
      /\ clientSlowVotes' = [clientSlowVotes EXCEPT ![m.cmd] = @ \cup {r}]
      /\ lightSlowAckToReplica' = lightSlowAckToReplica \cup
           { [to |-> globalLeader, from |-> r, b |-> ballot[r], cmd |-> m.cmd] }
      /\ lightSlowAckToClient' = lightSlowAckToClient \cup
           { [to |-> m.cmd.client, from |-> r, b |-> ballot[r], cmd |-> m.cmd] }
      /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum,
                     knownCmds, hasPropose, cmdData, fastVotes, leaderAckSeen,
                     committed, delivered, executing, executed, proposeNet,
                     fastAckToClient, replyNet, acceptNet, recoverQueue,
                     newLeaderNet, newLeaderAckNNet, syncNet, recoveryBallot,
                     ackCollected, selectedCBallot, selectedCmds, selectedPhases,
                     selectedDeps, selectedData, clientBallot, clientFastVotes,
                     clientDelivered >>

ReplicaRecvLeaderFastAckSlowPath(r) ==
  /\ r \in Nodes
  /\ r # globalLeader
  /\ status[r] = "NORMAL"
  /\ \E m \in fastAckToReplica :
      /\ m.to = r
      /\ m.from = globalLeader
      /\ m.b = ballot[r]
      /\ m.cmd \in knownCmds[r]
      /\ fastAckToReplica' = fastAckToReplica \ {m}
      /\ cmdPhase' = [cmdPhase EXCEPT ![r][m.cmd] = "ACCEPT"]
      /\ fastVotes' = [fastVotes EXCEPT ![m.cmd] = @ \cup {m.from}]
      /\ leaderAckSeen' = [leaderAckSeen EXCEPT ![m.cmd] = TRUE]
      /\ clientFastVotes' = [clientFastVotes EXCEPT ![m.cmd] = @ \cup {m.from}]
      /\ slowPath' = [slowPath EXCEPT ![r][m.cmd] = TRUE]
      /\ slowVotes' = [slowVotes EXCEPT ![m.cmd] = @ \cup {r}]
      /\ clientSlowVotes' = [clientSlowVotes EXCEPT ![m.cmd] = @ \cup {r}]
      /\ lightSlowAckToReplica' = lightSlowAckToReplica \cup
           { [to |-> globalLeader, from |-> r, b |-> ballot[r], cmd |-> m.cmd] }
      /\ lightSlowAckToClient' = lightSlowAckToClient \cup
           { [to |-> m.cmd.client, from |-> r, b |-> ballot[r], cmd |-> m.cmd] }
      /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum,
                     knownCmds, hasPropose, cmdData, cmdDep, committed, delivered,
                     executing, executed, proposeNet, fastAckToClient, replyNet,
                     acceptNet, recoverQueue, newLeaderNet, newLeaderAckNNet,
                     syncNet, recoveryBallot, ackCollected, selectedCBallot,
                     selectedCmds, selectedPhases, selectedDeps, selectedData,
                     clientBallot, clientDelivered >>

ReplicaRecvLeaderFastAckSlowPathExact(r, id, src) ==
  /\ r \in Nodes
  /\ id \in CmdIds
  /\ src \in Nodes
  /\ r # globalLeader
  /\ status[r] = "NORMAL"
  /\ src = globalLeader
  /\ \E m \in fastAckToReplica :
      /\ m.to = r
      /\ m.from = src
      /\ m.b = ballot[r]
      /\ m.cmd = id
      /\ m.cmd \in knownCmds[r]
      /\ fastAckToReplica' = fastAckToReplica \ {m}
      /\ cmdPhase' = [cmdPhase EXCEPT ![r][m.cmd] = "ACCEPT"]
      /\ fastVotes' = [fastVotes EXCEPT ![m.cmd] = @ \cup {m.from}]
      /\ leaderAckSeen' = [leaderAckSeen EXCEPT ![m.cmd] = TRUE]
      /\ clientFastVotes' = [clientFastVotes EXCEPT ![m.cmd] = @ \cup {m.from}]
      /\ slowPath' = [slowPath EXCEPT ![r][m.cmd] = TRUE]
      /\ slowVotes' = [slowVotes EXCEPT ![m.cmd] = @ \cup {r}]
      /\ clientSlowVotes' = [clientSlowVotes EXCEPT ![m.cmd] = @ \cup {r}]
      /\ lightSlowAckToReplica' = lightSlowAckToReplica \cup
           { [to |-> globalLeader, from |-> r, b |-> ballot[r], cmd |-> m.cmd] }
      /\ lightSlowAckToClient' = lightSlowAckToClient \cup
           { [to |-> m.cmd.client, from |-> r, b |-> ballot[r], cmd |-> m.cmd] }
      /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum,
                     knownCmds, hasPropose, cmdData, cmdDep, committed, delivered,
                     executing, executed, proposeNet, fastAckToClient, replyNet,
                     acceptNet, recoverQueue, newLeaderNet, newLeaderAckNNet,
                     syncNet, recoveryBallot, ackCollected, selectedCBallot,
                     selectedCmds, selectedPhases, selectedDeps, selectedData,
                     clientBallot, clientDelivered >>

ReplicaRecvLightSlowAck(r) ==
  /\ r \in Nodes
  /\ status[r] = "NORMAL"
  /\ \E m \in lightSlowAckToReplica :
      /\ m.to = r
      /\ m.b = ballot[r]
      /\ lightSlowAckToReplica' = lightSlowAckToReplica \ {m}
      /\ slowVotes' = [slowVotes EXCEPT ![m.cmd] = @ \cup {m.from}]
      /\ clientSlowVotes' = [clientSlowVotes EXCEPT ![m.cmd] = @ \cup {m.from}]
      /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum,
                     knownCmds, hasPropose, cmdData, cmdDep, cmdPhase, slowPath,
                     fastVotes, leaderAckSeen, committed, delivered, executing,
                     executed, proposeNet, fastAckToReplica, fastAckToClient,
                     lightSlowAckToClient, replyNet, acceptNet, recoverQueue,
                     newLeaderNet, newLeaderAckNNet, syncNet, recoveryBallot,
                     ackCollected, selectedCBallot, selectedCmds, selectedPhases,
                     selectedDeps, selectedData, clientBallot, clientFastVotes,
                     clientDelivered >>

ReplicaCommitOnQuorum(r, id) ==
  /\ r \in Nodes
  /\ id \in CmdIds
  /\ id \in knownCmds[r]
  /\ id \notin committed[r]
  /\ CanCommit(id)
  /\ committed' = [committed EXCEPT ![r] = @ \cup {id}]
  /\ cmdPhase' = [cmdPhase EXCEPT ![r][id] = "COMMIT"]
  /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum,
                 knownCmds, hasPropose, cmdData, cmdDep, slowPath,
                 fastVotes, slowVotes, leaderAckSeen, delivered, executing,
                 executed, proposeNet, fastAckToReplica, fastAckToClient,
                 lightSlowAckToReplica, lightSlowAckToClient, acceptNet,
                 recoverQueue, newLeaderNet, newLeaderAckNNet, syncNet, replyNet,
                 recoveryBallot, ackCollected, selectedCBallot, selectedCmds,
                 selectedPhases, selectedDeps, selectedData, clientBallot,
                 clientFastVotes, clientSlowVotes, clientDelivered >>

ReplicaCommandExecuteStart(r, id) ==
  /\ r \in Nodes
  /\ id \in CmdIds
  /\ CanExecute(r, id)
  /\ executing' = [executing EXCEPT ![r] = @ \cup {id}]
  /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum,
                 knownCmds, hasPropose, cmdData, cmdDep, cmdPhase, slowPath,
                 fastVotes, slowVotes, leaderAckSeen, committed, delivered,
                 executed, proposeNet, fastAckToReplica, fastAckToClient,
                 lightSlowAckToReplica, lightSlowAckToClient, replyNet,
                 acceptNet, recoverQueue, newLeaderNet, newLeaderAckNNet,
                 syncNet, recoveryBallot, ackCollected, selectedCBallot,
                 selectedCmds, selectedPhases, selectedDeps, selectedData,
                 clientBallot, clientFastVotes, clientSlowVotes, clientDelivered >>

ReplicaCommandExecuteFinish(r, id) ==
  /\ r \in Nodes
  /\ id \in executing[r]
  /\ executing' = [executing EXCEPT ![r] = @ \ {id}]
  /\ delivered' = [delivered EXCEPT ![r] = @ \cup {id}]
  /\ executed' = [executed EXCEPT ![r] = Append(@, id)]
  /\ replyNet' =
       IF OptExec /\ r = globalLeader
       THEN replyNet \cup
              { [to |-> id.client, from |-> r, b |-> ballot[r],
                 cmd |-> id, checksum |-> HashOf(id, cmdDep[r][id])] }
       ELSE replyNet
  /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum,
                 knownCmds, hasPropose, cmdData, cmdDep, cmdPhase, slowPath,
                 fastVotes, slowVotes, leaderAckSeen, committed,
                 proposeNet, fastAckToReplica, fastAckToClient,
                 lightSlowAckToReplica, lightSlowAckToClient,
                 acceptNet, recoverQueue, newLeaderNet, newLeaderAckNNet,
                 syncNet, recoveryBallot, ackCollected, selectedCBallot,
                 selectedCmds, selectedPhases, selectedDeps, selectedData,
                 clientBallot, clientFastVotes, clientSlowVotes, clientDelivered >>

RecoveryTrigger(r, b) ==
  /\ r \in Nodes
  /\ b \in 0..MaxBallot
  /\ b > ballot[r]
  /\ [requester |-> r, b |-> b] \notin recoverQueue
  /\ recoverQueue' = recoverQueue \cup { [requester |-> r, b |-> b] }
  /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum,
                 knownCmds, hasPropose, cmdData, cmdDep, cmdPhase, slowPath,
                 fastVotes, slowVotes, leaderAckSeen, committed, delivered,
                 executing, executed, proposeNet, fastAckToReplica,
                 fastAckToClient, lightSlowAckToReplica, lightSlowAckToClient,
                 replyNet, acceptNet, newLeaderNet, newLeaderAckNNet, syncNet,
                 recoveryBallot, ackCollected, selectedCBallot, selectedCmds,
                 selectedPhases, selectedDeps, selectedData, clientBallot,
                 clientFastVotes, clientSlowVotes, clientDelivered >>

ReplicaBroadcastNewLeader(r) ==
  /\ r \in Nodes
  /\ \E q \in recoverQueue :
      /\ q.requester = r
      /\ q.b > ballot[r]
      /\ recoverQueue' = recoverQueue \ {q}
      /\ recoveryBallot' = q.b
      /\ globalLeader' = LeaderOf(q.b)
      /\ ackCollected' = {}
      /\ selectedCBallot' = 0
      /\ selectedCmds' = {}
      /\ selectedPhases' = [c \in CmdIds |-> "START"]
      /\ selectedDeps' = [c \in CmdIds |-> {}]
      /\ selectedData' = [c \in CmdIds |-> NoCmd]
      /\ newLeaderNet' = newLeaderNet \cup
           { [to |-> t, from |-> r, b |-> q.b] : t \in Nodes }
      /\ UNCHANGED << status, ballot, cballot, seqnum, knownCmds, hasPropose,
                     cmdData, cmdDep, cmdPhase, slowPath, fastVotes, slowVotes,
                     leaderAckSeen, committed, delivered, executing, executed,
                     proposeNet, fastAckToReplica, fastAckToClient,
                     lightSlowAckToReplica, lightSlowAckToClient, replyNet,
                     acceptNet, newLeaderAckNNet, syncNet, clientBallot,
                     clientFastVotes, clientSlowVotes, clientDelivered >>

ReplicaRecvNewLeader(r) ==
  /\ r \in Nodes
  /\ \E m \in newLeaderNet :
      /\ m.to = r
      /\ m.b > ballot[r]
      /\ newLeaderNet' = newLeaderNet \ {m}
      /\ status' = [status EXCEPT ![r] = "RECOVERING"]
      /\ ballot' = [ballot EXCEPT ![r] = m.b]
      /\ newLeaderAckNNet' = newLeaderAckNNet \cup
           { [to |-> m.from, from |-> r, b |-> m.b, cb |-> cballot[r],
              cmds |-> knownCmds[r], phases |-> cmdPhase[r], deps |-> cmdDep[r], data |-> cmdData[r]] }
      /\ UNCHANGED << cballot, globalLeader, seqnum, knownCmds, hasPropose,
                     cmdData, cmdDep, cmdPhase, slowPath, fastVotes, slowVotes,
                     leaderAckSeen, committed, delivered, executing, executed,
                     proposeNet, fastAckToReplica, fastAckToClient,
                     lightSlowAckToReplica, lightSlowAckToClient, replyNet,
                     acceptNet, recoverQueue, syncNet, recoveryBallot,
                     ackCollected, selectedCBallot, selectedCmds, selectedPhases,
                     selectedDeps, selectedData, clientBallot,
                     clientFastVotes, clientSlowVotes, clientDelivered >>

LeaderCollectNewLeaderAckN(l) ==
  /\ l \in Nodes
  /\ l = globalLeader
  /\ \E m \in newLeaderAckNNet :
      /\ m.to = l
      /\ m.b = recoveryBallot
      /\ newLeaderAckNNet' = newLeaderAckNNet \ {m}
      /\ ackCollected' = ackCollected \cup {m.from}
      /\ selectedCBallot' = IF m.cb >= selectedCBallot THEN m.cb ELSE selectedCBallot
      /\ selectedCmds' = IF m.cb >= selectedCBallot THEN m.cmds ELSE selectedCmds
      /\ selectedPhases' = IF m.cb >= selectedCBallot THEN m.phases ELSE selectedPhases
      /\ selectedDeps' = IF m.cb >= selectedCBallot THEN m.deps ELSE selectedDeps
      /\ selectedData' = IF m.cb >= selectedCBallot THEN m.data ELSE selectedData
      /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum,
                     knownCmds, hasPropose, cmdData, cmdDep, cmdPhase, slowPath,
                     fastVotes, slowVotes, leaderAckSeen, committed, delivered,
                     executing, executed, proposeNet, fastAckToReplica,
                     fastAckToClient, lightSlowAckToReplica, lightSlowAckToClient,
                     replyNet, acceptNet, recoverQueue, newLeaderNet, syncNet,
                     recoveryBallot, clientBallot, clientFastVotes,
                     clientSlowVotes, clientDelivered >>

LeaderBroadcastSync(l) ==
  /\ l \in Nodes
  /\ l = globalLeader
  /\ Cardinality(ackCollected) >= MajorityThreshold
  /\ syncNet' = syncNet \cup
       { [to |-> t, from |-> l, b |-> recoveryBallot,
          cmds |-> selectedCmds,
          phases |-> selectedPhases,
          deps |-> selectedDeps,
          data |-> selectedData] : t \in Nodes }
  /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum,
                 knownCmds, hasPropose, cmdData, cmdDep, cmdPhase, slowPath,
                 fastVotes, slowVotes, leaderAckSeen, committed, delivered,
                 executing, executed, proposeNet, fastAckToReplica,
                 fastAckToClient, lightSlowAckToReplica, lightSlowAckToClient,
                 replyNet, acceptNet, recoverQueue, newLeaderNet,
                 newLeaderAckNNet, recoveryBallot, ackCollected,
                 selectedCBallot, selectedCmds, selectedPhases,
                 selectedDeps, selectedData, clientBallot,
                 clientFastVotes, clientSlowVotes, clientDelivered >>

ReplicaInstallRecoveredState(r) ==
  /\ r \in Nodes
  /\ \E m \in syncNet :
      /\ m.to = r
      /\ m.b = recoveryBallot
      /\ syncNet' = syncNet \ {m}
      /\ status' = [status EXCEPT ![r] = "NORMAL"]
      /\ ballot' = [ballot EXCEPT ![r] = m.b]
      /\ cballot' = [cballot EXCEPT ![r] = m.b]
      /\ globalLeader' = LeaderOf(m.b)
      /\ knownCmds' = [knownCmds EXCEPT ![r] = m.cmds]
      /\ cmdData' = [cmdData EXCEPT ![r] = [c \in CmdIds |-> IF c \in m.cmds THEN m.data[c] ELSE NoCmd]]
      /\ cmdDep' = [cmdDep EXCEPT ![r] = [c \in CmdIds |-> IF c \in m.cmds THEN m.deps[c] ELSE {}]]
      /\ cmdPhase' = [cmdPhase EXCEPT ![r] = [c \in CmdIds |-> IF c \in m.cmds THEN
                                                 IF m.phases[c] \in {"ACCEPT", "COMMIT"} THEN m.phases[c] ELSE "ACCEPT"
                                               ELSE "START"]]
      /\ UNCHANGED << seqnum, hasPropose, slowPath, fastVotes, slowVotes,
                     leaderAckSeen, committed, delivered, executing, executed,
                     proposeNet, fastAckToReplica, fastAckToClient,
                     lightSlowAckToReplica, lightSlowAckToClient, replyNet,
                     acceptNet, recoverQueue, newLeaderNet, newLeaderAckNNet,
                     recoveryBallot, ackCollected, selectedCBallot, selectedCmds,
                     selectedPhases, selectedDeps, selectedData, clientBallot,
                     clientFastVotes, clientSlowVotes, clientDelivered >>

ClientRecvReply(c) ==
  /\ c \in Clients
  /\ \E m \in replyNet :
      /\ m.to = c
      /\ replyNet' = replyNet \ {m}
      /\ clientBallot' = [clientBallot EXCEPT ![c] = IF @ < m.b THEN m.b ELSE @]
      /\ clientFastVotes' = [clientFastVotes EXCEPT ![m.cmd] = @ \cup {m.from}]
      /\ leaderAckSeen' = [leaderAckSeen EXCEPT ![m.cmd] = TRUE]
      /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum,
                     knownCmds, hasPropose, cmdData, cmdDep, cmdPhase, slowPath,
                     fastVotes, slowVotes, committed, delivered, executing,
                     executed, proposeNet, fastAckToReplica, fastAckToClient,
                     lightSlowAckToReplica, lightSlowAckToClient, acceptNet,
                     recoverQueue, newLeaderNet, newLeaderAckNNet, syncNet,
                     recoveryBallot, ackCollected, selectedCBallot, selectedCmds,
                     selectedPhases, selectedDeps, selectedData,
                     clientSlowVotes, clientDelivered >>

ClientRecvReplyExact(c, id, from) ==
  /\ c \in Clients
  /\ id \in CmdIds
  /\ from \in Nodes
  /\ \E m \in replyNet :
      /\ m.to = c
      /\ m.cmd = id
      /\ m.from = from
      /\ replyNet' = replyNet \ {m}
      /\ clientBallot' = [clientBallot EXCEPT ![c] = IF @ < m.b THEN m.b ELSE @]
      /\ clientFastVotes' = [clientFastVotes EXCEPT ![m.cmd] = @ \cup {m.from}]
      /\ leaderAckSeen' = [leaderAckSeen EXCEPT ![m.cmd] = TRUE]
      /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum,
                     knownCmds, hasPropose, cmdData, cmdDep, cmdPhase, slowPath,
                     fastVotes, slowVotes, committed, delivered, executing,
                     executed, proposeNet, fastAckToReplica, fastAckToClient,
                     lightSlowAckToReplica, lightSlowAckToClient, acceptNet,
                     recoverQueue, newLeaderNet, newLeaderAckNNet, syncNet,
                     recoveryBallot, ackCollected, selectedCBallot, selectedCmds,
                     selectedPhases, selectedDeps, selectedData,
                     clientSlowVotes, clientDelivered >>

ClientRecvFastAckExact(c, id, from) ==
  /\ c \in Clients
  /\ id \in CmdIds
  /\ from \in Nodes
  /\ \E m \in fastAckToClient :
      /\ m.to = c
      /\ m.cmd = id
      /\ m.from = from
      /\ fastAckToClient' = fastAckToClient \ {m}
      /\ clientBallot' = [clientBallot EXCEPT ![c] = IF @ < m.b THEN m.b ELSE @]
      /\ clientFastVotes' = [clientFastVotes EXCEPT ![m.cmd] = @ \cup {m.from}]
      /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum,
                     knownCmds, hasPropose, cmdData, cmdDep, cmdPhase, slowPath,
                     fastVotes, slowVotes, leaderAckSeen, committed, delivered,
                     executing, executed, proposeNet, fastAckToReplica,
                     lightSlowAckToReplica, lightSlowAckToClient, replyNet,
                     acceptNet, recoverQueue, newLeaderNet, newLeaderAckNNet,
                     syncNet, recoveryBallot, ackCollected, selectedCBallot,
                     selectedCmds, selectedPhases, selectedDeps, selectedData,
                     clientSlowVotes, clientDelivered >>

ClientRecvFastAck(c) ==
  /\ c \in Clients
  /\ \E id \in CmdIds, from \in Nodes :
      ClientRecvFastAckExact(c, id, from)

ClientRecvSyntheticFastAck(c, id, from) ==
  /\ c \in Clients
  /\ id \in CmdIds
  /\ from \in Nodes
  /\ id \notin clientDelivered
  /\ from \in clientSlowVotes[id]
  /\ clientBallot' = [clientBallot EXCEPT ![c] = IF @ < ballot[from] THEN ballot[from] ELSE @]
  /\ clientFastVotes' = [clientFastVotes EXCEPT ![id] = @ \cup {from}]
  /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum,
                 knownCmds, hasPropose, cmdData, cmdDep, cmdPhase, slowPath,
                 fastVotes, slowVotes, leaderAckSeen, committed, delivered,
                 executing, executed, proposeNet, fastAckToReplica,
                 fastAckToClient, lightSlowAckToReplica, lightSlowAckToClient,
                 replyNet, acceptNet, recoverQueue, newLeaderNet, newLeaderAckNNet,
                 syncNet, recoveryBallot, ackCollected, selectedCBallot,
                 selectedCmds, selectedPhases, selectedDeps, selectedData,
                 clientSlowVotes, clientDelivered >>

ClientRecvLightSlowAckExact(c, id, from) ==
  /\ c \in Clients
  /\ id \in CmdIds
  /\ from \in Nodes
  /\ \E m \in lightSlowAckToClient :
      /\ m.to = c
      /\ m.cmd = id
      /\ m.from = from
      /\ lightSlowAckToClient' = lightSlowAckToClient \ {m}
      /\ clientBallot' = [clientBallot EXCEPT ![c] = IF @ < m.b THEN m.b ELSE @]
      /\ clientSlowVotes' = [clientSlowVotes EXCEPT ![m.cmd] = @ \cup {m.from}]
      /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum,
                     knownCmds, hasPropose, cmdData, cmdDep, cmdPhase, slowPath,
                     fastVotes, slowVotes, leaderAckSeen, committed, delivered,
                     executing, executed, proposeNet, fastAckToReplica,
                     fastAckToClient, lightSlowAckToReplica, replyNet, acceptNet,
                     recoverQueue, newLeaderNet, newLeaderAckNNet, syncNet,
                     recoveryBallot, ackCollected, selectedCBallot, selectedCmds,
                     selectedPhases, selectedDeps, selectedData,
                     clientFastVotes, clientDelivered >>

ClientRecvLightSlowAck(c) ==
  /\ c \in Clients
  /\ \E id \in CmdIds, from \in Nodes :
      ClientRecvLightSlowAckExact(c, id, from)

ClientRecvSyntheticLightSlowAck(c, id, from) ==
  /\ c \in Clients
  /\ id \in CmdIds
  /\ from \in Nodes
  /\ id \notin clientDelivered
  /\ clientSlowVotes' = [clientSlowVotes EXCEPT ![id] = @ \cup {from}]
  /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum,
                 knownCmds, hasPropose, cmdData, cmdDep, cmdPhase, slowPath,
                 fastVotes, slowVotes, leaderAckSeen, committed, delivered,
                 executing, executed, proposeNet, fastAckToReplica,
                 fastAckToClient, lightSlowAckToReplica, lightSlowAckToClient,
                 replyNet, acceptNet, recoverQueue, newLeaderNet, newLeaderAckNNet,
                 syncNet, recoveryBallot, ackCollected, selectedCBallot,
                 selectedCmds, selectedPhases, selectedDeps, selectedData,
                 clientBallot, clientFastVotes, clientDelivered >>

ClientRecvAccept(c) ==
  /\ c \in Clients
  /\ \E m \in acceptNet :
      /\ m.to = c
      /\ acceptNet' = acceptNet \ {m}
      /\ clientDelivered' = clientDelivered \cup {m.cmd}
      /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum,
                     knownCmds, hasPropose, cmdData, cmdDep, cmdPhase, slowPath,
                     fastVotes, slowVotes, leaderAckSeen, committed, delivered,
                     executing, executed, proposeNet, fastAckToReplica,
                     fastAckToClient, lightSlowAckToReplica, lightSlowAckToClient,
                     replyNet, recoverQueue, newLeaderNet, newLeaderAckNNet,
                     syncNet, recoveryBallot, ackCollected, selectedCBallot,
                     selectedCmds, selectedPhases, selectedDeps, selectedData,
                     clientBallot, clientFastVotes, clientSlowVotes >>

ClientFastPathDecide(id) ==
  /\ id \in CmdIds
  /\ id \notin clientDelivered
  /\ Cardinality(clientFastVotes[id]) >= FastThreshold
  /\ clientDelivered' = clientDelivered \cup {id}
  /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum,
                 knownCmds, hasPropose, cmdData, cmdDep, cmdPhase, slowPath,
                 fastVotes, slowVotes, leaderAckSeen, committed, delivered,
                 executing, executed, proposeNet, fastAckToReplica,
                 fastAckToClient, lightSlowAckToReplica, lightSlowAckToClient,
                 replyNet, acceptNet, recoverQueue, newLeaderNet, newLeaderAckNNet,
                 syncNet, recoveryBallot, ackCollected, selectedCBallot,
                 selectedCmds, selectedPhases, selectedDeps, selectedData,
                 clientBallot, clientFastVotes, clientSlowVotes >>

ClientSlowPathDecide(id) ==
  /\ id \in CmdIds
  /\ id \notin clientDelivered
  /\ Cardinality(clientSlowVotes[id]) >= MajorityThreshold
  /\ clientDelivered' = clientDelivered \cup {id}
  /\ UNCHANGED << status, ballot, cballot, globalLeader, seqnum,
                 knownCmds, hasPropose, cmdData, cmdDep, cmdPhase, slowPath,
                 fastVotes, slowVotes, leaderAckSeen, committed, delivered,
                 executing, executed, proposeNet, fastAckToReplica,
                 fastAckToClient, lightSlowAckToReplica, lightSlowAckToClient,
                 replyNet, acceptNet, recoverQueue, newLeaderNet, newLeaderAckNNet,
                 syncNet, recoveryBallot, ackCollected, selectedCBallot,
                 selectedCmds, selectedPhases, selectedDeps, selectedData,
                 clientBallot, clientFastVotes, clientSlowVotes >>

Next ==
  \/ \E c \in Clients, r \in Nodes, id \in CmdIds, op \in {"GET", "PUT", "SCAN"}, k \in Keys :
       ClientSubmit(c, r, id, op, k)
  \/ \E r \in Nodes : ReplicaRecvPropose(r)
  \/ \E r \in Nodes, id \in CmdIds : ReplicaPropagate(r, id)
  \/ \E id \in CmdIds : ReplicaLeaderFastAckAssignSeq(id)
  \/ \E r \in Nodes : ReplicaRecvFastAckAgree(r)
  \/ \E r \in Nodes : ReplicaRecvFastAckConflict(r)
  \/ \E r \in Nodes : ReplicaRecvLightSlowAck(r)
  \/ \E r \in Nodes, id \in CmdIds : ReplicaCommitOnQuorum(r, id)
  \/ \E r \in Nodes, id \in CmdIds : ReplicaCommandExecuteStart(r, id)
  \/ \E r \in Nodes, id \in CmdIds : ReplicaCommandExecuteFinish(r, id)
  \/ \E r \in Nodes, b \in 0..MaxBallot : RecoveryTrigger(r, b)
  \/ \E r \in Nodes : ReplicaBroadcastNewLeader(r)
  \/ \E r \in Nodes : ReplicaRecvNewLeader(r)
  \/ \E l \in Nodes : LeaderCollectNewLeaderAckN(l)
  \/ \E l \in Nodes : LeaderBroadcastSync(l)
  \/ \E r \in Nodes : ReplicaInstallRecoveredState(r)
  \/ \E c \in Clients : ClientRecvReply(c)
  \/ \E c \in Clients : ClientRecvFastAck(c)
  \/ \E c \in Clients, id \in CmdIds, from \in Nodes : ClientRecvSyntheticFastAck(c, id, from)
  \/ \E c \in Clients : ClientRecvLightSlowAck(c)
  \/ \E c \in Clients, id \in CmdIds, from \in Nodes : ClientRecvSyntheticLightSlowAck(c, id, from)
  \/ \E c \in Clients : ClientRecvAccept(c)
  \/ \E id \in CmdIds : ClientFastPathDecide(id)
  \/ \E id \in CmdIds : ClientSlowPathDecide(id)

IsAcceptOrCommit(r, id) ==
  cmdPhase[r][id] \in {"ACCEPT", "COMMIT"}

RECURSIVE Reach(_, _, _, _)
Reach(r, frontier, allowed, k) ==
  IF k = 0
  THEN frontier
  ELSE LET prev == Reach(r, frontier, allowed, k - 1)
       IN prev \cup {d \in allowed : \E c \in prev : d \in cmdDep[r][c]}

CommittedReach(r, c) ==
  Reach(r, cmdDep[r][c] \cap committed[r], committed[r], Cardinality(committed[r]))

AllReach(r, c) ==
  Reach(r, cmdDep[r][c] \cap knownCmds[r], knownCmds[r], Cardinality(knownCmds[r]))

AcceptedOrCommittedIds(r) ==
  {id \in knownCmds[r] : IsAcceptOrCommit(r, id)}

\* Any two replicas commit a command with the same dependencies.
InvCommittedDepsAgreement ==
  \A r1 \in Nodes, r2 \in Nodes :
    \A c \in committed[r1] \cap committed[r2] :
      cmdDep[r1][c] = cmdDep[r2][c]

\* Any two conflicting committed commands are dependency-ordered.
InvCommittedConflictsOrdered ==
  \A r \in Nodes :
    \A c1 \in committed[r], c2 \in committed[r] :
      c1 # c2 /\ Conflict(cmdData[r][c1], cmdData[r][c2]) =>
        (c1 \in cmdDep[r][c2] \/ c2 \in cmdDep[r][c1])

\* The committed dependency graph is acyclic.
InvCommittedDepGraphAcyclic ==
  \A r \in Nodes :
    \A c \in committed[r] :
      c \notin CommittedReach(r, c)

\* If cmd[id] is populated then id is known and either waiting to propagate
\* or already moved past START.
InvCommandRecordAndPropagation ==
  \A r \in Nodes :
    \A id \in knownCmds[r] :
      hasPropose[r][id] =>
        /\ id \in knownCmds[r]
        /\ cmdData[r][id] # NoCmd
        /\ (cmdPhase[r][id] = "START" \/ cmdPhase[r][id] \in {"PRE_ACCEPT", "ACCEPT", "COMMIT"})

\* START commands are not dependencies of any command.
InvStartNotInDependencies ==
  \A r \in Nodes :
    \A c \in knownCmds[r] :
      cmdPhase[r][c] = "START" =>
        \A d \in knownCmds[r] : c \notin cmdDep[r][d]

\* Ack sends carry the sender's current ballot/cballot.
InvAckUsesCurrentBallot ==
  /\ \A m \in fastAckToReplica :
       m.b <= ballot[m.from]
  /\ \A m \in lightSlowAckToReplica :
       m.b <= ballot[m.from]
  /\ \A r \in Nodes :
       status[r] = "NORMAL" => cballot[r] = ballot[r]

\* At ballot b, the leader emits one dependency set per command id in Ack.
InvLeaderAckUniqueDepPerBallot ==
  \A m1 \in fastAckToReplica, m2 \in fastAckToReplica :
    m1.from = LeaderOf(m1.b) /\ m2.from = LeaderOf(m2.b) /\
    m1.b = m2.b /\ m1.cmd = m2.cmd =>
      m1.dep = m2.dep

\* Leader Ack and Sync are dependency-consistent at the same ballot.
InvLeaderAckSyncConsistent ==
  \A m \in fastAckToReplica, s \in syncNet :
    m.from = LeaderOf(m.b) /\ s.from = LeaderOf(s.b) /\
    m.b = s.b /\ m.from = s.from /\ m.cmd \in s.cmds =>
      s.deps[m.cmd] = m.dep

\* At ballot b, the leader emits one Sync payload.
InvLeaderSyncUniquePerBallot ==
  \A s1 \in syncNet, s2 \in syncNet :
    s1.from = LeaderOf(s1.b) /\ s2.from = LeaderOf(s2.b) /\
    s1.b = s2.b /\ s1.from = s2.from =>
      /\ s1.cmds = s2.cmds
      /\ s1.phases = s2.phases
      /\ s1.deps = s2.deps
      /\ s1.data = s2.data

\* After sending NewLeaderAck at higher ballot, a replica does not send Ack
\* at that ballot or above.
InvNoAckAtOrAboveNewLeaderAckBallot ==
  \A n \in newLeaderAckNNet :
    /\ \A m \in fastAckToReplica :
         m.from = n.from => m.b < n.b
    /\ \A m \in lightSlowAckToReplica :
         m.from = n.from => m.b < n.b

\* Accepted/committed dependency agrees with the leader's dependency once both
\* sides have reached ACCEPT/COMMIT in the same cballot. This captures
\* convergence, not lockstep phase progression.
InvAcceptedDepMatchesLeaderWhenNormal ==
  \A r \in Nodes :
    \A id \in AcceptedOrCommittedIds(r) :
      IsAcceptOrCommit(r, id) =>
        LET l == LeaderOf(cballot[r])
        IN /\ cballot[l] = cballot[r]
           /\ (status[l] = "NORMAL" /\ id \in knownCmds[l] /\ IsAcceptOrCommit(l, id) =>
                cmdDep[l][id] = cmdDep[r][id])

\* For a fixed ballot, accepted/committed commands are unique.
InvAcceptedUniquePerBallot ==
  \A r1 \in Nodes :
    \A r2 \in Nodes :
      \A id \in AcceptedOrCommittedIds(r1) \cap AcceptedOrCommittedIds(r2) :
        IsAcceptOrCommit(r1, id) /\ IsAcceptOrCommit(r2, id) /\
        cballot[r1] = cballot[r2] =>
          /\ cmdData[r1][id] = cmdData[r2][id]
          /\ cmdDep[r1][id] = cmdDep[r2][id]

\* In ACCEPT/COMMIT, transitive dependencies are also in ACCEPT/COMMIT.
InvAcceptCommitTransitiveDepsAccepted ==
  \A r \in Nodes :
    \A c \in AcceptedOrCommittedIds(r) :
      IsAcceptOrCommit(r, c) =>
        \A d \in AllReach(r, c) : IsAcceptOrCommit(r, d)

\* Once a command is accepted/committed, higher cballots keep its dependency.
InvHigherCBallotPreservesDep ==
  \A r1 \in Nodes :
    \A r2 \in Nodes :
      \A id \in AcceptedOrCommittedIds(r1) \cap AcceptedOrCommittedIds(r2) :
        IsAcceptOrCommit(r1, id) /\ IsAcceptOrCommit(r2, id) /\
        cballot[r2] > cballot[r1] =>
          cmdDep[r2][id] = cmdDep[r1][id]

RequestedInvariants ==
  /\ InvCommittedDepsAgreement
  /\ InvCommittedConflictsOrdered
  /\ InvCommittedDepGraphAcyclic
  /\ InvCommandRecordAndPropagation
  /\ InvStartNotInDependencies
  /\ InvAckUsesCurrentBallot
  /\ InvLeaderAckUniqueDepPerBallot
  /\ InvLeaderAckSyncConsistent
  /\ InvLeaderSyncUniquePerBallot
  /\ InvNoAckAtOrAboveNewLeaderAckBallot
  /\ InvAcceptedDepMatchesLeaderWhenNormal
  /\ InvAcceptedUniquePerBallot
  /\ InvAcceptCommitTransitiveDepsAccepted
  /\ InvHigherCBallotPreservesDep

Spec ==
  /\ Init
  /\ [][Next]_vars
  /\ \A r \in Nodes : WF_vars(ReplicaRecvPropose(r))
  /\ \A r \in Nodes, id \in CmdIds : WF_vars(ReplicaPropagate(r, id))
  /\ \A id \in CmdIds : WF_vars(ReplicaLeaderFastAckAssignSeq(id))
  /\ \A r \in Nodes : WF_vars(ReplicaRecvFastAckAgree(r))
  /\ \A r \in Nodes : WF_vars(ReplicaRecvFastAckConflict(r))
  /\ \A r \in Nodes, id \in CmdIds : WF_vars(ReplicaCommitOnQuorum(r, id))
  /\ \A r \in Nodes, id \in CmdIds : WF_vars(ReplicaCommandExecuteStart(r, id))
  /\ \A r \in Nodes, id \in CmdIds : WF_vars(ReplicaCommandExecuteFinish(r, id))
  /\ \A r \in Nodes : SF_vars(ReplicaRecvNewLeader(r))
  /\ \A r \in Nodes : WF_vars(ReplicaInstallRecoveredState(r))
  /\ \A id \in CmdIds : WF_vars(ClientFastPathDecide(id))
  /\ \A id \in CmdIds : WF_vars(ClientSlowPathDecide(id))

====
