---- MODULE MC ----
EXTENDS base

CONSTANTS MaxClientReq, MaxCrash, MaxRestart, MaxLose, MaxPrepare, MaxMsgs, MaxDepth

ASSUME /\ MaxClientReq \in Nat
       /\ MaxCrash \in Nat
       /\ MaxRestart \in Nat
       /\ MaxLose \in Nat
       /\ MaxPrepare \in Nat
       /\ MaxMsgs \in Nat
       /\ MaxDepth \in Nat

VARIABLES faultCounts, depth, crashBalFloor

faultVars == <<faultCounts, depth, crashBalFloor>>
mcVars == <<vars, faultCounts, depth, crashBalFloor>>

MCInit ==
  /\ Init
  /\ faultCounts = [clientReq |-> 0, crash |-> 0, restart |-> 0, lose |-> 0, prepare |-> 0]
  /\ depth = 0
  /\ crashBalFloor = [n \in Replicas |-> [r \in Replicas |-> [i \in Instances |-> 0]]]

MCClientRequest ==
  /\ faultCounts.clientReq < MaxClientReq
  /\ ClientRequest
  /\ faultCounts' = [faultCounts EXCEPT !.clientReq = @ + 1]
  /\ depth' = depth + 1
  /\ crashBalFloor' = crashBalFloor

MCCrash ==
  /\ faultCounts.crash < MaxCrash
  /\ Crash
  /\ \E n \in Replicas :
       /\ ~crashed[n]
       /\ crashed'[n]
       /\ crashBalFloor' = [crashBalFloor EXCEPT ![n] = [r \in Replicas |-> [i \in Instances |-> inst[n][r][i].bal]]]
  /\ faultCounts' = [faultCounts EXCEPT !.crash = @ + 1]
  /\ depth' = depth + 1

MCRestart ==
  /\ faultCounts.restart < MaxRestart
  /\ Restart
  /\ faultCounts' = [faultCounts EXCEPT !.restart = @ + 1]
  /\ depth' = depth + 1
  /\ crashBalFloor' = crashBalFloor

MCLoseMessage ==
  /\ faultCounts.lose < MaxLose
  /\ LoseMessage
  /\ faultCounts' = [faultCounts EXCEPT !.lose = @ + 1]
  /\ depth' = depth + 1
  /\ crashBalFloor' = crashBalFloor

MCPrepare ==
  /\ faultCounts.prepare < MaxPrepare
  /\ Prepare
  /\ faultCounts' = [faultCounts EXCEPT !.prepare = @ + 1]
  /\ depth' = depth + 1
  /\ crashBalFloor' = crashBalFloor

MCReactive ==
  /\ depth < MaxDepth
  /\ \/ PreAccept
     \/ PreAcceptOK
     \/ FastPathCommit
     \/ Accept
     \/ AcceptOK
     \/ Commit
     \/ Execute
     \/ Join
     \/ PrepareOK
     \/ TryPreAccept
     \/ TryPreAcceptReply
     \/ TryPreAcceptOK
     \/ RecoveryAccept
  /\ UNCHANGED faultCounts
  /\ depth' = depth + 1
  /\ crashBalFloor' = crashBalFloor

MCNext ==
  /\ depth < MaxDepth
  /\ \/ MCClientRequest
     \/ MCCrash
     \/ MCRestart
     \/ MCLoseMessage
     \/ MCPrepare
     \/ MCReactive

MessageBound == Cardinality(msgs) <= MaxMsgs
DepthBound == depth <= MaxDepth
MCTypeOK ==
  /\ TypeOK
  /\ depth \in 0..MaxDepth
  /\ crashBalFloor \in [Replicas -> [Replicas -> [Instances -> 0..MaxBallot]]]

\* expected-correctness checker for Family 5; should fail under persisted bal overwrite
CrashRecoveryBallotMonotonicity ==
  \A n \in Replicas, r \in Replicas, i \in Instances :
    ~crashed[n] => inst[n][r][i].bal >= crashBalFloor[n][r][i]

MCSpec == MCInit /\ [][MCNext]_mcVars

====
