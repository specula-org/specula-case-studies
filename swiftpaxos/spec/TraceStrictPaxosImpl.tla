---- MODULE TraceStrictPaxosImpl ----
EXTENDS Json, IOUtils, Sequences, SequencesExt, FiniteSets, TLC, Naturals, Integers, Folds

CONSTANTS Nodes, Clients, Keys, MaxCmdSeq, MaxBallot, MaxSeqnum, MaxChecksum, OptExec, FixedMajority

ASSUME TLCGet("config").mode = "bfs"

JsonFile ==
    IF "JSON" \in DOMAIN IOEnv THEN IOEnv.JSON ELSE "../artifact/swiftpaxos/traces/merged1.ndjson"

OriginTraceLog ==
    SelectSeq(ndJsonDeserialize(JsonFile), LAMBDA x: "event" \in DOMAIN x)

TraceLog ==
    TLCEval(IF "MAX_TRACE" \in DOMAIN IOEnv THEN SubSeq(OriginTraceLog, 1, atoi(IOEnv.MAX_TRACE)) ELSE OriginTraceLog)

ProgressStride ==
    IF Len(TraceLog) < 100 THEN 1 ELSE Len(TraceLog) \div 100

TraceReplicaRaw == TLCEval(FoldSeq(
    LAMBDA x, acc: acc \cup
      IF "event" \in DOMAIN x /\ "nid" \in DOMAIN x.event
      THEN {atoi(x.event.nid)}
      ELSE {},
    {}, TraceLog))

TraceClientRaw == TLCEval(FoldSeq(
    LAMBDA x, acc: acc \cup
      IF "event" \in DOMAIN x /\ "cmd" \in DOMAIN x.event /\ "client" \in DOMAIN x.event.cmd
      THEN {x.event.cmd.client}
      ELSE {},
    {}, TraceLog))

TraceKeyRaw == TLCEval(FoldSeq(
    LAMBDA x, acc: acc \cup
      IF "event" \in DOMAIN x /\ "command" \in DOMAIN x.event /\ "key" \in DOMAIN x.event.command
      THEN {x.event.command.key}
      ELSE IF "event" \in DOMAIN x /\ "cmd" \in DOMAIN x.event /\ "key" \in DOMAIN x.event.cmd
           THEN {x.event.cmd.key}
           ELSE {},
    {}, TraceLog))

TraceSeqSet == TLCEval(FoldSeq(
    LAMBDA x, acc: acc \cup
      IF "event" \in DOMAIN x /\ "cmd" \in DOMAIN x.event /\ "seq" \in DOMAIN x.event.cmd
      THEN {x.event.cmd.seq}
      ELSE {},
    {}, TraceLog))

MaxFromSet(S) ==
    CHOOSE m \in S : \A n \in S : m >= n

MinFromSet(S) ==
    CHOOSE m \in S : \A n \in S : m <= n

MaxTraceSeq == IF TraceSeqSet = {} THEN 0 ELSE MaxFromSet(TraceSeqSet)

RawNodeToNode(n) == n + 1

RankInt(S, x) == Cardinality({y \in S : y <= x})

RawClientToClient(c) == RankInt(TraceClientRaw, c)
RawKeyToKey(k) == RankInt(TraceKeyRaw, k)

CmdFromRaw(rawcmd) ==
    [client |-> RawClientToClient(rawcmd.client), seq |-> rawcmd.seq + 1]

PayloadFromEvent(ev) ==
    [op |-> ev.command.op, key |-> RawKeyToKey(ev.command.key)]

StatusFromTrace(s) ==
    IF s = "NORMAL" THEN "NORMAL" ELSE "RECOVERING"

DefaultCmdId == [client |-> CHOOSE c \in Clients : TRUE, seq |-> 1]

EmptyClientSubmitPending ==
    [active |-> FALSE,
     c |-> CHOOSE c \in Clients : TRUE,
     id |-> DefaultCmdId,
     op |-> "GET",
     k |-> CHOOSE k \in Keys : TRUE,
     rem |-> {}]

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
  clientDelivered,
  l,
  csPending

SPI == INSTANCE StrictPaxosImpl
  WITH status <- status,
       ballot <- ballot,
       cballot <- cballot,
       globalLeader <- globalLeader,
       seqnum <- seqnum,
       knownCmds <- knownCmds,
       hasPropose <- hasPropose,
       cmdData <- cmdData,
       cmdDep <- cmdDep,
       cmdPhase <- cmdPhase,
       slowPath <- slowPath,
       fastVotes <- fastVotes,
       slowVotes <- slowVotes,
       leaderAckSeen <- leaderAckSeen,
       committed <- committed,
       delivered <- delivered,
       executing <- executing,
       executed <- executed,
       proposeNet <- proposeNet,
       fastAckToReplica <- fastAckToReplica,
       fastAckToClient <- fastAckToClient,
       lightSlowAckToReplica <- lightSlowAckToReplica,
       lightSlowAckToClient <- lightSlowAckToClient,
       replyNet <- replyNet,
       acceptNet <- acceptNet,
       recoverQueue <- recoverQueue,
       newLeaderNet <- newLeaderNet,
       newLeaderAckNNet <- newLeaderAckNNet,
       syncNet <- syncNet,
       recoveryBallot <- recoveryBallot,
       ackCollected <- ackCollected,
       selectedCBallot <- selectedCBallot,
       selectedCmds <- selectedCmds,
       selectedPhases <- selectedPhases,
       selectedDeps <- selectedDeps,
       selectedData <- selectedData,
       clientBallot <- clientBallot,
       clientFastVotes <- clientFastVotes,
       clientSlowVotes <- clientSlowVotes,
       clientDelivered <- clientDelivered

CmdIds == SPI!CmdIds

logline == TraceLog[l]

TargetsFromLogline ==
    IF "target" \in DOMAIN logline.event
    THEN {RawNodeToNode(atoi(logline.event.target[i])) : i \in DOMAIN logline.event.target}
    ELSE Nodes

BaseVars == <<
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

TraceVars == Append(BaseVars, l)

ASSUME TraceReplicaRaw # {}
ASSUME TraceClientRaw # {}
ASSUME TraceKeyRaw # {}
ASSUME \A n \in TraceReplicaRaw : RawNodeToNode(n) \in Nodes
ASSUME Cardinality(TraceClientRaw) <= Cardinality(Clients)
ASSUME Cardinality(TraceKeyRaw) <= Cardinality(Keys)
ASSUME MaxTraceSeq + 1 <= MaxCmdSeq

StepToNextTrace ==
    /\ l' = l + 1
    /\ l % ProgressStride = 0 => PrintT(<<"Progress %:", (l * 100) \div Len(TraceLog)>>)
    /\ l' > Len(TraceLog) => PrintT(<<"Progress %:", 100>>)

LoglineIs(name) ==
    /\ l <= Len(TraceLog)
    /\ logline.event.name = name

ReplicaStateMatches(r) ==
    /\ "state" \in DOMAIN logline.event
    /\ ("status" \in DOMAIN logline.event.state) => status[r] = StatusFromTrace(logline.event.state.status)
    /\ ("ballot" \in DOMAIN logline.event.state) => ballot[r] = logline.event.state.ballot
    /\ ("cballot" \in DOMAIN logline.event.state) => cballot[r] = logline.event.state.cballot
    /\ ("leader" \in DOMAIN logline.event.state) => globalLeader = RawNodeToNode(logline.event.state.leader)

ClientBallotMatches(c) ==
    TRUE

ClientSubmitObserved ==
    /\ LoglineIs("ClientSubmit")
    /\ ~csPending.active
    /\ "cmd" \in DOMAIN logline.event
    /\ TargetsFromLogline # {}
    /\ LET c == RawClientToClient(logline.event.cmd.client)
           id == CmdFromRaw(logline.event.cmd)
           op == logline.event.cmd.op
           k == RawKeyToKey(logline.event.cmd.key)
           r == MinFromSet(TargetsFromLogline)
           rem2 == TargetsFromLogline \ {r}
       IN /\ c \in Clients
          /\ id \in CmdIds
          /\ op \in {"GET", "PUT", "SCAN"}
          /\ k \in Keys
          /\ r \in Nodes
          /\ SPI!ClientSubmit(c, r, id, op, k)
          /\ csPending' =
              [active |-> rem2 # {},
               c |-> c,
               id |-> id,
               op |-> op,
               k |-> k,
               rem |-> rem2]

ReplicaClientSubmitLogged ==
    /\ LoglineIs("ReplicaClientSubmit")
    /\ LET r == RawNodeToNode(atoi(logline.event.nid))
           id == CmdFromRaw(logline.event.cmd)
           op == logline.event.command.op
           k == RawKeyToKey(logline.event.command.key)
           c == RawClientToClient(logline.event.cmd.client)
       IN /\ r \in Nodes
          /\ id \in CmdIds
          /\ op \in {"GET", "PUT", "SCAN"}
          /\ k \in Keys
          /\ c \in Clients
          /\ [to |-> r, from |-> c, cmd |-> id, payload |-> [op |-> op, key |-> k]] \in proposeNet
          /\ ReplicaStateMatches(r)
          /\ SPI!ReplicaRecvProposeExact(r, c, id, [op |-> op, key |-> k])
    /\ UNCHANGED csPending

ReplicaPropagateLogged ==
    /\ LoglineIs("ReplicaPropagate")
    /\ LET r == RawNodeToNode(atoi(logline.event.nid))
           id == CmdFromRaw(logline.event.cmd)
       IN /\ r \in Nodes
          /\ id \in CmdIds
          /\ hasPropose[r][id]
          /\ ReplicaStateMatches(r)
          /\ SPI!ReplicaPropagate(r, id)
    /\ UNCHANGED csPending

ReplicaLeaderFastAckLogged ==
    /\ LoglineIs("ReplicaLeaderFastAck")
    /\ LET id == CmdFromRaw(logline.event.cmd)
           r == RawNodeToNode(atoi(logline.event.nid))
       IN /\ id \in CmdIds
          /\ r \in Nodes
          /\ r = globalLeader
          /\ hasPropose[r][id]
          /\ ReplicaStateMatches(r)
          /\ SPI!ReplicaLeaderFastAckAssignSeq(id)
    /\ UNCHANGED csPending

ReplicaFastAckObserved ==
    /\ LoglineIs("ReplicaFastAck")
    /\ LET r == RawNodeToNode(atoi(logline.event.nid))
       IN /\ r \in Nodes
          /\ ReplicaStateMatches(r)
          /\ SPI!ReplicaRecvFastAckSelf(r)
    /\ UNCHANGED csPending

ReplicaSlowPathDecideLogged ==
    /\ LoglineIs("ReplicaSlowPathDecide")
    /\ LET r == RawNodeToNode(atoi(logline.event.nid))
       IN /\ r \in Nodes
          /\ ReplicaStateMatches(r)
          /\ SPI!ReplicaRecvLeaderFastAckSlowPath(r)
    /\ UNCHANGED csPending

ReplicaCommitOnQuorumObserved ==
    /\ LoglineIs("ReplicaCommitOnQuorum")
    /\ LET r == RawNodeToNode(atoi(logline.event.nid))
           id == CmdFromRaw(logline.event.cmd)
       IN /\ r \in Nodes
          /\ id \in CmdIds
          /\ ReplicaStateMatches(r)
          /\ \/ SPI!ReplicaCommitOnQuorum(r, id)
             \/ /\ id \in committed[r]
                /\ UNCHANGED BaseVars
    /\ UNCHANGED csPending

ReplicaCommandExecuteStartLogged ==
    /\ LoglineIs("ReplicaCommandExecuteStart")
    /\ LET r == RawNodeToNode(atoi(logline.event.nid))
           id == CmdFromRaw(logline.event.cmd)
       IN /\ r \in Nodes
          /\ id \in CmdIds
          /\ ReplicaStateMatches(r)
          /\ SPI!ReplicaCommandExecuteStart(r, id)
    /\ UNCHANGED csPending

ReplicaCommandExecuteLogged ==
    /\ LoglineIs("ReplicaCommandExecute")
    /\ LET r == RawNodeToNode(atoi(logline.event.nid))
           id == CmdFromRaw(logline.event.cmd)
       IN /\ r \in Nodes
          /\ id \in CmdIds
          /\ ReplicaStateMatches(r)
          /\ SPI!ReplicaCommandExecuteFinish(r, id)
    /\ UNCHANGED csPending

ClientReplyReceivedLogged ==
    /\ LoglineIs("ClientReplyReceived")
    /\ LET c == RawClientToClient(logline.event.cmd.client)
           id == CmdFromRaw(logline.event.cmd)
           from == RawNodeToNode(logline.event.from)
       IN /\ c \in Clients
          /\ id \in CmdIds
          /\ from \in Nodes
          /\ ClientBallotMatches(c)
          /\ SPI!ClientRecvReplyExact(c, id, from)
    /\ UNCHANGED csPending

ClientFastAckReceivedLogged ==
    /\ LoglineIs("ClientFastAckReceived")
    /\ LET c == RawClientToClient(logline.event.cmd.client)
           id == CmdFromRaw(logline.event.cmd)
           from == RawNodeToNode(logline.event.from)
       IN /\ c \in Clients
          /\ id \in CmdIds
          /\ from \in Nodes
          /\ ClientBallotMatches(c)
          /\ \/ /\ ~("hasChecksum" \in DOMAIN logline.event) \/ logline.event.hasChecksum = TRUE
                /\ SPI!ClientRecvFastAckExact(c, id, from)
             \/ /\ "hasChecksum" \in DOMAIN logline.event
                /\ logline.event.hasChecksum = FALSE
                /\ SPI!ClientRecvSyntheticFastAck(c, id, from)
    /\ UNCHANGED csPending

ClientLightSlowAckReceivedLogged ==
    /\ LoglineIs("ClientLightSlowAckReceived")
    /\ LET c == RawClientToClient(logline.event.cmd.client)
           id == CmdFromRaw(logline.event.cmd)
           from == RawNodeToNode(logline.event.from)
       IN /\ c \in Clients
          /\ id \in CmdIds
          /\ from \in Nodes
          /\ ClientBallotMatches(c)
          /\ IF \E m \in lightSlowAckToClient : m.to = c /\ m.cmd = id /\ m.from = from
             THEN SPI!ClientRecvLightSlowAckExact(c, id, from)
             ELSE SPI!ClientRecvSyntheticLightSlowAck(c, id, from)
    /\ UNCHANGED csPending

ClientFastPathDecideLogged ==
    /\ LoglineIs("ClientFastPathDecide")
    /\ \E id \in CmdIds :
        /\ id = CmdFromRaw(logline.event.cmd)
        /\ SPI!ClientFastPathDecide(id)
    /\ UNCHANGED csPending

ClientSlowPathDecideLogged ==
    /\ LoglineIs("ClientSlowPathDecide")
    /\ \E id \in CmdIds :
        /\ id = CmdFromRaw(logline.event.cmd)
        /\ SPI!ClientSlowPathDecide(id)
    /\ UNCHANGED csPending

ConsumeLineNoStep ==
    \/ ClientSubmitObserved
    \/ ReplicaClientSubmitLogged
    \/ ReplicaPropagateLogged
    \/ ReplicaLeaderFastAckLogged
    \/ ReplicaFastAckObserved
    \/ ReplicaSlowPathDecideLogged
    \/ ReplicaCommitOnQuorumObserved
    \/ ReplicaCommandExecuteStartLogged
    \/ ReplicaCommandExecuteLogged
    \/ ClientReplyReceivedLogged
    \/ ClientFastAckReceivedLogged
    \/ ClientLightSlowAckReceivedLogged
    \/ ClientFastPathDecideLogged
    \/ ClientSlowPathDecideLogged

ConsumeLine ==
    /\ ConsumeLineNoStep
    /\ StepToNextTrace

ClientSubmitFanoutInternal ==
    /\ csPending.active
    /\ LET r == MinFromSet(csPending.rem)
           rem2 == csPending.rem \ {r}
       IN /\ SPI!ClientSubmit(csPending.c, r, csPending.id, csPending.op, csPending.k)
          /\ csPending' =
             [active |-> rem2 # {},
              c |-> csPending.c,
              id |-> csPending.id,
              op |-> csPending.op,
              k |-> csPending.k,
              rem |-> rem2]
    /\ UNCHANGED l

TraceNext ==
    \/ /\ csPending.active
       /\ ClientSubmitFanoutInternal
    \/ /\ ~csPending.active
       /\ l <= Len(TraceLog)
       /\ ConsumeLine

TraceInit ==
    /\ SPI!Init
    /\ l = 1
    /\ csPending = EmptyClientSubmitPending

TraceSpec ==
    TraceInit /\ [][TraceNext]_<<
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
      clientDelivered,
      l,
      csPending
    >>

TraceView ==
    <<
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
      clientDelivered,
      l,
      csPending
    >>

TraceDone ==
    /\ l > Len(TraceLog)
    /\ ~csPending.active

CanStepOrDone ==
    ENABLED TraceNext \/ TraceDone

TraceMatched ==
    [](l <= Len(TraceLog) => [](TLCGet("queue") = 1 \/ l > Len(TraceLog)))

====
