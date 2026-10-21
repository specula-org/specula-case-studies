------------------------------- MODULE MC -------------------------------
EXTENDS base

\* Source actions stay in base.tla. Only invocation and optional spurious
\* scheduler activity introduce counter-bounded environmental choices.
B == INSTANCE base
CONSTANTS CallLimit, SpuriousLimit, Hunt
ASSUME /\ CallLimit \in Nat \ {0} /\ SpuriousLimit \in Nat
       /\ Hunt \in {"all", "consume", "observe", "wake", "publication", "api"}
VARIABLE budget
mcvars == <<s, budget>>

\* Brief S1-S5. Restrictions select clients, never weaken synchronization.
MCRequests == {r \in ValidRequests :
    CASE Hunt = "consume" -> ~r.nowait
      [] Hunt = "observe" -> ~r.nohang
      [] Hunt = "wake" -> ~r.nowait /\ ~r.nohang
      [] Hunt = "publication" -> ~r.nohang
      [] OTHER -> TRUE}

MCInit == /\ B!Init /\ budget = [requests |-> 0, spurious |-> 0]

\* syscall/wait4.rs:18-36; syscall/waitid.rs:29-43.
MCBegin(t, r) ==
    /\ budget.requests < CallLimit /\ r \in MCRequests
    /\ Hunt /= "wake" \/ s.current[t] = 0
    /\ B!SysWaitBegin(t, r)
    /\ budget' = [budget EXCEPT !.requests = @ + 1]

\* ostd/src/task/scheduler/mod.rs:441-444. No token is invented.
MCSpurious(t) ==
    /\ budget.spurious < SpuriousLimit /\ B!ParkCurrentSpurious(t)
    /\ budget' = [budget EXCEPT !.spurious = @ + 1]

\* Brief S3 fixture: both consuming calls have begun before child release.
\* Only exit initiation is scheduled here. Publication and all notifications
\* remain unbounded reactive transitions.
MCStoreExitCode(v) ==
    /\ Hunt /= "wake" \/ (\A t \in Threads : s.current[t] = 1)
    /\ B!ProcessStoreExitCode(v) /\ UNCHANGED budget
MCExitStep ==
    \/ (\E v \in ExitValues : MCStoreExitCode(v))
    \/ /\ B!ExitReactive /\ UNCHANGED budget
MCThreadStep(t) == /\ B!ThreadStep(t) /\ UNCHANGED budget
MCAcquire(t) == /\ B!TryWaitChildrenLock(t) /\ UNCHANGED budget
MCFirstBegin(t) ==
    /\ s.current[t] = 0
    /\ \E r \in MCRequests : MCBegin(t, r)
MCNext ==
    \/ MCExitStep
    \/ \E t \in Threads : MCThreadStep(t) \/ MCSpurious(t)
                           \/ (\E r \in MCRequests : MCBegin(t, r))

\* Finite client activity, eventual child exit/notification, lock progress,
\* runnable execution, and pending unpark completion are execution assumptions.
\* No fairness is attached to a token appearing or a parked thread resuming.
MCFairSpec ==
    /\ MCInit /\ [][MCNext]_mcvars
    /\ WF_mcvars(MCExitStep)
    /\ \A t \in Threads :
         /\ WF_mcvars(MCFirstBegin(t))
         /\ WF_mcvars(MCThreadStep(t))
         /\ SF_mcvars(MCAcquire(t))

\* Keep budget in the state identity because it changes enabled actions.
\* There is no message buffer. Queue entries are not capped or deduplicated.
\* Do not enable symmetry for temporal checks.
Symmetry == Permutations(Threads)
MCTypeOK == /\ TypeOK
            /\ budget \in [requests : 0..CallLimit, spurious : 0..SpuriousLimit]
            /\ budget.requests = Cardinality(DOMAIN s.calls)

\* Finite instantiations of base's unbounded invocation properties are needed
\* for TLC. No reaction is stopped when an invocation budget is exhausted.
MCBlockingWaitCompletes ==
    \A t \in Threads : \A n \in 1..CallLimit :
       (IF <<t,n>> \in DOMAIN s.calls
        THEN ~s.calls[<<t,n>>].nohang /\ s.zombie ELSE FALSE)
       ~> Completed(<<t,n>>)
MCCompetingConsumersComplete ==
    \A a \in Threads \X (1..CallLimit) :
    \A b \in Threads \X (1..CallLimit) :
       (IF a \in DOMAIN s.calls /\ b \in DOMAIN s.calls
        THEN PairEligible(a,b) ELSE FALSE) ~> PairCompleted(a,b)

=============================================================================
