------------------------------- MODULE MC -------------------------------
EXTENDS base
B == INSTANCE base
CONSTANTS TickLimit, RequestLimit, CrashLimit, LossLimit, DuplicateLimit,
          RetryLimit, PartialLimit, ReadErrorLimit, MaxView, MaxLog,
          MaxNetwork, LiveMode, StableHealthy
VARIABLES faults, tickDue
faultVars == <<faults,tickDue>>
mcvars == <<vars,faultVars>>

\* No fault counters on handler execution, persistence, publication, recovery
\* completion, or sender completion. Each injection checks and increments once.
Bump(k) == /\ faults'=[faults EXCEPT ![k]=@+1] /\ UNCHANGED tickDue

\* Scenario 5 timing contract: after stabilization, drain all available
\* transport and owner output between timer/client-retry/invocation events.
\* This is an explicit synchronous subcase, not arbitrary eventual delivery.
\* No queue can be replenished by idle/retry events while it is being drained.
\* Each healthy replica ticks exactly once per timer round (arbitrary order).
\* This bounds relative clock rates and permits primary heartbeats; mere SF
\* of independent clocks would still allow endless false failure suspicions.
Quiet ==
 /\ \A i \in healthySet:owner[i] \in {"ready","down"}
 /\ network={}
 /\ \A f \in DOMAIN tx:tx[f].stage \in {"complete","admitted","lost"}
EnvReady == phase="faults" \/ Quiet
MCOnIdle(i) ==
 /\ EnvReady
 /\ IF phase="stable"
    THEN /\ i \in tickDue /\ B!OnIdle(i) /\ UNCHANGED faults
         /\ tickDue'=IF tickDue\{i}={} THEN healthySet ELSE tickDue\{i}
    ELSE /\ faults.tick<TickLimit /\ B!OnIdle(i) /\ Bump("tick")
MCCrash(i) ==
 /\ faults.crash<CrashLimit
 /\ (~LiveMode \/ StableHealthy=Server \/ i \notin StableHealthy)
 /\ B!Crash(i) /\ Bump("crash")
MCLoseMessage(m) ==
 /\ faults.loss<LossLimit /\ B!LoseMessage(m) /\ Bump("loss")
MCClientOnRequest(c,op) ==
 /\ EnvReady /\ faults.request<RequestLimit
 \* Reserve new work for the stable phase: at most one fault-prefix call.
 /\ (~LiveMode \/ phase="stable" \/ faults.request<Min(1,RequestLimit-1))
 /\ B!ClientOnRequest(c,op) /\ Bump("request")
MCClientOnIdle(c) ==
 /\ EnvReady
 /\ IF phase="stable" THEN /\ B!ClientOnIdle(c) /\ UNCHANGED faultVars
    ELSE /\ faults.retry<RetryLimit /\ B!ClientOnIdle(c) /\ Bump("retry")
MCPartial(f) ==
 /\ phase="faults" /\ faults.partial<PartialLimit
 /\ B!RunSenderBeginPartial(f) /\ Bump("partial")
MCReadError(f) ==
 /\ phase="faults" /\ faults.readError<ReadErrorLimit
 /\ B!RunPeerAcceptorReadError(f) /\ Bump("readError")
MCDeliver(i,m) == /\ B!ReplicaMessage(i,m,FALSE) /\ UNCHANGED faultVars
MCReply(m) == /\ B!ClientOnReply(m,FALSE) /\ UNCHANGED faultVars
MCDuplicate(m) ==
 /\ phase="faults" /\ faults.duplicate<DuplicateLimit
 /\ (\E i \in Server:B!ReplicaMessage(i,m,TRUE))
 /\ Bump("duplicate")
MCDuplicateReply(m) ==
 /\ phase="faults" /\ faults.duplicate<DuplicateLimit
 /\ B!ClientOnReply(m,TRUE) /\ Bump("duplicate")
MCStabilize ==
 /\ LiveMode /\ B!Stabilize(StableHealthy) /\ UNCHANGED faults
 /\ tickDue'=StableHealthy
MCReactive ==
 /\ \/ \E i \in Server:PersistView(i) \/ PublishOutput(i) \/ Recover(i)
    \/ \E m \in network:DiscardUnavailable(m)
    \/ \E f \in DOMAIN tx:RunSenderComplete(f) \/ RunPeerAcceptorEOF(f)
 /\ UNCHANGED faultVars
MCInit ==
 /\ Init /\ tickDue=Server
 /\ faults=[tick |-> 0,request |-> 0,crash |-> 0,loss |-> 0,
            duplicate |-> 0,retry |-> 0,partial |-> 0,readError |-> 0]
MCNext ==
 \/ MCReactive \/ MCStabilize
 \/ \E i \in Server:OnIdle(i) \/ Crash(i)
 \/ \E i \in Server: \E m \in network:MCDeliver(i,m)
 \/ \E m \in network:MCReply(m) \/ LoseMessage(m) \/ MCDuplicate(m) \/ MCDuplicateReply(m)
 \/ \E c \in Clients:ClientOnIdle(c) \/ (\E op \in Ops:ClientOnRequest(c,op))
 \/ \E f \in DOMAIN tx:RunSenderBeginPartial(f) \/ RunPeerAcceptorReadError(f)

\* The cfg overrides above names; INSTANCE B accesses the original base actions.
\* Do NOT exclude finite fault counters from TLC VIEW: remaining budgets alter
\* future behavior. Using a counter-free VIEW would unsoundly merge states.
MCView == mcvars
\* Replica symmetry is invalid: integer IDs have a fixed round-robin order,
\* tie-breaking, and initial primary 0. Client identities alone are symmetric.
\* Safety cfgs use model values for Clients; trace cfg derives actual IDs.
Symmetry == Permutations(Clients)

StateConstraint ==
 /\ \A i \in Server:replica[i].view<=MaxView /\ Len(replica[i].log)<=MaxLog
 /\ Cardinality(network)<=MaxNetwork
 /\ \A i \in Server:Len(replica[i].messages)+Len(replica[i].replies)<=MaxNetwork
MCTypeOK ==
 /\ TypeOK /\ tickDue \subseteq Server /\ tickDue/={}
 /\ faults \in [tick:0..TickLimit,request:0..RequestLimit,crash:0..CrashLimit,
                 loss:0..LossLimit,duplicate:0..DuplicateLimit,retry:0..RetryLimit,
                 partial:0..PartialLimit,readError:0..ReadErrorLimit]

DeliverFor(i) == \E m \in network:MCDeliver(i,m)
ReplyFor(c) == \E m \in network:m.dst=c /\ MCReply(m)
FinishOwner(i) == /\ (PersistView(i) \/ PublishOutput(i)) /\ UNCHANGED faultVars
RecoverHealthy(i) == /\ i \in healthySet /\ Recover(i) /\ UNCHANGED faultVars
DiscardDown == /\ (\E m \in network:DiscardUnavailable(m)) /\ UNCHANGED faultVars
NewRequest == \E c \in Clients,op \in Ops:ClientOnRequest(c,op)
\* SF timers are needed because Quiet is enabled repeatedly, not continuously.
\* Per-node delivery WF cannot silently starve a queued message under this
\* drain-before-environment schedule: a finite reactive closure must drain.
StableFairness ==
 /\ \A i \in Server:WF_mcvars(FinishOwner(i)) /\ WF_mcvars(DeliverFor(i))
 /\ \A i \in Server:WF_mcvars(RecoverHealthy(i)) /\ SF_mcvars(OnIdle(i))
 /\ \A c \in Clients:WF_mcvars(ReplyFor(c)) /\ SF_mcvars(ClientOnIdle(c))
 /\ WF_mcvars(DiscardDown) /\ SF_mcvars(NewRequest)
MCSpec == MCInit /\ [][MCNext]_mcvars
 /\ IF LiveMode THEN (<> (phase="stable") /\ StableFairness) ELSE TRUE
\* Explicit workload coverage, not an infinite workload theorem.
BoundedNewWorkIsAdmitted == <> (faults.request=RequestLimit)
\* Always enable with liveness hunts. A violation means INCONCLUSIVE BOUNDS,
\* not a vsr-rs defect. The boundary is checked BEFORE pruning successors.
LivenessBoundsNotReached ==
 /\ \A i \in Server:replica[i].view<MaxView /\ Len(replica[i].log)<MaxLog
 /\ Cardinality(network)<MaxNetwork
 /\ \A i \in Server:Len(replica[i].messages)+Len(replica[i].replies)<MaxNetwork
=============================================================================
