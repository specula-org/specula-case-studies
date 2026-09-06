------------------------------- MODULE MC -------------------------------
EXTENDS base
\* Brief 3.1 baseline assurance only; all caller contracts remain in force.
\* No pre-fix guards, filesystem loss, reused nonces, or singleton schedules.
CONSTANTS RequestLimit, IdleLimit, ClientIdleLimit, CrashLimit,
          LoseLimit, DuplicateLimit, MaxView, MaxMessages
VARIABLE faults
mcvars == <<vars,faults>>

\* Configuration overrides refer to this unmodified instance to avoid recursion.
B == INSTANCE base
MCClientOnRequest(c,op) ==
    /\ faults.request < RequestLimit /\ B!ClientOnRequest(c,op)
    /\ faults'=[faults EXCEPT !.request=@+1]
MCOnIdle(i) ==
    /\ faults.idle < IdleLimit /\ B!OnIdle(i)
    /\ faults'=[faults EXCEPT !.idle=@+1]
MCClientOnIdle(c) ==
    /\ faults.retry < ClientIdleLimit /\ B!ClientOnIdle(c)
    /\ faults'=[faults EXCEPT !.retry=@+1]
MCCrash(i) ==
    /\ faults.crash < CrashLimit /\ B!Crash(i)
    /\ faults'=[faults EXCEPT !.crash=@+1]
MCLose(m) ==
    /\ faults.lose < LoseLimit /\ B!Lose(m)
    /\ faults'=[faults EXCEPT !.lose=@+1]
MCDuplicate(m) ==
    /\ faults.duplicate < DuplicateLimit /\ B!Duplicate(m)
    /\ faults'=[faults EXCEPT !.duplicate=@+1]

MCInit == Init /\ faults=[request |-> 0,idle |-> 0,retry |-> 0,
                          crash |-> 0,lose |-> 0,duplicate |-> 0]
MCNext ==
    \* Reactive handlers and recovery completion have NO counter gates.
    \/ /\ \E i \in Servers,m \in DOMAIN network : OnMessage(i,m)
       /\ UNCHANGED faults
    \/ /\ \E c \in Clients,m \in DOMAIN network : ClientOnReply(c,m)
       /\ UNCHANGED faults
    \* A fresh restart is possible after each bounded crash. This is finite
    \* without an additional recovery gate; old authentic messages survive.
    \/ /\ \E i \in Servers : Recover(i,incarnations[i]+1)
       /\ UNCHANGED faults
    \/ \E c \in Clients,op \in Operations : ClientOnRequest(c,op)
    \/ \E c \in Clients : ClientOnIdle(c)
    \/ \E i \in Servers : OnIdle(i) \/ Crash(i)
    \/ \E m \in DOMAIN network : Lose(m) \/ Duplicate(m)
MCSpec == MCInit /\ [][MCNext]_mcvars

\* Replica IDs cannot be freely permuted: Primary(view)=view mod N and Rust's
\* BTreeMap tie-break use their concrete order. Only client model values may
\* be renamed. Keep counters in TLC's state identity (they affect enabledness).
MCSymmetry == Permutations(Clients)
MCView == <<vars,faults>>
RECURSIVE BagSize(_)
BagSize(b) == IF DOMAIN b={} THEN 0
             ELSE LET m == CHOOSE x \in DOMAIN b : TRUE
                  IN b[m]+BagSize(Remove(b,{m}))
MCConstraint ==
    /\ BagSize(network)<=MaxMessages
    /\ \A i \in Servers : replicas[i].view<=MaxView /\ durableView[i]<=MaxView
MCTypeOK ==
    /\ TypeOK
    /\ faults \in [request : 0..RequestLimit, idle : 0..IdleLimit,
                    retry : 0..ClientIdleLimit, crash : 0..CrashLimit,
                    lose : 0..LoseLimit, duplicate : 0..DuplicateLimit]

\* A temporal formulation of the intended client progress contract. It is
\* deliberately NOT enabled: bounded callback budgets and a lossy asynchronous
\* network provide neither eventual stability nor fair retries/delivery.
\* Enabling this without an assumption-satisfying stabilization witness would
\* diagnose the finite search environment, not a library progress defect.
ClientProgress == \A c \in Clients :
    (clients[c].pending /= <<>>) ~> (clients[c].pending = <<>>)
=============================================================================
