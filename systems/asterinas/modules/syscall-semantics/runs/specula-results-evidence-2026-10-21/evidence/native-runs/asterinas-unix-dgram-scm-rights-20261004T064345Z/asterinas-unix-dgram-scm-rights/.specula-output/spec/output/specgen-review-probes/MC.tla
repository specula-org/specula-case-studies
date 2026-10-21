---- MODULE MC ----
EXTENDS base

\* Bounds apply to pre-call fixture choices, not source reactions.
\* Source anchors for each transition are in base.tla. No faulty ordering is
\* injected: the installation/copy window is the pinned implementation itself.
CONSTANTS AllowedLayouts, SendFaultLimit, PayloadFaultLimit, OutputFaultLimit,
          PeekLimit, RecvLimit, ReuseLimit
VARIABLE budget
mcVars == <<vars, budget>>

MCInit ==
    /\ Init
    /\ budget = [sendFault |-> 0, payloadFault |-> 0, outputFault |-> 0,
                 peek |-> 0, recv |-> 0, reuse |-> 0]

\* SCM-14: datagram/message.rs:81. The buffer is fixed before SendBegin.
MCSendBegin(good) ==
    /\ (~good => budget.sendFault < SendFaultLimit)
    /\ SendBegin(good)
    /\ budget' = [budget EXCEPT !.sendFault = @ + IF good THEN 0 ELSE 1]

\* S2/S3/S4: request/fault setup before syscall/recvmsg.rs:20-33.
\* Every limit is both checked and advanced on this very transition.
MCRecvBegin(o, mode, name, good) ==
    /\ name \in AllowedLayouts
    /\ (~good => budget.payloadFault < PayloadFaultLimit)
    /\ (OutputFault(Layout(name)) => budget.outputFault < OutputFaultLimit)
    /\ IF mode = "Peek" THEN budget.peek < PeekLimit ELSE budget.recv < RecvLimit
    /\ RecvBegin(o, mode, name, good)
    /\ budget' = [budget EXCEPT
         !.payloadFault = @ + IF good THEN 0 ELSE 1,
         !.outputFault = @ + IF OutputFault(Layout(name)) THEN 1 ELSE 0,
         !.peek = @ + IF mode = "Peek" THEN 1 ELSE 0,
         !.recv = @ + IF mode = "Recv" THEN 1 ELSE 0]

\* S1: controlled post-send reuse at syscall/dup.rs:77-82.
MCSenderReuse ==
    /\ budget.reuse < ReuseLimit /\ SenderReuse
    /\ budget' = [budget EXCEPT !.reuse = @ + 1]

MCNext ==
    \/ \E good \in BOOLEAN : MCSendBegin(good)
    \/ \E o \in Ops, mode \in {"Recv", "Peek"}, name \in AllowedLayouts,
          good \in BOOLEAN : MCRecvBegin(o, mode, name, good)
    \/ MCSenderReuse
    \/ /\ RequestCleanup \/ ReactiveNext
       /\ UNCHANGED budget

MCSpec == MCInit /\ [][MCNext]_mcVars
MCFairness ==
    /\ WF_mcVars(SendStep /\ UNCHANGED budget)
    /\ \A o \in Ops : WF_mcVars(RecvStep(o) /\ UNCHANGED budget)
    /\ WF_mcVars(DisposeStep /\ UNCHANGED budget)
    /\ \A s \in Slots :
        WF_mcVars(cleanupRequested /\ FileTableCloseFile(s) /\ UNCHANGED budget) /\
        WF_mcVars(ClosedFileDrop(s) /\ UNCHANGED budget)
MCLiveSpec == MCSpec /\ MCFairness

\* Receiver identities are interchangeable. Attempt indices, object identities
\* and FD numbers are not. Liveness configs deliberately omit symmetry.
Symmetry == Permutations(Threads)
\* Counters stay in the view because they determine remaining fault budgets.
MCView == mcVars
\* There is only one message slot. This redundant constraint is not a queue
\* capacity shortcut and does not exclude any valid fault/publication state.
MessageBufferConstraint == Cardinality({queue.msg} \ {NoMessage}) <= 1
MCTypeOK ==
    /\ TypeOK
    /\ AllowedLayouts \subseteq LayoutNames /\ AllowedLayouts /= {}
    /\ budget \in [sendFault : 0..SendFaultLimit,
                   payloadFault : 0..PayloadFaultLimit,
                   outputFault : 0..OutputFaultLimit,
                   peek : 0..PeekLimit, recv : 0..RecvLimit,
                   reuse : 0..ReuseLimit]
    /\ PeekLimit <= 2 /\ RecvLimit <= 2

\* All brief section 5 operators are inherited from base, without redefining
\* their truth conditions. Hunt cfgs enable them by their original names.
====
