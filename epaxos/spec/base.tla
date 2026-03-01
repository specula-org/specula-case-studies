---- MODULE base ----
EXTENDS TLC, Naturals, Integers, Sequences, FiniteSets

CONSTANTS Replicas, Clients, Keys, MaxInstance, MaxBallot, MaxSeq, MaxCmdId

ASSUME /\ Replicas /= {}
       /\ Clients /= {}
       /\ Keys /= {}
       /\ Replicas = 1..Cardinality(Replicas)
       /\ Clients = 1..Cardinality(Clients)
       /\ Keys = 1..Cardinality(Keys)
       /\ MaxInstance \in Nat
       /\ MaxBallot \in Nat
       /\ MaxSeq \in Nat
       /\ MaxCmdId \in Nat \ {0}

Instances == 0..MaxInstance
DepVals == -1..MaxInstance
Ops == {"GET", "PUT", "SCAN", "NONE"}
Statuses == {"NONE", "PREACCEPTED", "PREACCEPTED_EQ", "ACCEPTED", "COMMITTED", "EXECUTED"}
Origins == {"none", "client", "recovery_noop", "recovery_reproposal"}
MsgTypes == {"PreAccept", "PreAcceptReply", "Accept", "AcceptReply", "Commit", "Prepare", "PrepareReply", "TryPreAccept", "TryPreAcceptReply"}

ClientOrNone == Clients \cup {0}
CmdIds == 0..MaxCmdId
ReplicaOrNone == Replicas \cup {-1}
InstOrNone == Instances \cup {-1}

Majority == (Cardinality(Replicas) \div 2) + 1
SlowQuorum == Majority
FastQuorum == IF Cardinality(Replicas) <= 3 THEN Majority ELSE Majority + 1

NilDeps == [q \in Replicas |-> -1]
NoCmd == [id |-> 0, client |-> 0, op |-> "NONE", key |-> CHOOSE k \in Keys : TRUE]

CmdType == [id : CmdIds, client : ClientOrNone, op : Ops, key : Keys]
CmdBatchType == UNION { [1..k -> CmdType] : k \in 1..2 }
DepsType == [Replicas -> DepVals]

InstType ==
  [ hasCmd  : BOOLEAN,
    cmd     : CmdType,
    cmds    : CmdBatchType,
    bal     : 0..MaxBallot,
    vbal    : 0..MaxBallot,
    status  : Statuses,
    seq     : 0..MaxSeq,
    deps    : DepsType,
    origin  : Origins ]

LBType ==
  [ ballot            : 0..MaxBallot,
    lastTriedBallot   : 0..MaxBallot,
    status            : Statuses,
    seq               : 0..MaxSeq,
    deps              : DepsType,
    allEqual          : BOOLEAN,
    preAcceptOKs      : Nat,
    acceptOKs         : Nat,
    nacks             : Nat,
    preparing         : BOOLEAN,
    tryingToPreAccept : BOOLEAN,
    tpaReps           : Nat,
    tpaAccepted       : BOOLEAN,
    leaderResponded   : BOOLEAN,
    committedDeps     : DepsType,
    recoverySubcase   : 0..6,
    prepareAcks       : SUBSET Replicas,
    possibleQuorum    : [Replicas -> BOOLEAN] ]

MsgType ==
  [ typ          : MsgTypes,
    from         : Replicas,
    to           : Replicas,
    rr           : Replicas,
    ii           : Instances,
    ballot       : 0..MaxBallot,
    vbal         : 0..MaxBallot,
    seq          : 0..MaxSeq,
    deps         : DepsType,
    cmd          : CmdType,
    cmds         : CmdBatchType,
    status       : Statuses,
    committedDeps: DepsType,
    confRep      : ReplicaOrNone,
    confInst     : InstOrNone,
    confStatus   : Statuses ]

SlotType == [n : Replicas, r : Replicas, i : Instances]

DefaultInst ==
  [ hasCmd |-> FALSE,
    cmd |-> NoCmd,
    cmds |-> <<NoCmd>>,
    bal |-> 0,
    vbal |-> 0,
    status |-> "NONE",
    seq |-> 0,
    deps |-> NilDeps,
    origin |-> "none" ]

DefaultLB ==
  [ ballot |-> 0,
    lastTriedBallot |-> 0,
    status |-> "NONE",
    seq |-> 0,
    deps |-> NilDeps,
    allEqual |-> TRUE,
    preAcceptOKs |-> 0,
    acceptOKs |-> 0,
    nacks |-> 0,
    preparing |-> FALSE,
    tryingToPreAccept |-> FALSE,
    tpaReps |-> 0,
    tpaAccepted |-> FALSE,
    leaderResponded |-> FALSE,
    committedDeps |-> NilDeps,
    recoverySubcase |-> 0,
    prepareAcks |-> {},
    possibleQuorum |-> [q \in Replicas |-> TRUE] ]

Slot(n, r, i) == [n |-> n, r |-> r, i |-> i]

MkMsg(typ, from, to, rr, ii, ballot, vbal, seq, deps, cmd, status, cdeps, confRep, confInst, confStatus) ==
  [ typ |-> typ,
    from |-> from,
    to |-> to,
    rr |-> rr,
    ii |-> ii,
    ballot |-> ballot,
    vbal |-> vbal,
    seq |-> seq,
    deps |-> deps,
    cmd |-> cmd,
    cmds |-> <<cmd>>,
    status |-> status,
    committedDeps |-> cdeps,
    confRep |-> confRep,
    confInst |-> confInst,
    confStatus |-> confStatus ]

VARIABLES
  inst,
  lb,
  crtInstance,
  committedUpTo,
  execedUpTo,
  conflictsLast,
  conflictsLastWrite,
  maxSeqPerKey,
  maxSeqSeen,
  maxRecvBallot,
  isLeader,
  msgs,
  proposedByClient,
  cmdCatalog,
  serializedPairs,
  commitSeen,
  commitSnapshot,
  executedOrder,
  pendingFastPath,
  pendingRecoveryAccept,
  deferredPairs,
  stableMeta,
  crashed,
  members

CommittedAt(n, r, i) == inst[n][r][i].status \in {"COMMITTED", "EXECUTED"}
ExecutedAt(n, r, i) == inst[n][r][i].status = "EXECUTED"

DepForCmd(n, q, cmd) ==
  IF cmd.op = "GET"
  THEN conflictsLastWrite[n][q][cmd.key]
  ELSE conflictsLast[n][q][cmd.key]

DepsFromConflicts(n, rr, cmd) ==
  [q \in Replicas |-> IF q = rr THEN -1 ELSE DepForCmd(n, q, cmd)]

SeqFromConflicts(n, cmd) ==
  IF maxSeqPerKey[n][cmd.key] + 1 <= MaxSeq THEN maxSeqPerKey[n][cmd.key] + 1 ELSE MaxSeq

BumpLast(conf, n, rr, cmd, ii) ==
  [conf EXCEPT ![n][rr][cmd.key] = IF @ >= ii THEN @ ELSE ii]

BumpLastWrite(confW, n, rr, cmd, ii) ==
  [confW EXCEPT ![n][rr][cmd.key] = IF cmd.op = "GET" THEN @ ELSE IF @ >= ii THEN @ ELSE ii]

BumpMaxSeq(ms, n, cmd, seq) ==
  [ms EXCEPT ![n][cmd.key] = IF @ >= seq THEN @ ELSE seq]

HeadCmd(cmds) == cmds[1]

BatchConflict(cmds1, cmds2) ==
  \E i \in 1..Len(cmds1), j \in 1..Len(cmds2) :
    /\ cmds1[i].key = cmds2[j].key
    /\ ~(cmds1[i].op = "GET" /\ cmds2[j].op = "GET")

SlotLess(a, b) ==
  LET sa == inst[a.n][a.r][a.i].seq
      sb == inst[b.n][b.r][b.i].seq
      ida == HeadCmd(inst[a.n][a.r][a.i].cmds).id
      idb == HeadCmd(inst[b.n][b.r][b.i].cmds).id
  IN (sa < sb) \/ /\ sa = sb
                  /\ (a.r < b.r \/ /\ a.r = b.r /\ ida < idb)

AppendBatchIds(seq, cmds) ==
  IF Len(cmds) = 1 THEN Append(seq, cmds[1].id)
  ELSE Append(Append(seq, cmds[1].id), cmds[2].id)

MergeDeps(d1, d2) == [q \in Replicas |-> IF d1[q] >= d2[q] THEN d1[q] ELSE d2[q]]

InitialBallot(ballot, rr) == ballot = rr

CmdConflict(c1, c2) ==
  /\ c1.key = c2.key
  /\ ~(c1.op = "GET" /\ c2.op = "GET")

SeqContains(seq, x) == \E i \in 1..Len(seq) : seq[i] = x
SeqPos(seq, x) == CHOOSE i \in 1..Len(seq) : seq[i] = x
Before(seq, x, y) == SeqContains(seq, x) /\ SeqContains(seq, y) /\ SeqPos(seq, x) < SeqPos(seq, y)

vars == <<
  inst,
  lb,
  crtInstance,
  committedUpTo,
  execedUpTo,
  conflictsLast,
  conflictsLastWrite,
  maxSeqPerKey,
  maxSeqSeen,
  maxRecvBallot,
  isLeader,
  msgs,
  proposedByClient,
  cmdCatalog,
  serializedPairs,
  commitSeen,
  commitSnapshot,
  executedOrder,
  pendingFastPath,
  pendingRecoveryAccept,
  deferredPairs,
  stableMeta,
  crashed,
  members
>>

TypeOK ==
  /\ inst \in [Replicas -> [Replicas -> [Instances -> InstType]]]
  /\ lb \in [Replicas -> [Replicas -> [Instances -> LBType]]]
  /\ crtInstance \in [Replicas -> [Replicas -> DepVals]]
  /\ committedUpTo \in [Replicas -> [Replicas -> DepVals]]
  /\ execedUpTo \in [Replicas -> [Replicas -> DepVals]]
  /\ conflictsLast \in [Replicas -> [Replicas -> [Keys -> DepVals]]]
  /\ conflictsLastWrite \in [Replicas -> [Replicas -> [Keys -> DepVals]]]
  /\ maxSeqPerKey \in [Replicas -> [Keys -> 0..MaxSeq]]
  /\ maxSeqSeen \in [Replicas -> 0..MaxSeq]
  /\ maxRecvBallot \in [Replicas -> 0..MaxBallot]
  /\ isLeader \in [Replicas -> BOOLEAN]
  /\ msgs \subseteq MsgType
  /\ proposedByClient \subseteq CmdIds
  /\ cmdCatalog \in [CmdIds -> CmdType]
  /\ serializedPairs \subseteq (CmdIds \X CmdIds)
  /\ commitSeen \in [Replicas -> [Replicas -> [Instances -> BOOLEAN]]]
  /\ commitSnapshot \in [Replicas -> [Replicas -> [Instances -> CmdBatchType]]]
  /\ executedOrder \in [Replicas -> Seq(CmdIds)]
  /\ pendingFastPath \subseteq SlotType
  /\ pendingRecoveryAccept \subseteq SlotType
  /\ deferredPairs \subseteq (SlotType \X SlotType)
  /\ stableMeta \in [Replicas -> [Replicas -> [Instances -> [bal : 0..MaxBallot, vbal : 0..MaxBallot, status : Statuses, seq : 0..MaxSeq, deps : DepsType]]]]
  /\ crashed \in [Replicas -> BOOLEAN]
  /\ members \subseteq Replicas

Init ==
  /\ inst = [n \in Replicas |-> [r \in Replicas |-> [i \in Instances |-> DefaultInst]]]
  /\ lb = [n \in Replicas |-> [r \in Replicas |-> [i \in Instances |-> DefaultLB]]]
  /\ crtInstance = [n \in Replicas |-> [r \in Replicas |-> -1]]
  /\ committedUpTo = [n \in Replicas |-> [r \in Replicas |-> -1]]
  /\ execedUpTo = [n \in Replicas |-> [r \in Replicas |-> -1]]
  /\ conflictsLast = [n \in Replicas |-> [r \in Replicas |-> [k \in Keys |-> -1]]]
  /\ conflictsLastWrite = [n \in Replicas |-> [r \in Replicas |-> [k \in Keys |-> -1]]]
  /\ maxSeqPerKey = [n \in Replicas |-> [k \in Keys |-> 0]]
  /\ maxSeqSeen = [n \in Replicas |-> 0]
  /\ maxRecvBallot = [n \in Replicas |-> 0]
  /\ isLeader = [n \in Replicas |-> n = 1]
  /\ msgs = {}
  /\ proposedByClient = {}
  /\ cmdCatalog = [id \in CmdIds |-> NoCmd]
  /\ serializedPairs = {}
  /\ commitSeen = [n \in Replicas |-> [r \in Replicas |-> [i \in Instances |-> FALSE]]]
  /\ commitSnapshot = [n \in Replicas |-> [r \in Replicas |-> [i \in Instances |-> <<NoCmd>>]]]
  /\ executedOrder = [n \in Replicas |-> <<>>]
  /\ pendingFastPath = {}
  /\ pendingRecoveryAccept = {}
  /\ deferredPairs = {}
  /\ stableMeta = [n \in Replicas |-> [r \in Replicas |-> [i \in Instances |-> [bal |-> 0, vbal |-> 0, status |-> "NONE", seq |-> 0, deps |-> NilDeps]]]]
  /\ crashed = [n \in Replicas |-> FALSE]
  /\ members = Replicas

\* handlePropose/startPhase1: artifact/epaxos/epaxos/epaxos.go:742-801
ClientRequest ==
  \E n \in members, c \in Clients, id \in 1..MaxCmdId, op \in {"GET", "PUT", "SCAN"}, k \in Keys :
    /\ ~crashed[n]
    /\ crtInstance[n][n] < MaxInstance
    /\ LET i == crtInstance[n][n] + 1
           cmd == [id |-> id, client |-> c, op |-> op, key |-> k]
           seq == SeqFromConflicts(n, cmd)
           deps == DepsFromConflicts(n, n, cmd)
           last0 == conflictsLast[n][n][k]
           lastW0 == conflictsLastWrite[n][n][k]
           nowCommitted == { cid \in proposedByClient : \E rn \in Replicas : \E rr \in Replicas : \E ii \in Instances : CommittedAt(rn, rr, ii) /\ inst[rn][rr][ii].cmd.id = cid }
       IN
         /\ inst' = [inst EXCEPT ![n][n][i] =
             [ hasCmd |-> TRUE, cmd |-> cmd, cmds |-> <<cmd>>, bal |-> n, vbal |-> n,
               status |-> "PREACCEPTED", seq |-> seq, deps |-> deps, origin |-> "client" ]]
         /\ lb' = [lb EXCEPT ![n][n][i] =
             [ @ EXCEPT
                !.ballot = n,
                !.lastTriedBallot = n,
                !.status = "PREACCEPTED",
                !.seq = seq,
                !.deps = deps,
                !.allEqual = TRUE,
                !.preAcceptOKs = 0,
                !.acceptOKs = 0,
                !.nacks = 0,
                !.preparing = FALSE,
                !.tryingToPreAccept = FALSE,
                !.tpaReps = 0,
                !.tpaAccepted = FALSE,
                !.leaderResponded = FALSE,
                !.committedDeps = NilDeps,
                !.prepareAcks = {},
                !.possibleQuorum = [q \in Replicas |-> TRUE] ] ]
         /\ crtInstance' = [crtInstance EXCEPT ![n][n] = i]
         /\ conflictsLast' = [conflictsLast EXCEPT ![n][n][k] = IF last0 >= i THEN last0 ELSE i]
         /\ conflictsLastWrite' = [conflictsLastWrite EXCEPT ![n][n][k] = IF op = "GET" THEN lastW0 ELSE IF lastW0 >= i THEN lastW0 ELSE i]
         /\ maxSeqPerKey' = [maxSeqPerKey EXCEPT ![n][k] = IF @ >= seq THEN @ ELSE seq]
         /\ maxSeqSeen' = [maxSeqSeen EXCEPT ![n] = IF @ >= seq THEN @ ELSE seq]
         /\ maxRecvBallot' = maxRecvBallot
         /\ isLeader' = isLeader
         /\ proposedByClient' = proposedByClient \cup {id}
         /\ cmdCatalog' = [cmdCatalog EXCEPT ![id] = cmd]
         /\ serializedPairs' = serializedPairs \cup UNION { IF CmdConflict(cmdCatalog[cid], cmd) THEN {<<cid, id>>} ELSE {} : cid \in nowCommitted }
         /\ msgs' = msgs \cup { MkMsg("PreAccept", n, q, n, i, n, n, seq, deps, cmd, "PREACCEPTED", committedUpTo[n], -1, -1, "NONE") : q \in members \ {n} }
         /\ pendingFastPath' = pendingFastPath
         /\ pendingRecoveryAccept' = pendingRecoveryAccept
         /\ deferredPairs' = deferredPairs
         /\ stableMeta' = [stableMeta EXCEPT ![n][n][i] = [bal |-> n, vbal |-> n, status |-> "PREACCEPTED", seq |-> seq, deps |-> deps]]
         /\ crashed' = crashed
         /\ members' = members
         /\ commitSeen' = commitSeen
         /\ commitSnapshot' = commitSnapshot
         /\ executedOrder' = executedOrder
         /\ committedUpTo' = committedUpTo
         /\ execedUpTo' = execedUpTo

\* implementation-level batching analogue for handlePropose/startPhase1
ClientRequestBatch ==
  \E n \in members, c \in Clients, id1 \in 1..MaxCmdId, id2 \in 1..MaxCmdId, op1 \in {"GET", "PUT", "SCAN"}, op2 \in {"GET", "PUT", "SCAN"}, k1 \in Keys, k2 \in Keys :
    /\ ~crashed[n]
    /\ id1 # id2
    /\ crtInstance[n][n] < MaxInstance
    /\ LET i == crtInstance[n][n] + 1
           cmd1 == [id |-> id1, client |-> c, op |-> op1, key |-> k1]
           cmd2 == [id |-> id2, client |-> c, op |-> op2, key |-> k2]
           cmds == <<cmd1, cmd2>>
           seq1 == SeqFromConflicts(n, cmd1)
           seq2 == SeqFromConflicts(n, cmd2)
           seq == IF seq1 >= seq2 THEN seq1 ELSE seq2
           deps == MergeDeps(DepsFromConflicts(n, n, cmd1), DepsFromConflicts(n, n, cmd2))
           nowCommitted == { cid \in proposedByClient : \E rn \in Replicas : \E rr \in Replicas : \E ii \in Instances : CommittedAt(rn, rr, ii) /\ inst[rn][rr][ii].cmd.id = cid }
       IN
         /\ inst' = [inst EXCEPT ![n][n][i] =
             [ hasCmd |-> TRUE, cmd |-> cmd1, cmds |-> cmds, bal |-> n, vbal |-> n,
               status |-> "PREACCEPTED", seq |-> seq, deps |-> deps, origin |-> "client" ]]
         /\ lb' = [lb EXCEPT ![n][n][i] =
             [ @ EXCEPT
                !.ballot = n,
                !.lastTriedBallot = n,
                !.status = "PREACCEPTED",
                !.seq = seq,
                !.deps = deps,
                !.allEqual = TRUE,
                !.preAcceptOKs = 0,
                !.acceptOKs = 0,
                !.nacks = 0,
                !.preparing = FALSE,
                !.tryingToPreAccept = FALSE,
                !.tpaReps = 0,
                !.tpaAccepted = FALSE,
                !.leaderResponded = FALSE,
                !.committedDeps = NilDeps,
                !.prepareAcks = {},
                !.possibleQuorum = [q \in Replicas |-> TRUE] ] ]
         /\ crtInstance' = [crtInstance EXCEPT ![n][n] = i]
         /\ conflictsLast' = BumpLast(BumpLast(conflictsLast, n, n, cmd1, i), n, n, cmd2, i)
         /\ conflictsLastWrite' = BumpLastWrite(BumpLastWrite(conflictsLastWrite, n, n, cmd1, i), n, n, cmd2, i)
         /\ maxSeqPerKey' = BumpMaxSeq(BumpMaxSeq(maxSeqPerKey, n, cmd1, seq), n, cmd2, seq)
         /\ maxSeqSeen' = [maxSeqSeen EXCEPT ![n] = IF @ >= seq THEN @ ELSE seq]
         /\ maxRecvBallot' = maxRecvBallot
         /\ isLeader' = isLeader
         /\ proposedByClient' = proposedByClient \cup {id1, id2}
         /\ cmdCatalog' = [cmdCatalog EXCEPT ![id1] = cmd1, ![id2] = cmd2]
         /\ serializedPairs' =
              serializedPairs
              \cup UNION { IF CmdConflict(cmdCatalog[cid], cmd1) THEN {<<cid, id1>>} ELSE {} : cid \in nowCommitted }
              \cup UNION { IF CmdConflict(cmdCatalog[cid], cmd2) THEN {<<cid, id2>>} ELSE {} : cid \in nowCommitted }
              \cup IF CmdConflict(cmd1, cmd2) THEN {<<id1, id2>>} ELSE {}
         /\ msgs' = msgs \cup { [MkMsg("PreAccept", n, q, n, i, n, n, seq, deps, cmd1, "PREACCEPTED", committedUpTo[n], -1, -1, "NONE") EXCEPT !.cmds = cmds] : q \in members \ {n} }
         /\ pendingFastPath' = pendingFastPath
         /\ pendingRecoveryAccept' = pendingRecoveryAccept
         /\ deferredPairs' = deferredPairs
         /\ stableMeta' = [stableMeta EXCEPT ![n][n][i] = [bal |-> n, vbal |-> n, status |-> "PREACCEPTED", seq |-> seq, deps |-> deps]]
         /\ crashed' = crashed
         /\ members' = members
         /\ commitSeen' = commitSeen
         /\ commitSnapshot' = commitSnapshot
         /\ executedOrder' = executedOrder
         /\ committedUpTo' = committedUpTo
         /\ execedUpTo' = execedUpTo

\* deterministic wrapper used by Trace spec to reduce branching
ClientRequestOn(n, c, id, op, k, iWanted) ==
  /\ n \in members
  /\ c \in Clients
  /\ id \in 1..MaxCmdId
  /\ op \in {"GET", "PUT", "SCAN"}
  /\ k \in Keys
  /\ iWanted \in Instances
  /\ crtInstance[n][n] + 1 = iWanted
  /\ ClientRequest
  /\ crtInstance'[n][n] = iWanted
  /\ inst'[n][n][iWanted].hasCmd
  /\ inst'[n][n][iWanted].cmd = [id |-> id, client |-> c, op |-> op, key |-> k]
  /\ inst'[n][n][iWanted].cmds = <<[id |-> id, client |-> c, op |-> op, key |-> k]>>

\* client submit event (client-side send) modeled as explicit no-op step for trace alignment
ClientSubmit ==
  /\ UNCHANGED vars

\* handlePreAccept: artifact/epaxos/epaxos/epaxos.go:803-871
PreAccept ==
  \E m \in msgs :
    /\ m.typ = "PreAccept"
    /\ ~crashed[m.to]
    /\ LET n == m.to
           ii == m.ii
           rr == m.rr
           cur == inst[n][rr][ii]
           stale == m.ballot < cur.bal
           seq0 == SeqFromConflicts(n, m.cmd)
           deps0 == DepsFromConflicts(n, rr, m.cmd)
           changed == (seq0 # m.seq) \/ (deps0 # m.deps)
           newStatus == IF changed THEN "PREACCEPTED" ELSE "PREACCEPTED_EQ"
           rowToWrite == IF cur.status \in {"ACCEPTED", "COMMITTED", "EXECUTED"} /\ ~cur.hasCmd THEN m.from ELSE rr
           seqUsed == IF rowToWrite = rr /\ ~stale /\ ~(cur.status \in {"ACCEPTED", "COMMITTED", "EXECUTED"}) THEN seq0 ELSE cur.seq
           depsUsed == IF rowToWrite = rr /\ ~stale /\ ~(cur.status \in {"ACCEPTED", "COMMITTED", "EXECUTED"}) THEN deps0 ELSE cur.deps
           statUsed == IF rowToWrite = rr /\ ~stale /\ ~(cur.status \in {"ACCEPTED", "COMMITTED", "EXECUTED"}) THEN newStatus ELSE cur.status
           last0 == conflictsLast[n][rr][m.cmd.key]
           lastW0 == conflictsLastWrite[n][rr][m.cmd.key]
           crtNew == IF crtInstance[n][rr] >= ii THEN crtInstance[n][rr] ELSE ii
       IN
         /\ msgs' = (msgs \ {m}) \cup
              IF stale THEN {}
              ELSE { [MkMsg("PreAcceptReply", n, m.from, rr, ii,
                            IF stale THEN cur.bal ELSE m.ballot,
                            IF stale THEN cur.vbal ELSE IF rowToWrite = rr /\ ~(cur.status \in {"ACCEPTED", "COMMITTED", "EXECUTED"}) THEN m.ballot ELSE cur.vbal,
                            seqUsed, depsUsed, m.cmd, statUsed, committedUpTo[n], -1, -1, "NONE") EXCEPT !.cmds = m.cmds] }
         /\ inst' =
              IF stale THEN inst
              ELSE IF rowToWrite # rr
                   THEN [inst EXCEPT ![n][rowToWrite][ii] = [@ EXCEPT !.hasCmd = TRUE, !.cmd = m.cmd, !.cmds = m.cmds ]]
                   ELSE IF cur.status \in {"ACCEPTED", "COMMITTED", "EXECUTED"}
                        THEN inst
                        ELSE [inst EXCEPT ![n][rr][ii] =
                               [ hasCmd |-> TRUE, cmd |-> m.cmd, cmds |-> m.cmds, bal |-> m.ballot, vbal |-> m.ballot,
                                 status |-> newStatus, seq |-> seq0, deps |-> deps0, origin |-> cur.origin ]]
         /\ lb' = lb
         /\ crtInstance' = IF stale THEN crtInstance ELSE [crtInstance EXCEPT ![n][rr] = crtNew]
         /\ maxRecvBallot' = [maxRecvBallot EXCEPT ![n] = IF @ >= m.ballot THEN @ ELSE m.ballot]
         /\ maxSeqSeen' = [maxSeqSeen EXCEPT ![n] = IF @ >= m.seq THEN @ ELSE m.seq]
         /\ conflictsLast' =
              IF stale THEN conflictsLast ELSE [conflictsLast EXCEPT ![n][rr][m.cmd.key] = IF last0 >= ii THEN last0 ELSE ii]
         /\ conflictsLastWrite' =
              IF stale THEN conflictsLastWrite ELSE
                [conflictsLastWrite EXCEPT ![n][rr][m.cmd.key] = IF m.cmd.op = "GET" THEN lastW0 ELSE IF lastW0 >= ii THEN lastW0 ELSE ii]
         /\ maxSeqPerKey' = IF stale THEN maxSeqPerKey ELSE [maxSeqPerKey EXCEPT ![n][m.cmd.key] = IF @ >= m.seq THEN @ ELSE m.seq]
         /\ isLeader' = isLeader
         /\ proposedByClient' = proposedByClient
         /\ cmdCatalog' = cmdCatalog
         /\ serializedPairs' = serializedPairs
         /\ pendingFastPath' = pendingFastPath
         /\ pendingRecoveryAccept' = pendingRecoveryAccept
         /\ deferredPairs' = deferredPairs
         /\ stableMeta' = IF stale THEN stableMeta ELSE [stableMeta EXCEPT ![n][rr][ii] =
              [ bal |-> IF rowToWrite = rr /\ ~(cur.status \in {"ACCEPTED", "COMMITTED", "EXECUTED"}) THEN m.ballot ELSE cur.vbal,
                vbal |-> IF rowToWrite = rr /\ ~(cur.status \in {"ACCEPTED", "COMMITTED", "EXECUTED"}) THEN m.ballot ELSE cur.vbal,
                status |-> statUsed,
                seq |-> seqUsed,
                deps |-> depsUsed ]]
         /\ crashed' = crashed
         /\ members' = members
         /\ commitSeen' = commitSeen
         /\ commitSnapshot' = commitSnapshot
         /\ executedOrder' = executedOrder
         /\ committedUpTo' = committedUpTo
         /\ execedUpTo' = execedUpTo

\* handlePreAcceptReply: artifact/epaxos/epaxos/epaxos.go:873-1004
PreAcceptOK ==
  \E m \in msgs :
    /\ m.typ = "PreAcceptReply"
    /\ ~crashed[m.to]
    /\ LET n == m.to
           curLB == lb[n][m.rr][m.ii]
           ballotMatch == curLB.lastTriedBallot = m.ballot
           mergedSeq == IF curLB.seq >= m.seq THEN curLB.seq ELSE m.seq
           mergedDeps == MergeDeps(curLB.deps, m.deps)
           eqNow == (curLB.seq = m.seq /\ curLB.deps = m.deps)
           allEqNew == curLB.allEqual /\ eqNow
           oksNew == curLB.preAcceptOKs + 1
           initial == InitialBallot(curLB.lastTriedBallot, m.rr)
       IN
         /\ msgs' = msgs \ {m}
         /\ lb' =
            IF ~ballotMatch
            THEN [lb EXCEPT ![n][m.rr][m.ii].nacks = @ + 1]
            ELSE [lb EXCEPT ![n][m.rr][m.ii] =
                    [ @ EXCEPT
                      !.preAcceptOKs = oksNew,
                      !.seq = mergedSeq,
                      !.deps = mergedDeps,
                      !.allEqual = allEqNew,
                      !.ballot = IF @ >= m.vbal THEN @ ELSE m.vbal ] ]
         /\ pendingFastPath' =
            IF ballotMatch /\ oksNew >= (FastQuorum - 1) /\ allEqNew /\ initial
            THEN pendingFastPath \cup {Slot(n, m.rr, m.ii)}
            ELSE pendingFastPath
         /\ inst' = inst
         /\ crtInstance' = crtInstance
         /\ committedUpTo' = committedUpTo
         /\ execedUpTo' = execedUpTo
         /\ conflictsLast' = conflictsLast
         /\ conflictsLastWrite' = conflictsLastWrite
         /\ maxSeqPerKey' = maxSeqPerKey
         /\ maxSeqSeen' = maxSeqSeen
         /\ maxRecvBallot' = [maxRecvBallot EXCEPT ![n] = IF @ >= m.ballot THEN @ ELSE m.ballot]
         /\ isLeader' = isLeader
         /\ proposedByClient' = proposedByClient
         /\ cmdCatalog' = cmdCatalog
         /\ serializedPairs' = serializedPairs
         /\ pendingRecoveryAccept' = pendingRecoveryAccept
         /\ deferredPairs' = deferredPairs
         /\ stableMeta' = stableMeta
         /\ crashed' = crashed
         /\ members' = members
         /\ commitSeen' = commitSeen
         /\ commitSnapshot' = commitSnapshot
         /\ executedOrder' = executedOrder

\* fast-path commit branch: artifact/epaxos/epaxos/epaxos.go:946-977
FastPathCommit ==
  \E s \in pendingFastPath :
    /\ ~crashed[s.n]
    /\ LET n == s.n
           rr == s.r
           ii == s.i
           curLB == lb[n][rr][ii]
           cmd == inst[n][rr][ii].cmd
           seq == curLB.seq
           deps == curLB.deps
           cup0 == committedUpTo[n][rr]
           cup1 == IF cup0 + 1 = ii THEN ii ELSE cup0
           seen0 == commitSeen[n][rr][ii]
       IN
         /\ inst' = [inst EXCEPT ![n][rr][ii] = [@ EXCEPT !.status = "COMMITTED", !.bal = curLB.ballot, !.seq = seq, !.deps = deps ]]
         /\ lb' = [lb EXCEPT ![n][rr][ii].status = "COMMITTED"]
         /\ committedUpTo' = [committedUpTo EXCEPT ![n][rr] = cup1]
         /\ commitSeen' = [commitSeen EXCEPT ![n][rr][ii] = TRUE]
         /\ commitSnapshot' = IF seen0 THEN commitSnapshot ELSE [commitSnapshot EXCEPT ![n][rr][ii] = inst[n][rr][ii].cmds]
         /\ msgs' = msgs \cup { [MkMsg("Commit", n, q, rr, ii, curLB.ballot, curLB.ballot, seq, deps, cmd, "COMMITTED", committedUpTo[n], -1, -1, "NONE") EXCEPT !.cmds = inst[n][rr][ii].cmds] : q \in members \ {n} }
         /\ pendingFastPath' = pendingFastPath \ {s}
         /\ stableMeta' = [stableMeta EXCEPT ![n][rr][ii] = [bal |-> curLB.ballot, vbal |-> curLB.ballot, status |-> "COMMITTED", seq |-> seq, deps |-> deps]]
         /\ crtInstance' = crtInstance
         /\ execedUpTo' = execedUpTo
         /\ conflictsLast' = conflictsLast
         /\ conflictsLastWrite' = conflictsLastWrite
         /\ maxSeqPerKey' = maxSeqPerKey
         /\ maxSeqSeen' = maxSeqSeen
         /\ maxRecvBallot' = maxRecvBallot
         /\ isLeader' = isLeader
         /\ proposedByClient' = proposedByClient
         /\ cmdCatalog' = cmdCatalog
         /\ serializedPairs' = serializedPairs
         /\ pendingRecoveryAccept' = pendingRecoveryAccept
         /\ deferredPairs' = deferredPairs
         /\ crashed' = crashed
         /\ members' = members
         /\ executedOrder' = executedOrder

\* bcastAccept/handleAccept split: artifact/epaxos/epaxos/epaxos.go:564-583 and 1006-1041
Accept ==
  \E m \in msgs :
    /\ m.typ = "Accept"
    /\ ~crashed[m.to]
    /\ LET n == m.to
           cur == inst[n][m.rr][m.ii]
           crtNew == IF crtInstance[n][m.rr] >= m.ii THEN crtInstance[n][m.rr] ELSE m.ii
       IN
         /\ msgs' = (msgs \ {m}) \cup
              { [MkMsg("AcceptReply", n, m.from, m.rr, m.ii,
                       IF m.ballot < cur.bal THEN cur.bal ELSE m.ballot,
                       IF m.ballot < cur.bal THEN cur.vbal ELSE m.ballot,
                       m.seq, m.deps, m.cmd, cur.status, committedUpTo[n], -1, -1, "NONE") EXCEPT !.cmds = m.cmds] }
         /\ inst' =
              IF m.ballot < cur.bal \lor cur.status \in {"COMMITTED", "EXECUTED"}
              THEN inst
              ELSE [inst EXCEPT ![n][m.rr][m.ii] = [@ EXCEPT
                      !.deps = m.deps,
                      !.seq = m.seq,
                      !.bal = m.ballot,
                      !.vbal = m.ballot ]]
         /\ lb' = lb
         /\ crtInstance' = [crtInstance EXCEPT ![n][m.rr] = crtNew]
         /\ committedUpTo' = committedUpTo
         /\ execedUpTo' = execedUpTo
         /\ conflictsLast' = conflictsLast
         /\ conflictsLastWrite' = conflictsLastWrite
         /\ maxSeqPerKey' = maxSeqPerKey
         /\ maxSeqSeen' = maxSeqSeen
         /\ maxRecvBallot' = [maxRecvBallot EXCEPT ![n] = IF @ >= m.ballot THEN @ ELSE m.ballot]
         /\ isLeader' = isLeader
         /\ proposedByClient' = proposedByClient
         /\ cmdCatalog' = cmdCatalog
         /\ serializedPairs' = serializedPairs
         /\ pendingFastPath' = pendingFastPath
         /\ pendingRecoveryAccept' = pendingRecoveryAccept
         /\ deferredPairs' = deferredPairs
         /\ stableMeta' = [stableMeta EXCEPT ![n][m.rr][m.ii] = [bal |-> m.ballot, vbal |-> m.ballot, status |-> inst'[n][m.rr][m.ii].status, seq |-> m.seq, deps |-> m.deps]]
         /\ crashed' = crashed
         /\ members' = members
         /\ commitSeen' = commitSeen
         /\ commitSnapshot' = commitSnapshot
         /\ executedOrder' = executedOrder

\* handleAcceptReply: artifact/epaxos/epaxos/epaxos.go:1043-1102
AcceptOK ==
  \E m \in msgs :
    /\ m.typ = "AcceptReply"
    /\ ~crashed[m.to]
    /\ LET n == m.to
           curLB == lb[n][m.rr][m.ii]
           okBallot == (curLB.lastTriedBallot = m.ballot)
           oksNew == curLB.acceptOKs + 1
           quorum == oksNew + 1 > (Cardinality(Replicas) \div 2)
           cmd == inst[n][m.rr][m.ii].cmd
           cmds == inst[n][m.rr][m.ii].cmds
           seq == inst[n][m.rr][m.ii].seq
           deps == inst[n][m.rr][m.ii].deps
           cup0 == committedUpTo[n][m.rr]
           cup1 == IF cup0 + 1 = m.ii THEN m.ii ELSE cup0
           seen0 == commitSeen[n][m.rr][m.ii]
       IN
         /\ msgs' =
            IF okBallot /\ quorum
            THEN (msgs \ {m}) \cup { [MkMsg("Commit", n, q, m.rr, m.ii, m.ballot, m.ballot, seq, deps, cmd, "COMMITTED", committedUpTo[n], -1, -1, "NONE") EXCEPT !.cmds = cmds] : q \in members \ {n} }
            ELSE msgs \ {m}
         /\ lb' =
            IF okBallot
            THEN [lb EXCEPT ![n][m.rr][m.ii].acceptOKs = oksNew]
            ELSE lb
         /\ inst' =
            IF okBallot /\ quorum
            THEN [inst EXCEPT ![n][m.rr][m.ii].status = "COMMITTED"]
            ELSE inst
         /\ committedUpTo' =
            IF okBallot /\ quorum THEN [committedUpTo EXCEPT ![n][m.rr] = cup1] ELSE committedUpTo
         /\ commitSeen' = IF okBallot /\ quorum THEN [commitSeen EXCEPT ![n][m.rr][m.ii] = TRUE] ELSE commitSeen
         /\ commitSnapshot' = IF okBallot /\ quorum /\ ~seen0 THEN [commitSnapshot EXCEPT ![n][m.rr][m.ii] = cmds] ELSE commitSnapshot
         /\ crtInstance' = crtInstance
         /\ execedUpTo' = execedUpTo
         /\ conflictsLast' = conflictsLast
         /\ conflictsLastWrite' = conflictsLastWrite
         /\ maxSeqPerKey' = maxSeqPerKey
         /\ maxSeqSeen' = maxSeqSeen
         /\ maxRecvBallot' = [maxRecvBallot EXCEPT ![n] = IF @ >= m.ballot THEN @ ELSE m.ballot]
         /\ isLeader' = isLeader
         /\ proposedByClient' = proposedByClient
         /\ cmdCatalog' = cmdCatalog
         /\ serializedPairs' = serializedPairs
         /\ pendingFastPath' = pendingFastPath
         /\ pendingRecoveryAccept' = pendingRecoveryAccept
         /\ deferredPairs' = deferredPairs
         /\ stableMeta' = IF okBallot /\ quorum THEN [stableMeta EXCEPT ![n][m.rr][m.ii] = [bal |-> m.ballot, vbal |-> m.ballot, status |-> "COMMITTED", seq |-> seq, deps |-> deps]] ELSE stableMeta
         /\ crashed' = crashed
         /\ members' = members
         /\ executedOrder' = executedOrder

\* handleCommit: artifact/epaxos/epaxos/epaxos.go:1104-1155
Commit ==
  \E m \in msgs :
    /\ m.typ = "Commit"
    /\ ~crashed[m.to]
    /\ LET n == m.to
           cur == inst[n][m.rr][m.ii]
           canApply == ~(cur.status \in {"COMMITTED", "EXECUTED"}) /\ m.ballot >= cur.bal
           crtNew == IF crtInstance[n][m.rr] >= m.ii THEN crtInstance[n][m.rr] ELSE m.ii
           cup0 == committedUpTo[n][m.rr]
           cup1 == IF cup0 + 1 = m.ii THEN m.ii ELSE cup0
           seen0 == commitSeen[n][m.rr][m.ii]
           origin1 == IF m.cmd.op = "NONE" THEN "recovery_noop" ELSE "client"
           last0 == conflictsLast[n][m.rr][m.cmd.key]
           lastW0 == conflictsLastWrite[n][m.rr][m.cmd.key]
       IN
         /\ msgs' = msgs \ {m}
         /\ inst' =
            IF canApply
            THEN [inst EXCEPT ![n][m.rr][m.ii] = [ hasCmd |-> TRUE, cmd |-> m.cmd, cmds |-> m.cmds, bal |-> m.ballot, vbal |-> m.ballot,
                                                    status |-> "COMMITTED", seq |-> m.seq, deps |-> m.deps, origin |-> origin1 ]]
            ELSE inst
         /\ crtInstance' = [crtInstance EXCEPT ![n][m.rr] = crtNew]
         /\ committedUpTo' = IF canApply THEN [committedUpTo EXCEPT ![n][m.rr] = cup1] ELSE committedUpTo
         /\ commitSeen' = IF canApply THEN [commitSeen EXCEPT ![n][m.rr][m.ii] = TRUE] ELSE commitSeen
         /\ commitSnapshot' = IF canApply /\ ~seen0 THEN [commitSnapshot EXCEPT ![n][m.rr][m.ii] = m.cmds] ELSE commitSnapshot
         /\ conflictsLast' = IF canApply THEN [conflictsLast EXCEPT ![n][m.rr][m.cmd.key] = IF last0 >= m.ii THEN last0 ELSE m.ii] ELSE conflictsLast
         /\ conflictsLastWrite' = IF canApply THEN [conflictsLastWrite EXCEPT ![n][m.rr][m.cmd.key] = IF m.cmd.op = "GET" THEN lastW0 ELSE IF lastW0 >= m.ii THEN lastW0 ELSE m.ii] ELSE conflictsLastWrite
         /\ maxSeqPerKey' = IF canApply THEN [maxSeqPerKey EXCEPT ![n][m.cmd.key] = IF @ >= m.seq THEN @ ELSE m.seq] ELSE maxSeqPerKey
         /\ maxSeqSeen' = IF canApply THEN [maxSeqSeen EXCEPT ![n] = IF @ >= m.seq THEN @ ELSE m.seq] ELSE maxSeqSeen
         /\ maxRecvBallot' = [maxRecvBallot EXCEPT ![n] = IF @ >= m.ballot THEN @ ELSE m.ballot]
         /\ lb' = lb
         /\ execedUpTo' = execedUpTo
         /\ isLeader' = isLeader
         /\ proposedByClient' = proposedByClient
         /\ cmdCatalog' = cmdCatalog
         /\ serializedPairs' = serializedPairs
         /\ pendingFastPath' = pendingFastPath
         /\ pendingRecoveryAccept' = pendingRecoveryAccept
         /\ deferredPairs' = deferredPairs
         /\ stableMeta' = IF canApply THEN [stableMeta EXCEPT ![n][m.rr][m.ii] = [bal |-> m.ballot, vbal |-> m.ballot, status |-> "COMMITTED", seq |-> m.seq, deps |-> m.deps]] ELSE stableMeta
         /\ crashed' = crashed
         /\ members' = members
         /\ executedOrder' = executedOrder

\* executeCommands/strongconnect (coarse): artifact/epaxos/epaxos/exec.go:25-151 and epaxos.go:385-433
Execute ==
  \E n \in members, rr \in Replicas, ii \in Instances :
    /\ ~crashed[n]
    /\ inst[n][rr][ii].status = "COMMITTED"
    /\ \A q \in Replicas : inst[n][rr][ii].deps[q] <= committedUpTo[n][q]
    /\ \A rr2 \in Replicas, ii2 \in Instances :
         /\ inst[n][rr2][ii2].status = "COMMITTED"
         /\ ~ExecutedAt(n, rr2, ii2)
         /\ BatchConflict(inst[n][rr2][ii2].cmds, inst[n][rr][ii].cmds)
         => ~SlotLess(Slot(n, rr2, ii2), Slot(n, rr, ii))
    /\ LET cmds == inst[n][rr][ii].cmds
           e0 == execedUpTo[n][rr]
           e1 == IF e0 + 1 = ii THEN ii ELSE e0
       IN
         /\ inst' = [inst EXCEPT ![n][rr][ii].status = "EXECUTED"]
         /\ execedUpTo' = [execedUpTo EXCEPT ![n][rr] = e1]
         /\ executedOrder' = [executedOrder EXCEPT ![n] = AppendBatchIds(@, cmds)]
         /\ lb' = lb
         /\ crtInstance' = crtInstance
         /\ committedUpTo' = committedUpTo
         /\ conflictsLast' = conflictsLast
         /\ conflictsLastWrite' = conflictsLastWrite
         /\ maxSeqPerKey' = maxSeqPerKey
         /\ maxSeqSeen' = maxSeqSeen
         /\ maxRecvBallot' = maxRecvBallot
         /\ isLeader' = isLeader
         /\ msgs' = msgs
         /\ proposedByClient' = proposedByClient
         /\ cmdCatalog' = cmdCatalog
         /\ serializedPairs' = serializedPairs
         /\ pendingFastPath' = pendingFastPath
         /\ pendingRecoveryAccept' = pendingRecoveryAccept
         /\ deferredPairs' = deferredPairs
         /\ stableMeta' = stableMeta
         /\ crashed' = crashed
         /\ members' = members
         /\ commitSeen' = commitSeen
         /\ commitSnapshot' = commitSnapshot

\* startRecoveryForInstance + bcastPrepare: artifact/epaxos/epaxos/epaxos.go:1169-1214 and 469-496
Prepare ==
  \E n \in members, rr \in Replicas, ii \in Instances :
    /\ ~crashed[n]
    /\ inst[n][rr][ii].status \notin {"COMMITTED", "EXECUTED"} \/ ~inst[n][rr][ii].hasCmd
    /\ LET b == IF maxRecvBallot[n] + 1 <= MaxBallot THEN maxRecvBallot[n] + 1 ELSE MaxBallot
           cur == inst[n][rr][ii]
       IN
         /\ lb' = [lb EXCEPT ![n][rr][ii] =
             [ @ EXCEPT
                !.preparing = TRUE,
                !.lastTriedBallot = b,
                !.ballot = cur.vbal,
                !.seq = cur.seq,
                !.deps = cur.deps,
                !.status = cur.status,
                !.prepareAcks = {n},
                !.leaderResponded = (n = rr) ]]
         /\ inst' = [inst EXCEPT ![n][rr][ii].bal = b, ![n][rr][ii].vbal = b]
         /\ msgs' = msgs \cup { [MkMsg("Prepare", n, q, rr, ii, b, b, cur.seq, cur.deps, cur.cmd, cur.status, committedUpTo[n], -1, -1, "NONE") EXCEPT !.cmds = cur.cmds] : q \in members \ {n} }
         /\ maxRecvBallot' = [maxRecvBallot EXCEPT ![n] = IF @ >= b THEN @ ELSE b]
         /\ crtInstance' = crtInstance
         /\ committedUpTo' = committedUpTo
         /\ execedUpTo' = execedUpTo
         /\ conflictsLast' = conflictsLast
         /\ conflictsLastWrite' = conflictsLastWrite
         /\ maxSeqPerKey' = maxSeqPerKey
         /\ maxSeqSeen' = maxSeqSeen
         /\ isLeader' = [isLeader EXCEPT ![n] = TRUE]
         /\ proposedByClient' = proposedByClient
         /\ cmdCatalog' = cmdCatalog
         /\ serializedPairs' = serializedPairs
         /\ pendingFastPath' = pendingFastPath
         /\ pendingRecoveryAccept' = pendingRecoveryAccept
         /\ deferredPairs' = deferredPairs
         /\ stableMeta' = stableMeta
         /\ crashed' = crashed
         /\ members' = members
         /\ commitSeen' = commitSeen
         /\ commitSnapshot' = commitSnapshot
         /\ executedOrder' = executedOrder

\* handlePrepare join-branch and reply generation: artifact/epaxos/epaxos/epaxos.go:1216-1253
Join ==
  \E m \in msgs :
    /\ m.typ = "Prepare"
    /\ ~crashed[m.to]
    /\ LET n == m.to
           cur == inst[n][m.rr][m.ii]
           joined == m.ballot > cur.bal
           b1 == IF joined THEN m.ballot ELSE cur.bal
       IN
         /\ inst' = [inst EXCEPT ![n][m.rr][m.ii].bal = b1]
         /\ msgs' = (msgs \ {m}) \cup { [MkMsg("PrepareReply", n, m.from, m.rr, m.ii, b1, inst'[n][m.rr][m.ii].vbal,
                                              inst'[n][m.rr][m.ii].seq, inst'[n][m.rr][m.ii].deps,
                                              inst'[n][m.rr][m.ii].cmd, inst'[n][m.rr][m.ii].status,
                                              committedUpTo[n], -1, -1, "NONE") EXCEPT !.cmds = inst'[n][m.rr][m.ii].cmds] }
         /\ members' = members \cup {m.from}
         /\ lb' = lb
         /\ crtInstance' = crtInstance
         /\ committedUpTo' = committedUpTo
         /\ execedUpTo' = execedUpTo
         /\ conflictsLast' = conflictsLast
         /\ conflictsLastWrite' = conflictsLastWrite
         /\ maxSeqPerKey' = maxSeqPerKey
         /\ maxSeqSeen' = maxSeqSeen
         /\ maxRecvBallot' = [maxRecvBallot EXCEPT ![n] = IF @ >= m.ballot THEN @ ELSE m.ballot]
         /\ isLeader' = isLeader
         /\ proposedByClient' = proposedByClient
         /\ cmdCatalog' = cmdCatalog
         /\ serializedPairs' = serializedPairs
         /\ pendingFastPath' = pendingFastPath
         /\ pendingRecoveryAccept' = pendingRecoveryAccept
         /\ deferredPairs' = deferredPairs
         /\ stableMeta' = stableMeta
         /\ crashed' = crashed
         /\ commitSeen' = commitSeen
         /\ commitSnapshot' = commitSnapshot
         /\ executedOrder' = executedOrder

\* handlePrepareReply + subcases: artifact/epaxos/epaxos/epaxos.go:1255-1373
PrepareOK ==
  \E m \in msgs :
    /\ m.typ = "PrepareReply"
    /\ ~crashed[m.to]
    /\ LET n == m.to
           curLB == lb[n][m.rr][m.ii]
           ok == curLB.preparing /\ m.ballot = curLB.lastTriedBallot
           acks1 == curLB.prepareAcks \cup {m.from}
           b1 == IF curLB.ballot >= m.vbal THEN curLB.ballot ELSE m.vbal
           st1 == IF curLB.ballot >= m.vbal THEN curLB.status ELSE m.status
           seq1 == IF curLB.ballot >= m.vbal THEN curLB.seq ELSE m.seq
           deps1 == IF curLB.ballot >= m.vbal THEN curLB.deps ELSE m.deps
           quorum == Cardinality(acks1) >= SlowQuorum
           subAccept == st1 \in {"ACCEPTED", "PREACCEPTED", "PREACCEPTED_EQ"}
           preAcceptCount == curLB.preAcceptOKs + IF subAccept THEN 1 ELSE 0
           cond3 == subAccept /\ preAcceptCount >= (SlowQuorum - 1) /\ ~curLB.leaderResponded /\ curLB.allEqual
           cond4 == subAccept /\ preAcceptCount >= (SlowQuorum - 1) /\ ~curLB.leaderResponded /\ curLB.allEqual
           subCase == IF st1 \in {"COMMITTED", "EXECUTED"} THEN 1
                     ELSE IF st1 = "ACCEPTED" THEN 2
                     ELSE IF cond3 THEN 3
                     ELSE IF cond4 THEN 4
                     ELSE IF subAccept THEN 5
                     ELSE 6
           curInst == inst[n][m.rr][m.ii]
           noopCmd == [id |-> 0, client |-> 0, op |-> "NONE", key |-> CHOOSE k \in Keys : TRUE]
           seqNoop == SeqFromConflicts(n, noopCmd)
           depsNoop == DepsFromConflicts(n, m.rr, noopCmd)
       IN
         /\ msgs' =
            IF ok /\ quorum /\ ~subAccept /\ st1 = "NONE"
            THEN (msgs \ {m}) \cup { MkMsg("PreAccept", n, q, m.rr, m.ii, curLB.lastTriedBallot, curLB.lastTriedBallot, seqNoop, depsNoop, noopCmd, "PREACCEPTED", committedUpTo[n], -1, -1, "NONE") : q \in members \ {n} }
            ELSE msgs \ {m}
         /\ lb' =
            IF ~ok
            THEN [lb EXCEPT ![n][m.rr][m.ii].nacks = @ + 1]
            ELSE [lb EXCEPT ![n][m.rr][m.ii] =
                    [ @ EXCEPT
                      !.prepareAcks = acks1,
                      !.ballot = b1,
                      !.status = st1,
                      !.seq = seq1,
                      !.deps = deps1,
                      !.recoverySubcase = IF quorum THEN subCase ELSE @,
                      !.preparing = IF quorum THEN FALSE ELSE @ ] ]
         /\ pendingRecoveryAccept' = IF ok /\ quorum /\ subAccept THEN pendingRecoveryAccept \cup {Slot(n, m.rr, m.ii)} ELSE pendingRecoveryAccept
         /\ inst' =
            IF ok /\ quorum /\ ~subAccept /\ st1 = "NONE"
            THEN [inst EXCEPT ![n][m.rr][m.ii] = [ hasCmd |-> TRUE, cmd |-> noopCmd, cmds |-> <<noopCmd>>, bal |-> curLB.lastTriedBallot, vbal |-> curLB.lastTriedBallot,
                                                   status |-> "PREACCEPTED", seq |-> seqNoop, deps |-> depsNoop, origin |-> "recovery_noop" ]]
            ELSE [inst EXCEPT ![n][m.rr][m.ii] = [@ EXCEPT !.bal = curLB.lastTriedBallot, !.vbal = curLB.lastTriedBallot, !.seq = seq1, !.deps = deps1, !.status = st1 ]]
         /\ pendingFastPath' = pendingFastPath
         /\ crtInstance' = crtInstance
         /\ committedUpTo' = committedUpTo
         /\ execedUpTo' = execedUpTo
         /\ conflictsLast' = conflictsLast
         /\ conflictsLastWrite' = conflictsLastWrite
         /\ maxSeqPerKey' = maxSeqPerKey
         /\ maxSeqSeen' = maxSeqSeen
         /\ maxRecvBallot' = [maxRecvBallot EXCEPT ![n] = IF @ >= m.ballot THEN @ ELSE m.ballot]
         /\ isLeader' = isLeader
         /\ proposedByClient' = proposedByClient
         /\ cmdCatalog' = cmdCatalog
         /\ serializedPairs' = serializedPairs
         /\ deferredPairs' = deferredPairs
         /\ stableMeta' = stableMeta
         /\ crashed' = crashed
         /\ members' = members
         /\ commitSeen' = commitSeen
         /\ commitSnapshot' = commitSnapshot
         /\ executedOrder' = executedOrder

\* explicit try-preaccept broadcast path: artifact/epaxos/epaxos/epaxos.go:1375-1410
TryPreAccept ==
  \E n \in members, rr \in Replicas, ii \in Instances :
    /\ ~crashed[n]
    /\ lb[n][rr][ii].status = "PREACCEPTED_EQ"
    /\ lb[n][rr][ii].lastTriedBallot > 0
    /\ LET b == lb[n][rr][ii].lastTriedBallot
           seq == lb[n][rr][ii].seq
           deps == lb[n][rr][ii].deps
           cmd == inst[n][rr][ii].cmd
       IN
         /\ msgs' = msgs \cup { [MkMsg("TryPreAccept", n, q, rr, ii, b, b, seq, deps, cmd, "PREACCEPTED_EQ", committedUpTo[n], -1, -1, "NONE") EXCEPT !.cmds = inst[n][rr][ii].cmds] : q \in members \ {n} }
         /\ lb' = [lb EXCEPT ![n][rr][ii] =
                     [ @ EXCEPT
                       !.tryingToPreAccept = TRUE,
                       !.tpaReps = 0,
                       !.preAcceptOKs = 0,
                       !.tpaAccepted = FALSE,
                       !.possibleQuorum = [q \in Replicas |-> TRUE] ] ]
         /\ UNCHANGED <<inst, crtInstance, committedUpTo, execedUpTo, conflictsLast, conflictsLastWrite,
                       maxSeqPerKey, maxSeqSeen, maxRecvBallot, isLeader, proposedByClient, cmdCatalog,
                       serializedPairs, commitSeen, commitSnapshot, executedOrder, pendingFastPath,
                       pendingRecoveryAccept, deferredPairs, stableMeta, crashed, members>>

\* explicit try-preaccept reply handling with conflict/defer bookkeeping
TryPreAcceptReply ==
  \E m \in msgs :
    /\ m.typ = "TryPreAccept"
    /\ ~crashed[m.to]
    /\ LET n == m.to
           cur == inst[n][m.rr][m.ii]
           key == HeadCmd(m.cmds).key
           confRep == CHOOSE r \in Replicas : conflictsLast[n][r][key] > m.deps[r]
           hasConflict == \E r \in Replicas : conflictsLast[n][r][key] > m.deps[r]
           confInst == IF hasConflict THEN conflictsLast[n][confRep][key] ELSE -1
           confStatus == "NONE"
           writeNew == cur.status = "NONE" /\ ~hasConflict
       IN
         /\ msgs' = (msgs \ {m}) \cup
              { [MkMsg("TryPreAcceptReply", n, m.from, m.rr, m.ii, m.ballot, cur.vbal, m.seq, m.deps, m.cmd,
                       cur.status, committedUpTo[n], IF hasConflict THEN confRep ELSE -1, confInst, confStatus) EXCEPT !.cmds = m.cmds] }
         /\ inst' =
              IF writeNew
              THEN [inst EXCEPT ![n][m.rr][m.ii] =
                    [ hasCmd |-> TRUE, cmd |-> m.cmd, cmds |-> m.cmds, bal |-> m.ballot, vbal |-> m.ballot,
                      status |-> "PREACCEPTED", seq |-> m.seq, deps |-> m.deps, origin |-> cur.origin ]]
              ELSE [inst EXCEPT ![n][m.rr][m.ii].bal = IF m.ballot > cur.bal THEN m.ballot ELSE cur.bal]
         /\ lb' = lb
         /\ crtInstance' = [crtInstance EXCEPT ![n][m.rr] = IF @ >= m.ii THEN @ ELSE m.ii]
         /\ committedUpTo' = committedUpTo
         /\ execedUpTo' = execedUpTo
         /\ conflictsLast' = conflictsLast
         /\ conflictsLastWrite' = conflictsLastWrite
         /\ maxSeqPerKey' = maxSeqPerKey
         /\ maxSeqSeen' = [maxSeqSeen EXCEPT ![n] = IF @ >= m.seq THEN @ ELSE m.seq]
         /\ maxRecvBallot' = [maxRecvBallot EXCEPT ![n] = IF @ >= m.ballot THEN @ ELSE m.ballot]
         /\ isLeader' = isLeader
         /\ proposedByClient' = proposedByClient
         /\ cmdCatalog' = cmdCatalog
         /\ serializedPairs' = serializedPairs
         /\ pendingFastPath' = pendingFastPath
         /\ pendingRecoveryAccept' = pendingRecoveryAccept
         /\ deferredPairs' = deferredPairs
         /\ stableMeta' = stableMeta
         /\ crashed' = crashed
         /\ members' = members
         /\ commitSeen' = commitSeen
         /\ commitSnapshot' = commitSnapshot
         /\ executedOrder' = executedOrder

\* leader-side processing for TryPreAcceptReply
TryPreAcceptOK ==
  \E m \in msgs :
    /\ m.typ = "TryPreAcceptReply"
    /\ ~crashed[m.to]
    /\ LET n == m.to
           curLB == lb[n][m.rr][m.ii]
           ballotMatch == curLB.tryingToPreAccept /\ (m.ballot = curLB.lastTriedBallot)
           isAccept == m.confStatus \in {"ACCEPTED", "COMMITTED", "EXECUTED"}
           okReply == m.confRep = -1
           reps1 == curLB.tpaReps + 1
           oks1 == IF okReply THEN curLB.preAcceptOKs + 1 ELSE curLB.preAcceptOKs
           quorum == oks1 + 1 > (Cardinality(Replicas) \div 2)
       IN
         /\ msgs' = msgs \ {m}
         /\ lb' =
              IF ~ballotMatch
              THEN lb
              ELSE [lb EXCEPT ![n][m.rr][m.ii] =
                     [ @ EXCEPT
                       !.tpaReps = reps1,
                       !.preAcceptOKs = oks1,
                       !.tpaAccepted = @ \/ isAccept,
                       !.tryingToPreAccept = IF quorum THEN FALSE ELSE @,
                       !.status = IF quorum THEN "ACCEPTED" ELSE @ ] ]
         /\ pendingRecoveryAccept' =
              IF ballotMatch /\ quorum
              THEN pendingRecoveryAccept \cup {Slot(n, m.rr, m.ii)}
              ELSE pendingRecoveryAccept
         /\ deferredPairs' =
              IF ballotMatch /\ ~okReply /\ m.confRep # -1 /\ m.confInst \in Instances
              THEN deferredPairs \cup { <<Slot(n, m.confRep, m.confInst), Slot(n, m.rr, m.ii)>> }
              ELSE deferredPairs
         /\ UNCHANGED <<inst, crtInstance, committedUpTo, execedUpTo, conflictsLast, conflictsLastWrite,
                       maxSeqPerKey, maxSeqSeen, maxRecvBallot, isLeader, proposedByClient, cmdCatalog,
                       serializedPairs, commitSeen, commitSnapshot, executedOrder, pendingFastPath,
                       stableMeta, crashed, members>>

\* recovery accept broadcast: artifact/epaxos/epaxos/epaxos.go:1354-1366 and 1492-1502
RecoveryAccept ==
  \E s \in pendingRecoveryAccept :
    /\ ~crashed[s.n]
    /\ LET n == s.n
           rr == s.r
           ii == s.i
           b == lb[n][rr][ii].lastTriedBallot
           seq == lb[n][rr][ii].seq
           deps == lb[n][rr][ii].deps
           cmd == inst[n][rr][ii].cmd
       IN
         /\ inst' = [inst EXCEPT ![n][rr][ii] = [@ EXCEPT !.status = "ACCEPTED", !.bal = b, !.vbal = b, !.seq = seq, !.deps = deps ]]
         /\ lb' = [lb EXCEPT ![n][rr][ii].status = "ACCEPTED", ![n][rr][ii].acceptOKs = 0, ![n][rr][ii].tryingToPreAccept = FALSE]
         /\ msgs' = msgs \cup { [MkMsg("Accept", n, q, rr, ii, b, b, seq, deps, cmd, "ACCEPTED", committedUpTo[n], -1, -1, "NONE") EXCEPT !.cmds = inst[n][rr][ii].cmds] : q \in members \ {n} }
         /\ pendingRecoveryAccept' = pendingRecoveryAccept \ {s}
         /\ deferredPairs' = deferredPairs
         /\ pendingFastPath' = pendingFastPath
         /\ crtInstance' = crtInstance
         /\ committedUpTo' = committedUpTo
         /\ execedUpTo' = execedUpTo
         /\ conflictsLast' = conflictsLast
         /\ conflictsLastWrite' = conflictsLastWrite
         /\ maxSeqPerKey' = maxSeqPerKey
         /\ maxSeqSeen' = maxSeqSeen
         /\ maxRecvBallot' = maxRecvBallot
         /\ isLeader' = isLeader
         /\ proposedByClient' = proposedByClient
         /\ cmdCatalog' = cmdCatalog
         /\ serializedPairs' = serializedPairs
         /\ stableMeta' = [stableMeta EXCEPT ![n][rr][ii] = [bal |-> b, vbal |-> b, status |-> "ACCEPTED", seq |-> seq, deps |-> deps]]
         /\ crashed' = crashed
         /\ members' = members
         /\ commitSeen' = commitSeen
         /\ commitSnapshot' = commitSnapshot
         /\ executedOrder' = executedOrder

\* message loss / network nondeterminism
LoseMessage ==
  \E m \in msgs :
    /\ msgs' = msgs \ {m}
    /\ UNCHANGED <<inst, lb, crtInstance, committedUpTo, execedUpTo, conflictsLast, conflictsLastWrite,
                   maxSeqPerKey, maxSeqSeen, maxRecvBallot, isLeader, proposedByClient, cmdCatalog,
                   serializedPairs, commitSeen, commitSnapshot, executedOrder, pendingFastPath,
                   pendingRecoveryAccept, deferredPairs, stableMeta, crashed, members>>

\* crash/restart around stable metadata (recordInstanceMetadata bug): artifact/epaxos/epaxos/epaxos.go:199-215
Crash ==
  \E n \in Replicas :
    /\ ~crashed[n]
    /\ crashed' = [crashed EXCEPT ![n] = TRUE]
    \* model durable encoding bug: persisted bal bytes are overwritten by vbal bytes
    /\ stableMeta' = [stableMeta EXCEPT ![n] =
          [r \in Replicas |-> [i \in Instances |->
            [ stableMeta[n][r][i] EXCEPT
              !.bal = stableMeta[n][r][i].vbal ] ] ]]
    /\ UNCHANGED <<inst, lb, crtInstance, committedUpTo, execedUpTo, conflictsLast, conflictsLastWrite,
                   maxSeqPerKey, maxSeqSeen, maxRecvBallot, isLeader, msgs, proposedByClient, cmdCatalog,
                   serializedPairs, commitSeen, commitSnapshot, executedOrder, pendingFastPath,
                   pendingRecoveryAccept, deferredPairs, members>>

Restart ==
  \E n \in Replicas :
    /\ crashed[n]
    /\ crashed' = [crashed EXCEPT ![n] = FALSE]
    /\ inst' = [inst EXCEPT ![n] =
          [r \in Replicas |-> [i \in Instances |->
            [ inst[n][r][i] EXCEPT
              !.bal = stableMeta[n][r][i].bal,
              !.vbal = stableMeta[n][r][i].vbal,
              !.status = stableMeta[n][r][i].status,
              !.seq = stableMeta[n][r][i].seq,
              !.deps = stableMeta[n][r][i].deps ] ] ]]
    /\ UNCHANGED <<lb, crtInstance, committedUpTo, execedUpTo, conflictsLast, conflictsLastWrite,
                   maxSeqPerKey, maxSeqSeen, maxRecvBallot, isLeader, msgs, proposedByClient, cmdCatalog,
                   serializedPairs, commitSeen, commitSnapshot, executedOrder, pendingFastPath,
                   pendingRecoveryAccept, deferredPairs, stableMeta, members>>

Next ==
  \/ ClientRequest
  \/ ClientRequestBatch
  \/ ClientSubmit
  \/ PreAccept
  \/ PreAcceptOK
  \/ FastPathCommit
  \/ Accept
  \/ AcceptOK
  \/ Commit
  \/ Execute
  \/ Prepare
  \/ Join
  \/ PrepareOK
  \/ TryPreAccept
  \/ TryPreAcceptReply
  \/ TryPreAcceptOK
  \/ RecoveryAccept
  \/ LoseMessage
  \/ Crash
  \/ Restart

\* Nontriviality (invariants.md:1)
Nontriviality ==
  \A n \in Replicas, r \in Replicas, i \in Instances :
    CommittedAt(n, r, i) => inst[n][r][i].origin = "client"

\* Stability (invariants.md:3)
Stability ==
  \A n \in Replicas, r \in Replicas, i \in Instances :
    commitSeen[n][r][i] => CommittedAt(n, r, i) /\ inst[n][r][i].cmds = commitSnapshot[n][r][i]

\* Consistency (invariants.md:5)
Consistency ==
  \A n1 \in Replicas, n2 \in Replicas, r \in Replicas, i \in Instances :
    (CommittedAt(n1, r, i) /\ CommittedAt(n2, r, i)) => inst[n1][r][i].cmds = inst[n2][r][i].cmds

\* expected-correctness checker for Family 3; should fail under implementation bug
TryPreAcceptConflictStatusPropagated ==
  \A m \in msgs :
    (m.typ = "TryPreAcceptReply" /\ m.confRep # -1) => m.confStatus # "NONE"

ExecConsistency ==
  \A n1 \in Replicas, n2 \in Replicas, c1 \in 1..MaxCmdId, c2 \in 1..MaxCmdId :
    c1 # c2 /\ CmdConflict(cmdCatalog[c1], cmdCatalog[c2]) /\
    SeqContains(executedOrder[n1], c1) /\ SeqContains(executedOrder[n1], c2) /\
    SeqContains(executedOrder[n2], c1) /\ SeqContains(executedOrder[n2], c2)
      => (Before(executedOrder[n1], c1, c2) <=> Before(executedOrder[n2], c1, c2))

ExecLinearizability ==
  \A p \in serializedPairs, n \in Replicas :
    LET c1 == p[1]
        c2 == p[2]
    IN SeqContains(executedOrder[n], c1) /\ SeqContains(executedOrder[n], c2)
         => Before(executedOrder[n], c1, c2)

Spec == Init /\ [][Next]_vars

THEOREM Spec => []TypeOK

====
