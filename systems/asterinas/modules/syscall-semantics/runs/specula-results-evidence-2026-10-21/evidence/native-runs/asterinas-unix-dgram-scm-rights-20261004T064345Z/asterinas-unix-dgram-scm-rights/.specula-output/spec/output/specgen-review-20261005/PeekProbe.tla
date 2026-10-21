---- MODULE PeekProbe ----
EXTENDS base

OneOp == <<CHOOSE t \in Threads : TRUE, 1>>
ProbeNext ==
    \/ SendBegin(TRUE)
    \/ SendStep
    \/ RecvBegin(OneOp, "Peek", "Full", TRUE)
    \/ RecvStep(OneOp)
ProbeSpec == Init /\ [][ProbeNext]_vars

\* Deliberately replace PEEK's clone by a move and consume, while retaining
\* the original observer assignments. This tests the invariant's independence.
MutantGenerateControlPeek(o) ==
    /\ rx[o].pc = "GeneratePeek" /\ queue.lock = o
    /\ rx' = [rx EXCEPT ![o].temp = queue.rights, ![o].generated = TRUE,
               ![o].generatedObjects = queue.rights, ![o].pc = "Unlock",
               ![o].peekBefore = queue.rights, ![o].peekAfter = queue.rights,
               ![o].peekMessageBefore = queue.msg, ![o].peekMessageAfter = queue.msg]
    /\ queue' = [queue EXCEPT !.msg = NoMessage, !.rights = <<>>,
                             !.consumed = @ + 1]
    /\ UNCHANGED <<send, tableVars, refBalance, environmentVars>>

\* This restricted driver never runs an ordinary receive or disposal.
ActualPeekRetention ==
    rx[OneOp].generated =>
        (queue.msg = Message /\ queue.rights = send.capturedObjects)
====

