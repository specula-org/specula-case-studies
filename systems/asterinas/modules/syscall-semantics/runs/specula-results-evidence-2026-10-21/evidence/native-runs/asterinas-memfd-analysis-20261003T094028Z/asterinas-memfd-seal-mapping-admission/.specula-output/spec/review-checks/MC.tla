------------------------------- MODULE MC -------------------------------
EXTENDS base
CONSTANT Scenario

\* Only the external workload is bounded. InternalStep passes through every
\* source step, including failed RMWs, splits, merges and flush completion.
\* There is no injected stale read, weakened lock, early drop or lost IPI.
\* Round numbers are harness barriers, not implementation guards. Requests
\* in one round can overlap at every base action boundary.
Step(round,request) == [round |-> round, request |-> request]
Schedules(a,b) == {[t \in Threads |-> IF t = u THEN a ELSE b] : u \in Threads}

TV1aPlans == Schedules(
    <<Step(2,MapReq(0,1,0,"rw",TRUE,{"R"},FALSE))>>,
    <<Step(1,AddReq({"WRITE"}))>>)
TV1bPlans == Schedules(
    <<Step(2,MapReq(0,1,0,"rw",TRUE,{"R"},FALSE))>>,
    <<Step(1,AddReq({"FUTURE"})),Step(3,AddReq({"WRITE"}))>>)
TV2Plans == UNION {Schedules(
    <<Step(1,MapReq(0,3,0,"rw",TRUE,{"R","W"},FALSE)),
      Step(3,MapReq(l,h,l,"rw",TRUE,{"R","W"},TRUE))>>,
    <<Step(2,AddReq({"FUTURE"})),Step(4,AddReq({"WRITE"})),Step(5,GetReq)>>)
    : <<l,h>> \in {<<0,3>>,<<1,2>>}}

\* Scenario 1 includes actual O_RDONLY and private controls, post-seal WRITE
\* rejection, and an attempted shared WRITE upgrade after successful READ.
AdmissionPlans == TV1aPlans \cup TV1bPlans \cup UNION {Schedules(
    <<Step(2,MapReq(0,1,0,f,sh,p,FALSE)),
      Step(3,ProtectReq(0,1,{"R","W"})),Step(4,UnmapReq(0,1))>>,
    <<Step(1,AddReq(bits)),Step(5,AddReq({"WRITE"})),Step(6,GetReq)>>)
    : f \in Files, sh \in BOOLEAN, p \in {{"R"},{"R","W"}},
      bits \in {{"WRITE"},{"FUTURE"},{"SEAL"}}}

\* Scenario 2 races admission with seal publication and protects retained
\* eligibility afterward. Combined busy requests must publish no new bits.
SealingPlans == UNION {Schedules(
    <<Step(1,MapReq(0,2,0,"rw",TRUE,p,FALSE)),
      Step(2,ProtectReq(0,2,{"R","W"})),
      Step(3,ProtectReq(0,2,{"R"})),Step(4,UnmapReq(0,2))>>,
    <<Step(1,AddReq(bits)),Step(2,GetReq),Step(3,AddReq({"WRITE","SEAL"})),
      Step(5,AddReq({"WRITE","SEAL"})),Step(6,AddReq({})),Step(7,GetReq)>>)
    : p \in {{"R"},{"R","W"}},
      bits \in {{"FUTURE"},{"WRITE"},{"SEAL"},{"FUTURE","SEAL"}}}

\* Scenario 3 has three pages, two splits, a remerge, partial removal and
\* removal of the final eligible owner. Cached WRITE is populated first.
LifecyclePlans == Schedules(
    <<Step(1,MapReq(0,3,0,"rw",TRUE,{"R","W"},FALSE)),
      Step(2,FaultReq(0,{"R","W"})),Step(2,FaultReq(1,{"R","W"})),
      Step(2,FaultReq(2,{"R","W"})),Step(3,ProtectReq(1,2,{"R"})),
      Step(4,ProtectReq(1,2,{"R","W"})),Step(5,UnmapReq(1,2)),
      Step(6,UnmapReq(0,1)),Step(7,UnmapReq(2,3))>>,
    <<Step(3,AddReq({"FUTURE"})),Step(4,AddReq({"WRITE"})),
      Step(5,AddReq({"WRITE"})),Step(6,AddReq({"WRITE"})),
      Step(7,AddReq({"WRITE"})),Step(8,AddReq({"WRITE"})),Step(9,GetReq)>>)
MergeControlPlans == UNION {Schedules(
    <<Step(1,MapReq(0,1,0,"rw",TRUE,{"R"},FALSE)),
      Step(2,MapReq(1,2,off,f,TRUE,{"R"},FALSE)),
      Step(3,ProtectReq(0,2,{"R","W"})),Step(5,UnmapReq(0,2))>>,
    <<Step(4,AddReq({"WRITE"})),Step(6,AddReq({"WRITE"}))>>)
    : off \in {1,2}, f \in Files}

\* Scenario 4 separates EACCES at an ineligible segment, ENOMEM at a hole,
\* and the permitted changed prefix. The fixed conflict has its own plan.
PrefixPlans == Schedules(
    <<Step(1,MapReq(0,1,0,"rw",TRUE,{"R"},FALSE)),
      Step(2,MapReq(1,2,1,"ro",TRUE,{"R"},FALSE)),
      Step(3,ProtectReq(0,2,{"R","W"})),Step(5,UnmapReq(0,2))>>,
    <<Step(4,AddReq({"WRITE","FUTURE","SEAL"})),Step(6,GetReq)>>)
HolePlans == Schedules(
    <<Step(1,MapReq(0,1,0,"rw",TRUE,{"R"},FALSE)),
      Step(2,MapReq(2,3,2,"rw",TRUE,{"R"},FALSE)),
      Step(3,ProtectReq(0,3,{"R","W"})),Step(4,UnmapReq(0,3))>>,
    <<Step(5,AddReq({"WRITE"}))>>)

AllPlans == AdmissionPlans \cup SealingPlans \cup LifecyclePlans
            \cup MergeControlPlans \cup PrefixPlans \cup HolePlans \cup TV2Plans
Plans == CASE Scenario = "standard" -> AllPlans
    [] Scenario = "scenario1" -> AdmissionPlans
    [] Scenario = "scenario2" -> SealingPlans
    [] Scenario = "scenario3" -> LifecyclePlans \cup MergeControlPlans
    [] Scenario = "scenario4" -> PrefixPlans \cup HolePlans \cup TV2Plans
    [] Scenario = "TV1a" -> TV1aPlans
    [] Scenario = "TV1b" -> TV1bPlans
    [] Scenario = "TV2" -> TV2Plans

VARIABLES plan, issued
mcVars == <<s,plan,issued>>
Completed(t) == IF s.call[t].pc = "idle" THEN issued[t] ELSE issued[t]-1
Ready(t) ==
    LET step == plan[t][issued[t]+1] IN
    \A u \in Threads : \A i \in 1..Len(plan[u]) :
        plan[u][i].round < step.round => Completed(u) >= i

\* The counter guard and increment occur on the same request transition.
\* This bounds client requests only. No normal operation is cut off midway.
MCRequest(t) ==
    /\ issued[t] < Len(plan[t]) /\ Ready(t)
    /\ SyscallEnter(t,plan[t][issued[t]+1].request)
    /\ issued' = [issued EXCEPT ![t] = @+1] /\ UNCHANGED plan
MCInternal(t) == InternalStep(t) /\ UNCHANGED <<plan,issued>>
Finished == \A t \in Threads : issued[t] = Len(plan[t]) /\ s.call[t].pc = "idle"
MCInit == /\ Init /\ plan \in Plans /\ issued = [t \in Threads |-> 0]
MCNext == (\E t \in Threads : MCRequest(t) \/ MCInternal(t))
          \/ (Finished /\ UNCHANGED mcVars)
MCSpec == MCInit /\ [][MCNext]_mcVars

\* Both assignments of worker roles are initial states, so thread symmetry
\* preserves the selected scripts. Owner IDs are canonical reusable slots.
Symmetry == Permutations(Threads)
MCStructural ==
    /\ TypeAndIdentity /\ TrackedOwnershipConservation
    /\ \A t \in Threads : issued[t] \in 0..Len(plan[t])
    /\ Cardinality(Live) <= NumPages+1
\* No VIEW discards driver counters: they determine remaining input choices.
\* No state constraint discards a pending owner, invalidation or failure.
\* No liveness claim is enabled without scheduler/IPI fairness and traces.
=============================================================================
