------------------------------- MODULE MC -------------------------------
EXTENDS base
B == INSTANCE base
CONSTANTS MaxView, MaxLog, RequestLimit, RequestsPerClient, TickLimit,
          RetryLimit, CrashLimit, PauseLimit, LossLimit, ReplayLimit,
          RetireLimit, MaxNetwork, MaxOutbox, EnforceFailureBudget,
          ServiceMode, DelayTicks, ClockSkew
VARIABLES faults, stabilized, stableCore, serviceNodes, serviceClients,
          messageAge, replyAge, clock, tickBit
faultVars == <<faults>>
envVars == <<stabilized,stableCore,serviceNodes,serviceClients,messageAge,replyAge,clock,tickBit>>
mcVars == <<vars,faultVars,envVars>>
CounterKeys == {"request","tick","retry","crash","pause","loss","replay","retire"}
Limits == [request |-> RequestLimit, tick |-> TickLimit, retry |-> RetryLimit,
           crash |-> CrashLimit, pause |-> PauseLimit, loss |-> LossLimit,
           replay |-> ReplayLimit, retire |-> RetireLimit]
Failed == {i \in Server : life[i]/="Running" \/ r[i].status="Recovering"}
FailureBudgetOK == Cardinality(Failed)<=FailureBudget
FaultRoom(i) == ~EnforceFailureBudget \/ i \in Failed \/ Cardinality(Failed)<FailureBudget
Count(tag) == /\ faults[tag]<Limits[tag] /\ faults'=[faults EXCEPT ![tag]=@+1]
NoCount == UNCHANGED faults

\* S3 explicit, deliberately strong timing envelope. An age unit is ONE idle
\* call at ANY service replica, not simulator lockstep. Message handling,
\* persistence and drain can take arbitrarily many interleaved TLA steps.
\* Their delay is bounded in ticks, with the configured skew between replicas.
Reliable(e) == e.dst \in serviceNodes /\ (e.src \in serviceNodes \/ e.src \in serviceClients)
ReliableReply(e) == e.dst \in serviceClients /\ e.src \in serviceNodes
MinClock(c) == CHOOSE x \in {c[i] : i \in serviceNodes} :
    \A j \in serviceNodes : x<=c[j]
TickAllowed(i) ==
  /\ i \in serviceNodes
  /\ \A j \in serviceNodes :
       phase[j]/="Persist" /\ r[j].out= <<>> /\ r[j].replies= <<>>
  /\ \A c \in serviceClients : clients[c].out= <<>>
  /\ \A e \in DOMAIN messageAge : messageAge[e]<DelayTicks
  /\ \A e \in DOMAIN replyAge : replyAge[e]<DelayTicks
  /\ clock[i]<MinClock(clock)+ClockSkew
\* Reset a content's age when one copy is consumed; with MaxNetwork copies,
\* each occurrence is processed within at most MaxNetwork*DelayTicks ticks.
NextAge(old,oldBag,newBag,ticking,kind) ==
  [e \in {m \in DOMAIN newBag : IF kind="message" THEN Reliable(m) ELSE ReliableReply(m)} |->
    IF e \notin DOMAIN old THEN 0
    ELSE IF e \in DOMAIN oldBag /\ newBag[e]<oldBag[e] THEN 0
    ELSE old[e]+IF ticking THEN 1 ELSE 0]
Schedule(ticker) ==
  /\ UNCHANGED <<stabilized,stableCore,serviceNodes,serviceClients>>
  /\ IF stabilized THEN
       /\ messageAge'=NextAge(messageAge,network,network',ticker \in Server,"message")
       /\ replyAge'=NextAge(replyAge,replyChannel,replyChannel',ticker \in Server,"reply")
       /\ LET c == [j \in Server |-> clock[j]+IF j=ticker THEN 1 ELSE 0]
              low == MinClock(c)
          IN clock'=[j \in Server |-> IF j \in serviceNodes THEN c[j]-low ELSE 0]
       /\ tickBit'=[j \in Server |-> IF j=ticker THEN ~tickBit[j] ELSE tickBit[j]]
     ELSE UNCHANGED <<messageAge,replyAge,clock,tickBit>>

\* Explicit wrappers use the unoverridden INSTANCE; reactive handlers have NO counters.
MCReplicaOnMessage(i,e) == B!ReplicaOnMessage(i,e) /\ NoCount /\ Schedule(Nil)
MCPersistView(i) == B!PersistView(i) /\ NoCount /\ Schedule(Nil)
MCReleaseMessage(i) == B!ReleaseMessage(i) /\ NoCount /\ Schedule(Nil)
MCReleaseReply(i) == B!ReleaseReply(i) /\ NoCount /\ Schedule(Nil)
MCRecover(i) == B!Recover(i) /\ NoCount /\ Schedule(Nil)
MCResume(i) == B!Resume(i) /\ NoCount /\ Schedule(Nil)
MCClientDrain(c) == B!ClientDrain(c) /\ NoCount /\ Schedule(Nil)
MCClientOnReply(c,e) == B!ClientOnReply(c,e) /\ NoCount /\ Schedule(Nil)
\* lib.rs:1233; spontaneous idle injection is bounded in safety exploration.
\* After stabilization it is an unbounded service clock; no exhausted retry quota.
MCReplicaOnIdle(i) ==
  /\ IF stabilized THEN TickAllowed(i) /\ NoCount ELSE Count("tick")
  /\ B!ReplicaOnIdle(i) /\ Schedule(i)
MCClientOnIdle(c) ==
  /\ IF stabilized THEN c \in serviceClients /\ NoCount ELSE Count("retry")
  /\ B!ClientOnIdle(c) /\ Schedule(Nil)
MCClientOnRequest(c,x) ==
  /\ clients[c].next<RequestsPerClient /\ Count("request")
  /\ B!ClientOnRequest(c,x) /\ Schedule(Nil)
MCCrash(i) ==
  /\ ~stabilized /\ FaultRoom(i) /\ Count("crash")
  /\ B!Crash(i) /\ Schedule(Nil)
MCPause(i) ==
  /\ ~stabilized /\ FaultRoom(i) /\ Count("pause")
  /\ B!Pause(i) /\ Schedule(Nil)
MCClientRetire(c) ==
  /\ ~stabilized /\ Count("retire") /\ B!ClientRetire(c) /\ Schedule(Nil)
MCLoseMessage(e) ==
  /\ ~stabilized /\ Count("loss") /\ B!LoseMessage(e) /\ Schedule(Nil)
MCLoseReply(e) ==
  /\ ~stabilized /\ Count("loss") /\ B!LoseReply(e) /\ Schedule(Nil)
MCReplayMessage(e) ==
  /\ ~stabilized /\ Count("replay") /\ B!ReplayMessage(e) /\ Schedule(Nil)
MCReplayReply(e) ==
  /\ ~stabilized /\ Count("replay") /\ B!ReplayReply(e) /\ Schedule(Nil)

\* S3 stabilization does NOT require a Normal replica or a common view.
\* Core is a quorum of running, non-recovering nodes, possibly all ViewChange.
\* Eligible recovery targets include Down nodes; their restart/retry is fair.
Stabilize(core) ==
  /\ ServiceMode /\ ~stabilized /\ core \subseteq Server /\ Cardinality(core)=Quorum
  /\ \A i \in core : life[i]="Running" /\ r[i].status/="Recovering"
  /\ FailureBudgetOK
  /\ stabilized'=TRUE /\ stableCore'=core
  /\ serviceNodes'={i \in Server : life[i]/="Paused"}
  /\ serviceClients'=Clients \ retiredClients
  /\ messageAge'=[e \in DOMAIN network |-> 0]
  /\ replyAge'=[e \in DOMAIN replyChannel |-> 0]
  /\ clock'=[i \in Server |-> 0] /\ tickBit'=[i \in Server |-> FALSE]
  /\ UNCHANGED <<vars,faultVars>>

MCInit ==
  /\ B!Init /\ faults=[k \in CounterKeys |-> 0]
  /\ stabilized=FALSE /\ stableCore={} /\ serviceNodes={} /\ serviceClients={}
  /\ messageAge=EmptyMap /\ replyAge=EmptyMap
  /\ clock=[i \in Server |-> 0] /\ tickBit=[i \in Server |-> FALSE]
\* Each base action in Next is overridden by its wrapper in the cfg. The
\* wrappers call B!Action, keeping original implementation logic accessible.
MCNext == Next \/ (\E core \in SUBSET Server : Stabilize(core))
MCSpec == MCInit /\ [][MCNext]_mcVars

\* Bounds prune states, NEVER guard a received packet or deterministic transition.
\* For temporal checking any pruned boundary discharges the bounded question;
\* BoundHit below prevents reporting a cutoff-induced stall as a protocol bug.
WithinBounds ==
  /\ \A i \in Server : r[i].view<=MaxView /\ Len(r[i].log)<=MaxLog /\
       Len(r[i].out)+Len(r[i].replies)<=MaxOutbox
  /\ \A c \in Clients : Len(clients[c].out)<=MaxOutbox
  /\ BagCardinality(network)+BagCardinality(replyChannel)<=MaxNetwork
HandlerWouldExceed(s) == Len(s.out)+Len(s.replies)>MaxOutbox
PendingNumber(c,q) == IF clients[c].pending=Nil THEN FALSE ELSE clients[c].pending.request=q
BoundHit ==
  \/ \E i \in Server : r[i].view>=MaxView \/ Len(r[i].log)>=MaxLog \/
       Len(r[i].out)+Len(r[i].replies)>=MaxOutbox
  \/ \E i \in Server : Ready(i) /\
       (HandlerWouldExceed(OnIdle(Begin(r[i]),i)) \/
        (\E e \in DOMAIN network : e.dst=i /\ HandlerWouldExceed(OnMessage(Begin(r[i]),i,e))))
  \/ \E c \in Clients : Len(clients[c].out)>MaxOutbox-N
  \/ BagCardinality(network)+BagCardinality(replyChannel)>=MaxNetwork
\* Symmetry only over client model values: replica IDs have arithmetic order.
\* Values and replica IDs MUST NOT be permuted. Do not enable symmetry for liveness.
Symmetry == Permutations(Clients)
\* Available for inspection only; excluding counters from TLC VIEW would merge
\* states with different future fault budgets. All supplied cfgs retain full state.
ProtocolView == vars
MCTypeOK ==
  /\ TypeOK /\ faults \in [CounterKeys -> Nat] /\ stabilized \in BOOLEAN
  /\ stableCore \subseteq serviceNodes /\ serviceNodes \subseteq Server
  /\ serviceClients \subseteq Clients /\ tickBit \in [Server -> BOOLEAN]
  /\ \A k \in CounterKeys : faults[k]<=Limits[k]
MCFailureBudget == EnforceFailureBudget => FailureBudgetOK

\* Conditional liveness, separate from state invariants. Infinite independent
\* ticks plus deadline guards give bounded communication relative to timeouts.
\* This is stronger than fairness alone and weaker than assuming an elected primary.
ClockProgress == \A i \in Server :
  (<>(stabilized /\ i \in serviceNodes)) => ([]<>(tickBit[i]) /\ []<>(~tickBit[i]))
OwnerFairness ==
  /\ \A i \in Server :
       /\ WF_mcVars(MCPersistView(i)) /\ WF_mcVars(MCReleaseMessage(i))
       /\ WF_mcVars(MCReleaseReply(i)) /\ WF_mcVars(MCRecover(i))
  /\ \A c \in Clients : WF_mcVars(MCClientDrain(c)) /\ WF_mcVars(MCClientOnIdle(c))
ServiceAssumptions == <>stabilized /\ ClockProgress /\ OwnerFairness /\ []FailureBudgetOK
RequestEventuallyAnswered ==
  ServiceAssumptions =>
    \A c \in Clients : \A q \in 0..(RequestsPerClient-1) :
      (stabilized /\ c \in serviceClients /\ PendingNumber(c,q))
       ~> (\E e \in acceptedReplies : e.wire.client=c /\ e.wire.request=q /\ ReplyCorrect(e))
RecoveryEventuallyNormal ==
  ServiceAssumptions =>
    \A i \in Server : (stabilized /\ i \in serviceNodes /\
       (life[i]="Down" \/ r[i].status="Recovering"))
      ~> (life[i]="Running" /\ r[i].status="Normal")
\* Honest finite-slice properties. A pass that reaches BoundHit is inconclusive.
\* Check the unqualified formulas above only in a run without state pruning.
MCRequestEventuallyAnswered == (<>BoundHit) \/ RequestEventuallyAnswered
MCRecoveryEventuallyNormal == (<>BoundHit) \/ RecoveryEventuallyNormal
=============================================================================
